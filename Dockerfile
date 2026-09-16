# syntax=docker/dockerfile:1

# comix-downloader (https://github.com/Yui007/comix-downloader) in a container.
#
# The GUI is PyQt6/QML -- a native desktop app with no web server of its own.
# To reach it from a browser it runs against a virtual X display exported over
# noVNC:
#
#     gui/main.py --cpu  ->  Xvfb :99  ->  x11vnc :5900  ->  websockify :9000
#
# Base is Debian rather than python:3.12-slim on purpose: PyQt6 publishes no
# aarch64 wheel, so `pip install pyqt6` on Apple Silicon falls back to the sdist
# and dies wanting qmake and a full Qt SDK. Debian ships prebuilt PyQt6 6.4.2
# for arm64, so Qt comes from apt and only the pure-Python deps come from pip.

FROM debian:bookworm-slim

ARG COMIX_REF=97a63fa55bbf0813b84ebca60e2f2c5361755bbd

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    XDG_CONFIG_HOME=/config \
    DISPLAY=:99 \
    SCREEN_GEOMETRY=1400x950x24 \
    NOVNC_PORT=9000 \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip \
        chromium ca-certificates git \
        fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
        # virtual display + browser-facing VNC bridge
        xvfb x11vnc novnc websockify openbox tini \
        # PyQt6 bindings (qtquick pulls in qtqml)
        python3-pyqt6 python3-pyqt6.qtquick python3-pyqt6.qtsvg \
        # QML runtime modules the QML files import at load time
        qml6-module-qtquick qml6-module-qtquick-controls \
        qml6-module-qtquick-layouts qml6-module-qtquick-window \
        qml6-module-qtquick-templates qml6-module-qtqml-workerscript \
        qml6-module-qtquick-dialogs qml6-module-qtcore \
    && rm -rf /var/lib/apt/lists/*

# --system-site-packages so the venv can import the apt-installed PyQt6 while
# still letting pip manage the rest (Debian's python3 is externally managed).
RUN python3 -m venv --system-site-packages /opt/venv

WORKDIR /app

RUN git clone https://github.com/Yui007/comix-downloader.git . \
    && git checkout --detach "${COMIX_REF}" \
    && rm -rf .git

# Patch an upstream GUI bug. manga_bridge.py passes `volume` to QML with its raw
# type -- an int when the API supplies one, str("") when it does not -- while the
# adjacent `number` field is correctly coerced with str(). QML's ListModel locks a
# role's type on the first append, so every numeric volume after a string one is
# rejected with:
#     Can't assign to existing role 'volume' of different type [String -> Number]
# The greps make the build fail loudly if upstream changes this line, rather than
# letting the sed silently no-op.
RUN grep -q '"volume": ch.volume or ""' gui/bridge/manga_bridge.py \
    && sed -i 's/"volume": ch\.volume or ""/"volume": str(ch.volume) if ch.volume else ""/' gui/bridge/manga_bridge.py \
    && grep -q '"volume": str(ch.volume) if ch.volume else ""' gui/bridge/manga_bridge.py \
    && echo "patched manga_bridge.py volume coercion"

# Patch two upstream bugs that make every download failure invisible.
#
# 1. DownloadBridge.errorOccurred has no handler in main.qml -- the Connections
#    block wires onDownloadStarted/onOverallProgress/onChapterProgress/
#    onChapterComplete/onDownloadFinished but not onErrorOccurred. Every error
#    path in startDownload() and DownloadWorker.run() emits into the void, so a
#    failed download is indistinguishable from nothing happening.
# 2. DownloadWorker.run() swallows the traceback: `except Exception as e:
#    self.error.emit(str(e))` loses the stack, and the string goes to the
#    unhandled signal above. Print it so it reaches `docker compose logs`.
RUN grep -q "target: DownloadBridge" gui/qml/main.qml \
    && sed -i 's|        target: DownloadBridge|        target: DownloadBridge\n        function onErrorOccurred(error) { browseView.showMangaError(error) }|' gui/qml/main.qml \
    && grep -q "function onErrorOccurred(error) { browseView.showMangaError(error) }" gui/qml/main.qml \
    && grep -q "            self.error.emit(str(e))" gui/bridge/download_bridge.py \
    && sed -i 's|            self.error.emit(str(e))|            import traceback; traceback.print_exc()\n            self.error.emit(str(e))|' gui/bridge/download_bridge.py \
    && grep -q "traceback.print_exc()" gui/bridge/download_bridge.py \
    && echo "patched download error visibility"

# Patch the actual download failure. startDownload() is declared
# @pyqtSlot('QVariant', 'QVariant', str, str) and converts `chapters` with
# toVariant(), but never does the same for `manga`. Newer Qt (what upstream
# develops against) auto-converts the QJSValue; Debian's Qt 6.4.2 does not, so
# `manga` reaches DownloadWorker.run() raw and dies on the first attribute
# access:
#     AttributeError: 'QJSValue' object has no attribute 'get'
# The hasattr guard makes this a no-op on Qt versions that already convert.
RUN grep -q "if hasattr(chapters, 'toVariant'):" gui/bridge/download_bridge.py \
    && sed -i "s|        if hasattr(chapters, 'toVariant'):|        if hasattr(manga, 'toVariant'):\n            manga = manga.toVariant()\n        if hasattr(chapters, 'toVariant'):|" gui/bridge/download_bridge.py \
    && grep -q "manga = manga.toVariant()" gui/bridge/download_bridge.py \
    && echo "patched manga QJSValue conversion"

# pyqt6 comes from apt above; installing it from pip would rebuild Qt from source.
RUN grep -viE '^\s*pyqt6' requirements.txt > /tmp/requirements-nogui.txt \
    && /opt/venv/bin/pip install -r /tmp/requirements-nogui.txt \
    && rm /tmp/requirements-nogui.txt

# noVNC's Debian package ships vnc.html but no index; make / serve the client.
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# The upstream repo ships a stale cf_cookies.dat; drop it. Clearance is carried
# to/from /config by the entrypoint -- NOT by a symlink here, because the app
# saves via os.replace() (rename), which would replace the symlink itself.
RUN rm -f cf_cookies.dat

RUN mkdir -p /app/downloads /config

EXPOSE 9000

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# tini as PID 1: Chromium orphans reparent to it, and compose's init:true
# has no equivalent in a plain pod spec.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
