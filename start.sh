#!/bin/bash
# Launch Hugo on OpenHost.
#
# Topology:
#
#   $SOURCE_DIR (persistent, edited via SSH)
#         │
#         │  inotify-tools sees changes
#         ▼
#   rebuild.sh runs `hugo --destination /output/public`
#         │
#         ▼
#   /output/public/  (ephemeral inside container)
#         │
#         ▼
#   darkhttpd 0.0.0.0:8080  →  browser
#
# Three child processes:
#   * The first hugo build (synchronous, before darkhttpd)
#   * darkhttpd serving /output/public
#   * inotifywait | xargs rebuild.sh — the file-change watcher
set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/hugo}"
SOURCE_DIR="$PERSIST/site"
OUTPUT_DIR="/output/public"

mkdir -p "$SOURCE_DIR" "$OUTPUT_DIR"

# -----------------------------------------------------------------
# First-boot scaffolding
# -----------------------------------------------------------------
#
# If the source dir is empty, drop a tiny placeholder Hugo site
# so the operator's first visit shows a "site is up; replace
# this content" page instead of a 404 or build error.  We only
# scaffold when the dir is completely empty — never clobber.
if [[ -z "$(ls -A "$SOURCE_DIR" 2>/dev/null)" ]]; then
    echo "[start.sh] First boot: scaffolding empty Hugo site"
    cat > "$SOURCE_DIR/hugo.toml" <<'TOML'
baseURL = "/"
languageCode = "en-us"
title = "openhost-hugo"

[markup.goldmark.renderer]
unsafe = true  # allow raw HTML in Markdown (safe because
               # only operator authors via SSH)
TOML

    mkdir -p "$SOURCE_DIR/content" "$SOURCE_DIR/layouts/_default"

    cat > "$SOURCE_DIR/content/_index.md" <<'MARKDOWN'
+++
title = "openhost-hugo placeholder"
+++

# Hello from Hugo

This is the placeholder page from the openhost-hugo container.
Replace it by SSHing into the OpenHost host:

```
cd ~/.openhost/local_compute_space/persistent_data/app_data/hugo/site/
rm content/_index.md
# ... add your own content/, layouts/, themes/, etc.
```

The container watches this directory with inotify and rebuilds
the site within a few seconds of any change.
MARKDOWN

    # Minimal single-template layout so the placeholder renders
    # without requiring the operator to install a theme first.
    cat > "$SOURCE_DIR/layouts/_default/baseof.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{{ .Site.Title }}{{ if .Title }} — {{ .Title }}{{ end }}</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 720px;
           margin: 4rem auto; padding: 0 1rem; color: #333; }
    pre, code { background: #f4f4f4; }
    pre { padding: 1rem; border-radius: 4px; overflow-x: auto; }
    code { padding: 2px 6px; border-radius: 3px; }
  </style>
</head>
<body>
{{ block "main" . }}{{ .Content }}{{ end }}
</body>
</html>
HTML

    cat > "$SOURCE_DIR/layouts/_default/single.html" <<'HTML'
{{ define "main" }}
<article>
  <h1>{{ .Title }}</h1>
  {{ .Content }}
</article>
{{ end }}
HTML

    cat > "$SOURCE_DIR/layouts/_default/list.html" <<'HTML'
{{ define "main" }}
{{ .Content }}
{{ range .Pages }}
  <h2><a href="{{ .RelPermalink }}">{{ .Title }}</a></h2>
  <p>{{ .Summary }}</p>
{{ end }}
{{ end }}
HTML

    cat > "$SOURCE_DIR/layouts/index.html" <<'HTML'
{{ define "main" }}
{{ .Content }}
{{ end }}
HTML
fi

# -----------------------------------------------------------------
# Initial build (synchronous)
# -----------------------------------------------------------------
#
# Block on the first build so darkhttpd has content to serve
# when it starts.  If the build fails (e.g., the operator's
# Hugo config is invalid) we still proceed to launch darkhttpd
# so they see a 404 / empty dir instead of an unresponsive
# container — and the inotify watcher will retry on every
# subsequent file save.
echo "[start.sh] Running initial Hugo build"
if ! /opt/openhost-hugo/rebuild.sh; then
    echo "[start.sh] WARNING: initial Hugo build failed; serving empty /output/public until next source change"
    mkdir -p "$OUTPUT_DIR"
fi

# -----------------------------------------------------------------
# Launch darkhttpd
# -----------------------------------------------------------------
#
# Same flags as openhost-darkhttpd: chroot, drop privilege,
# no directory listings, log to stderr.
echo "[start.sh] Starting darkhttpd on 0.0.0.0:8080 -> $OUTPUT_DIR"
darkhttpd "$OUTPUT_DIR" \
    --port 8080 \
    --addr 0.0.0.0 \
    --no-listing \
    --chroot \
    --uid nobody \
    --gid nobody \
    --log /dev/stderr &
DARKHTTPD_PID=$!

# -----------------------------------------------------------------
# Launch the inotify watcher
# -----------------------------------------------------------------
#
# inotifywait blocks on filesystem events and prints one line
# per event.  We feed those lines into a tight bash loop that
# debounces (sleeps 1s after each event in case the operator
# is rsync'ing many files in a row) and then calls rebuild.sh.
#
# We watch the persistent SOURCE_DIR recursively for the kinds
# of events that imply content changed:
#   modify        — file rewritten
#   create        — file added
#   delete        — file removed
#   move_to       — file moved into dir
#   move_from     — file moved out of dir
# We ignore noisy events (attrib, access) that fire on every
# stat() the build itself does.
echo "[start.sh] Starting inotify watcher on $SOURCE_DIR"
(
    # Initial sentinel to make the loop self-documenting in
    # `oh app logs hugo`.
    echo "[watcher] watching $SOURCE_DIR for changes"
    inotifywait -m -r -q \
        -e modify -e create -e delete -e moved_to -e moved_from \
        --format '%T %w%f %e' --timefmt '%Y-%m-%dT%H:%M:%S' \
        "$SOURCE_DIR" | while read -r event; do
        # Debounce: 1 second of quiet after the LAST event in a
        # burst.  inotifywait keeps emitting events for the
        # duration of an rsync, so we drain the queue before
        # rebuilding.
        last_event="$event"
        while read -r -t 1 next_event; do
            last_event="$next_event"
        done
        echo "[watcher] change detected; rebuilding (last event: $last_event)"
        if /opt/openhost-hugo/rebuild.sh; then
            echo "[watcher] rebuild OK"
        else
            echo "[watcher] rebuild FAILED (see hugo output above); previous output dir kept"
        fi
    done
) &
WATCHER_PID=$!

# -----------------------------------------------------------------
# Supervision
# -----------------------------------------------------------------
#
# The container's lifecycle is tied to darkhttpd, NOT the
# watcher.  If darkhttpd dies, the container exits (OpenHost
# restarts it).  If the watcher dies, we log noisily but
# keep darkhttpd running so the existing built site stays
# online — losing live-reload is annoying, but a watcher
# crash is not a reason to take the public site down.
trap 'kill -TERM "$DARKHTTPD_PID" "$WATCHER_PID" 2>/dev/null; wait' TERM INT

# Loop: wait for any child to exit; if it's the watcher, log
# it, restart it, and continue.  If it's darkhttpd, the loop
# exits and the container terminates.
while true; do
    set +e
    wait -n "$DARKHTTPD_PID" "$WATCHER_PID"
    EXIT_CODE=$?
    set -e

    if ! kill -0 "$DARKHTTPD_PID" 2>/dev/null; then
        # darkhttpd is gone — that's fatal for the container.
        echo "[start.sh] darkhttpd exited (code=$EXIT_CODE); container will shut down"
        break
    fi

    if ! kill -0 "$WATCHER_PID" 2>/dev/null; then
        echo "[start.sh] watcher exited (code=$EXIT_CODE); restarting" >&2
        (
            echo "[watcher] watching $SOURCE_DIR for changes (restarted)"
            inotifywait -m -r -q \
                -e modify -e create -e delete -e moved_to -e moved_from \
                --format '%T %w%f %e' --timefmt '%Y-%m-%dT%H:%M:%S' \
                "$SOURCE_DIR" | while read -r event; do
                last_event="$event"
                while read -r -t 1 next_event; do
                    last_event="$next_event"
                done
                echo "[watcher] change detected; rebuilding (last event: $last_event)"
                if /opt/openhost-hugo/rebuild.sh; then
                    echo "[watcher] rebuild OK"
                else
                    echo "[watcher] rebuild FAILED; previous output dir kept"
                fi
            done
        ) &
        WATCHER_PID=$!
        # Brief sleep so a tight-loop watcher crash doesn't fork-storm.
        sleep 2
        continue
    fi
done

kill -TERM "$DARKHTTPD_PID" "$WATCHER_PID" 2>/dev/null || true
wait || true
exit "$EXIT_CODE"
