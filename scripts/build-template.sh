#!/usr/bin/env bash
# Build the Ubuntu 26.04 template on Proxmox with Packer, run from the
# project's tools image (see Containerfile). Nothing is installed on this
# machine. Set TOOLS_IMAGE in .env to use a different image.
#
#   scripts/build-template.sh            # build
#   scripts/build-template.sh validate   # syntax/variable check only
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
default_image="ghcr.io/braveantony/pve-ubuntu-autoinstall:v0.1.0"
action="${1:-build}"

[ -f "$repo/.env" ] || { echo "missing $repo/.env (copy env.example and fill it in)" >&2; exit 1; }
set -a; . "$repo/.env"; set +a

# One source of truth for the template's VMID: TEMPLATE_VMID in .env. It is
# passed to Packer here and to OpenTofu in scripts/tofu.sh, overriding the
# defaults in the HCL variable files.
template_vmid="${TEMPLATE_VMID:-605}"
image="${TOOLS_IMAGE:-$default_image}"

# Packer cannot build over an existing VM, and this script never deletes one
# for you: the old template may still have linked clones or be the only copy.
if [ "$action" = build ]; then
  http=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
    "${PVE_ENDPOINT}/api2/json/nodes/${PVE_NODE}/qemu/${template_vmid}/status/current")
  case "$http" in
    200) echo "VMID ${template_vmid} already exists on ${PVE_NODE}. Check what it is first (on the node: qm config ${template_vmid}). If it is an old template you want to rebuild, remove it yourself (qm destroy ${template_vmid}); otherwise set TEMPLATE_VMID in .env to a free ID. Then run this again." >&2; exit 1 ;;
    500|404) ;; # PVE answers 500 "does not exist" for a free VMID
    *) echo "cannot query the PVE API (HTTP ${http}); check .env" >&2; exit 1 ;;
  esac
fi

# A fresh throwaway password for the build account on every run. It never
# touches disk here and the account is deleted before the VM becomes a
# template.
build_password=$(openssl rand -hex 16)
build_password_hash=$(openssl passwd -6 "$build_password")

mkdir -p "$repo/.cache/packer/cache"

run_packer() {
  podman run --rm -i \
    -v "$repo/packer:/work:ro" \
    -v "$repo/.cache/packer/cache:/cache" \
    -w /work \
    -e PACKER_CACHE_DIR=/cache \
    -e PACKER_LOG="${PACKER_LOG:-0}" \
    -e CHECKPOINT_DISABLE=1 \
    -e PKR_VAR_pve_endpoint="$PVE_ENDPOINT" \
    -e PKR_VAR_pve_node="$PVE_NODE" \
    -e PKR_VAR_pve_token_id="$PVE_TOKEN_ID" \
    -e PKR_VAR_pve_token_secret="$PVE_TOKEN_SECRET" \
    -e PKR_VAR_template_vmid="$template_vmid" \
    -e PKR_VAR_build_password="$build_password" \
    -e PKR_VAR_build_password_hash="$build_password_hash" \
    "$image" packer "$@"
}

case "$action" in
  validate) run_packer validate . ;;
  build)    run_packer build -timestamp-ui . ;;
  *) echo "usage: $0 [build|validate]" >&2; exit 2 ;;
esac
