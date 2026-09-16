# comix-downloader

Container image wrapping [Yui007/comix-downloader](https://github.com/Yui007/comix-downloader)
for the platypod stack. Consumed by `stack/src/media/templates/comix-downloader/`.

`ghcr.io/platypod/comix-downloader`

## What this adds over upstream

Upstream is a desktop app. This image makes it reachable from a browser and
survivable as a pod:

```
gui/main.py --cpu -> Xvfb :99 -> openbox -> x11vnc :5900 -> websockify :9000
```

The GUI is PyQt6/QML with no HTTP listener of its own, so noVNC is how you
reach it. Port 9000 serves the noVNC client.

## Why Debian, not python:3-slim

**PyQt6 publishes no aarch64 wheel.** On arm64 (the whole platypod fleet)
`pip install pyqt6` falls back to the source tarball and fails wanting `qmake`
and a full Qt SDK. So Qt comes from apt (Debian's PyQt6 6.4.2, Python 3.11) and
only the pure-Python deps come from pip, into a venv created with
`--system-site-packages`.

Do not "simplify" this back to `python:3-slim` + `pip install -r
requirements.txt`. It will not build.

## Upstream patches applied at build time

Four bugs, patched with guarded `sed` steps. Each greps for the exact original
line before and after, so a `COMIX_REF` bump that touches them **fails the
build** rather than silently dropping the patch.

| Patch | Bug |
|---|---|
| `manga.toVariant()` | `startDownload` converts `chapters` but not `manga`. Qt 6.11 (upstream's version) auto-converts the QJSValue; Qt 6.4.2 does not, so it reaches `DownloadWorker.run()` raw and dies with `AttributeError: 'QJSValue' object has no attribute 'get'`. **Every download fails.** |
| `volume` coercion | `manga_bridge.py` coerces `number` with `str()` but not `volume`. QML's `ListModel` locks a role's type on first append, so numeric volumes after a string one are refused — 480 warnings on a 374-chapter title. |
| `onErrorOccurred` handler | `main.qml`'s `DownloadBridge` block wires every signal *except* the error one, so failures emit into the void. |
| `traceback.print_exc()` | `DownloadWorker.run()` swallows the stack. |

All four are worth reporting upstream; the first is invisible on Qt 6.11.

## Runtime configuration

| Env | Default | Purpose |
|---|---|---|
| `NOVNC_PORT` | `9000` | noVNC/websockify listen port |
| `SCREEN_GEOMETRY` | `1400x950x24` | Xvfb size; the Qt window is 1100x750 |
| `VNC_PASSWORD` | *(empty)* | `x11vnc -rfbauth`. **Empty means `-nopw`** — only safe on a loopback-bound port |
| `UMASK` | `002` | Keeps chapters group-readable for the library server |
| `XDG_CONFIG_HOME` | `/config` | Settings + WAF cookie jar live here |

Passing arguments switches the entrypoint to the CLI instead of the GUI:

```bash
docker run --rm ghcr.io/platypod/comix-downloader:latest download "<url>" -c "1-20" -f pdf
```

## The site's WAF

comix.to redirects title pages to `/@waf/challenge` — an interactive
"drag to rotate the circle" puzzle. It is **not** Cloudflare's JS challenge, so
nothing clears it by waiting, and FlareSolverr does not apply. The resulting
`waf_pass` cookie lasts about an hour.

This is why `headless: false` matters: the scraping Chromium must be visible on
the X display for a human to solve the puzzle. Clearance is then written to
`$XDG_CONFIG_HOME/comix-downloader/cf_cookies.dat` and reused.

Consequence: **this cannot run unattended.** Keep batches inside the hour. When
clearance lapses mid-run the worker holding the app's global browser lock blocks
on the challenge and every other worker queues behind it.

## Notes

- **Chromium runs as root with its sandbox off.** Upstream picks the sandbox
  flag from the euid (`_sandbox_enabled()`); as non-root it requests the
  namespace sandbox, which needs `CAP_SYS_ADMIN` or a loosened seccomp profile
  in a pod. uid 0 is the only combination that starts without extra caps.
- **`/dev/shm` needs ≥ 2GB.** The 64MB default crashes renderers on
  image-heavy chapters.
- **tini is PID 1** so Chromium orphans get reaped.
- Cookie persistence is by copy, not symlink: the app saves via `os.replace()`
  (`rename(2)`), which replaces whatever directory entry is at the path —
  destroying a symlink. The entrypoint copies the jar in at start and out at
  exit instead.

## Build

```bash
make build                 # multi-arch, pushes to GHCR
```

CI builds and pushes on any tag push.
