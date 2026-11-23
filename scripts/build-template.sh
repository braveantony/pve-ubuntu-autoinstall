#!/usr/bin/env bash
# Build an overlay's Ubuntu 26.04 template on Proxmox with Packer, run from
# the project's tools image (see Containerfile). Nothing is installed on this
# machine.
#
#   scripts/build-template.sh <overlay>            # build
#   scripts/build-template.sh <overlay> validate   # syntax/variable check only
set -euo pipefail

. "$(dirname "$0")/lib.sh"
load_overlay "${1:-}"
require_files site.hcl template.pkrvars.hcl
action="${2:-build}"

# Packer cannot build over an existing VM, and this script never deletes one
# for you: the old template may still have linked clones or be the only copy.
if [ "$action" = build ]; then
  http=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
    "${PVE_ENDPOINT}/api2/json/nodes/${PVE_NODE}/qemu/${TEMPLATE_VMID}/status/current")
  case "$http" in
    200) echo "VMID ${TEMPLATE_VMID} already exists on ${PVE_NODE}. Check what it is first (on the node: qm config ${TEMPLATE_VMID}). If it is an old template you want to rebuild, remove it yourself (qm destroy ${TEMPLATE_VMID}); otherwise set TEMPLATE_VMID in overlays/${overlay}/env to a free ID. Then run this again." >&2; exit 1 ;;
    500|404) ;; # PVE answers 500 "does not exist" for a free VMID
    *) echo "cannot query the PVE API (HTTP ${http}); check overlays/${overlay}/env" >&2; exit 1 ;;
  esac
fi

# A fresh throwaway password for the build account on every run. It never
# touches disk here and the account is deleted before the VM becomes a
# template.
build_password=$(openssl rand -hex 16)
build_password_hash=$(openssl passwd -6 "$build_password")

# An overlay may replace the autoinstall answers (for example to change the
# disk layout) with its own user-data.pkrtpl.yaml.
user_data_template=""
[ -f "$overlay_dir/user-data.pkrtpl.yaml" ] && user_data_template=/overlay/user-data.pkrtpl.yaml

mkdir -p "$repo/.cache/packer/cache"

run_packer() {
  podman run --rm -i \
    -v "$repo/base/packer:/work:ro" \
    -v "$overlay_dir:/overlay:ro" \
    -v "$repo/.cache/packer/cache:/cache" \
    -w /work \
    -e PACKER_CACHE_DIR=/cache \
    -e PACKER_LOG="${PACKER_LOG:-0}" \
    -e CHECKPOINT_DISABLE=1 \
    -e PKR_VAR_pve_endpoint="$PVE_ENDPOINT" \
    -e PKR_VAR_pve_node="$PVE_NODE" \
    -e PKR_VAR_pve_token_id="$PVE_TOKEN_ID" \
    -e PKR_VAR_pve_token_secret="$PVE_TOKEN_SECRET" \
    -e PKR_VAR_template_vmid="$TEMPLATE_VMID" \
    -e PKR_VAR_user_data_template="$user_data_template" \
    -e PKR_VAR_build_password="$build_password" \
    -e PKR_VAR_build_password_hash="$build_password_hash" \
    "$image" packer "$1" "${@:2}" \
    -var-file=/overlay/site.hcl -var-file=/overlay/template.pkrvars.hcl .
}

case "$action" in
  validate) run_packer validate ;;
  build)    run_packer build -timestamp-ui ;;
  *) echo "usage: $0 <overlay> [build|validate]" >&2; exit 2 ;;
esac
