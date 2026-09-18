#!/usr/bin/env bash
# Generalises the golden image so every Terraform clone boots with its own identity. Runs as root at the end of the build.
set -euxo pipefail

source /etc/os-release
[[ "$ID" == "rocky" && "$VERSION_ID" == "9.8" ]]
systemctl is-enabled vmtoolsd.service
systemctl is-active NetworkManager.service
systemctl set-default multi-user.target
! rpm -q gnome-shell
! rpm -q xorg-x11-server-Xorg

# Keep the build's static address active until Packer shuts the VM down, but make the saved NetworkManager profile use
# DHCP on the next boot. Clear interface/MAC binding because the provider gives every clone a new NIC and MAC.
connection=$(nmcli -t -f UUID,TYPE connection show --active | awk -F: '$2 == "802-3-ethernet" || $2 == "ethernet" {print $1; exit}')
[[ -n "$connection" ]]
nmcli connection modify "$connection" \
  connection.id k3slab-dhcp \
  connection.interface-name "" \
  802-3-ethernet.mac-address "" \
  ipv4.method auto \
  ipv4.addresses "" \
  ipv4.gateway "" \
  ipv4.dns "" \
  ipv4.ignore-auto-dns no \
  ipv4.dhcp-client-id mac \
  ipv6.method disabled
chmod 600 /etc/NetworkManager/system-connections/*

# SSH host keys must differ per clone: drop them now and regenerate on each clone's first boot.
cat >/etc/systemd/system/k3slab-ssh-hostkeys.service <<'EOF'
[Unit]
Description=Generate SSH host keys on the first boot of a cloned VM
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=sshd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target sshd.service
EOF
systemctl enable k3slab-ssh-hostkeys.service

dnf -y clean all
rm -rf /var/cache/dnf/*
rm -f /etc/ssh/ssh_host_*

# An empty machine-id makes systemd mint a new one on first boot (DHCP DUID, journald and kubelet identity all derive from it).
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
install -d -m 0755 /var/lib/dbus
ln -s /etc/machine-id /var/lib/dbus/machine-id

rm -rf /tmp/* /var/tmp/*
find /var/log -type f -exec truncate -s 0 {} +
sync
