# shellcheck shell=bash
# Shared helpers for k3s-vmware-lab scripts. Source this file; do not execute it.

# [한국어 설명] 모든 scripts/*.sh가 맨 위에서 `source`로 불러오는 공통 라이브러리.
#   실행하는 파일이 아니라 "불러오는" 파일이라서 실행 권한(+x)과 shebang(#!)이 없다.
#   여기서 정의하는 것: 경로 변수(LAB_*), vmrest 접속 정보(VMREST_*), 고정 버전(PIN_*),
#   공통 함수(log, die, load_vmrest_env, vmrest_api, vmrest_find_id_by_name, vmrest_power_state, workstation_default_vm_dir)

# --- 1) 경로 변수 (XDG 디렉터리 규칙) ---
# `${A:-B}` = A가 비어 있으면 B를 쓴다 → 환경변수로 덮어쓸 수 있고, 없으면 기본 경로를 쓴다.
#   데이터 (골든 이미지·VM·ISO)           : ~/.local/share/k3s-vmware-lab/{images,vms,iso-cache}
#   상태 (Terraform state·로그·백업)       : ~/.local/state/k3s-vmware-lab/{terraform,logs,...}
#   설정 (비밀 파일: 인증서·비밀번호·SSH 키) : ~/.config/k3s-vmware-lab/secrets
LAB_NAME="k3s-vmware-lab"
LAB_DATA_DIR="${LAB_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$LAB_NAME}"
LAB_STATE_DIR="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$LAB_NAME}"
LAB_CONFIG_DIR="${LAB_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/$LAB_NAME}"
LAB_SECRETS_DIR="$LAB_CONFIG_DIR/secrets"
LAB_LOG_DIR="$LAB_STATE_DIR/logs"
LAB_VM_DIR="$LAB_DATA_DIR/vms"
LAB_IMAGE_DIR="$LAB_DATA_DIR/images"
LAB_ISO_DIR="$LAB_DATA_DIR/iso-cache"
# REPO_ROOT = 저장소 최상위 경로. 이 파일(scripts/lib/common.sh)에서 두 단계 위(../..).
#   BASH_SOURCE[0]은 "지금 source된 파일 자신"의 경로라서, 어느 폴더에서 어떤 스크립트로 실행해도 정확하다.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- 2) vmrest 접속 정보 ---
# vmrest = VMware Workstation에 포함된 REST API 서버. Terraform provider와 스크립트가 이걸로 VM을 조작한다.
#   보안상 루프백(127.0.0.1) + HTTPS로만 쓴다. Accept / Content-Type은 vmrest 전용 MIME 타입 헤더.
VMREST_HOST="127.0.0.1"
VMREST_PORT="8697"
VMREST_BASE="https://$VMREST_HOST:$VMREST_PORT/api"
VMREST_ACCEPT="Accept: application/vnd.vmware.vmw.rest-v1+json"
VMREST_CT="Content-Type: application/vnd.vmware.vmw.rest-v1+json"

# --- 3) 고정 버전 목록(PIN_* 변수) 불러오기 → scripts/lib/pinned-versions.env ---
# shellcheck source=pinned-versions.env
source "$REPO_ROOT/scripts/lib/pinned-versions.env"

# --- 4) 출력 함수 ---
# log 메시지 : "시:분:초 메시지" 형식으로 출력
# die 메시지 : "FATAL: 메시지"를 에러 출력(stderr)으로 찍고 스크립트를 즉시 종료(exit 1)
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }

# --- 5) vmrest 자격증명 불러오기 ---
# load_vmrest_env : secrets/vmrest.env 파일(VMWS_USERNAME, VMWS_PASSWORD, VMWS_ENDPOINT)을 읽는다.
#   - 파일 권한이 600(소유자만 읽기·쓰기)이 아니면 중단 → 비밀번호 파일 보호
#   - `: "${VAR:?}"` = VAR가 비어 있으면 에러로 종료하는 관용구 (`:`는 아무 일도 안 하는 명령)
#   - 마지막 줄: TF_VAR_<이름> 환경변수 = Terraform 변수 var.<이름> 으로 전달된다
load_vmrest_env() {
  local f="$LAB_SECRETS_DIR/vmrest.env"
  [[ -f "$f" ]] || die "missing $f (see README: vmrest credentials)"
  [[ "$(stat -c %a "$f")" == "600" ]] || die "$f must be mode 600"
  # shellcheck disable=SC1090
  source "$f"
  : "${VMWS_USERNAME:?}" "${VMWS_PASSWORD:?}" "${VMWS_ENDPOINT:?}"
  # The provider marks endpoint/username/password as required, so its VMWS_* env fallback
  # never runs; Terraform has to receive them as (sensitive) input variables instead.
  export TF_VAR_vmws_endpoint="$VMWS_ENDPOINT" TF_VAR_vmws_username="$VMWS_USERNAME" TF_VAR_vmws_password="$VMWS_PASSWORD"
}

# --- 6) vmrest API 호출 함수들 ---
# vmrest_api [curl 옵션...] URL : 인증·인증서·Accept 헤더를 자동으로 붙여 curl을 실행하는 래퍼
#   - `--config -` : curl 설정("user = 아이디:비번")을 표준입력으로 받음 → ps 명령에 비밀번호가 보이지 않음
#   - `--cacert vmrest.crt` : 자체 서명 인증서를 실제로 검증한다 (검증을 끄는 -k 옵션은 쓰지 않음)
#   사용 예) vmrest_api "$VMREST_BASE/vms"  → VM 목록 JSON
# Credentials are fed through stdin so they never show up in the process list.
vmrest_api() {
  printf 'user = "%s:%s"\n' "$VMWS_USERNAME" "$VMWS_PASSWORD" |
    curl --silent --show-error --config - --cacert "$LAB_SECRETS_DIR/vmrest.crt" -H "$VMREST_ACCEPT" "$@"
}

# vmrest_find_id_by_name 이름 : 표시 이름(displayName)이 일치하는 VM의 vmrest id를 출력, 없으면 return 1
#   /vms 목록에는 id와 경로만 있어서, VM마다 /params/displayName을 하나씩 조회해 비교한다
vmrest_find_id_by_name() {
  local name=$1 id
  for id in $(vmrest_api "$VMREST_BASE/vms" | jq -r '.[].id'); do
    if [[ "$(vmrest_api "$VMREST_BASE/vms/$id/params/displayName" | jq -r '.value')" == "$name" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

# vmrest_power_state id : 전원 상태 문자열("poweredOn" / "poweredOff")을 출력
vmrest_power_state() { vmrest_api "$VMREST_BASE/vms/$1/power" | jq -r '.power_state'; }

# workstation_default_vm_dir : Workstation 설정 파일(~/.vmware/preferences)의 "새 VM 기본 저장 경로"를 출력
#   vmrest 복제 API는 저장 위치를 지정할 수 없어서 복제 VM은 항상 이 경로에 생긴다
#   → preflight.sh가 이 값이 LAB_VM_DIR과 같은지 검사한다
#   sed : `prefvmx.defaultVMPath = "경로"` 줄에서 따옴표 안의 경로만 추출 / 설정이 없으면 ~/vmware
workstation_default_vm_dir() {
  local v
  v=$(sed -n 's/^prefvmx\.defaultVMPath = "\(.*\)"$/\1/p' "$HOME/.vmware/preferences" 2>/dev/null | tail -1)
  printf '%s\n' "${v:-$HOME/vmware}"
}
