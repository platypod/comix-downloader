#!/usr/bin/env bash
# Default (no args)  -> GUI on the virtual display, reachable at :9000 via noVNC.
# With args          -> CLI, e.g. `download <url> -c 1-10 -f pdf`.
#
# The display stack starts in BOTH modes: with `headless: false` in the config,
# the scraping Chromium is headful and needs an X display to attach to, whether
# it was launched from the GUI or the CLI.
set -uo pipefail

# Chapters are written into a shared NFS library that Komga reads as a
# different uid, so keep them group-readable.
umask "${UMASK:-002}"

JAR_PERSIST=/config/cf_cookies.dat
JAR_LIVE=/app/cf_cookies.dat

# Persist Cloudflare/WAF clearance across --rm runs.
#
# The app saves cookies with os.replace(tmp, /app/cf_cookies.dat), which is
# rename(2): it replaces whatever directory entry sits at that path. A symlink
# there is destroyed on first save, and a bind-mounted file would fail with
# EBUSY. So keep a real file in /app and copy it to/from the volume instead.
[ -f "$JAR_PERSIST" ] && cp -f "$JAR_PERSIST" "$JAR_LIVE" 2>/dev/null

save_jar() {
  if [ -f "$JAR_LIVE" ]; then
    mkdir -p "$(dirname "$JAR_PERSIST")"
    cp -f "$JAR_LIVE" "$JAR_PERSIST" 2>/dev/null
  fi
}

pids=()
cleanup() {
  save_jar
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done
}
trap 'cleanup' EXIT INT TERM

echo "[entrypoint] starting Xvfb on ${DISPLAY} (${SCREEN_GEOMETRY})"
Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOMETRY}" -nolisten tcp &
pids+=($!)

# Wait for the X socket rather than sleeping a fixed amount.
sock="/tmp/.X11-unix/X${DISPLAY#:}"
for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.2; done
if [ ! -S "$sock" ]; then echo "[entrypoint] ERROR: Xvfb never came up" >&2; exit 1; fi
echo "[entrypoint] Xvfb ready"

# A window manager matters once the headful scraping Chromium shares the display
# with the Qt window: without one, neither can be raised, moved or resized.
openbox --sm-disable >/dev/null 2>&1 &
pids+=($!)

# VNC_PASSWORD is required in the cluster, where the Service is reachable by
# anything in the pod network. Locally (compose, bound to 127.0.0.1) it may be
# empty, which falls back to -nopw.
if [ -n "${VNC_PASSWORD:-}" ]; then
  mkdir -p /root/.vnc
  x11vnc -storepasswd "${VNC_PASSWORD}" /root/.vnc/passwd >/dev/null 2>&1
  VNC_AUTH="-rfbauth /root/.vnc/passwd"
  echo "[entrypoint] x11vnc: password auth enabled"
else
  VNC_AUTH="-nopw"
  echo "[entrypoint] x11vnc: NO PASSWORD (only safe on a loopback-bound port)"
fi
# shellcheck disable=SC2086
x11vnc -display "${DISPLAY}" -forever -shared $VNC_AUTH -quiet -rfbport 5900 -bg >/dev/null 2>&1

echo "[entrypoint] noVNC on :${NOVNC_PORT} -> open http://localhost:${NOVNC_PORT}/"
websockify --web=/usr/share/novnc "${NOVNC_PORT}" localhost:5900 >/dev/null 2>&1 &
pids+=($!)

# Both branches background the child and wait on it. bash does NOT run EXIT/TERM
# traps while a foreground child is running, so a foreground GUI meant docker's
# SIGTERM was deferred until the grace period expired and SIGKILL landed -- and
# save_jar never ran, losing the clearance cookies on every stop.
if [ "$#" -gt 0 ]; then
  echo "[entrypoint] CLI mode: main.py $*"
  python main.py "$@" &
else
  echo "[entrypoint] launching GUI (software rendering)"
  python gui/main.py --cpu &
fi
app_pid=$!
pids+=("$app_pid")
wait "$app_pid" || true
