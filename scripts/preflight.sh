#!/usr/bin/env bash
# Read-only host checks for the k3s-vmware-lab workflow. Changes nothing; exits 1 on any FAIL.
#
# [한국어 설명] 호스트 사전 점검. 아무것도 바꾸지 않고(읽기 전용) 검사 결과만 출력한다. entry.sh 3단계.
#   [PASS] 정상  [WARN] 주의(진행은 함)  [FAIL] 문제(하나라도 있으면 종료 코드 1 → entry.sh 중단)  [INFO] 참고
#   검사 순서: 프로젝트 파일 → 호스트 → 도구 버전 → VMware 커널 모듈 → vmnet8 NAT → vmrest
#             → 비밀 파일·경로 권한 → 관리 VM·UI 목록 → Rocky ISO → 디스크·메모리
#             → provider 잠금 해시 → Packer 플러그인 해시 → 골든 이미지 무결성 → 원격 접속 표시

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 결과 카운터와 출력 함수 ---
# warn / fail 은 출력과 함께 카운터를 1 올린다.
# check_eq "항목" 실제값 고정값 : 같으면 PASS, 다르면 FAIL
fails=0
warns=0
pass() { printf '  [PASS] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '  [INFO] %s\n' "$*"; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1: $2"; else fail "$1: found '$2', pinned '$3'"; fi; }

# --- 1) 프로젝트 파일: verify-project.sh (필수 파일·실행 권한·Bash 문법) 실행 ---
echo "== Project files"
if "$REPO_ROOT/scripts/verify-project.sh"; then
  pass "required files, permissions, and Bash syntax"
else
  fail "project file verification failed (see output above)"
fi

# --- 2) 호스트가 Linux x86_64인지 ---
# `조건 && pass ... || fail ...` : 조건이 참이면 pass, 거짓이면 fail (한 줄짜리 if/else처럼 사용)
echo "== Host"
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] && pass "Linux x86_64, kernel $(uname -r)" || fail "unsupported host $(uname -s)/$(uname -m)"

# --- 3) 도구 버전: 각 도구의 버전 출력에서 숫자만 뽑아 PIN_* 고정값과 비교 ---
# ${PIN_VERIFIED_ON:+, verified ...} : 값이 있을 때만 ", verified 날짜"를 붙임
echo "== Pinned tool versions (status: $PIN_STATUS${PIN_VERIFIED_ON:+, verified $PIN_VERIFIED_ON})"
check_eq "VMware Workstation" "$(vmware --version 2>/dev/null | awk '{print $3" "$4}')" "$PIN_WORKSTATION_VERSION $PIN_WORKSTATION_BUILD"
check_eq "vmrest" "$(vmrest -v 2>/dev/null | awk '/^vmrest /{print $2}')" "$PIN_VMREST_VERSION"
check_eq "terraform" "$(terraform version -json 2>/dev/null | jq -r .terraform_version)" "$PIN_TERRAFORM_VERSION"
check_eq "packer" "$(packer version 2>/dev/null | awk 'NR==1{sub(/^v/,"",$2); print $2}')" "$PIN_PACKER_VERSION"
# ansible refuses to start when stdio handles are non-blocking, so give it plain files/pipes.
check_eq "ansible-core" "$(ansible --version </dev/null 2>/dev/null | awk -F'[][ ]+' 'NR==1{print $3}')" "$PIN_ANSIBLE_CORE_VERSION"
# helm version --template로 "v4.3.1"을 받아 앞의 v를 뗀다 (${v#v} = 맨 앞 "v" 하나 제거)
helm_v=$(helm version --template '{{.Version}}' 2>/dev/null || true)
check_eq "helm" "${helm_v#v}" "$PIN_HELM_VERSION"
info "guest image target: $PIN_GUEST_OS"

# --- 4) VMware 커널 모듈 (vmmon: VM 실행, vmnet: 가상 네트워크) ---
# 지금 커널에 모듈이 로드돼 있는지(lsmod), 그 커널용 .ko 파일이 빌드돼 있는지 확인
echo "== VMware kernel modules"
running=$(uname -r)
for m in vmmon vmnet; do
  lsmod | awk '{print $1}' | grep -qx "$m" && pass "$m loaded" || fail "$m not loaded"
  [[ -f "/lib/modules/$running/misc/$m.ko" ]] && pass "$m.ko built for $running" ||
    fail "$m.ko missing for $running (maintenance: sudo vmware-modconfig --console --install-all)"
done
# 설치된 커널 중 가장 최신 버전(sort -V = 버전 순 정렬)에 vmmon.ko가 없으면 → 다음 재부팅 후 VMware가 안 뜬다고 경고
# Workstation does not rebuild its modules on kernel updates; this is what made vmware.service fail at boot on 2026-09-11.
newest=$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V | tail -1)
if [[ "$newest" != "$running" && ! -f "/lib/modules/$newest/misc/vmmon.ko" ]]; then
  warn "newest installed kernel $newest has no vmmon.ko: VMware will fail after the next reboot; before rebooting run (console): scripts/vmware-modules.sh --install $newest"
fi
# KVM 모듈(kvm_amd)이 같이 로드돼 있으면 참고 정보로만 표시 (VMware와 함께 동작함을 확인했음)
if lsmod | awk '{print $1}' | grep -qx kvm_amd; then
  info "kvm_amd loaded (kvm.enable_virt_at_load=$(cat /sys/module/kvm/parameters/enable_virt_at_load 2>/dev/null || echo n/a)); coexistence with VMware $PIN_WORKSTATION_VERSION verified 2026-09-18"
fi

# --- 5) VMware NAT 네트워크: vmnet8에 IPv4 주소가 있는지, DHCP(vmnet-dhcpd)·NAT(vmnet-natd) 데몬이 도는지 ---
echo "== VMware NAT network (vmnet8)"
v8=$(ip -4 -o addr show dev vmnet8 2>/dev/null | awk '{print $4}')
[[ -n "$v8" ]] && pass "vmnet8 up with $v8" || fail "vmnet8 has no IPv4 address"
pgrep -f 'vmnet-dhcpd .*vmnet8' >/dev/null && pass "vmnet-dhcpd (vmnet8) running" || fail "vmnet-dhcpd for vmnet8 not running"
pgrep -x vmnet-natd >/dev/null && pass "vmnet-natd running" || fail "vmnet-natd not running"

# --- 6) vmrest: 포트가 열려 있는지 → 루프백에만 열렸는지 → 인증서·자격증명으로 실제 API 호출(HTTP 200)이 되는지 ---
echo "== vmrest"
listeners=$(ss -Hltn "( sport = :$VMREST_PORT )" | awk '{print $4}')
if [[ -z "$listeners" ]]; then
  fail "vmrest not listening on :$VMREST_PORT (start it with scripts/vmrest-start.sh)"
elif grep -qvE "^(127\.0\.0\.1|\[::1\]):$VMREST_PORT$" <<<"$listeners"; then
  fail "vmrest reachable beyond loopback: $(tr '\n' ' ' <<<"$listeners")"
else
  pass "vmrest bound to loopback only ($listeners)"
fi
if [[ -f "$LAB_SECRETS_DIR/vmrest.env" ]]; then
  load_vmrest_env
  code=$(vmrest_api -o /dev/null -w '%{http_code}' "$VMREST_BASE/vms" 2>/dev/null || true)
  [[ "$code" == "200" ]] && pass "vmrest HTTPS auth OK (certificate verified)" || fail "vmrest auth/TLS check returned HTTP ${code:-none}"
else
  fail "missing $LAB_SECRETS_DIR/vmrest.env"
fi

# --- 7) 비밀 파일과 로컬 경로 ---
#   secrets 폴더 0700, 안의 파일 모두 0600 / 데이터·상태 폴더 존재
#   Terraform state 폴더 0700, state 파일 0600 / Workstation 기본 VM 경로 = LAB_VM_DIR
#   (stat -c %a = 권한을 숫자로 출력. 예: 600)
echo "== Secrets and local paths"
[[ "$(stat -c %a "$LAB_SECRETS_DIR" 2>/dev/null)" == "700" ]] && pass "$LAB_SECRETS_DIR is 0700" || fail "$LAB_SECRETS_DIR must exist with mode 0700"
while IFS= read -r f; do
  [[ "$(stat -c %a "$f")" == "600" ]] || fail "$f is not 0600"
done < <(find "$LAB_SECRETS_DIR" -type f 2>/dev/null)
for d in "$LAB_VM_DIR" "$LAB_IMAGE_DIR" "$LAB_ISO_DIR" "$LAB_STATE_DIR/terraform"; do
  [[ -d "$d" ]] && pass "exists: $d" || fail "missing: $d"
done
tf_state_dir="$LAB_STATE_DIR/terraform"
[[ "$(stat -c %a "$tf_state_dir" 2>/dev/null)" == "700" ]] && pass "$tf_state_dir is 0700" || fail "$tf_state_dir must be mode 0700 (state may hold sensitive values)"
while IFS= read -r f; do
  [[ "$(stat -c %a "$f")" == "600" ]] || fail "$f is not 0600"
done < <(find "$tf_state_dir" -type f -name 'terraform.tfstate*' 2>/dev/null)
# vmrest's clone API has no destination argument; clones always land in Workstation's default VM path.
default_vm_dir=$(workstation_default_vm_dir)
check_eq "Workstation prefvmx.defaultVMPath" "$default_vm_dir" "$LAB_VM_DIR"

# --- 8) Terraform이 관리하는 VM: VMX 파일이 있는지, Workstation UI 목록에 정확히 1번 등록돼 있는지 ---
#   state가 아직 없으면(첫 구축 전) 건너뜀. 미등록은 WARN(cluster-apply.sh가 등록함), 중복은 FAIL
#   jq @tsv : "이름<탭>VMX경로" 줄로 출력 → while IFS=$'\t' read 로 두 칸씩 읽음
echo "== Managed VMs and Workstation UI library"
tf_state="$LAB_STATE_DIR/terraform/terraform.tfstate"
if [[ -s "$tf_state" ]]; then
  nodes=$("$REPO_ROOT/scripts/tf.sh" output -json nodes 2>/dev/null || true)
  if jq -e 'type == "object" and length > 0' <<<"$nodes" >/dev/null 2>&1; then
    inventory="$HOME/.vmware/inventory.vmls"
    while IFS=$'\t' read -r name vmx; do
      [[ -f "$vmx" ]] && pass "$name VMX exists" || fail "$name VMX missing: $vmx"
      count=0
      if [[ -f "$inventory" ]]; then
        count=$(sed -n 's/^vmlist[0-9][0-9]*\.config = "\(.*\)"$/\1/p' "$inventory" |
          awk -v path="$vmx" '$0 == path {count++} END {print count + 0}')
      fi
      if ((count == 1)); then
        pass "$name appears in the Workstation UI library"
      elif ((count > 1)); then
        fail "$name appears $count times in the Workstation UI library"
      else
        warn "$name is absent from the Workstation UI library; scripts/cluster-apply.sh will register it"
      fi
    done < <(jq -r 'to_entries[] | [.key, .value.path] | @tsv' <<<"$nodes")
  else
    fail "Terraform state exists but output 'nodes' cannot be read"
  fi
else
  info "no Terraform state yet; managed VM file/UI checks start after the first apply"
fi

# --- 9) Rocky ISO 크기·해시 확인 + 예전(Ubuntu 시절) 산출물이 남아 있지 않은지 ---
echo "== Rocky Linux installation media"
rocky_iso="$LAB_ISO_DIR/$PIN_ROCKY_ISO_FILENAME"
if [[ -f "$rocky_iso" ]]; then
  check_eq "Rocky ISO size" "$(stat -c %s "$rocky_iso")" "$PIN_ROCKY_ISO_SIZE"
  check_eq "Rocky ISO SHA-256" "$(sha256sum "$rocky_iso" | cut -d' ' -f1)" "$PIN_ROCKY_ISO_SHA256"
else
  info "Rocky ISO not downloaded yet (scripts/fetch-rocky-iso.sh)"
fi
legacy=$(find "$LAB_IMAGE_DIR" "$LAB_VM_DIR" "$LAB_ISO_DIR" -maxdepth 3 -iname '*ubuntu*' -print -quit 2>/dev/null)
[[ -z "$legacy" ]] && pass "no active Ubuntu guest artifacts" || fail "legacy Ubuntu guest artifact remains: $legacy"

# --- 10) 용량: 디스크 여유 40G 이상, 사용 가능 메모리 14G 이상 (VM 3대가 12G 사용) — 부족하면 WARN ---
# tr -dc '0-9' : 숫자가 아닌 문자(예: "G") 제거 / MemAvailable(kB) ÷ 1048576 = GB
echo "== Capacity"
avail_gb=$(df -BG --output=avail "$LAB_DATA_DIR" | tail -1 | tr -dc '0-9')
((avail_gb >= 40)) && pass "free disk under $LAB_DATA_DIR: ${avail_gb}G" || warn "only ${avail_gb}G free under $LAB_DATA_DIR (golden image + 3 VMs need ~40G)"
mem_gb=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
((mem_gb >= 14)) && pass "available memory: ${mem_gb}G" || warn "available memory ${mem_gb}G; the 3-VM cluster reserves 12G"

# --- 11) Terraform provider 잠금 파일(.terraform.lock.hcl)에 고정 해시("zh:...")가 들어 있는지 ---
# ${변수:0:12} : 문자열 앞 12글자만 (출력용)
echo "== Terraform provider lock"
lock="$REPO_ROOT/infra/terraform/.terraform.lock.hcl"
if [[ -f "$lock" ]]; then
  grep -q "zh:$PIN_PROVIDER_VMWORKSTATION_ZIP_SHA256_LINUX_AMD64" "$lock" &&
    pass "lock file pins provider zip sha256 ${PIN_PROVIDER_VMWORKSTATION_ZIP_SHA256_LINUX_AMD64:0:12}..." ||
    fail "lock file does not contain the pinned provider hash"
else
  info "no infra/terraform/.terraform.lock.hcl yet"
fi

# --- 12) Packer vmware 플러그인 바이너리의 SHA-256이 infra/packer/plugins.sha256 기록과 같은지 ---
# plugins.sha256 줄 형식: "해시  플러그인주소 버전 OS_아키텍처 파일명" → read로 칸별 분리 (_ = 버리는 칸)
echo "== Packer plugin"
while read -r sum _ ver _ bin; do
  f="$HOME/.config/packer/plugins/github.com/hashicorp/vmware/$bin"
  if [[ ! -f "$f" ]]; then
    info "packer plugin $ver not installed yet (packer init infra/packer/templates)"
  elif [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "$sum" ]]; then
    pass "packer plugin vmware $ver matches infra/packer/plugins.sha256"
  else
    fail "packer plugin $bin differs from infra/packer/plugins.sha256"
  fi
done < <(grep -v '^#' "$REPO_ROOT/infra/packer/plugins.sha256")

# --- 13) 골든 이미지: 이름 규칙 / SHA256SUMS 일치(빌드 후 변경 없음) / image.json상 Server·GUI 없음 / VMX·VMDK 읽기 전용 ---
# shopt -s nullglob : 일치하는 파일이 없으면 패턴 문자열 대신 빈 배열이 되게 함 (끝에서 다시 끔)
# find -perm /222 : 누구에게든 쓰기 권한이 하나라도 있는 파일
echo "== Golden images (must stay unchanged and read-only)"
shopt -s nullglob
images=("$LAB_IMAGE_DIR"/*/SHA256SUMS)
((${#images[@]})) || info "no golden image built yet (scripts/golden-build.sh)"
for sums in "${images[@]}"; do
  dir=$(dirname "$sums")
  [[ "$(basename "$dir")" == k3slab-golden-rocky98-* ]] && pass "$(basename "$dir"): Rocky 9.8 image name" || fail "unexpected golden image: $(basename "$dir")"
  (cd "$dir" && sha256sum --quiet -c SHA256SUMS >/dev/null 2>&1) && pass "$(basename "$dir"): files match SHA256SUMS" || fail "$(basename "$dir"): files changed since the build"
  jq -e '.os == "Rocky Linux 9.8 Server (no GUI)" and .package_profile == "server-product-environment" and .graphical_environment == false' "$dir/image.json" >/dev/null 2>&1 &&
    pass "$(basename "$dir"): Server profile, GUI disabled" || fail "$(basename "$dir"): image metadata does not prove Rocky Server/no-GUI"
  writable=$(find "$dir" -maxdepth 1 \( -name '*.vmx' -o -name '*.vmdk' \) -perm /222 -printf '%f ')
  [[ -z "$writable" ]] && pass "$(basename "$dir"): VMX/VMDK are read-only" || fail "$(basename "$dir"): writable golden files: $writable"
done
shopt -u nullglob

# --- 14) 원격 접속 표시: TeamViewer·KRFB(KDE 원격 데스크톱)·SSH 세션이 있으면 정보로 알림 ---
#   이 스크립트들은 호스트 네트워크·서비스를 건드리지 않는다는 안내 (원격 작업 중 안전 확인용)
echo "== Remote-session guard"
remote=$(pgrep -a -f 'teamviewerd|krfb|sshd: .*@' 2>/dev/null | awk '{print $2}' | xargs -r -n1 basename | sort -u | tr '\n' ' ')
[[ -n "$remote" ]] && info "remote access active ($remote); these scripts never touch host networking or services" || true

# --- 결과 요약: FAIL이 0개면 종료 코드 0, 아니면 1 (스크립트의 마지막 명령 결과가 종료 코드가 됨) ---
echo
echo "preflight: $fails FAIL, $warns WARN"
((fails == 0))
