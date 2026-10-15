#!/usr/bin/env bash
# run-on-mac.sh - Phase 0 helper for running notchsendd on the owner's Mac.
#
# Usage:
#   tools/run-on-mac.sh start   # preflight + release build + start daemon (background)
#   tools/run-on-mac.sh stop    # stop the daemon started by this script
#   tools/run-on-mac.sh status  # daemon status via notchsendctl
#   tools/run-on-mac.sh watch   # stream daemon events (approvals happen here)
#
# Written for macOS default bash 3.2: no empty-array expansions under set -u.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$HOME/.notchsend"
PIDFILE="$DATA_DIR/daemon.pid"
LOGFILE="$DATA_DIR/daemon.log"
SOCK="$DATA_DIR/daemon.sock"
DAEMON="$ROOT/target/release/notchsendd"
CTL="$ROOT/target/release/notchsendctl"

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_cargo() {
  if ! command -v cargo >/dev/null 2>&1; then
    if [ -f "$HOME/.cargo/env" ]; then
      # shellcheck disable=SC1091
      . "$HOME/.cargo/env"
    fi
  fi
  command -v cargo >/dev/null 2>&1 || die "cargo not found. Install Rust first: https://rustup.rs (rustup default stable), then re-run."
}

preflight() {
  # Port 53317 must be free: the official LocalSend app and this daemon cannot coexist.
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:53317 -sTCP:LISTEN >/dev/null 2>&1; then
      die "TCP 53317 is already in use. Quit the official LocalSend app (or whatever holds the port) first: lsof -nP -iTCP:53317 -sTCP:LISTEN"
    fi
  fi
  if pgrep -fl "LocalSend" >/dev/null 2>&1; then
    echo "WARNING: a process matching 'LocalSend' is running. If that is the official app, quit it - it will fight the daemon for port 53317." >&2
  fi
}

build() {
  ensure_cargo
  echo "Building release binaries (first build takes a few minutes)..."
  (cd "$ROOT" && cargo build --release --bin notchsendd --bin notchsendctl)
  [ -x "$DAEMON" ] || die "build finished but $DAEMON missing"
  [ -x "$CTL" ] || die "build finished but $CTL missing"
}

cmd_start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    die "daemon already running (pid $(cat "$PIDFILE")). Use: $0 stop"
  fi
  preflight
  build
  mkdir -p "$DATA_DIR" "$HOME/Downloads"
  echo "Starting notchsendd (alias NotchSend, downloads -> $HOME/Downloads, log -> $LOGFILE)"
  nohup "$DAEMON" >>"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  # Wait for the control socket to appear.
  n=0
  while [ ! -S "$SOCK" ]; do
    n=$((n+1))
    [ "$n" -gt 50 ] && die "daemon did not create $SOCK within 5s. Check the log: tail -50 $LOGFILE"
    sleep 0.1
  done
  "$CTL" --socket "$SOCK" status
  echo
  echo "Daemon is up. Next steps:"
  echo "  1. In a second terminal:  $0 watch        (see the incoming request + its request_id)"
  echo "  2. Send files from the phone's official LocalSend app to 'NotchSend'."
  echo "  3. Accept from terminal:  $CTL --socket $SOCK accept <request_id>"
  echo "     or reject:             $CTL --socket $SOCK reject <request_id>"
  echo "  Full test sequence: ../PHASE0_MAC_INTEROP.md"
}

cmd_stop() {
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      echo "Stopped notchsendd (pid $pid)."
    else
      echo "No running daemon for pid $pid (stale pidfile removed)."
    fi
    rm -f "$PIDFILE"
  else
    echo "No pidfile at $PIDFILE - daemon was not started by this script."
  fi
}

cmd_status() {
  [ -x "$CTL" ] || die "notchsendctl not built yet. Run: $0 start"
  "$CTL" --socket "$SOCK" status
  "$CTL" --socket "$SOCK" peers
}

cmd_watch() {
  [ -x "$CTL" ] || die "notchsendctl not built yet. Run: $0 start"
  exec "$CTL" --socket "$SOCK" watch
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  watch) cmd_watch ;;
  *) echo "usage: $0 <start|stop|status|watch>" >&2; exit 2 ;;
esac
