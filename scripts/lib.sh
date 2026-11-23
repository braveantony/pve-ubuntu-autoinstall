# Shared by the scripts: resolve an overlay name and load its settings.
# Sourced, not executed.

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
default_image="ghcr.io/braveantony/pve-ubuntu-autoinstall:v0.2.1"

# load_overlay <name>: sets $overlay (name), $overlay_dir and $image, and
# exports the variables in overlays/<name>/env.
load_overlay() {
  overlay="${1:-}"
  if [ -z "$overlay" ] || [ ! -d "$repo/overlays/$overlay" ]; then
    echo "unknown overlay '${overlay}'. Available:" >&2
    for d in "$repo"/overlays/*/; do echo "  $(basename "$d")" >&2; done
    return 1
  fi
  overlay_dir="$repo/overlays/$overlay"
  if [ ! -f "$overlay_dir/env" ]; then
    echo "missing overlays/$overlay/env (copy env.example to env and fill it in)" >&2
    return 1
  fi
  set -a; . "$overlay_dir/env"; set +a
  : "${TEMPLATE_VMID:?set TEMPLATE_VMID in overlays/$overlay/env}"
  image="${TOOLS_IMAGE:-$default_image}"
}

# require_files <file>...: fail if the overlay lacks one of them.
require_files() {
  local f
  for f in "$@"; do
    [ -f "$overlay_dir/$f" ] || { echo "missing overlays/$overlay/$f" >&2; return 1; }
  done
}
