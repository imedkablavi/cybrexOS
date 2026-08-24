#!/usr/bin/env python3
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

IMAGE = Path(sys.argv[1] if len(sys.argv) > 1 else "artifacts/CybrexTech_Dev_Preview.vmdk")
REPORT = Path(os.environ.get("RELEASE_VMDK_REPORT", "artifacts/qualification-release-vmdk.txt"))
QEMU_LOG = Path(os.environ.get("RELEASE_VMDK_QEMU_LOG", "artifacts/qualification-release-vmdk-qemu.log"))
BOOT_TIMEOUT = int(os.environ.get("RELEASE_VMDK_TIMEOUT", "240"))
USER = os.environ.get("QUALIFY_USER", "cybrex")
PASSWORD = os.environ.get("QUALIFY_PASSWORD", "cybrex")


def die(message, proc=None, transcript=b""):
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
    write_log(transcript)
    print(f"[release-vmdk] ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def write_log(data: bytes):
    QEMU_LOG.parent.mkdir(parents=True, exist_ok=True)
    scrubbed = data
    if PASSWORD:
        scrubbed = scrubbed.replace(PASSWORD.encode(), b"<redacted>")
    QEMU_LOG.write_bytes(scrubbed)


def send(proc, text: str):
    if proc.stdin is None:
        die("QEMU stdin is unavailable", proc)
    proc.stdin.write(text.encode())
    proc.stdin.flush()


def wait_for(proc, transcript, normalized, pattern, start, timeout, label):
    regex = re.compile(pattern)
    deadline = time.monotonic() + timeout
    fd = proc.stdout.fileno()
    while time.monotonic() < deadline:
        match = regex.search(normalized, start)
        if match:
            return transcript, normalized, match
        if proc.poll() is not None:
            remaining = os.read(fd, 65536) if proc.stdout else b""
            transcript += remaining
            normalized += remaining.replace(b"\r", b"")
            die(f"QEMU exited before {label} (rc={proc.returncode})", proc, transcript)
        ready, _, _ = select.select([fd], [], [], 0.5)
        if ready:
            chunk = os.read(fd, 4096)
            if chunk:
                transcript += chunk
                normalized += chunk.replace(b"\r", b"")
    die(f"timed out waiting for {label}", proc, transcript)


for binary in ("qemu-system-x86_64", "qemu-img"):
    if not shutil.which(binary):
        die(f"{binary} is required")
if not IMAGE.is_file():
    die(f"VMDK not found: {IMAGE}")

check = subprocess.run(
    ["qemu-img", "check", "-f", "vmdk", str(IMAGE)],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)
if check.returncode != 0:
    die("qemu-img check failed: " + check.stdout.strip())

pairs = [
    (Path("/usr/share/OVMF/OVMF_CODE_4M.fd"), Path("/usr/share/OVMF/OVMF_VARS_4M.fd")),
    (Path("/usr/share/OVMF/OVMF_CODE.fd"), Path("/usr/share/OVMF/OVMF_VARS.fd")),
]
ovmf = next(((code, var) for code, var in pairs if code.is_file() and var.is_file()), None)
if ovmf is None:
    die("no supported OVMF CODE/VARS pair found")
code, vars_template = ovmf

REPORT.parent.mkdir(parents=True, exist_ok=True)
QEMU_LOG.parent.mkdir(parents=True, exist_ok=True)
transcript = b""
normalized = b""
markers = []

with tempfile.TemporaryDirectory(prefix="cybrex-vmdk-") as temp:
    vars_copy = Path(temp) / "OVMF_VARS.fd"
    shutil.copyfile(vars_template, vars_copy)
    cmd = [
        "qemu-system-x86_64",
        "-machine", "q35,accel=tcg",
        "-cpu", "max",
        "-m", "1536",
        "-smp", "2",
        "-nodefaults",
        "-device", "virtio-rng-pci",
        "-device", "virtio-blk-pci,drive=osdisk",
        "-drive", f"if=none,id=osdisk,format=vmdk,file={IMAGE},cache=unsafe",
        "-device", "virtio-net-pci,netdev=net0",
        "-netdev", "user,id=net0",
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={vars_copy}",
        "-display", "none",
        "-serial", "stdio",
        "-monitor", "none",
        "-no-reboot",
    ]
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )

    transcript, normalized, _ = wait_for(
        proc, transcript, normalized, rb"login:", 0, BOOT_TIMEOUT, "serial login prompt"
    )
    cursor = len(normalized)
    send(proc, USER + "\n")
    transcript, normalized, _ = wait_for(
        proc, transcript, normalized, rb"Password:", cursor, 30, "login password prompt"
    )
    cursor = len(normalized)
    send(proc, PASSWORD + "\n")
    transcript, normalized, _ = wait_for(
        proc, transcript, normalized, rb"\$ ", cursor, 30, "user shell prompt"
    )

    cursor = len(normalized)
    send(proc, "sudo -S -p 'CYBREX_SUDO:' sh\n")
    transcript, normalized, _ = wait_for(
        proc, transcript, normalized, rb"CYBREX_SUDO:", cursor, 30, "sudo password prompt"
    )
    cursor = len(normalized)
    send(proc, PASSWORD + "\n")
    transcript, normalized, _ = wait_for(
        proc, transcript, normalized, rb"# ", cursor, 30, "root shell prompt"
    )

    checks = (
        "state=$(systemctl is-system-running 2>/dev/null || true); "
        "case \"$state\" in running|degraded) ;; *) echo RELEASE_VMDK:FAIL:systemd:$state; exit 41;; esac; "
        "for svc in systemd-networkd.service systemd-resolved.service nftables.service; do "
        "systemctl is-active --quiet \"$svc\" || { echo RELEASE_VMDK:FAIL:service:$svc; exit 42; }; done; "
        "ip -4 -o addr show scope global | grep -q . || { echo RELEASE_VMDK:FAIL:ipv4; exit 43; }; "
        "ip -4 route show default | grep -q . || { echo RELEASE_VMDK:FAIL:default-route; exit 44; }; "
        "nft list ruleset >/dev/null || { echo RELEASE_VMDK:FAIL:nft-ruleset; exit 45; }; "
        "nft list chain inet cybrex_fw inbound | grep -Eq 'policy[[:space:]]+drop' || { echo RELEASE_VMDK:FAIL:nft-inbound; exit 46; }; "
        "nft list chain inet cybrex_fw outbound | grep -Eq 'policy[[:space:]]+accept' || { echo RELEASE_VMDK:FAIL:nft-outbound; exit 47; }; "
        "failed=$(systemctl --failed --no-legend --plain 2>/dev/null || true); "
        "[ -z \"$failed\" ] || { echo RELEASE_VMDK:FAIL:failed-units; exit 48; }; "
        "echo RELEASE_VMDK:SYSTEMD:$state; echo RELEASE_VMDK:NETWORK:qualified; "
        "echo RELEASE_VMDK:NFTABLES:qualified; echo RELEASE_VMDK:PASS; sync; systemctl poweroff\n"
    )
    cursor = len(normalized)
    send(proc, checks)
    transcript, normalized, match = wait_for(
        proc,
        transcript,
        normalized,
        rb"RELEASE_VMDK:(?:PASS|FAIL:[^\r\n ]+)",
        cursor,
        60,
        "release qualification result",
    )
    result = match.group(0).decode(errors="replace")
    markers.append(result)
    if result != "RELEASE_VMDK:PASS":
        die(f"guest qualification reported {result}", proc, transcript)

    shutdown_deadline = time.monotonic() + 60
    fd = proc.stdout.fileno()
    while proc.poll() is None and time.monotonic() < shutdown_deadline:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if ready:
            chunk = os.read(fd, 4096)
            if chunk:
                transcript += chunk
                normalized += chunk.replace(b"\r", b"")
    if proc.poll() is None:
        die("guest passed checks but did not power off within 60s", proc, transcript)
    if proc.returncode != 0:
        die(f"QEMU exited with code {proc.returncode} after guest poweroff", proc, transcript)

for line in normalized.decode(errors="replace").splitlines():
    if line.startswith("RELEASE_VMDK:"):
        markers.append(line.strip())
# Preserve order while removing duplicates/command-echo noise.
clean = []
for marker in markers:
    marker = marker.strip()
    if marker.startswith("RELEASE_VMDK:") and marker not in clean:
        clean.append(marker)
REPORT.write_text("\n".join(clean) + "\n", encoding="utf-8")
write_log(transcript)
print(REPORT.read_text(encoding="utf-8"), end="")
print("[release-vmdk] PASS")
