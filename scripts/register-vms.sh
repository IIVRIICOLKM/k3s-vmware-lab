#!/usr/bin/env bash
# Registers every Terraform-managed VM in the VMware Workstation UI library.
# The vmworkstation provider creates and powers VMs through vmrest, but clones can be absent from
# ~/.vmware/inventory.vmls. This script reconciles that UI-only inventory without touching VM state.
# Usage: scripts/register-vms.sh
#
# [한국어 설명] Terraform이 만든 VM을 VMware Workstation 화면의 라이브러리 목록에 등록한다. (cluster-apply.sh 마지막에 호출)
#   provider로 복제한 VM은 실행은 되지만 UI 목록 파일(~/.vmware/inventory.vmls)에서 빠져 화면에 안 보일 수 있다.
#   vmrest 공식 등록 API(POST /vms/registration)로 "빠진 VM만" 등록 → 여러 번 실행해도 안전(멱등).
#   VM 전원·설정·디스크는 건드리지 않는다.

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 도움말(-h, --help)과 인자 검사 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)에서 앞의 "# "를 떼고 출력
#   → 한국어 설명 블록은 6번째 줄 이후에 있어야 도움말 출력이 바뀌지 않는다.
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit 0
fi
# 인자를 받지 않는 스크립트이므로 인자가 있으면 거부 ($# = 인자 개수)
(($# == 0)) || die "scripts/register-vms.sh takes no arguments (see --help)"

# Workstation UI 라이브러리 목록 파일
inventory="$HOME/.vmware/inventory.vmls"

# --- 2) inventory_path_count VMX경로 : UI 목록 파일에 그 VMX가 몇 번 등록돼 있는지 출력 ---
#   목록 파일의 `vmlist숫자.config = "VMX경로"` 줄에서 경로만 뽑고(sed), 정확히 같은 줄 수를 센다(awk).
#   0 = 미등록 → 등록 필요 / 1 = 정상 / 2 이상 = 중복 → 에러
inventory_path_count() {
  local vmx=$1
  if [[ ! -f "$inventory" ]]; then
    printf '0\n'
    return
  fi
  sed -n 's/^vmlist[0-9][0-9]*\.config = "\(.*\)"$/\1/p' "$inventory" |
    awk -v path="$vmx" '$0 == path {count++} END {print count + 0}'
}

# --- 3) Terraform output에서 노드 목록 읽기 ---
# nodes 예) {"k3s-server": {"id": "...", "path": ".../k3s-server.vmx", "ansible_groups": [...]}, ...}
# jq -e : 결과가 false/null이면 종료 코드 1 → 노드가 하나도 없으면 die
load_vmrest_env
nodes=$("$REPO_ROOT/scripts/tf.sh" output -json nodes)
jq -e 'type == "object" and length > 0' <<<"$nodes" >/dev/null ||
  die "Terraform output 'nodes' is empty; create the VMs before registering them"

# --- 4) 노드마다 반복: 이미 등록됐으면 건너뛰고, 없으면 vmrest API로 등록한 뒤 결과 확인 ---
# while ... done < <(jq -r 'keys[]' ...) : 노드 이름을 한 줄씩 읽어 반복 (< <(명령) = 명령 출력을 파일처럼 입력)
registered=0
already_present=0
while IFS= read -r name; do
  # 노드의 VMX 경로 (문자열이 아니거나 비어 있으면 jq -e가 실패 → 종료)
  vmx=$(jq -er --arg name "$name" '.[$name].path | select(type == "string" and length > 0)' <<<"$nodes")
  [[ -f "$vmx" ]] || die "managed VMX is missing for $name: $vmx"

  # 이미 정확히 1번 등록돼 있으면 건너뜀(continue), 2번 이상이면 중복이라 중단
  count=$(inventory_path_count "$vmx")
  ((count <= 1)) || die "$name appears $count times in $inventory; remove duplicate UI library entries before retrying"
  if ((count == 1)); then
    log "Workstation UI: $name already registered"
    already_present=$((already_present + 1))
    continue
  fi

  # 등록 요청 본문 {"name": 노드이름, "path": VMX경로} — jq로 만들어 따옴표 같은 특수문자를 안전하게 처리
  payload=$(jq -cn --arg name "$name" --arg path "$vmx" '{name:$name,path:$path}')
  # curl -w $'\n%{http_code}' : 응답 본문 뒤에 "줄바꿈 + HTTP 상태코드"를 덧붙여 한 변수로 받음
  #   ${response##*$'\n'} = 마지막 줄바꿈 뒤 = 상태코드 / ${response%$'\n'*} = 마지막 줄바꿈 앞 = 본문
  response=$(vmrest_api -w $'\n%{http_code}' -H "$VMREST_CT" -X POST --data "$payload" "$VMREST_BASE/vms/registration")
  code=${response##*$'\n'}
  body=${response%$'\n'*}
  # 검증 3가지: HTTP 201(Created)인지 / 응답의 path가 요청과 같고 id가 있는지 / 목록 파일에 정확히 1번 들어갔는지
  [[ "$code" == 201 ]] || die "failed to register $name in the Workstation UI (HTTP $code): $body"
  jq -e --arg path "$vmx" '.path == $path and (.id | type == "string" and length > 0)' <<<"$body" >/dev/null ||
    die "vmrest returned an unexpected registration response for $name: $body"
  [[ "$(inventory_path_count "$vmx")" == 1 ]] || die "vmrest registered $name but $inventory was not updated exactly once"

  log "Workstation UI: registered $name"
  registered=$((registered + 1))
done < <(jq -r 'keys[]' <<<"$nodes")

# 결과 요약: 새로 등록한 수, 이미 있던 수
log "Workstation UI inventory ready: $registered added, $already_present already present"
