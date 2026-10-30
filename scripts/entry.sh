#!/usr/bin/env bash
# Provisions the whole lab by calling the stage scripts in order:
#   vmrest-start -> fetch-rocky-iso -> preflight -> golden-build -> tf init -> cluster-apply (+ Workstation UI registration) -> render-inventory
#   -> ansible ping.yml -> ansible site.yml
# Every stage is re-runnable, so the same command builds the lab the first time and brings it back later
# (for example after a host reboot). If a stage fails, fix the cause and run it again.
# Usage: scripts/entry.sh
#
# [한국어 설명] 실습 환경 전체를 한 번에 구축·복구하는 진입점. 아래 단계별 스크립트를 순서대로 "호출만" 한다.
#   1 vmrest-start.sh       VMware REST API 서버 시작
#   2 fetch-rocky-iso.sh    Rocky ISO 다운로드·서명 검증 (이미 있으면 검증만)
#   3 preflight.sh          호스트 사전 점검 (읽기 전용, FAIL이 있으면 여기서 중단)
#   4 golden-build.sh       골든 이미지 빌드 (이미 있으면 건너뜀)
#   5 tf.sh init            Terraform 초기화
#   6 cluster-apply.sh      VM 3대 생성 · 전원 켜기 · Workstation UI 등록
#   7 render-inventory.sh   VM IP를 모아 Ansible 인벤토리 생성
#   8 ping.yml              Ansible SSH 접속 확인
#   9 site.yml              OS 공통 설정 + K3s 설치
#   모든 단계가 다시 실행해도 안전(멱등)하므로, 실패하면 원인만 고치고 같은 명령을 다시 실행하면 된다.
#
# 엄격 모드: -E 함수 안에서 난 에러에도 ERR trap 동작 · -e 실패 즉시 종료 · -u 미정의 변수 금지 · -o pipefail 파이프 중간 실패 감지
set -Eeuo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 도움말(-h, --help)과 인자 검사 ---
# sed -n '2,7s/^# \{0,1\}//p' "$0" : 이 파일 2~7번째 줄(영문 설명)의 "# "를 떼고 출력
#   → 한국어 설명 블록은 8번째 줄 이후라 도움말에 영향 없음. 영문 설명 줄 수를 바꾸면 '2,7'도 같이 고칠 것.
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,7s/^# \{0,1\}//p' "$0"
  exit 0
fi
# 인자를 받지 않음 ($# = 인자 개수)
(($# == 0)) || die "scripts/entry.sh takes no arguments (see --help)"

# --- 2) 빌드할 골든 이미지 버전 결정 ---
# sed : variables.tf의 `variable "golden_vm_name" {` ~ `}` 블록 안 `default = "값"` 줄에서 값만 추출
# ${golden_name#"$GOLDEN_PREFIX"-} : 앞의 "k3slab-golden-rocky98-"를 떼어 버전(예: 20260918-1)만 남김
# Terraform clones the image named by golden_vm_name in infra/terraform/variables.tf, so build exactly that version.
GOLDEN_PREFIX="k3slab-golden-rocky98"
golden_name=$(sed -n '/^variable "golden_vm_name"/,/^}/s/^ *default *= *"\(.*\)"$/\1/p' "$REPO_ROOT/infra/terraform/variables.tf")
[[ "$golden_name" == "$GOLDEN_PREFIX"-* ]] || die "golden_vm_name default in infra/terraform/variables.tf must start with $GOLDEN_PREFIX-"
GOLDEN_VERSION="${golden_name#"$GOLDEN_PREFIX"-}"

# --- 3) Ansible 가상환경(venv)이 준비돼 있는지 확인 (없으면 README "시작하기 > 1. 준비" 안내 후 종료) ---
VENV="$LAB_DATA_DIR/ansible-venv"
[[ -f "$VENV/bin/activate" ]] || die "missing $VENV (see README: 시작하기 > 1. 준비)"

# --- 4) 단계 실행·시간 측정 도구 ---
# STEPS : 전체 단계 수 / step : 지금 몇 번째 단계인지
# timing_* : 단계별 번호·이름·걸린 초를 모아 두는 배열 (마지막에 표로 출력)
STEPS=9
step=0
declare -a timing_steps=()
declare -a timing_names=()
declare -a timing_seconds=()

# duration 초 : 60초 이상이면 "1m 05s", 미만이면 "38s" 형식으로 출력
duration() {
  local total="$1"
  if ((total >= 60)); then
    printf '%dm %02ds' "$((total / 60))" "$((total % 60))"
  else
    printf '%ds' "$total"
  fi
}

# run "단계 이름" 명령 [인자...] : 단계 번호를 올리고 로그를 찍은 뒤 명령을 실행, 끝나면 걸린 시간을 기록
#   명령이 실패하면 set -e 때문에 그 자리에서 스크립트가 멈추고 아래 ERR trap이 실행된다
#   SECONDS = bash 내장 변수(스크립트 시작 후 지난 초)
run() {
  local name="$1"
  shift
  local started=$SECONDS
  step=$((step + 1))
  log "[$step/$STEPS] $name: $*"
  "$@"
  local elapsed=$((SECONDS - started))
  timing_steps+=("$step")
  timing_names+=("$name")
  timing_seconds+=("$elapsed")
  log "[$step/$STEPS] $name completed in $(duration "$elapsed")"
}

# skip "단계 이름" "이유" : 실행하지 않은 단계도 표에서 빠지지 않게 0초로 기록
skip() {
  local name="$1"
  local reason="$2"
  step=$((step + 1))
  timing_steps+=("$step")
  timing_names+=("$name")
  timing_seconds+=("0")
  log "[$step/$STEPS] $name skipped: $reason"
}

# print_timing_table : 모아 둔 단계별 시간을 표로 출력하고 합계 계산
#   ${!timing_steps[@]} = 배열 인덱스 목록 (0 1 2 ...)
print_timing_table() {
  printf '\n%-6s %-24s %s\n' "Step" "Task" "Elapsed"
  printf '%-6s %-24s %s\n' "----" "------------------------" "-------"
  local i total=0
  for i in "${!timing_steps[@]}"; do
    printf '%-6s %-24s %s\n' "${timing_steps[$i]}/$STEPS" "${timing_names[$i]}" "$(duration "${timing_seconds[$i]}")"
    total=$((total + timing_seconds[i]))
  done
  printf '%-6s %-24s %s\n' "Total" "all steps" "$(duration "$total")"
  printf '\n'
}
# 실패 처리(ERR trap) : 몇 번째 단계의 어떤 명령($BASH_COMMAND)에서 실패했는지와 "고치고 다시 실행" 안내 출력
trap 'log "FAILED at step $step/$STEPS: $BASH_COMMAND"; log "fix the cause and re-run scripts/entry.sh; completed stages are skipped or make no changes"' ERR

# --- 5) 1~3단계: vmrest 시작 → ISO 확인 → 사전 점검 (저장소 최상위 폴더에서 실행) ---
cd "$REPO_ROOT"
run "vmrest 시작" scripts/vmrest-start.sh
run "Rocky ISO 확인" scripts/fetch-rocky-iso.sh
run "사전 점검" scripts/preflight.sh

# --- 6) 4단계: 골든 이미지 — 이미 폴더가 있으면 건너뜀 (이미지는 불변이라 다시 빌드하지 않음) ---
if [[ -d "$LAB_IMAGE_DIR/$golden_name" ]]; then
  skip "기준 이미지" "$golden_name already exists (images are immutable)"
else
  run "기준 이미지" scripts/golden-build.sh "$GOLDEN_VERSION"
fi

# --- 7) 5~7단계: Terraform 초기화 → VM 생성·전원·UI 등록 → 인벤토리 생성 ---
run "Terraform 준비" scripts/tf.sh init
run "VM 상태 + UI 목록" scripts/cluster-apply.sh -auto-approve
run "IP 목록 생성" scripts/render-inventory.sh

# --- 8) 8~9단계: Ansible 가상환경을 켜고, ansible.cfg가 있는 infra/ansible 폴더에서 플레이북 실행 ---
# shellcheck disable=SC1091
source "$VENV/bin/activate"
cd infra/ansible
run "SSH 확인" ansible-playbook playbooks/ping.yml
run "OS + K3s" ansible-playbook playbooks/site.yml

# --- 9) 마무리: 노드 목록 조회 → 단계별 시간 표 출력 → 완료 로그 ---
# jq 'keys | join(", ")' : {"k3s-server": …, "worker-cpu-1": …} → "k3s-server, worker-cpu-1, …"
nodes=$("$REPO_ROOT/scripts/tf.sh" output -json nodes)
print_timing_table
log "provisioning complete: golden image $golden_name, nodes $(jq -r 'keys | join(", ")' <<<"$nodes")"
