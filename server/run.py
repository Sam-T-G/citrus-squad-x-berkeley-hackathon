#!/usr/bin/env python3
"""One-command belt-bridge bring-up.

Does the whole phone -> server -> Arduino setup in one step:
  1. finds this laptop's Wi-Fi IP and prints exactly what to type on the phone,
  2. detects the Arduino serial port (or falls back to mock),
  3. checks the macOS firewall is not going to block the UDP link,
  4. launches the server,
  5. shows a live monitor so you see the moment the phone connects and cues flow.

Run it from the `server/` directory (with the venv active):

    python run.py              # auto-detect the Arduino, fall back to mock
    python run.py --mock       # force mock mode (no Arduino plugged in)
    python run.py --port 8080 --udp-port 9999

Ctrl-C stops the server.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from contextlib import suppress

HERE = os.path.dirname(os.path.abspath(__file__))


# --------------------------------------------------------------------------- #
# Detection
# --------------------------------------------------------------------------- #

def lan_ips() -> list[str]:
    """This laptop's LAN IPv4 address(es), most likely first. The first one is the
    address the phone should aim at when both are on the same Wi-Fi."""
    found: list[str] = []

    # The address used to reach the outside world: the active interface's IP.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    with suppress(Exception):
        s.connect(("8.8.8.8", 80))
        found.append(s.getsockname()[0])
    s.close()

    # macOS Wi-Fi / Ethernet interfaces, in case the route trick picked a VPN.
    for iface in ("en0", "en1"):
        with suppress(Exception):
            ip = subprocess.run(["ipconfig", "getifaddr", iface],
                                capture_output=True, text=True, timeout=2).stdout.strip()
            if ip:
                found.append(ip)

    # De-dup, drop loopback / link-local, keep order.
    out: list[str] = []
    for ip in found:
        if ip and not ip.startswith(("127.", "169.254.")) and ip not in out:
            out.append(ip)
    return out


def detect_serial_port() -> str | None:
    """The Arduino's serial device, or None if none is plugged in. Reuses the server's
    own autodetect so the two never disagree."""
    with suppress(Exception):
        sys.path.insert(0, HERE)
        import app  # noqa: E402  (import here so --mock works without the dep installed)
        return app.autodetect_port()
    return None


def firewall_warning() -> str | None:
    """A one-line warning if the macOS application firewall is on, since it can silently
    drop the inbound UDP. None when there is nothing to worry about."""
    with suppress(Exception):
        out = subprocess.run(
            ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"],
            capture_output=True, text=True, timeout=2).stdout
        if "State = 1" in out or "enabled" in out.lower():
            return ("macOS firewall is ON. If the phone cannot reach the server, allow "
                    "incoming connections for python, or turn it off for the demo: "
                    "System Settings > Network > Firewall.")
    return None


# --------------------------------------------------------------------------- #
# Health polling
# --------------------------------------------------------------------------- #

def health(port: int) -> dict | None:
    with suppress(Exception):
        with urllib.request.urlopen(f"http://localhost:{port}/health", timeout=1) as r:
            return json.load(r)
    return None


def wait_until_up(port: int, timeout_s: float = 15.0) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if health(port) is not None:
            return True
        time.sleep(0.3)
    return False


# --------------------------------------------------------------------------- #
# Pretty output
# --------------------------------------------------------------------------- #

BOLD, DIM, GREEN, YELLOW, CYAN, RED, RESET = (
    "\033[1m", "\033[2m", "\033[32m", "\033[33m", "\033[36m", "\033[31m", "\033[0m")


def banner(ips: list[str], port: int, udp_port: int, serial_port: str | None, mock: bool) -> None:
    primary = ips[0] if ips else "<this laptop's Wi-Fi IP>"
    print()
    print(f"{BOLD}{CYAN}  Citrus Squad belt bridge{RESET}")
    print(f"  {DIM}phone --UDP--> this laptop --USB--> Arduino{RESET}")
    print()
    if mock or not serial_port:
        print(f"  Arduino:   {YELLOW}none detected, running in MOCK mode{RESET} "
              f"{DIM}(commands are logged, not sent){RESET}")
    else:
        print(f"  Arduino:   {GREEN}{serial_port}{RESET}")
    print(f"  Dashboard: {CYAN}http://localhost:{port}{RESET}")
    print()
    print(f"{BOLD}  On the phone (Control Panel > Belt link):{RESET}")
    print(f"    Belt host : {BOLD}{GREEN}{primary}{RESET}")
    print(f"    Port      : {BOLD}{GREEN}{udp_port}{RESET}")
    print(f"    then tap {BOLD}Connect belt{RESET}, and tap {BOLD}Allow{RESET} on the "
          f"Local Network prompt.")
    if len(ips) > 1:
        print(f"    {DIM}(other addresses if that one does not work: {', '.join(ips[1:])}){RESET}")
    fw = firewall_warning()
    if fw:
        print(f"\n  {YELLOW}! {fw}{RESET}")
    print()
    print(f"  {DIM}Waiting for the phone... (Ctrl-C to stop){RESET}")
    print()


def monitor(port: int) -> None:
    """Live one-line readout, plus a loud announcement the first time the phone connects
    and the first time a real cue reaches the belt."""
    announced_phone = False
    announced_cue = False

    while True:
        h = health(port)
        if h is None:
            sys.stdout.write(f"\r  {RED}server not responding...{RESET}            ")
            sys.stdout.flush()
            time.sleep(0.5)
            continue

        src = h.get("last_src")
        # A phone link shows an ip:port source; the test client shows "ws".
        phone_connected = bool(src and src != "ws" and ":" in src)

        if phone_connected and not announced_phone:
            print(f"\r  {GREEN}{BOLD}PHONE CONNECTED{RESET} from {GREEN}{src}{RESET}"
                  f"{' ' * 20}")
            announced_phone = True
        last_cmd = h.get("last_cmd")
        if last_cmd not in (None, "idle") and not announced_cue:
            print(f"  {GREEN}belt is receiving cues (first: {last_cmd}){RESET}"
                  f"{' ' * 20}")
            announced_cue = True

        serial = "mock" if h.get("mock") else ("open" if h.get("serial_open") else "down")
        scolor = YELLOW if h.get("mock") else (GREEN if h.get("serial_open") else RED)
        age = h.get("last_frame_age_s")
        link = f"{GREEN}live{RESET}" if (age is not None and age < 1.0) else f"{DIM}idle{RESET}"
        line = (f"\r  serial:{scolor}{serial}{RESET}  "
                f"link:{link}  "
                f"src:{src or '-'}  "
                f"in:{h.get('frames_in', 0)}  out:{h.get('frames_out', 0)}  "
                f"last:{h.get('last_cmd') or '-'}        ")
        sys.stdout.write(line)
        sys.stdout.flush()
        time.sleep(0.5)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main() -> int:
    ap = argparse.ArgumentParser(description="Belt-bridge one-command bring-up.")
    ap.add_argument("--mock", action="store_true", help="force mock mode (no Arduino)")
    ap.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    ap.add_argument("--udp-port", type=int, default=int(os.environ.get("UDP_PORT", "9999")))
    args = ap.parse_args()

    ips = lan_ips()
    serial_port = None if args.mock else detect_serial_port()

    env = dict(os.environ)
    env["PORT"] = str(args.port)
    env["UDP_PORT"] = str(args.udp_port)
    if args.mock or serial_port is None:
        env["SERIAL_PORT"] = "mock"

    # Launch the server with the same interpreter, quietly (it has its own prints).
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "app.py")], env=env)

    try:
        if not wait_until_up(args.port):
            print(f"{RED}server did not come up on port {args.port}.{RESET} "
                  f"Is the port already in use?")
            proc.terminate()
            return 1
        banner(ips, args.port, args.udp_port, serial_port, args.mock or serial_port is None)
        monitor(args.port)
    except KeyboardInterrupt:
        print(f"\n  {DIM}stopping...{RESET}")
    finally:
        proc.send_signal(signal.SIGINT)
        with suppress(Exception):
            proc.wait(timeout=3)
        if proc.poll() is None:
            proc.terminate()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
