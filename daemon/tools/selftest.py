#!/usr/bin/env python3
"""Loopback self-test for the NotchSend Phase 0 spike.

Starts two daemons (A = receiver, B = sender) on loopback with distinct
ports/sockets/data dirs, then drives three cases through notchsendctl and a
raw-socket control client on A:

  1. happy path  - send >1MB, driver accepts, SHA-256 must match
  2. reject path - driver rejects, sender must report declined, no file
  3. timeout     - driver stays silent, approval timeout (5s) must fire

Prints PASS/FAIL per assertion and exits non-zero on any failure.
"""
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "target" / "debug"
DAEMON = str(BIN / "notchsendd")
CTL = str(BIN / "notchsendctl")
WORK = ROOT / ".selftest"
PORT_A, PORT_B = 53318, 53319
APPROVAL_TIMEOUT = 5

failures = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}: {name} {detail}", flush=True)
    if not cond:
        failures.append(name)


def sha256_of(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Driver:
    """Persistent control-socket client (stands in for the notch UI)."""

    def __init__(self, sock_path: Path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(sock_path))
        self.buf = b""
        self.messages = []
        self.lock = threading.Lock()
        self.closed = False
        self.thread = threading.Thread(target=self._reader, daemon=True)
        self.thread.start()
        self.send({"type": "hello", "client": "selftest", "ipc_version": 1})

    def _reader(self):
        while not self.closed:
            try:
                data = self.sock.recv(65536)
            except OSError:
                return
            if not data:
                return
            self.buf += data
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if line.strip():
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    with self.lock:
                        self.messages.append(msg)

    def send(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def snapshot_from(self, idx):
        with self.lock:
            return list(self.messages[idx:])

    def mark(self):
        with self.lock:
            return len(self.messages)

    def wait_event(self, event, timeout=20, from_idx=0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for m in self.snapshot_from(from_idx):
                if m.get("type") == "event" and m.get("event") == event:
                    return m
            time.sleep(0.05)
        return None

    def wait_welcome(self, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for m in self.snapshot_from(0):
                if m.get("type") == "welcome":
                    return m
            time.sleep(0.05)
        return None

    def close(self):
        self.closed = True
        try:
            self.sock.close()
        except OSError:
            pass


def start_daemon(name, port, base: Path):
    dl = base / "downloads"
    data = base / "data"
    dl.mkdir(parents=True, exist_ok=True)
    data.mkdir(parents=True, exist_ok=True)
    sock = base / "daemon.sock"
    log = open(base / "daemon.log", "wb")
    proc = subprocess.Popen(
        [
            DAEMON,
            "--alias", name,
            "--port", str(port),
            "--download-dir", str(dl),
            "--data-dir", str(data),
            "--socket-path", str(sock),
            "--approval-timeout-secs", str(APPROVAL_TIMEOUT),
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    deadline = time.time() + 15
    while time.time() < deadline:
        if sock.exists():
            r = subprocess.run(
                [CTL, "--socket", str(sock), "status"],
                capture_output=True, text=True, timeout=10,
            )
            if r.returncode == 0:
                return proc, sock, dl
        if proc.poll() is not None:
            raise RuntimeError(f"daemon {name} exited early, see {base}/daemon.log")
        time.sleep(0.2)
    raise RuntimeError(f"daemon {name} did not come up, see {base}/daemon.log")


def run_ctl_send(sock_b: Path, target: str, fingerprint: str, path: Path):
    """Run `notchsendctl send` in a thread; returns (thread, box)."""
    box = {}

    def _run():
        t0 = time.time()
        r = subprocess.run(
            [CTL, "--socket", str(sock_b), "send", "--to", target,
             "--fingerprint", fingerprint, str(path)],
            capture_output=True, text=True, timeout=120,
        )
        box["rc"] = r.returncode
        box["out"] = r.stdout + r.stderr
        box["elapsed"] = time.time() - t0

    t = threading.Thread(target=_run)
    t.start()
    return t, box


def main():
    if WORK.exists():
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True)
    send_dir = WORK / "tosend"
    send_dir.mkdir()

    daemons = []
    try:
        proc_a, sock_a, dl_a = start_daemon("A", PORT_A, WORK / "a")
        daemons.append(proc_a)
        proc_b, sock_b, _dl_b = start_daemon("B", PORT_B, WORK / "b")
        daemons.append(proc_b)
        check("daemons start", True, f"(A :{PORT_A}, B :{PORT_B})")

        driver = Driver(sock_a)
        welcome = driver.wait_welcome()
        check("driver hello/welcome on A", welcome is not None)
        fp_a = (welcome or {}).get("fingerprint", "")
        check("A fingerprint present", len(fp_a) == 64, f"({fp_a[:16]}...)")
        target = f"127.0.0.1:{PORT_A}"

        # ------------------------------------------------ case 1: happy path
        f1 = send_dir / "test.bin"
        with open(f1, "wb") as fh:
            fh.write(os.urandom(1_500_000))
        sha1 = sha256_of(f1)
        mark = driver.mark()
        t, box = run_ctl_send(sock_b, target, fp_a, f1)
        req = driver.wait_event("incoming_request", timeout=20, from_idx=mark)
        check("case1 incoming_request event", req is not None)
        if req:
            check("case1 request total_size", req.get("total_size") == 1_500_000,
                  f"(got {req.get('total_size')})")
            driver.send({"type": "accept", "id": "t1",
                         "request_id": req["request_id"]})
        t.join(timeout=60)
        check("case1 ctl send exit 0", box.get("rc") == 0,
              f"(rc={box.get('rc')}, out tail: {box.get('out', '')[-200:]!r})")
        landed = dl_a / "test.bin"
        check("case1 file landed in A downloads", landed.exists())
        if landed.exists():
            check("case1 sha256 identical", sha256_of(landed) == sha1)
        events = driver.snapshot_from(mark)
        check("case1 progress events seen",
              any(m.get("event") == "progress" for m in events))
        check("case1 session_completed event seen",
              any(m.get("event") == "session_completed" for m in events))

        # ------------------------------------------------ case 2: reject path
        f2 = send_dir / "test2.bin"
        shutil.copy(f1, f2)
        mark = driver.mark()
        t, box = run_ctl_send(sock_b, target, fp_a, f2)
        req = driver.wait_event("incoming_request", timeout=20, from_idx=mark)
        check("case2 incoming_request event", req is not None)
        if req:
            driver.send({"type": "reject", "id": "t2",
                         "request_id": req["request_id"]})
        t.join(timeout=60)
        check("case2 ctl send failed (rc=3)", box.get("rc") == 3,
              f"(rc={box.get('rc')})")
        check("case2 sender told 'declined'",
              "declined" in box.get("out", "").lower(),
              f"(out tail: {box.get('out', '')[-160:]!r})")
        check("case2 no file in A downloads", not (dl_a / "test2.bin").exists())

        # ------------------------------------------------ case 3: timeout path
        f3 = send_dir / "test3.bin"
        shutil.copy(f1, f3)
        mark = driver.mark()
        t, box = run_ctl_send(sock_b, target, fp_a, f3)
        req = driver.wait_event("incoming_request", timeout=20, from_idx=mark)
        check("case3 incoming_request event", req is not None)
        # Do nothing: the daemon's 5s approval timeout must reject.
        t.join(timeout=60)
        check("case3 ctl send failed (rc=3)", box.get("rc") == 3,
              f"(rc={box.get('rc')})")
        check("case3 waited for approval timeout",
              box.get("elapsed", 0) >= APPROVAL_TIMEOUT - 1.0,
              f"(elapsed {box.get('elapsed', 0):.1f}s)")
        check("case3 no file in A downloads", not (dl_a / "test3.bin").exists())
        expired = driver.wait_event("request_expired", timeout=5, from_idx=mark)
        check("case3 request_expired event seen", expired is not None)

        driver.close()
    finally:
        for p in daemons:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()

    print()
    if failures:
        print(f"SELFTEST FAILED ({len(failures)}): {failures}")
        print(f"artifacts kept at {WORK}")
        return 1
    shutil.rmtree(WORK, ignore_errors=True)
    print("SELFTEST PASSED (all cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
