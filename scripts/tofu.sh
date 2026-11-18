#!/usr/bin/env bash
# Run OpenTofu from its container image against tofu/. Nothing is installed
# on this machine. Arguments are passed straight through:
#
#   scripts/tofu.sh plan
#   scripts/tofu.sh apply
#   scripts/tofu.sh destroy
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
image="ghcr.io/opentofu/opentofu:1.13.9"

[ -f "$repo/.env" ] || { echo "missing $repo/.env (copy env.example and fill it in)" >&2; exit 1; }
set -a; . "$repo/.env"; set +a

key_file="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
if [ -f "$key_file" ]; then
  ssh_keys=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$key_file")
else
  ssh_keys='[]'
fi

mkdir -p "$repo/.cache/tofu-plugins"
tty_flag=""; [ -t 0 ] && tty_flag="-t"

podman run --rm -i $tty_flag \
  -v "$repo/tofu:/work" \
  -v "$repo/.cache/tofu-plugins:/plugin-cache" \
  -w /work \
  -e TF_PLUGIN_CACHE_DIR=/plugin-cache \
  -e TF_IN_AUTOMATION=1 \
  -e TF_VAR_pve_endpoint="$PVE_ENDPOINT" \
  -e TF_VAR_pve_node="$PVE_NODE" \
  -e TF_VAR_pve_token_id="$PVE_TOKEN_ID" \
  -e TF_VAR_pve_token_secret="$PVE_TOKEN_SECRET" \
  -e TF_VAR_ssh_public_keys="$ssh_keys" \
  "$image" "$@"
