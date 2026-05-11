# openhost-hugo

[Hugo](https://gohugo.io/) — fast Go-based static-site generator —
packaged for OpenHost with a live-rebuild loop. SSH into the host,
edit your Markdown / templates / themes, and the site rebuilds within
seconds.

## What you get

- Hugo extended (with SCSS + asset pipeline) running on
  `https://hugo.<zone>/`.
- Public by default. Anonymous visitors can read the site.
- Markdown source lives in `$OPENHOST_APP_DATA_DIR/site/` on the
  host filesystem.
- An `inotify` watcher inside the container rebuilds the site on
  every change to a source file. No `oh app reload`, no restart.
- Built output served by darkhttpd (same engine as
  `openhost-darkhttpd`).

## Authoring

```bash
ssh host@<zone>
cd ~/.openhost/local_compute_space/persistent_data/app_data/hugo/site/

# Edit existing content:
$EDITOR content/_index.md

# Add a new post:
mkdir -p content/posts
$EDITOR content/posts/hello.md

# Install a theme:
git clone https://github.com/<theme-author>/<theme>.git themes/<theme>
# then set `theme = "<theme>"` in hugo.toml

# Or replace the whole site with your own Hugo project tree:
rm -rf .
git clone https://github.com/me/my-hugo-site.git .
```

Each save triggers an inotify event; the watcher debounces 1 second
of quiet, then runs `hugo --destination /output/public` with an
atomic-swap output dir. Stale files from deleted pages are cleaned
up automatically.

## Architecture

```
SSH author
   │
   │  rsync / git pull / vim
   ▼
$OPENHOST_APP_DATA_DIR/site/   (persistent)
   │
   │  inotifywait -m -r -e modify -e create -e delete ...
   ▼
rebuild.sh
   │
   │  hugo --destination <staging>
   │  mv <staging> /output/public  (atomic)
   ▼
/output/public/   (ephemeral)
   │
   ▼
darkhttpd 0.0.0.0:8080
   │
   ▼
OpenHost router (public_paths = ["/"])
   │
   ▼
browser
```

## Why this is fast

- Hugo's build is fast on its own (small Go binary, no JS toolchain
  to spin up).
- `inotifywait` blocks on kernel-level filesystem events; we don't
  poll.
- The 1-second debounce window absorbs `rsync`-style bursty edits
  so a 50-file upload triggers a single rebuild, not 50.
- Output dir is in container-local storage (ephemeral). Swap is
  atomic via `rename(2)`; in-flight requests resolve cleanly.

## Themes

Most operators install a theme as a git submodule:

```bash
cd ~/.openhost/local_compute_space/persistent_data/app_data/hugo/site/
git submodule add https://github.com/adityatelange/hugo-PaperMod.git themes/PaperMod
```

Then in `hugo.toml`:

```toml
theme = "PaperMod"
```

The container ships `git`, so submodule operations work out of the
box.

## When NOT to use this

- You want a simpler "drop HTML and serve" workflow without a build
  step → use `openhost-darkhttpd` instead.
- You want Python-based docs generation with auto-nav from a
  `mkdocs.yml` → use `openhost-mkdocs` instead.
- You want server-side dynamic behaviour → Hugo is wrong tool.

## Limitations

- **Build memory.** A very large site (~thousands of pages with
  heavy SCSS / image-processing pipelines) can exceed the default
  256 MiB. Bump `[resources].memory_mb` in `openhost.toml` and
  redeploy.
- **No build queue.** If the operator saves a file mid-rebuild, the
  next debounce window picks it up. There's no "two rebuilds in
  flight" footgun.
- **Build failures keep the old output live.** A bad commit makes
  `hugo` exit non-zero; the atomic-swap is skipped; the previously-
  working site continues to serve. The error shows up in
  `oh app logs hugo`.
