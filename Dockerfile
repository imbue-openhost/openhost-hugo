# OpenHost Hugo container.
#
# Two roles in one container:
#   1. A Hugo build worker (idle 99% of the time, spikes when
#      the operator changes content).  Driven by an inotify
#      watcher on the persistent source directory.
#   2. A darkhttpd static-file server (the same package as
#      openhost-darkhttpd) that serves Hugo's BUILT output.
#
# Source dir:  $OPENHOST_APP_DATA_DIR/site/        (persistent)
# Output dir:  /output/public/                     (ephemeral)
#
# The output dir is intentionally NOT persistent — it's
# regenerated on every container start anyway, and keeping it
# inside the container makes the S3-write hit zero for hot-
# path serving.  The persistent state IS the source.

FROM docker.io/library/alpine:3.20

# Install:
#   * hugo — the static-site generator binary (alpine ships
#     hugo-extended in the community repo, which has SCSS
#     support and the asset pipeline most modern themes need).
#   * darkhttpd — to serve the built output.
#   * inotify-tools — `inotifywait` for change detection.
#   * git — most operator workflows clone themes as
#     submodules, so we ship git for the initial clone.
#   * tini — proper PID 1 + signal forwarding + zombie
#     reaping for the multi-process container.
#   * bash — start.sh uses `wait -n` and `[[` for cleaner
#     multi-child supervision.
RUN apk add --no-cache \
        hugo \
        darkhttpd \
        inotify-tools \
        git \
        tini \
        bash

# Copy entrypoint + helper scripts (mode 0755 in git).
COPY start.sh /opt/openhost-hugo/start.sh
COPY rebuild.sh /opt/openhost-hugo/rebuild.sh

# darkhttpd port.  Source-dir watcher and hugo itself bind
# nothing — they communicate via filesystem.
EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--", "/opt/openhost-hugo/start.sh"]
