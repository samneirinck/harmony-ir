#!/usr/bin/env python3
import argparse
import hashlib
import ipaddress
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

INSTALLER_DESCRIPTION = "Install the device-side Harmony IR service over owner SSH."
ROOT = Path(__file__).resolve().parent
PAYLOAD = {
    "ir.lua": ROOT / "ir.lua",
    "client.lua": ROOT / "client.lua",
    "http.lua": ROOT / "http.lua",
    "bridge.lua": ROOT / "bridge.lua",
    "server.lua": ROOT / "server.lua",
    "transmit.lua": ROOT / "transmit.lua",
    "capture.lua": ROOT / "capture.lua",
    "diagnose.lua": ROOT / "diagnose.lua",
    "service.sh": ROOT / "scripts/service.sh",
}


def build_remote_script():
    digest = hashlib.sha256()
    lines = ["write_payload() {", '    case "$1" in']
    for name, path in PAYLOAD.items():
        source = path.read_text(encoding="utf-8")
        if not source.endswith("\n"):
            raise ValueError(f"Source must end with a newline: {path}")
        delimiter = "HARMONY_IR_PAYLOAD_" + name.replace(".", "_").upper()
        if delimiter in source.splitlines():
            raise ValueError(f"Heredoc delimiter collision: {path}")
        digest.update(name.encode() + b"\0" + source.encode("utf-8"))
        lines.extend(
            [f"        {name}) cat <<'{delimiter}'", source.rstrip("\n"), delimiter, "        ;;"]
        )
    lines.extend(["        *) return 1 ;;", "    esac", "}"])
    template = (ROOT / "scripts/install.sh").read_text(encoding="utf-8")
    payload_placeholder = "write_payload() { return 1; }"
    if template.count(payload_placeholder) != 1:
        raise ValueError("Invalid remote installer template")
    script = template.replace(payload_placeholder, "\n".join(lines))
    return script.replace("RELEASE_ID='@RELEASE_ID@'", f"RELEASE_ID='{digest.hexdigest()[:20]}'", 1)


def port_number(value):
    number = int(value)
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError("port must be in 1..65535")
    return number


def main():
    parser = argparse.ArgumentParser(description=INSTALLER_DESCRIPTION)
    parser.add_argument(
        "--host", required=True, help="Hub IPv4 address or SSH hostname/alias (without root@)"
    )
    parser.add_argument(
        "--key",
        type=Path,
        help="SSH private key (otherwise use SSH defaults)",
    )
    parser.add_argument("--ssh-port", type=port_number, default=22)
    parser.add_argument(
        "--listen",
        type=ipaddress.IPv4Address,
        help="bridge IPv4 binding; new installs default to 0.0.0.0",
    )
    parser.add_argument(
        "--port", type=port_number, help="bridge port; new installs default to 8089"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="show deployment details without connecting"
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.host):
        parser.error(
            "host must be an IPv4 address or SSH hostname/alias, without user, URL or options"
        )
    if args.port is not None and args.port < 1024:
        parser.error("bridge port must be in 1024..65535")
    key = args.key.expanduser() if args.key is not None else None
    if key is not None and not key.is_file():
        parser.error(f"SSH key does not exist: {key}")
    ssh = shutil.which("ssh")
    if ssh is None:
        parser.error("OpenSSH client 'ssh' is required on this computer")
    try:
        script = build_remote_script().encode("utf-8")
    except (OSError, ValueError) as err:
        parser.error(str(err))
    remote = ["sh", "-s", "--"]
    if args.listen is not None:
        remote.extend(["--listen", str(args.listen)])
    if args.port is not None:
        remote.extend(["--port", str(args.port)])
    command = [ssh, "-T", "-o", "ConnectTimeout=10", "-p", str(args.ssh_port)]
    if key is not None:
        command.extend(["-i", str(key)])
    command.extend([f"root@{args.host}", shlex.join(remote)])
    print(f"Target: root@{args.host}; source: {ROOT}", flush=True)
    print("Deploying current source over SSH; no device downloads or HA installation.", flush=True)
    if args.dry_run:
        print("SSH command (display):", shlex.join(command))
        print(f"Remote installer stream: {len(script)} bytes")
        print("Dry run: no SSH connection or device changes.")
        return 0
    print("Keep Harmony controls idle; stop any unmanaged foreground bridge first.", flush=True)
    try:
        return subprocess.run(command, input=script, check=False).returncode
    except OSError as err:
        print(f"Could not start SSH: {err}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(
            "Interrupted. Check the Hub's service/install status before retrying.", file=sys.stderr
        )
        return 130


if __name__ == "__main__":
    sys.exit(main())
