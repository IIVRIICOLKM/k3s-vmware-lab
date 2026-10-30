#!/usr/bin/env bash
# Builds the Rocky Linux 9.8 Server (no GUI) golden image with Packer, records SHA-256 of its VMX/VMDK, makes them read-only and registers
# the VM in vmrest so Terraform can clone it. Images are immutable: an existing version is never rebuilt.
# Usage: scripts/golden-build.sh [version]   (default: YYYYMMDD-1)
#
# [한국어 설명] Packer로 Rocky Linux 9.8 "골든 이미지"(모든 노드 VM의 복제 원본)를 만든다. entry.sh 4단계, 약 11분.
#   흐름: ISO 재검증 → 빌드용 고정 IP 결정 → packer build (Kickstart 무인 설치 + finalize.sh)
#         → VMX displayName 대소문자 보정 → SHA-256 기록·읽기 전용 잠금 → vmrest 등록 → image.json 기록
#   이미지는 불변: 같은 버전 폴더가 이미 있으면 덮어쓰지 않고 중단 → 새 버전 번호로 빌드해야 한다.
#   [인자] 버전 (예: 20260918-1, 생략하면 "오늘날짜-1")
#     Terraform이 복제하는 이름은 infra/terraform/variables.tf의 golden_vm_name과 같아야 한다.

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"
# umask 077 : 이후 만드는 로그·이미지 파일을 소유자 전용으로
# The Packer log contains the rendered Kickstart (password hash); keep logs and image files owner-only.
umask 077

# --- 1) 이름·경로 결정 ---
# VERSION : 첫 번째 인자, 없으면 오늘날짜-1  /  VM_NAME 예) k3slab-golden-rocky98-20260918-1
# OUT : 이미지가 생길 폴더 (~/.local/share/k3s-vmware-lab/images/<VM_NAME>)  /  LOG : Packer 상세 로그
VERSION="${1:-$(date +%Y%m%d)-1}"
NAME="k3slab-golden-rocky98"
VM_NAME="$NAME-$VERSION"
ISO="$LAB_ISO_DIR/$PIN_ROCKY_ISO_FILENAME"
OUT="$LAB_IMAGE_DIR/$VM_NAME"
TEMPLATES="$REPO_ROOT/infra/packer/templates"
LOG="$LAB_LOG_DIR/golden-build-$VM_NAME.log"

# --- 2) 사전 검사: ISO 존재·크기·SHA-256, 같은 버전 이미지가 이미 있는지 ---
[[ -f "$ISO" ]] || die "missing $ISO (run scripts/fetch-rocky-iso.sh first)"
[[ "$(stat -c %s "$ISO")" == "$PIN_ROCKY_ISO_SIZE" ]] || die "$ISO has the wrong size"
[[ "$(sha256sum "$ISO" | cut -d' ' -f1)" == "$PIN_ROCKY_ISO_SHA256" ]] || die "$ISO failed SHA-256 verification"
[[ ! -e "$OUT" ]] || die "$OUT already exists; images are immutable, pass a new version"
# vmrest 자격증명과 콘솔 로그인 비밀번호 해시(GOLDEN_CONSOLE_PASSWORD_SHA512) 불러오기
load_vmrest_env
# shellcheck disable=SC1091
source "$LAB_SECRETS_DIR/golden-console.env"
mkdir -p "$LAB_LOG_DIR"

# --- 3) 빌드 VM의 고정 IP 정하기 ---
# vmnet8 주소(예: 172.16.133.1/24) → ${vmnet8_cidr%.*} 로 마지막 ".숫자/24"를 잘라 "172.16.133"만 남김
#   빌드 VM = .10 (BUILD_IP 환경변수로 변경 가능), 게이트웨이 = .2
# 그 주소에 이미 응답하는 장비가 있으면(ping 성공) IP 충돌이므로 중단
# Static build address on vmnet8 (below its .128-.254 DHCP pool); the NAT gateway is .2 on VMware desktop hypervisors.
vmnet8_cidr=$(ip -4 -o addr show dev vmnet8 | awk '{print $4}')
[[ "$vmnet8_cidr" == */24 ]] || die "expected a /24 on vmnet8, found '$vmnet8_cidr'"
net3=${vmnet8_cidr%.*}
export PKR_VAR_build_ip="${BUILD_IP:-$net3.10}"
export PKR_VAR_build_gateway="$net3.2"
if ping -c 2 -W 1 "$PKR_VAR_build_ip" >/dev/null 2>&1; then
  die "build address $PKR_VAR_build_ip already answers on vmnet8; pick another with BUILD_IP=..."
fi

# --- 4) Packer 변수 전달: PKR_VAR_<이름> 환경변수 = Packer 템플릿의 변수 <이름> ---
#   이미지 버전·저장 위치·ISO 경로·콘솔 비밀번호 해시·Ansible이 쓸 SSH 공개키/개인키
#   (공개키는 대입과 export를 두 줄로 나눔: 한 줄로 쓰면 $(cat ...) 실패가 export의 성공에 가려진다)
export PKR_VAR_image_version="$VERSION"
export PKR_VAR_image_root="$LAB_IMAGE_DIR"
export PKR_VAR_iso_path="$ISO"
export PKR_VAR_admin_password_hash="$GOLDEN_CONSOLE_PASSWORD_SHA512"
PKR_VAR_ssh_public_key="$(cat "$LAB_SECRETS_DIR/ansible_ed25519.pub")"
export PKR_VAR_ssh_public_key
export PKR_VAR_ssh_private_key_file="$LAB_SECRETS_DIR/ansible_ed25519"

# --- 5) Packer 실행: 플러그인 설치(init) → 템플릿 문법 검사(validate) → 빌드(build) ---
log "packer init + validate"
packer init "$TEMPLATES"
packer validate "$TEMPLATES"

# PACKER_LOG=1 + PACKER_LOG_PATH : 상세 로그를 파일로 저장 (비밀번호 해시가 담긴 Kickstart가 기록되므로 umask 077로 보호)
log "packer build $VM_NAME (headless; log: $LOG)"
PACKER_LOG=1 PACKER_LOG_PATH="$LOG" packer build -color=false "$TEMPLATES"

# --- 6) VMX의 displayName 키 대소문자 보정 ---
# Packer writes every VMX key in lower case. VMware ignores key case, but vmrest's /params lookups do not, and the
# provider finds VMs (and reads their names) through /params/displayName; without this, lookups return "".
sed -i 's/^displayname = /displayName = /' "$OUT/$VM_NAME.vmx"
grep -q '^displayName = ' "$OUT/$VM_NAME.vmx" || die "no displayName in $OUT/$VM_NAME.vmx"

# --- 7) 무결성 기록과 읽기 전용 잠금 ---
# SHA256SUMS : VMX/VMDK 해시 목록 (preflight.sh가 매번 비교해서 이미지가 바뀌었는지 확인)
# chmod 0444 : 모두 읽기만 가능 → 실수로 원본 이미지를 수정하지 못하게
log "record SHA-256, lock the image read-only"
(cd "$OUT" && sha256sum ./*.vmx ./*.vmdk >SHA256SUMS)
chmod 0444 "$OUT"/*.vmx "$OUT"/*.vmdk
cat "$OUT/SHA256SUMS"

# --- 8) vmrest에 등록 → Terraform이 이 이름으로 원본 VM을 찾아 복제할 수 있게 됨 ---
# -o /dev/null -w '%{http_code}' : 응답 본문은 버리고 HTTP 상태 코드만 받음 (201 = 등록 성공)
# 등록 후 NIC가 정확히 custom/vmnet8 한 개인지 확인 (provider 2.0.1 복제가 성공하는 조합)
log "register in vmrest as '$VM_NAME'"
code=$(vmrest_api -o /dev/null -w '%{http_code}' -H "$VMREST_CT" -X POST \
  -d "{\"name\":\"$VM_NAME\",\"path\":\"$OUT/$VM_NAME.vmx\"}" "$VMREST_BASE/vms/registration")
[[ "$code" == "201" ]] || die "vmrest registration returned HTTP $code"
ID=$(vmrest_find_id_by_name "$VM_NAME") || die "registration did not show up in vmrest"
NIC=$(vmrest_api "$VMREST_BASE/vms/$ID/nic" | jq -c '[.nics[] | {type, vmnet}]')
[[ "$NIC" == '[{"type":"custom","vmnet":"vmnet8"}]' ]] || die "golden NIC is $NIC, expected custom/vmnet8"

# --- 9) image.json 메타데이터 기록: 이름·vmrest id·ISO·OS·생성 시각·Packer 버전·해시 ---
#   preflight.sh가 이 파일로 "Rocky Server, GUI 없음" 이미지인지 확인한다
jq -n --arg name "$VM_NAME" --arg id "$ID" --arg iso "$(basename "$ISO")" --arg os "$PIN_GUEST_OS" --arg profile "server-product-environment" --arg created "$(date -Is)" \
  --arg packer "$(packer version | head -1)" --rawfile sums "$OUT/SHA256SUMS" \
  '{name: $name, vmrest_id: $id, iso: $iso, os: $os, package_profile: $profile, graphical_environment: false, created: $created, packer: $packer, sha256sums: $sums}' >"$OUT/image.json"
log "golden image ready: $VM_NAME (vmrest id $ID); set golden_vm_name in infra/terraform accordingly"
