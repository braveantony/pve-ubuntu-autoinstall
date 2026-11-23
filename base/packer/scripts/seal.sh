#!/usr/bin/env bash
# Runs as root as the very last step before Packer shuts the VM down and
# converts it to a template. Removes everything that must not be shared
# between clones, including the account Packer is logged in as.
set -euo pipefail

: "${BUILD_USERNAME:?}"
self=$(readlink -f "$0")

echo "==> re-enabling cloud-init for clones"
# Subiquity ships /etc/cloud/clean.d/99-installer, which makes this command
# also delete the files the installer used to pin cloud-init to datasource
# "None" and switch it off after first boot, plus the installer's netplan file.
cloud-init clean --logs --machine-id --seed

# Belt and braces: fail loudly if any of them survived.
for f in \
    /etc/cloud/cloud-init.disabled \
    /etc/cloud/cloud.cfg.d/99-installer.cfg \
    /etc/cloud/cloud.cfg.d/00-subiquity-disable-cloudinit-networking.cfg \
    /etc/cloud/ds-identify.cfg \
    /etc/netplan/00-installer-config.yaml
do
    if [ -e "$f" ]; then
        echo "    removing leftover $f"
        rm -f "$f"
    fi
done

echo "==> removing per-machine identity"
rm -f /etc/ssh/ssh_host_*            # cloud-init regenerates host keys per clone
rm -f /var/lib/systemd/random-seed
rm -f /var/lib/dbus/machine-id
apt-get clean
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
rm -f /root/.bash_history

echo "==> deleting build account ${BUILD_USERNAME}"
rm -f "/etc/sudoers.d/90-cloud-init-users"
# --force: the account is still logged in (this very SSH session).
userdel --remove --force "${BUILD_USERNAME}" 2>&1 || true
if getent passwd "${BUILD_USERNAME}" >/dev/null; then
    echo "CHECK FAILED: ${BUILD_USERNAME} still exists" >&2
    exit 1
fi
if [ -d "/home/${BUILD_USERNAME}" ]; then rm -rf "/home/${BUILD_USERNAME}"; fi

rm -f "$self"
sync
echo "==> sealed"
