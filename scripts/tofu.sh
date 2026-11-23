#!/usr/bin/env bash
# Run OpenTofu for one overlay from the project's tools image (see
# Containerfile). Nothing is installed on this machine. The definitions come
# from base/tofu; the values, the VM list and the state file come from
# overlays/<overlay>. Arguments after the overlay are passed straight through:
#
#   scripts/tofu.sh <overlay> init
#   scripts/tofu.sh <overlay> plan
#   scripts/tofu.sh <overlay> apply
#   scripts/tofu.sh <overlay> destroy
set -euo pipefail

. "$(dirname "$0")/lib.sh"
load_overlay "${1:-}"
shift
[ $# -gt 0 ] || { echo "usage: $0 <overlay> <tofu arguments>" >&2; exit 2; }
require_files site.hcl vms.tfvars secrets.tfvars

key_file="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
key_file="${key_file/#\~/$HOME}" # env values are not tilde-expanded
# Fail loudly: without a key the VMs would still be created, and the mistake
# would only show up later as a refused SSH login.
if [ ! -r "$key_file" ]; then
  echo "public key file not found: $key_file (set SSH_PUBLIC_KEY_FILE in overlays/$overlay/env)" >&2
  exit 1
fi
ssh_keys=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$key_file")

var_files="-var-file=/overlay/site.hcl -var-file=/overlay/vms.tfvars -var-file=/overlay/secrets.tfvars"
tty_flag=""; [ -t 0 ] && tty_flag="-t"

podman run --rm -i $tty_flag \
  -v "$repo/base/tofu:/work:ro" \
  -v "$overlay_dir:/overlay" \
  -w /work \
  -e TF_DATA_DIR=/overlay/.terraform \
  -e TF_IN_AUTOMATION=1 \
  -e TF_CLI_ARGS_init="-backend-config=path=/overlay/terraform.tfstate -lockfile=readonly" \
  -e TF_CLI_ARGS_plan="$var_files" \
  -e TF_CLI_ARGS_apply="$var_files" \
  -e TF_CLI_ARGS_destroy="$var_files" \
  -e TF_CLI_ARGS_refresh="$var_files" \
  -e TF_CLI_ARGS_import="$var_files" \
  -e TF_CLI_ARGS_console="$var_files" \
  -e TF_VAR_pve_endpoint="$PVE_ENDPOINT" \
  -e TF_VAR_pve_node="$PVE_NODE" \
  -e TF_VAR_pve_token_id="$PVE_TOKEN_ID" \
  -e TF_VAR_pve_token_secret="$PVE_TOKEN_SECRET" \
  -e TF_VAR_ssh_public_keys="$ssh_keys" \
  -e TF_VAR_template_vmid="$TEMPLATE_VMID" \
  "$image" tofu "$@"
