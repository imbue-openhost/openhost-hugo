#!/bin/bash
# Rebuild the Hugo site.
#
# Reads from $SOURCE_DIR (from env if set, else default), writes
# to $OUTPUT_DIR via an atomic-swap pattern so partial builds
# never become visible to darkhttpd.
#
# Returns 0 on success, non-zero if hugo failed.
set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/hugo}"
SOURCE_DIR="${SOURCE_DIR:-$PERSIST/site}"
OUTPUT_DIR="${OUTPUT_DIR:-/output/public}"

# Build into a staging directory next to the real output dir;
# only rename into place if hugo succeeds.  This avoids the
# in-between state where darkhttpd would serve a half-built
# site (404s, missing assets, etc.) during a rebuild.
#
# Hugo's own --destination flag does NOT clean stale files —
# if you delete a content/foo.md, the corresponding public/
# foo/index.html lingers.  Building into a fresh staging dir
# every time gets us correct deletion semantics for free.
PARENT_DIR="$(dirname "$OUTPUT_DIR")"
STAGING_DIR="$(mktemp -d "$PARENT_DIR/hugo-build-XXXXXX")"
mkdir -p "$PARENT_DIR"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cd "$SOURCE_DIR"

# Build flags:
#   --destination       where to write the rendered HTML
#   --cleanDestinationDir is redundant given we mktemp'd, but
#                       harmless and explicit.
#   --minify            small CSS/JS/HTML optimizations.  Cheap.
#   --gc                garbage-collect unused cache entries
#                       at the end of the build.
#   --logLevel info     verbose enough for the operator to see
#                       what got built without drowning the log.
if ! hugo \
        --destination "$STAGING_DIR" \
        --cleanDestinationDir \
        --minify \
        --gc \
        --logLevel info \
        --quiet; then
    echo "[rebuild.sh] hugo build failed; keeping existing $OUTPUT_DIR" >&2
    exit 1
fi

# Atomic-swap: rename(2) is atomic on POSIX.  We rename the
# previous output to a `.old.<pid>` name, move staging into
# place, then rm the old directory.  Brief window between the
# two renames where /output/public doesn't exist is the only
# observable race — at most a couple of milliseconds.
#
# darkhttpd holds open file handles only at the moment of a
# request; it stats fresh each time.  So even a request
# in-flight during the swap will resolve cleanly to either the
# old or new file, never something in-between.
OLD_DIR=""
if [[ -d "$OUTPUT_DIR" ]]; then
    OLD_DIR="$PARENT_DIR/hugo-old-$$"
    mv "$OUTPUT_DIR" "$OLD_DIR"
fi
mv "$STAGING_DIR" "$OUTPUT_DIR"

# Reset the trap target — STAGING_DIR has been moved into
# OUTPUT_DIR, so the cleanup trap below would (try to) delete
# the live site.  Cleanup now operates on OLD_DIR.
trap - EXIT
if [[ -n "$OLD_DIR" ]]; then
    rm -rf "$OLD_DIR"
fi

# Lock down so the dropped-privilege darkhttpd can read.
# nobody:nobody is alpine UID/GID 65534.
chmod -R a+rX "$OUTPUT_DIR"

echo "[rebuild.sh] rebuild OK; $(find "$OUTPUT_DIR" -type f | wc -l) files in $OUTPUT_DIR"
