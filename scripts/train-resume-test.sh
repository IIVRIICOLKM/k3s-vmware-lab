#!/usr/bin/env bash
# Verifies the training job contract on the GPU host (proposal slides 11 and 15): a training pod that is deleted in
# the middle of a run is retried by its Job and resumes from the last checkpoint, the run finishes on the GPU with an
# exported model, and a second request with the same job id is not trained again. Report: docs/labs/train-resume-<date>.md
# Usage: scripts/train-resume-test.sh [job-id] [image-tag]   (defaults: resume-<MMDDHHMM>, the tag in values-train.yaml)
#
# [한국어 설명] 학습 Job의 약속을 gpu-host에서 실제로 확인하고 보고서로 남긴다 (제안서 11·15번).
#   ① Helm으로 학습 Job 실행 (작업 번호 = Job 이름, 체크포인트는 gpu-host /var/lib/k3slab/checkpoints/<번호>/)
#   ② 2 에폭 체크포인트가 생긴 뒤 파드를 삭제 → 파드는 SIGTERM을 받아 체크포인트를 남기고 종료
#   ③ Job이 새 파드로 다시 시도 → 새 파드가 마지막 체크포인트에서 이어서 학습(resumed_from)하는지
#   ④ 끝까지 학습해 DONE, GPU(cuda)에서 돌았는지, model.k3sm(추론 워커용)이 생겼는지
#   ⑤ 같은 작업 번호로 다시 요청 → 학습하지 않고 기존 DONE을 돌려주는지 (중복 실행 방지)
#   [인자] 작업 번호(소문자·숫자·'-'), 이미지 태그
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자와 상수 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit 0
fi
JOB_ID=${1:-resume-$(date +%m%d%H%M)}
CHART="$REPO_ROOT/charts/k3slab-workload"
VALUES="$CHART/values-train.yaml"
TAG=${2:-$(awk '/^  tag:/ {print $2; exit}' "$VALUES")}
RELEASE="train-$JOB_ID"
JOB="train-$JOB_ID"
CKPT_DIR="/var/lib/k3slab/checkpoints/$JOB_ID"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
REPORT="$REPO_ROOT/docs/labs/train-resume-$(date +%Y%m%d-%H%M).md"
PASS=0
FAIL=0
mkdir -p "$(dirname "$REPORT")"

# k / h : 이 클러스터용 kubectl·helm
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
h() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }
# md 줄... : 보고서 끝에 줄 추가 / block "제목" 내용 : 제목과 코드 블록을 추가
md() { printf '%s\n' "$@" >>"$REPORT"; }
block() { md "" "**$1**" "" '```text' "$2" '```'; }
# check "설명" 명령... : 성공하면 PASS, 아니면 FAIL로 집계해 보고서에 남김
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); md "" "- ✅ **PASS** — $desc"; log "PASS $desc"
  else
    FAIL=$((FAIL + 1)); md "" "- ❌ **FAIL** — $desc"; log "FAIL $desc"
  fi
}
# job_pod : 이 Job의 파드 중 삭제 대기 중이 아닌 것의 이름 (재시도 중이면 새 파드)
job_pod() {
  k get pods -l job-name="$JOB" -o json |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}
# logs_have 파드 문자열 : 그 파드 로그에 문자열이 있으면 성공 (로그를 먼저 받아서 검사 — pipefail+grep -q 함정 회피)
logs_have() { local out; out=$(k logs "$1" 2>/dev/null) && grep -q "$2" <<<"$out"; }
# job_finished : Job 조건에 Complete 또는 Failed가 있으면 그 이름을 출력하고 성공
job_finished() {
  local c
  c=$(k get job "$JOB" -o jsonpath='{.status.conditions[?(@.status=="True")].type}')
  grep -qE 'Complete|Failed' <<<"$c" && printf '%s\n' "$c"
}
# has_pod : 이 Job의 파드가 하나라도 생겼으면 성공
has_pod() { [[ -n "$(job_pod)" ]]; }
# new_pod 이전파드이름 : 이전 파드와 다른(재시도) 파드가 생겼으면 성공
new_pod() { local p; p=$(job_pod); [[ -n "$p" && "$p" != "$1" ]]; }
# wait_for 제한초 명령... : 명령이 성공할 때까지 3초 간격으로 반복, 시간 초과면 return 1
wait_for() {
  local limit=$1 start=$SECONDS
  shift
  while ((SECONDS - start < limit)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}
# install : 학습 Job을 Helm으로 실행 (에폭 6, 에폭 사이 3초 대기 → 중간에 끊을 시간을 둔다)
install() {
  h upgrade --install "$RELEASE" "$CHART" -f "$VALUES" --set train.jobId="$JOB_ID" --set image.tag="$TAG" \
    --set train.epochs=6 --set train.epochSleep=3 >/dev/null
}

{
  printf '# 학습 중단·재개 시험 (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 생성: `scripts/train-resume-test.sh %s %s`\n' "$JOB_ID" "$TAG"
  printf -- '- 이미지 `registry.k3slab.local:5000/train-worker:%s`, 6 에폭 × 200 스텝, 체크포인트 `%s` (gpu-host)\n' "$TAG" "$CKPT_DIR"
} >"$REPORT"

# --- 2) ① 실행 → ② 2 에폭 뒤 파드 삭제 ---
log "start $RELEASE (image tag $TAG)"
install
wait_for 600 has_pod || die "no pod for $JOB"
first=$(job_pod)
# 2 에폭 체크포인트(ckpt-e0002-s00200)가 로그에 찍힐 때까지 대기 (첫 실행은 이미지 pull 포함)
wait_for 900 logs_have "$first" 'ckpt-e0002-s00200' || die "$first did not reach epoch 2 (see kubectl logs $first)"
# 파드를 지우면 로그도 사라지므로, 지우기 전에 logs -f로 따라가며 끝(SIGTERM 처리 결과)까지 파일에 받아 둔다
first_log=$(mktemp)
k logs -f "$first" >"$first_log" 2>&1 &
follow=$!
sleep 1
log "deleting $first in the middle of the run"
k delete pod "$first" --wait=true >/dev/null
wait "$follow" || true
md "" "## 1. 중단"
block "첫 파드($first) 로그 — 2 에폭 뒤 삭제(SIGTERM)" "$(cat "$first_log")"

# --- 3) ③ 재시도 파드가 체크포인트에서 이어서 학습하는지 ---
wait_for 120 new_pod "$first" || die "the Job did not start a new pod after $first was deleted"
second=$(job_pod)
wait_for 600 job_finished || die "$JOB did not finish (see kubectl logs $second)"
result=$(job_finished)
md "" "## 2. 재시도와 재개"
block "재시도 파드($second) 로그" "$(k logs "$second")"
# 호스트 경로라 gpu-host(이 PC)에서 직접 읽을 수 있다
block "체크포인트 폴더 ($CKPT_DIR)" "$(ls -l "$CKPT_DIR")"
block "status.json" "$(cat "$CKPT_DIR/status.json")"
check "첫 파드가 SIGTERM에 체크포인트를 남기고 INTERRUPTED로 끝남" grep -q '"status": "INTERRUPTED"' "$first_log"
check "재시도 파드가 체크포인트에서 이어서 학습 (resumed_from)" logs_have "$second" 'resumed_from'
check "Job 결과 Complete" grep -q Complete <<<"$result"
check "GPU(cuda)에서 학습" logs_have "$second" '"device": "cuda"'
check "최종 상태 DONE + 추론용 model.k3sm 생성" sh -c "grep -q '\"status\": \"DONE\"' '$CKPT_DIR/status.json' && test -s '$CKPT_DIR/model.k3sm'"

# --- 4) ⑤ 같은 작업 번호로 다시 요청 ---
md "" "## 3. 같은 작업 번호로 다시 요청"
h uninstall "$RELEASE" >/dev/null
k delete job "$JOB" --ignore-not-found --wait=true >/dev/null
install
wait_for 300 job_finished || die "the repeated request did not finish"
third=$(job_pod)
block "다시 요청한 파드($third) 로그" "$(k logs "$third")"
check "이미 DONE인 작업은 다시 학습하지 않음" logs_have "$third" 'already DONE'

rm -f "$first_log"
md "" "## 결과 요약" "" "PASS $PASS, FAIL $FAIL" "" "학습 결과 모델(추론 워커용): \`$CKPT_DIR/model.k3sm\`. 이 작업 번호를 \`infer.modelJobId\`로 쓴다."
log "train resume test: PASS $PASS, FAIL $FAIL (job $JOB_ID, report: $REPORT)"
((FAIL == 0))
