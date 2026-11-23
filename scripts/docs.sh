#!/usr/bin/env bash
# Preview or build the documentation site (Docusaurus, in website/) with Node
# run from a container image. Nothing is installed on this machine.
#
#   scripts/docs.sh            # live preview on http://localhost:3000
#   scripts/docs.sh build      # static site into website/build
#   scripts/docs.sh npm <...>  # any npm command inside website/
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
image="docker.io/library/node:22-alpine"
action="${1:-start}"
tty_flag=""; [ -t 0 ] && tty_flag="-t"

run() {
  podman run --rm -i $tty_flag \
    -v "$repo:/repo" -w /repo/website \
    -p "${DOCS_PORT:-3000}:3000" \
    "$image" "$@"
}

[ -d "$repo/website/node_modules" ] || [ "$action" = npm ] || run npm ci

case "$action" in
  start) run npm run start -- --host 0.0.0.0 ;;
  build) run npm run build ;;
  npm)   shift; run npm "$@" ;;
  *) echo "usage: $0 [start|build|npm <args>]" >&2; exit 2 ;;
esac
