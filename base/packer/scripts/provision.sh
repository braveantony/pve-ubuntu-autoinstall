#!/usr/bin/env bash
# Runs as root inside the freshly installed VM (first boot from disk).
# Fails the build early if the install is not what the template promises.
set -euo pipefail

echo "==> waiting for first-boot cloud-init to finish"
cloud-init status --wait || true

fail() { echo "CHECK FAILED: $*" >&2; exit 1; }

echo "==> checking the installed system"
root_src=$(findmnt -n -o SOURCE /)
[ "$root_src" = "/dev/mapper/ubuntu--vg-ubuntu--lv" ] || fail "root is on $root_src, expected ubuntu-vg/ubuntu-lv"
findmnt -n /boot >/dev/null || fail "/boot is not a separate filesystem"
dpkg -s linux-generic >/dev/null 2>&1 || fail "linux-generic is not installed"
if grep -q 'console=' /proc/cmdline; then fail "kernel command line has console=: $(cat /proc/cmdline)"; fi
if grep -qw autoinstall /proc/cmdline; then fail "'autoinstall' leaked into the installed kernel command line"; fi
[ "$(vgs --noheadings -o vg_free_count ubuntu-vg | tr -d ' ')" = "0" ] || fail "ubuntu-vg still has free extents"
systemctl is-enabled --quiet qemu-guest-agent || systemctl is-active --quiet qemu-guest-agent || fail "qemu-guest-agent is not enabled"
command -v growpart >/dev/null || fail "growpart (cloud-guest-utils) is missing"

echo "    kernel : $(uname -r)"
echo "    cmdline: $(cat /proc/cmdline)"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT

echo "==> installing grow-root-lvm"
install -o root -g root -m 0755 /tmp/grow-root-lvm /usr/local/sbin/grow-root-lvm
install -o root -g root -m 0644 /tmp/grow-root-lvm.service /etc/systemd/system/grow-root-lvm.service
rm -f /tmp/grow-root-lvm /tmp/grow-root-lvm.service
systemctl daemon-reload
systemctl enable grow-root-lvm.service
# Prove it is a clean no-op on a disk that is already full size.
/usr/local/sbin/grow-root-lvm

echo "==> provision checks passed"
