#!/usr/bin/env bash
# Generalises the golden image so every Terraform clone boots with its own identity. Runs as root at the end of the build.
#
# [한국어 설명] 골든 이미지 일반화 스크립트. 호스트가 아니라 "빌드 중인 게스트 VM 안에서" root로 실행된다.
#   (rocky-golden.pkr.hcl의 shell provisioner가 VM에 업로드한 뒤 `sudo -E bash finalize.sh`로 실행)
#   목적: 이 이미지를 복제한 VM들이 서로 다른 정체성(IP·MAC·SSH 호스트 키·machine-id)으로 부팅되도록
#         빌드 VM 고유 정보를 지우고, 복제본 첫 부팅 때 새로 만들어지게 설정한다.
#
# 엄격 모드 + -x (실행하는 명령을 한 줄씩 출력 → Packer 로그에서 어디서 실패했는지 보기 쉬움)
set -euxo pipefail

# --- 1) 설치 결과 검증 (한 줄이라도 실패하면 set -e로 빌드 실패) ---
#   Rocky 9.8인지 / VMware Tools 서비스 활성 / NetworkManager 동작 중 / 텍스트 모드(multi-user) 부팅
#   `! rpm -q 패키지` = 그 패키지가 "설치돼 있지 않아야" 성공 → GUI(gnome-shell, Xorg)가 없음을 보장
source /etc/os-release
[[ "$ID" == "rocky" && "$VERSION_ID" == "9.8" ]]
systemctl is-enabled vmtoolsd.service
systemctl is-active NetworkManager.service
systemctl set-default multi-user.target
! rpm -q gnome-shell
! rpm -q xorg-x11-server-Xorg

# --- 2) 부팅 화면 정리: 그래픽 부팅(rhgb)·quiet 옵션 제거, 커널 콘솔 로그 레벨 3 (에러 이상만 표시) ---
# VMware should hand off directly to tty1. K3s loads deprecated iptables/ipset modules whose warning-level messages
# would otherwise scroll the login prompt off the local console.
grubby --update-kernel=ALL --remove-args="rhgb quiet" --args="loglevel=3"

# --- 3) 네트워크를 DHCP로 전환 ---
#   지금은 Packer가 고정 IP(.10)로 SSH 접속 중이므로 "현재 연결"은 유지하고 "저장된 프로필"만 수정한다.
#   인터페이스 이름·MAC 고정을 지워야 복제본(새 NIC·새 MAC)에서도 이 프로필이 적용된다.
#   nmcli -t -f UUID,TYPE ... : 활성 연결 중 유선(ethernet) 연결의 UUID를 찾음
#   ipv4.dhcp-client-id mac : MAC 기준으로 DHCP 요청 → 같은 VM은 대체로 같은 IP를 받음 / IPv6는 끔
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

# --- 4) SSH 호스트 키: 복제본마다 달라야 하므로 첫 부팅 때 새로 만드는 systemd 서비스를 등록 ---
#   ConditionPathExists=!키파일 → 키가 없을 때만 실행 (두 번째 부팅부터는 자동으로 건너뜀), sshd보다 먼저 실행
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

# --- 5) 정리: 패키지 캐시 삭제, 빌드 VM의 SSH 호스트 키 삭제 (위 서비스가 복제본에서 새로 생성) ---
dnf -y clean all
rm -rf /var/cache/dnf/*
rm -f /etc/ssh/ssh_host_*

# --- 6) machine-id 비우기 → 복제본마다 첫 부팅 때 새로 생성 (dbus용 machine-id는 /etc/machine-id를 가리키는 링크로) ---
# An empty machine-id makes systemd mint a new one on first boot (DHCP DUID, journald and kubelet identity all derive from it).
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
install -d -m 0755 /var/lib/dbus
ln -s /etc/machine-id /var/lib/dbus/machine-id

# --- 7) 임시 파일 삭제, 로그 파일 내용 비우기, 디스크 기록 확정(sync) ---
rm -rf /tmp/* /var/tmp/*
find /var/log -type f -exec truncate -s 0 {} +
sync
