#!/usr/bin/env bash
# Run OpenTofu from the project's tools image (see Containerfile) against
# tofu/. Nothing is installed on this machine. Set TOOLS_IMAGE in .env to use
# a different image. Arguments are passed straight through:
#
#   scripts/tofu.sh plan
#   scripts/tofu.sh apply
#   scripts/tofu.sh destroy
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
default_image="ghcr.io/braveantony/pve-ubuntu-autoinstall:v0.1.0"

[ -f "$repo/.env" ] || { echo "missing $repo/.env (copy env.example and fill it in)" >&2; exit 1; }
set -a; . "$repo/.env"; set +a
image="${TOOLS_IMAGE:-$default_image}"

key_file="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
key_file="${key_file/#\~/$HOME}" # .env values are not tilde-expanded
# Fail loudly: without a key the VMs would still be created, and the mistake
# would only show up later as a refused SSH login.
if [ ! -r "$key_file" ]; then
  echo "public key file not found: $key_file (set SSH_PUBLIC_KEY_FILE in .env)" >&2
  exit 1
fi
ssh_keys=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$key_file")

tty_flag=""; [ -t 0 ] && tty_flag="-t"

podman run --rm -i $tty_flag \
  -v "$repo/tofu:/work" \
  -w /work \
  -e TF_IN_AUTOMATION=1 \
  -e TF_VAR_pve_endpoint="$PVE_ENDPOINT" \
  -e TF_VAR_pve_node="$PVE_NODE" \
  -e TF_VAR_pve_token_id="$PVE_TOKEN_ID" \
  -e TF_VAR_pve_token_secret="$PVE_TOKEN_SECRET" \
  -e TF_VAR_ssh_public_keys="$ssh_keys" \
  -e TF_VAR_template_vmid="${TEMPLATE_VMID:-605}" \
  "$image" tofu "$@"
