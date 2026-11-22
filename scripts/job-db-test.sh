#!/usr/bin/env bash
# Verifies job status in MySQL end to end (proposal slides 5, 11 and 14) through scripts/job.sh: registration,
# duplicate requests, an interrupted-and-resumed run, a MySQL restart during training, a bad request, an uploaded
# dataset and an inference job. Report: docs/labs/job-db-<date>.md
# Usage: scripts/job-db-test.sh [id-prefix]   (default: db-<MMDDHHMM>; needs scripts/mysql-deploy.sh and the images)
#
# [한국어 설명] MySQL 작업 상태 연동을 처음부터 끝까지 확인하고 보고서로 남긴다 (제안서 5·11·14번).
#   ① 등록: submit 직후 DB에 PENDING → 파드가 뜨면 RUNNING(attempts 1)
#   ② 중복 요청: 실행 중인 번호로 다시 submit → 새 Job을 만들지 않고 기존 상태를 돌려줌
#   ③ 학습 중단: 2 에폭 뒤 파드 삭제 → DB에 INTERRUPTED → 재시도 파드가 RUNNING(resumed_from, attempts 2)
#   ④ DB 중단: 학습 중에 MySQL을 내리고(replicas 0) 2 에폭 동안 둔 뒤 다시 올림 → 학습은 멈추지 않고,
#      그동안 못 쓴 기록은 메모리에 보류했다가 DB가 돌아오면 한꺼번에 기록됨 → DONE
#   ⑤ 완료 후 중복 요청: DONE인 번호로 submit → 학습하지 않음
#   ⑥ 잘못된 요청: 없는 데이터 파일 → DB FAILED + Job이 재시도 없이 바로 실패(podFailurePolicy, 파드 1개)
#   ⑦ 입력 파일 등록: .npz 파일을 upload → 그 파일로 학습해 DONE
#   ⑧ 추론 작업: 학습 결과를 서빙 → DB RUNNING, 요청 응답 확인 → stop → DONE
#   [인자] 작업 번호 앞부분(소문자·숫자·'-')
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
P=${1:-db-$(date +%m%d%H%M)}
ID="$P-train"          # ①~⑤ 학습 작업
BAD="$P-bad"           # ⑥ 잘못된 요청
NPZ_ID="$P-npz"        # ⑦ 업로드한 파일로 학습
SVC="$P-svc"           # ⑧ 추론 작업
JOB="train-$ID"
JOBSH="$REPO_ROOT/scripts/job.sh"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
REPORT="$REPO_ROOT/docs/labs/job-db-$(date +%Y%m%d-%H%M).md"
PASS=0
FAIL=0
mkdir -p "$(dirname "$REPORT")"

# k : 이 클러스터용 kubectl
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
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
# same 실제값 기대값 : 두 값이 같으면 성공 (check와 함께 씀. 여러 값은 '|'로 이어 한 번에 비교)
same() { [[ "$1" == "$2" ]]; }
# wait_for 제한초 명령... : 명령이 성공할 때까지 2초 간격으로 반복, 시간 초과면 return 1
wait_for() {
  local limit=$1 start=$SECONDS
  shift
  while ((SECONDS - start < limit)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
# db 쿼리 : MySQL 파드 안에서 앱 계정으로 실행 (job.sh와 같은 방식)
db() { k -n k3slab-system exec -i deploy/mysql -- sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -uk3slab -N -B -r k3slab' <<<"$1"; }
# field 작업번호 컬럼식 : jobs 행의 값 하나 (예: status, attempts, JSON_EXTRACT(detail, '$.epoch'))
field() { db "SELECT $2 FROM jobs WHERE job_id = '$1'"; }
# is 작업번호 상태 : DB 상태가 그 값이면 성공
is() { [[ "$(field "$1" status)" == "$2" ]]; }
# epoch_at_least 작업번호 N : DB에 기록된 에폭이 N 이상이면 성공
epoch_at_least() { local e; e=$(field "$1" "COALESCE(JSON_EXTRACT(detail, '\$.epoch'), 0)"); ((${e:-0} >= $2)); }
# has_event 작업번호 상태 [JSON경로] : 이력에 그 상태(그리고 경로가 있으면 그 값이 있는 행)가 있으면 성공
has_event() {
  local cond="1"
  [[ -n "${3:-}" ]] && cond="JSON_EXTRACT(detail, '$3') IS NOT NULL"
  [[ "$(db "SELECT COUNT(*) FROM job_events WHERE job_id = '$1' AND status = '$2' AND $cond")" -ge 1 ]]
}
# events 작업번호 : 상태 이력 표 (보고서용)
events() {
  db "SELECT DATE_FORMAT(CONVERT_TZ(at, '+00:00', '+09:00'), '%H:%i:%s'), status,
        COALESCE(JSON_UNQUOTE(JSON_EXTRACT(detail, '\$.epoch')), '-'),
        IF(JSON_EXTRACT(detail, '\$.resumed_from') IS NULL, '', 'resumed_from')
      FROM job_events WHERE job_id = '$1' ORDER BY id" | awk -F'\t' '{printf "%s  %-11s epoch %-3s %s\n", $1, $2, $3, $4}'
}
# pod_epoch 파드 : 그 파드 로그에서 마지막으로 끝난 에폭 번호 (체크포인트 파일 ckpt-eNNNN-s00200 기준, 없으면 0)
pod_epoch() {
  local out
  out=$(k logs "$1" 2>/dev/null || true)
  grep -o 'ckpt-e[0-9]*-s00200' <<<"$out" | sed 's/ckpt-e0*\([0-9]*\)-.*/\1/' | sort -n | tail -1 | grep . || echo 0
}
# epoch_passed 파드 N : 그 파드가 N 에폭까지 끝냈으면 성공
epoch_passed() { (($(pod_epoch "$1") >= $2)); }
# no_mysql_pod : MySQL 파드가 하나도 없으면 성공 (replicas 0 반영 확인)
no_mysql_pod() { [[ -z "$(k -n k3slab-system get pods -l app=mysql -o name)" ]]; }
# job_pod : 이 Job의 파드 중 삭제 대기 중이 아닌 최신 파드 이름
job_pod() {
  k get pods -l job-name="$1" -o json |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}
# job_cond Job이름 : Complete/Failed 조건 이름 (끝났을 때만 출력하고 성공)
job_cond() {
  local c
  c=$(k get job "$1" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null)
  grep -qE 'Complete|Failed' <<<"$c" && printf '%s\n' "$c"
}

{
  printf '# MySQL 작업 상태 연동 시험 (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 생성: `scripts/job-db-test.sh %s`\n' "$P"
  printf -- '- 경로: `scripts/job.sh` → MySQL `jobs`/`job_events` (worker-cpu-1) → Helm 학습 Job (gpu-host) → `apps/train/jobdb.py`가 상태 기록\n'
  printf -- '- 학습: 8 에폭 × 200 스텝, 에폭마다 6초 대기(중간에 끊고 DB를 재시작할 시간)\n'
} >"$REPORT"

# --- 2) ① 등록 → RUNNING ---
md "" "## 1. 등록과 실행"
"$JOBSH" submit train "$ID" --epochs 8 --epoch-sleep 6 >/dev/null
check "submit이 파드보다 먼저 DB에 PENDING을 기록 (이력의 첫 상태)" same "$(db "SELECT status FROM job_events WHERE job_id = '$ID' ORDER BY id LIMIT 1")" PENDING
wait_for 600 is "$ID" RUNNING || die "$ID never became RUNNING (scripts/job.sh status $ID)"
check "파드가 시작하면 RUNNING, attempts 1" same "$(field "$ID" attempts)" 1

# --- 3) ② 실행 중 중복 요청 ---
md "" "## 2. 실행 중 같은 번호로 다시 요청"
dup=$("$JOBSH" submit train "$ID" --epochs 8 2>&1)
block "scripts/job.sh submit train $ID (두 번째)" "$dup"
check "새로 실행하지 않고 기존 상태를 돌려줌" grep -q 'already exists' <<<"$dup"
check "Job은 여전히 1개 (Helm 리비전 1)" same "$(KUBECONFIG="$KUBECONFIG_FILE" helm history "train-$ID" -o json | jq length)" 1

# --- 4) ③ 2 에폭 뒤 파드 삭제 ---
md "" "## 3. 학습 중단과 재개"
wait_for 600 epoch_at_least "$ID" 2 || die "$ID did not reach epoch 2"
first=$(job_pod "$JOB")
log "deleting $first after epoch 2"
k delete pod "$first" --wait=true >/dev/null
wait_for 120 has_event "$ID" INTERRUPTED || true
wait_for 180 has_event "$ID" RUNNING '$.resumed_from' || true
check "DB에 INTERRUPTED 기록 (SIGTERM 시점 체크포인트)" has_event "$ID" INTERRUPTED
check "재시도 파드가 RUNNING + resumed_from 기록" has_event "$ID" RUNNING '$.resumed_from'
check "attempts 2 (재시도 횟수가 DB에 남음)" same "$(field "$ID" attempts)" 2

# --- 5) ④ 학습 중 MySQL 중단 ---
# rollout restart는 MySQL이 몇 초 만에 돌아와 재연결 한 번으로 끝난다. 그래서 replicas를 0으로 내려
# 학습이 2 에폭을 더 진행할 동안 DB가 없게 만든 뒤 다시 올린다 (보류된 기록이 나중에 채워지는지 보려는 것).
md "" "## 4. 학습 중 DB 중단 (2 에폭 동안)"
second=$(job_pod "$JOB")
base=$(pod_epoch "$second")
log "stopping MySQL while $second trains (pod at epoch $base)"
k -n k3slab-system scale deploy/mysql --replicas=0 >/dev/null
wait_for 120 no_mysql_pod || die "MySQL pod did not stop"
down_at=$(date +%H:%M:%S)
wait_for 180 epoch_passed "$second" $((base + 2)) || die "$second did not train while MySQL was down"
up_at=$(date +%H:%M:%S)
k -n k3slab-system scale deploy/mysql --replicas=1 >/dev/null
k -n k3slab-system rollout status deploy/mysql --timeout=5m >/dev/null
md "" "- MySQL 중단 $down_at → 재시작 $up_at. 그동안 학습 파드는 에폭 $base → $((base + 2)) 진행"
wait_for 600 job_cond "$JOB" || die "$JOB did not finish"
second_log=$(k logs "$second" 2>&1)
block "재시도 파드($second) 로그 중 DB 관련 줄" "$(grep -E '"db"' <<<"$second_log" | head -8)"
check "DB가 없는 동안에도 학습 계속 (기록을 보류: deferred)" grep -q '"db": "deferred"' <<<"$second_log"
check "Job Complete" grep -q Complete <<<"$(job_cond "$JOB")"
check "DB 최종 상태 DONE, result_path 기록" same "$(field "$ID" status)|$(field "$ID" "result_path IS NOT NULL")" "DONE|1"
check "DB가 없던 동안의 에폭 기록도 나중에 채워져 빠짐없이 남음 (에폭 1~8 완료 기록)" same "$(db "SELECT COUNT(DISTINCT JSON_EXTRACT(detail, '\$.epoch')) FROM job_events WHERE job_id = '$ID' AND status = 'RUNNING' AND JSON_EXTRACT(detail, '\$.loss') IS NOT NULL")" 8
block "상태 이력 (job_events)" "$(events "$ID")"

# --- 6) ⑤ 완료 후 중복 요청 ---
md "" "## 5. 완료된 번호로 다시 요청"
pods_before=$(k get pods -l job-name="$JOB" --no-headers | wc -l)
again=$("$JOBSH" submit train "$ID" --epochs 8 2>&1)
check "DONE인 번호는 다시 학습하지 않음 (기존 상태 반환, 새 파드 없음)" same "$(grep -c 'already exists' <<<"$again")|$(k get pods -l job-name="$JOB" --no-headers | wc -l)" "1|$pods_before"
block "scripts/job.sh result $ID" "$("$JOBSH" result "$ID" 2>&1)"

# --- 7) ⑥ 잘못된 요청 ---
md "" "## 6. 잘못된 요청 (없는 데이터 파일)"
"$JOBSH" submit train "$BAD" --dataset "npz:/data/missing-$P.npz" >/dev/null
wait_for 600 job_cond "train-$BAD" || die "train-$BAD did not finish"
check "DB FAILED + 오류 문구 기록" same "$(field "$BAD" status)|$(field "$BAD" "JSON_EXTRACT(detail, '\$.error') IS NOT NULL")" "FAILED|1"
check "Job이 재시도 없이 바로 실패 (podFailurePolicy, 파드 1개)" same "$(k get pods -l job-name="train-$BAD" --no-headers | wc -l)|$(k get job "train-$BAD" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}')" "1|PodFailurePolicy"
block "scripts/job.sh status $BAD" "$("$JOBSH" status "$BAD" 2>&1)"

# --- 8) ⑦ 입력 파일 등록 후 학습 ---
md "" "## 7. 입력 파일 등록 후 학습"
# 시험용 데이터: 3개 클래스, 16차원, 600행. numpy 없이 만들 수 있게 .npy를 직접 써서 zip(npz)으로 묶는다
npz_dir=$(mktemp -d)
python3 - "$npz_dir/demo-$P.npz" <<'PY'
import random, struct, sys, zipfile
def npy(dtype, shape, values, fmt):
    header = "{'descr': '%s', 'fortran_order': False, 'shape': %s, }" % (dtype, repr(tuple(shape)))
    header += " " * (63 - (len(header) + 10) % 64) + "\n"
    return b"\x93NUMPY\x01\x00" + struct.pack("<H", len(header)) + header.encode() + struct.pack("<%d%s" % (len(values), fmt), *values)
random.seed(3)
xs, ys = [], []
for i in range(600):
    c = i % 3
    ys.append(c)
    xs += [random.gauss(2.0 * (c - 1) if d < 4 else 0.0, 1.0) for d in range(16)]
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("x.npy", npy("<f4", (600, 16), xs, "f"))
    z.writestr("y.npy", npy("<i8", (600,), ys, "q"))
PY
up=$("$JOBSH" upload "$npz_dir/demo-$P.npz" 2>&1)
rm -rf "$npz_dir"
block "scripts/job.sh upload demo-$P.npz" "$up"
"$JOBSH" submit train "$NPZ_ID" --epochs 2 --hidden 32 --dataset "npz:/data/demo-$P.npz" >/dev/null
wait_for 600 job_cond "train-$NPZ_ID" || die "train-$NPZ_ID did not finish"
check "업로드한 파일로 학습해 DONE (dataset 기록)" same "$(field "$NPZ_ID" status)|$(field "$NPZ_ID" "JSON_UNQUOTE(JSON_EXTRACT(detail, '\$.dataset'))")" "DONE|npz:/data/demo-$P.npz"
block "scripts/job.sh result $NPZ_ID" "$("$JOBSH" result "$NPZ_ID" 2>&1)"

# --- 9) ⑧ 추론 작업 ---
md "" "## 8. 추론 작업 (①의 학습 결과 서빙)"
"$JOBSH" submit infer "$SVC" --model-job "$ID" >/dev/null
check "추론 작업 RUNNING" is "$SVC" RUNNING
answer=$(k run "curl-$SVC" --rm -i --restart=Never --quiet --image=docker.io/curlimages/curl:8.23.0 -- \
  sh -c "awk 'BEGIN { srand(1); printf \"{\\\"x\\\":[\"; for (i = 0; i < 64; i++) printf \"%s%.4f\", (i ? \",\" : \"\"), rand() * 2 - 1; print \"]}\" }' > /tmp/b.json && curl -s -X POST --data @/tmp/b.json http://infer-$SVC:8080/infer" 2>/dev/null || true)
block "POST /infer 응답" "$answer"
check "추론 응답에 클래스와 모델 버전" grep -q '"class"' <<<"$answer"
"$JOBSH" stop "$SVC" >/dev/null
check "stop 후 DONE" is "$SVC" DONE

block "scripts/job.sh list" "$("$JOBSH" list 10 2>&1)"
md "" "## 결과 요약" "" "PASS $PASS, FAIL $FAIL"
log "job db test: PASS $PASS, FAIL $FAIL (prefix $P, report: $REPORT)"
((FAIL == 0))
