#!/usr/bin/env bash
# End-to-end test of the CI/CD link: one code commit -> Jenkins checks and Kaniko build -> a new immutable image tag -> the tag is committed
# to the GitOps values file -> Argo CD syncs -> a new pod runs the new image digest. Then a commit with a failing unit test must change nothing.
# Usage: scripts/cicd-e2e-test.sh [--plan] [--seed] [--base-ref REF] [--no-block] [--no-resync] [--keep]
#   --plan  offline: show what the test commit contains    --seed  only push the "before" code to Gitea (Jenkins builds it)    --keep  leave the GPU pod running
# Needs: Jenkins (ci), Argo CD + Gitea, Prometheus; scripts/argocd-source.sh ci-init done. Starts one GPU pod. Report: docs/labs/cicd-e2e-<date>.md
#
# [한국어 설명] 코드 변경이 사람 손 없이 배포까지 이어지는지 처음부터 끝까지 확인하고, 단계마다 시각과 걸린 시간을 보고서로 남긴다.
#   시험할 변경은 추론 워커의 지연 히스토그램(apps/infer/metrics.cpp, metrics.h)이다. 클러스터 안 Gitea(k3slab/k3s-vmware-lab)가 코드와 배포 값의 출처다.
#   0. 사전 확인   Jenkins·Gitea·Argo CD·Prometheus가 준비됐고 Jenkins 작업이 Gitea를 보는지, 빌드가 돌고 있지 않은지, 시계가 맞는지
#   1. 기준선      Gitea의 코드를 "변경 전" 상태(작업 폴더에서 metrics 두 파일만 BASE_REF 것으로 바꾼 사본)로 맞춘다. 다르면 새로 올리고
#                  그 커밋의 CI·배포가 끝나기를 기다린다. Application이 없으면 만든다(GPU 1개). 기준선 파드는 CI가 만든 이미지로 돌고 /metrics에 버킷이 없다.
#   2. 성공 경로   변경 커밋 하나를 Gitea에 올린다 → Jenkins가 폴링으로 알아채고 → 검사 → 이미지 → 태그 커밋(k3slab ci) → Argo CD sync → 새 파드 Ready.
#                  단계별 시각을 재고, 새 파드의 digest가 CI가 기록한 digest와 같은지, 태그 커밋이 다시 빌드를 부르지 않았는지 확인한다.
#                  새 파드에 부하를 주고 Prometheus에서 k3slab_infer_request_seconds 버킷, p50/p95를 읽는다.
#   3. 차단 경로   단위 시험이 실패하는 커밋(버킷 경계 off-by-one) 하나를 올린다 → 빌드는 C++ 단계에서 실패하고 이미지·태그 커밋·배포가 없고
#                  기존 파드가 그대로인지 확인한다. 끝나면 그 커밋을 revert하고, revert 커밋이 정상으로 배포되는 것까지 본다.
#   4. 정리        Application을 지웠다 다시 만들어 첫 sync 시간을 이미지가 노드에 있는 상태로 다시 재고(DNS 수정 전 21초와 비교), 지워서 GPU를 돌려준다.
#   [주의] GPU를 1장 쓴다(추론 파드). 총괄에게 '시작'을 알린 뒤 실행하고 끝나면 '반납'을 알린다. Jenkins 빌드는 gpu-host에서 돈다(CPU 1코어 안팎).
#   [실패하면] 우회하지 않고 멈춘다(보고서에 멈춘 이유를 남긴다). 멈춰도 종료할 때 Application을 지워 GPU를 돌려준다(--keep이면 지우지 않음).
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자와 상수 ---
# sed -n '2,6s/^# \{0,1\}//p' "$0" : 이 파일 2~6번째 줄(영문 설명)을 도움말로 출력
usage() {
  sed -n '2,6s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}
PLAN=0 SEED=0 RUN_BLOCK=1 RESYNC=1 KEEP=0 BASE_REF=""
while (($#)); do
  case "$1" in
    -h | --help) usage 0 ;;
    --plan) PLAN=1 ;;
    --seed) SEED=1 ;;
    --base-ref) BASE_REF=${2:?--base-ref needs a value}; shift ;;
    --no-block) RUN_BLOCK=0 ;;
    --no-resync) RESYNC=0 ;;
    --keep) KEEP=1 ;;
    *) usage 1 ;;
  esac
  shift
done

JOB="k3slab-ci"                                   # 운영 Jenkins 작업 (Gitea main을 1분마다 폴링)
CI_NS="ci"
ARGO_NS="argocd"
APP_NS="k3slab-apps"
APP="infer"                                       # Application = Helm 릴리스 = Deployment·Service 이름
VALUES_FILE="charts/k3slab-workload/values-infer-argocd.yaml"
CI_PATHS=(Jenkinsfile apps charts scripts infra tests)   # Gitea에 두는 최상위 경로 (jenkins-run.sh의 스냅샷과 같다)
# 시험할 코드 변경 = 지연 히스토그램 구현(metrics.cpp, metrics.h) + 그 단위 시험(tests/infer/test_metrics.cpp) + 이 시험을 도는 C++ 단계 스크립트.
#   시험과 단계 스크립트는 구현과 짝이라 같은 커밋에 들어간다. 변경 전 사본에는 단위 시험이 없고 옛 단계 스크립트가 있다(그래야 변경 전 코드가 통과한다).
CHANGE_FILES=(apps/infer/metrics.cpp apps/infer/metrics.h tests/infer/test_metrics.cpp scripts/jenkins-stage-cpp.sh)
BAD_FILE="apps/infer/metrics.cpp"
BAD_SED='s/us > kBoundsUs\[i\]/us >= kBoundsUs[i]/'      # 차단 시험: 경계값이 위 버킷으로 가는 off-by-one (단위 시험만 잡는다)
SOURCE_SH="$REPO_ROOT/scripts/argocd-source.sh"
DEPLOY_SH="$REPO_ROOT/scripts/argocd-deploy.sh"
REGISTRY_SH="$REPO_ROOT/scripts/jenkins-registry.sh"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
REPORT="$REPO_ROOT/docs/labs/cicd-e2e-$(date +%Y%m%d-%H%M).md"
POLL_WAIT=300        # 커밋 뒤 Jenkins가 빌드를 시작하기까지 기다리는 최대 초 (폴링 1분 + 여유)
BUILD_WAIT=2400      # 빌드 하나가 끝나기까지 최대 초 (베이스 이미지를 처음 받으면 오래 걸릴 수 있다)
SETTLE=75            # 태그 커밋 뒤 "다시 빌드가 시작되지 않았다"를 확인하기까지 기다리는 초 (폴링 주기 60초보다 길게)
PASS=0 FAIL=0 APP_STARTED=0
PF_PID=""
WORK=$(mktemp -d)
declare -A MS=()     # 시각 기록: "<라벨>.<이름>" → epoch 밀리초
declare -A INFO=()   # 그 밖의 값(문자열)

# k : 이 클러스터용 kubectl (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
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
# cleanup : 종료할 때 port-forward를 닫고, (--keep이 아니면) 남은 Application을 지워 GPU를 돌려주고, 임시 폴더를 지운다. 시험이 중간에 멈춰도 실행된다.
cleanup() {
  [[ -z "$PF_PID" ]] || kill "$PF_PID" 2>/dev/null || true
  if ((APP_STARTED && !KEEP)); then
    log "cleanup: deleting Application $APP (the GPU pod goes away with it)"
    "$DEPLOY_SH" app-down || log "WARNING: app-down failed; delete it by hand: kubectl -n $ARGO_NS delete application $APP"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
# stuck 설명 : 기다리던 조건이 안 맞아 멈출 때 상태를 보고서에 남기고 종료한다 (우회하지 않는다)
stuck() {
  block "멈춘 이유: $1" "$(app_state 2>&1 || true)
$(k -n "$APP_NS" get pods -o wide 2>&1 || true)
$(k -n "$CI_NS" get pods 2>&1 || true)"
  md "" "## 결과 요약" "" "중단됨: $1 (PASS $PASS, FAIL $FAIL)"
  die "$1 (see $REPORT)"
}

# --- 2) 시각 도우미 ---
# now_ms : 지금 시각(epoch 밀리초)   iso_ms ISO시각 : 초 단위 ISO 시각 → 밀리초   hms 밀리초 : 시:분:초(이 컴퓨터의 시간대)   secs 시작ms 끝ms : 걸린 초(소수 1자리)
now_ms() { date +%s%3N; }
iso_ms() { echo $(($(date -d "$1" +%s) * 1000)); }
hms() { date -d "@$(($1 / 1000))" +%H:%M:%S; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }
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
# wait_until_ms 시각ms : 그 시각이 될 때까지 기다린다
wait_until_ms() { while (($(now_ms) < $1)); do sleep 1; done; }

# --- 3) 변경 트리 만들기 (클러스터 없이 확인할 수 있다) ---
# all_eq 값1 값2 [값3 값4]... : 짝을 이룬 값이 모두 같으면 성공 (check에 조건을 여러 개 넘길 때)
all_eq() {
  while (($# >= 2)); do
    [[ "$1" == "$2" ]] || return 1
    shift 2
  done
}
# default_base_ref : 변경 파일이 작업 폴더에서 아직 커밋되지 않았으면 HEAD, 이미 커밋됐으면 그 커밋의 부모 (= 변경 전 상태)
default_base_ref() {
  local last
  if git -C "$REPO_ROOT" diff --quiet HEAD -- "${CHANGE_FILES[@]}"; then
    last=$(git -C "$REPO_ROOT" log -1 --format=%H -- "${CHANGE_FILES[@]}")
    if [[ -n "$last" ]]; then echo "$last^"; else echo HEAD; fi
  else
    echo HEAD
  fi
}
# export_tree 폴더 [base] : Gitea에 둘 경로의 파일(git이 아는 것: 추적 + 새 파일 중 .gitignore에 안 걸리는 것)을 폴더로 복사한다.
#   base이면 변경 파일 두 개를 BASE_REF 의 내용으로 바꾼다 (= 변경 전 사본). BASE_REF에 없던 파일이면 지운다.
export_tree() {
  local dir=$1 mode=${2:-work} f
  mkdir -p "$dir"
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard -- "${CI_PATHS[@]}" |
    while IFS= read -r -d '' f; do [[ -f "$f" ]] && printf '%s\0' "$f"; done | xargs -0 -r cp --parents -t "$dir")
  if [[ "$mode" == base ]]; then
    for f in "${CHANGE_FILES[@]}"; do
      if git -C "$REPO_ROOT" cat-file -e "$BASE_REF:$f" 2>/dev/null; then
        git -C "$REPO_ROOT" show "$BASE_REF:$f" >"$dir/$f"
      else
        rm -f "$dir/$f"
      fi
    done
  fi
}
[[ -n "$BASE_REF" ]] || BASE_REF=$(default_base_ref)
git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null || die "--base-ref $BASE_REF is not a commit of this repository"
export_tree "$WORK/base" base
export_tree "$WORK/dev" work
# 변경 = 정확히 CHANGE_FILES 뿐이어야 한다 (그래야 "커밋 하나 = 히스토그램 변경"이다). 파일마다 "해시 경로"를 뽑아 두 목록의 차이에서 경로만 모은다.
tree_sums() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); }
changed=$( (LC_ALL=C diff <(tree_sums "$WORK/base") <(tree_sums "$WORK/dev") || true) | sed -n -E 's/^[<>] [0-9a-f]{64}  \.\/(.*)$/\1/p' | sort -u)
wanted=$(printf '%s\n' "${CHANGE_FILES[@]}" | sort)
[[ -n "$changed" ]] || die "the working tree has no change in ${CHANGE_FILES[*]} compared with $BASE_REF (nothing to deploy; use --base-ref)"
[[ "$changed" == "$wanted" ]] || die "the test commit must change only ${CHANGE_FILES[*]}, but the trees differ in: $(tr '\n' ' ' <<<"$changed")"
BASE_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$BASE_REF")
if ((PLAN)); then
  log "plan: base = $BASE_REF ($BASE_SHORT); the test commit changes only: $(tr '\n' ' ' <<<"$changed")"
  for f in "${CHANGE_FILES[@]}"; do
    log "plan: $f: $(diff -u "$( [[ -f "$WORK/base/$f" ]] && echo "$WORK/base/$f" || echo /dev/null)" "$WORK/dev/$f" | grep -c '^[+-][^+-]') changed lines"
  done
  log "plan: failing commit = sed '$BAD_SED' on $BAD_FILE (breaks the bucket boundary; tests/infer/test_metrics.cpp must catch it)"
  exit 0
fi
# --seed: Gitea의 코드를 "변경 전" 사본으로 맞추기만 하고 끝낸다. Jenkins가 새로 뜰 때(첫 폴링은 새 저장소를 바로 한 번 빌드한다)
#   기준선이 이미 올라가 있게 하려고 쓴다. 시험 본체는 이 상태에서 시작한다 (아래 1. 기준선이 "이미 같다"로 지나간다).
if ((SEED)); then
  SEED_SHA=$("$SOURCE_SH" tree "$WORK/base" "e2e baseline: code before the latency histogram ($BASE_SHORT)" "${CI_PATHS[@]}" --keep "$VALUES_FILE")
  log "seeded Gitea main with the baseline (commit $SEED_SHA). Jenkins builds it when it polls; then run scripts/cicd-e2e-test.sh"
  exit 0
fi
mkdir -p "$(dirname "$REPORT")"

# --- 4) Jenkins ---
# jx 경로 : 컨트롤러 파드 안에서 Jenkins API를 읽는다 (관리자 계정은 파드 안 파일에서 읽어서 호스트에 비밀번호가 나오지 않는다)
jx() {
  k -n "$CI_NS" exec jenkins-0 -c jenkins -- sh -c \
    'curl -sS -g -u "$(cat /run/secrets/additional/chart-admin-username):$(cat /run/secrets/additional/chart-admin-password)" "http://localhost:8080$1"' sh "$1"
}
# last_build : 작업의 마지막 빌드 번호 (없으면 0)
last_build() { jx "/job/$JOB/api/json?tree=lastBuild[number]" | jq -r '.lastBuild.number // 0'; }
# build_running : 돌고 있거나 대기열에 있는 빌드가 있으면 성공
build_running() {
  [[ "$(jx "/job/$JOB/api/json?tree=lastBuild[building],inQueue" | jq -r '(.lastBuild.building // false) or (.inQueue // false)')" == true ]] ||
    [[ "$(jx '/queue/api/json?tree=items[id]' | jq -r '.items | length')" -gt 0 ]]
}
# jenkins_idle : 빌드가 돌고 있지 않으면 성공
jenkins_idle() { ! build_running; }
# wait_new_build 이전번호 제한초 : 이전 번호보다 큰 빌드가 생기면 NEW_BUILD에 담고 성공
NEW_BUILD=0
wait_new_build() {
  local after=$1 limit=$2 start=$SECONDS n
  while ((SECONDS - start < limit)); do
    n=$(last_build)
    if ((n > after)); then NEW_BUILD=$n; return 0; fi
    sleep 3
  done
  return 1
}
# wait_build_done 번호 제한초 : 빌드가 끝나면 BUILD_RESULT(SUCCESS/FAILURE/...)에 담고 성공
BUILD_RESULT=""
wait_build_done() {
  local n=$1 limit=$2 start=$SECONDS r
  while ((SECONDS - start < limit)); do
    r=$(jx "/job/$JOB/$n/api/json?tree=building,result" | jq -r 'if .building then empty else (.result // empty) end')
    if [[ -n "$r" ]]; then BUILD_RESULT=$r; return 0; fi
    sleep 5
  done
  return 1
}
# collect_build 라벨 번호 : 빌드의 시작 시각, 단계별 시작·끝 시각, 콘솔 로그, 원인을 모은다.
#   wfapi는 중첩 단계(검사 안의 소스·C++…)를 따로 나열한다. 부모 '검사'는 자기 몫만 재므로 쓰지 않고 자식 단계의 끝을 쓴다.
collect_build() {
  local label=$1 n=$2 st s d
  jx "/job/$JOB/$n/wfapi/describe" >"$WORK/wf-$n.json"
  jx "/job/$JOB/$n/consoleText" >"$WORK/console-$n.txt"
  jx "/job/$JOB/$n/api/json?tree=timestamp,duration,result,actions[causes[shortDescription]]" >"$WORK/bj-$n.json"
  MS["$label.queued"]=$(jq -r '.timestamp' "$WORK/bj-$n.json")
  MS["$label.start"]=$(jq -r '.startTimeMillis' "$WORK/wf-$n.json")
  MS["$label.end"]=$(jq -r '.startTimeMillis + .durationMillis' "$WORK/wf-$n.json")
  INFO["$label.cause"]=$(jq -r '[.actions[]? | .causes[]? | .shortDescription] | join("; ")' "$WORK/bj-$n.json")
  for st in 소스 'C++' Python 쉘 Helm 이미지 '배포 값'; do
    s=$(jq -r --arg n "$st" '[.stages[] | select(.name == $n)][0] | .startTimeMillis // empty' "$WORK/wf-$n.json")
    d=$(jq -r --arg n "$st" '[.stages[] | select(.name == $n)][0] | .durationMillis // empty' "$WORK/wf-$n.json")
    if [[ -n "$s" && -n "$d" ]]; then
      MS["$label.st.$st.start"]=$s
      MS["$label.st.$st.end"]=$((s + d))
    fi
  done
}
# checks_end 라벨 : 검사 단계(소스, C++, Python, 쉘, Helm) 중 가장 늦게 끝난 시각
checks_end() {
  local label=$1 m=0 st e
  for st in 소스 'C++' Python 쉘 Helm; do
    e=${MS["$label.st.$st.end"]:-0}
    ((e > m)) && m=$e
  done
  echo "$m"
}
# console_has 번호 문자열 : 그 빌드의 콘솔 로그에 문자열이 있으면 성공
console_has() { grep -qF -- "$2" "$WORK/console-$1.txt"; }
# console_field 번호 정규식 : 콘솔 로그에서 처음 맞는 부분 (없으면 빈 값)
console_field() { grep -m1 -oE -- "$2" "$WORK/console-$1.txt" || true; }
# stages_skipped 번호 단계이름... : 그 빌드의 콘솔 로그에 모든 단계가 "건너뜀"으로 적혀 있으면 성공
stages_skipped() {
  local n=$1 st
  shift
  for st in "$@"; do grep -qF -- "Stage \"$st\" skipped" "$WORK/console-$n.txt" || return 1; done
}
# cm_get 키 : ConfigMap ci-latest의 값 (점이 든 키는 \. 로 쓴다)
cm_get() { k -n "$CI_NS" get cm ci-latest -o "jsonpath={.data.$1}" 2>/dev/null; }
# reg_digest 이미지 태그 : 레지스트리의 digest (태그가 없으면 빈 값)
reg_digest() { bash "$REGISTRY_SH" digest "$1" "$2"; }

# jenkins_caught_up : Jenkins가 돌고 있지 않고, 마지막 빌드가 Gitea main의 맨 위 커밋을 본 것이면 성공 (콘솔 로그의 "commit=<40자리>").
#   봇의 태그 커밋도 폴링에 잡혀 "건너뜀" 빌드가 하나 생기므로, 다음 시험을 시작하기 전에 Jenkins가 따라잡았는지 본다.
jenkins_caught_up() {
  local n head
  jenkins_idle || return 1
  head=$("$SOURCE_SH" head)
  n=$(last_build)
  ((n > 0)) || return 1
  jx "/job/$JOB/$n/consoleText" >"$WORK/caught-up.txt"
  grep -qF "commit=$head" "$WORK/caught-up.txt"
}
# expect_skip_build 라벨 이전빌드번호 태그커밋ms 태그커밋sha : CI 봇의 태그 커밋도 폴링에 잡혀 빌드가 하나 시작되지만, 소스 단계가 건너뛰어(NOT_BUILT)
#   이미지·태그 커밋 없이 끝나는지(고리가 막힌 것), 그 뒤로 빌드가 더 생기지 않는지 확인한다.
declare -A SKIP_N=()
expect_skip_build() {
  local label=$1 after=$2 tagms=$3 tagsha=$4 n
  wait_new_build "$after" 240 || stuck "the tag commit ${tagsha:0:7} did not trigger a skipped build within 4 minutes (polling)"
  n=$NEW_BUILD
  wait_build_done "$n" 600 || stuck "the skipped build #$n did not finish"
  collect_build "$label.skip" "$n"
  SKIP_N[$label]=$n
  check "태그 커밋(${tagsha:0:7})이 만든 빌드 #$n은 건너뛰기(NOT_BUILT)로 끝났다 (결과 $BUILD_RESULT)" test "$BUILD_RESULT" = NOT_BUILT
  check "빌드 #$n의 이유는 CI 봇 커밋이고 그 커밋을 봤다 (로그 'CI-SKIP: the commit is a CI bot commit', commit=${tagsha:0:7})" bash -c "grep -qF 'CI-SKIP: the commit is a CI bot commit' '$WORK/console-$n.txt' && grep -qF 'commit=$tagsha' '$WORK/console-$n.txt'"
  check "건너뛴 빌드에서 검사·이미지·배포 값 단계가 돌지 않았다" stages_skipped "$n" 'C++' Python 쉘 Helm 이미지 '배포 값'
  wait_until_ms $((tagms + SETTLE * 1000))
  check "태그 커밋 뒤 ${SETTLE}초가 지나도 건너뛴 빌드(#$n) 말고는 새 빌드가 없다 (고리가 막혔다)" test "$(last_build)" = "$n"
}
# repo_files : Gitea 저장소 main의 파일 목록 (Gitea 파드 안에서 git으로 읽는다)
repo_files() { k -n k3slab-system exec deploy/gitea -- git --git-dir=/var/lib/gitea/git/repositories/k3slab/k3s-vmware-lab.git ls-tree -r --name-only main; }
# no_secret_files : 목록에 *.env, kubeconfig, secrets, .generated, 키·인증서 같은 파일이 없으면 성공
no_secret_files() {
  local f
  f=$(repo_files) || return 1
  ! grep -Eiq '\.env$|kubeconfig|secrets|\.generated|\.pem$|\.key$|\.crt$|_ed25519|-token$|terraform\.yml$' <<<"$f"
}

# --- 5) Argo CD와 추론 파드 ---
# app_q jq식 [jq 옵션...] : Application 객체에서 값을 뽑는다
app_q() { local expr=$1; shift; k -n "$ARGO_NS" get application "$APP" -o json | jq -r "$@" "$expr"; }
# app_state : 한 줄 요약
app_state() { app_q '"sync=\(.status.sync.status) health=\(.status.health.status) revision=\(.status.sync.revision // "-" | .[0:8]) phase=\(.status.operationState.phase // "-")"'; }
# synced_healthy_at 커밋 : 그 커밋을 배포한 동기화가 끝났고(Succeeded) Synced + Healthy이면 성공
synced_healthy_at() {
  [[ "$(app_q '.status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.sync.revision == $rev and .status.operationState.syncResult.revision == $rev and .status.operationState.phase == "Succeeded"' --arg rev "$1")" == true ]]
}
# synced_head 커밋 : (배포 동기화가 없어도) Synced + Healthy이고 Argo CD가 그 커밋을 봤으면 성공. 코드만 바뀐 커밋은 매니페스트가 같아 동기화 없이 Synced로 남는다.
synced_head() {
  [[ "$(app_q '.status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.sync.revision == $rev' --arg rev "$1")" == true ]]
}
# live_pods : 추론 파드(삭제 대기 중이 아닌 것) 이름들, 오래된 순
live_pods() {
  k -n "$APP_NS" get pods -l app.kubernetes.io/instance="$APP" -o json |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | .[].metadata.name'
}
newest_pod() { live_pods | tail -1; }
pod_field() { k -n "$APP_NS" get pod "$1" -o jsonpath="$2" 2>/dev/null; }
pod_ready() { [[ "$(pod_field "$1" '{.status.conditions[?(@.type=="Ready")].status}')" == True ]]; }
# rolled_to_new_pod 이전파드 : 이전과 다른 파드가 Ready이고 파드가 정확히 1개이면 성공
rolled_to_new_pod() {
  local p
  p=$(newest_pod)
  [[ -n "$p" && "$p" != "$1" && "$(live_pods | wc -l)" == 1 ]] && pod_ready "$p"
}
# one_ready_pod : Ready인 추론 파드가 정확히 1개이면 성공
one_ready_pod() { [[ "$(live_pods | wc -l)" == 1 ]] && pod_ready "$(newest_pod)"; }
# pod_digest 파드 : 파드가 실제로 돌리는 이미지의 digest (sha256:...)
pod_digest() { pod_field "$1" '{.status.containerStatuses[0].imageID}' | sed 's/.*@//'; }
# pod_image_tag 파드 : 파드 이미지의 태그
pod_image_tag() { pod_field "$1" '{.spec.containers[0].image}' | sed 's/.*://'; }
# values_tag : Git 저장소 main의 배포 값 파일에 적힌 image.tag
values_tag() { "$SOURCE_SH" show "$VALUES_FILE" | sed -n 's/^  tag: //p'; }
# infer_metrics : 추론 서비스의 /metrics (API 서버의 서비스 프록시로 읽는다. 파드가 하나라 그 파드의 값이다)
infer_metrics() { k get --raw "/api/v1/namespaces/$APP_NS/services/$APP:8080/proxy/metrics"; }
# gpu_allocated : gpu-host가 할당한 GPU 수
gpu_allocated() { k describe node gpu-host 2>/dev/null | awk '/Allocated resources/ {f = 1} f && /nvidia.com\/gpu/ {print $2; exit}'; }

# deploy_follow 라벨 태그커밋 이전파드 : Argo CD가 태그 커밋을 배포하고 새 파드가 Ready가 될 때까지 기다리며 시각을 기록한다.
#   이전파드가 비어 있으면(첫 배포) 새 파드만 기다린다.
deploy_follow() {
  local label=$1 tagsha=$2 oldpod=$3 row ready
  wait_for 300 synced_healthy_at "$tagsha" || stuck "Argo CD did not deploy the tag commit $tagsha (Synced + Healthy) within 5 minutes"
  row=$(app_q '.status.operationState | [.startedAt, .finishedAt, .phase, (.operation.initiatedBy.automated // false | tostring)] | @tsv')
  MS["$label.argo_start"]=$(iso_ms "$(cut -f1 <<<"$row")")
  MS["$label.argo_end"]=$(iso_ms "$(cut -f2 <<<"$row")")
  INFO["$label.argo_auto"]=$(cut -f4 <<<"$row")
  if [[ -n "$oldpod" ]]; then
    wait_for 300 rolled_to_new_pod "$oldpod" || stuck "no new Ready pod after the tag commit $tagsha"
  else
    wait_for 600 one_ready_pod || stuck "no Ready inference pod after the sync"
  fi
  INFO["$label.pod"]=$(newest_pod)
  ready=$(pod_field "${INFO["$label.pod"]}" '{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')
  MS["$label.pod_created"]=$(iso_ms "$(pod_field "${INFO["$label.pod"]}" '{.metadata.creationTimestamp}')")
  MS["$label.pod_ready"]=$(iso_ms "$ready")
  INFO["$label.pod_digest"]=$(pod_digest "${INFO["$label.pod"]}")
  MS["$label.digest_checked"]=$(now_ms)
}

# --- 6) Prometheus와 부하 ---
# prom_json 식 : Prometheus 즉시 쿼리의 JSON (API 서버 프록시 경유)
prom_json() {
  local q
  q=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")
  k get --raw "/api/v1/namespaces/monitoring/services/prometheus:9090/proxy/api/v1/query?query=$q"
}
# prom 식 : 첫 값 (없으면 빈 값)   prom_label 식 라벨 : 첫 시계열의 라벨 값
prom() { prom_json "$1" | jq -r '.data.result[0].value[1] // empty'; }
prom_label() { prom_json "$1" | jq -r --arg l "$2" '.data.result[0].metric[$l] // empty'; }
# pf_open 네임스페이스 대상 원격포트 : port-forward를 열고 PF_PORT에 로컬 포트를 담는다 (PF_PID는 cleanup이 닫는다)
PF_PORT=""
pf_open() {
  local i
  PF_PORT=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  # k 함수가 아니라 kubectl을 직접 백그라운드로 실행한다: 그래야 $!가 kubectl의 PID라서 kill이 port-forward를 정말 끝낸다
  K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl -n "$1" port-forward "$2" "$PF_PORT:$3" >"$WORK/pf.log" 2>&1 &
  PF_PID=$!
  for i in $(seq 30); do
    curl -s -o /dev/null "http://127.0.0.1:$PF_PORT/" && return 0
    kill -0 "$PF_PID" 2>/dev/null || break
    sleep 1
  done
  return 1
}
pf_close() { [[ -z "$PF_PID" ]] || kill "$PF_PID" 2>/dev/null || true; PF_PID=""; }
# run_load 초 동시수 : 추론 서비스에 keep-alive curl --parallel로 요청을 보내고 "응답코드 걸린시간" 줄을 $WORK/load.out에 남긴다 (한 개의 port-forward 경유).
#   본문은 시드 고정 64개 숫자(infer-bench.sh와 같음).
run_load() {
  local secs_=$1 conc=$2 end i
  awk 'BEGIN { srand(1); printf "{\"x\":["; for (i = 0; i < 64; i++) printf "%s%.4f", (i ? "," : ""), rand() * 2 - 1; print "]}" }' >"$WORK/body.json"
  : >"$WORK/reqs.cfg"
  for i in $(seq 3000); do
    ((i == 1)) || printf 'next\n' >>"$WORK/reqs.cfg"
    printf 'url = "http://127.0.0.1:%s/infer"\nheader = "Content-Type: application/json"\ndata = "@%s"\noutput = "/dev/null"\nwrite-out = "%%{http_code} %%{time_total}\\n"\n' \
      "$PF_PORT" "$WORK/body.json" >>"$WORK/reqs.cfg"
  done
  : >"$WORK/load.out"
  end=$((SECONDS + secs_))
  while ((SECONDS < end)); do
    curl -s --parallel --parallel-max "$conc" -K "$WORK/reqs.cfg" >>"$WORK/load.out" || true
  done
}
# pctl 값들이 든 파일 분위수 : 숫자 한 줄씩 든 파일의 분위수 (예: 0.95)
pctl() { sort -n "$1" | awk -v p="$2" '{a[NR] = $1} END {i = int(p * NR + 0.999999); if (i < 1) i = 1; print a[i]}'; }

# --- 7) 보고서 머리 ---
{
  printf '# CI/CD 연결 시험: 코드 변경에서 Argo CD 배포까지 (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 생성: `scripts/cicd-e2e-test.sh` (11주차, 제안서 12–13주 몫을 앞당겨 진행)\n'
  printf -- '- 흐름: Gitea 커밋 → Jenkins 폴링(1분) → 검사(C++·Python·쉘·Helm) → Kaniko 이미지 → 태그 커밋(`k3slab ci`) → Argo CD sync → 새 파드\n'
  printf -- '- 코드·배포 값의 출처: 클러스터 안 Gitea `k3slab/k3s-vmware-lab` (`%s`)\n' "$("$SOURCE_SH" url)"
  printf -- '- 시험할 변경: 지연 히스토그램(`%s`). 변경 전 = `%s`(%s)의 이 파일들, 나머지는 작업 폴더\n' "${CHANGE_FILES[*]}" "$BASE_REF" "$BASE_SHORT"
  printf -- '- 시간은 이 컴퓨터의 시간대(KST). Jenkins는 밀리초, Argo CD·Kubernetes·Git은 초 단위라 단계 사이 값에 최대 1초 오차가 있다.\n'
} >"$REPORT"

# ============================================================
# --- 8) 0. 사전 확인 ---
log "0. preflight"
md "" "## 0. 사전 확인"
jenkins_ready() { k -n "$CI_NS" wait --for=condition=ready pod/jenkins-0 --timeout=30s; }
# 작업 설정(config.xml)을 먼저 받아서 검사한다 (파이프에서 grep -q가 먼저 끝나 SIGPIPE가 나는 pipefail 함정을 피한다)
job_reads_gitea() { local x; x=$(jx "/job/$JOB/config.xml"); grep -q 'gitea.k3slab-system.svc.cluster.local:3000/k3slab/k3s-vmware-lab.git' <<<"$x"; }
job_not_github() { local x; x=$(jx "/job/$JOB/config.xml"); ! grep -q 'github.com' <<<"$x"; }
cred_exists() { [[ "$(jx '/credentials/store/system/domain/_/credential/gitea-ci/api/json?tree=id' | jq -r '.id')" == gitea-ci ]]; }
gitea_ready() { [[ "$(k -n k3slab-system get deploy gitea -o jsonpath='{.status.readyReplicas}')" == 1 ]]; }
argocd_ready() {
  local d
  for d in argocd-server argocd-repo-server argocd-redis; do [[ "$(k -n "$ARGO_NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}')" == 1 ]] || return 1; done
  [[ "$(k -n "$ARGO_NS" get statefulset argocd-application-controller -o jsonpath='{.status.readyReplicas}')" == 1 ]]
}
prom_ready() { [[ "$(prom 'count(up == 1)')" -ge 1 ]]; }
k get nodes >/dev/null 2>&1 || die "the cluster is not reachable (is it running?)"
check "Jenkins 컨트롤러(jenkins-0)가 Ready" jenkins_ready
check "운영 작업 $JOB이 클러스터 안 Gitea(k3slab/k3s-vmware-lab)를 본다" job_reads_gitea
check "작업 정의에 GitHub 주소가 없다" job_not_github
check "Jenkins 자격증명 gitea-ci가 있다 (Secret ci/gitea-ci의 토큰)" cred_exists
check "Gitea가 Ready" gitea_ready
check "Argo CD 구성요소 4개가 Ready" argocd_ready
check "Prometheus가 응답" prom_ready
((FAIL == 0)) || stuck "the stack is not ready (see the failed checks above; scripts/argocd-source.sh ci-init, scripts/jenkins-deploy.sh)"
# 앞선 빌드(기준선을 막 올린 경우 등)가 끝나기를 기다린다
wait_for 2400 jenkins_idle || stuck "a Jenkins build is still running after 40 minutes"
check "Jenkins에 돌고 있거나 대기 중인 빌드가 없다" jenkins_idle
wait_for 300 jenkins_caught_up || stuck "Jenkins has not built the current Gitea head within 5 minutes (is the job polling? a first build must exist: scripts/jenkins-run.sh --git)"
check "Jenkins가 Gitea main의 맨 위 커밋까지 따라잡았다 (마지막 빌드 #$(last_build)가 그 커밋을 봤다)" jenkins_caught_up
# 시계: 컨테이너와 이 컴퓨터의 시각 차이. 두 시각 사이에 컨테이너 시각을 읽어 왕복 시간을 반으로 나눠 맞춘다.
clock_skew() {
  local t0 t1 tp
  t0=$(now_ms)
  tp=$("$@" 2>/dev/null | tr -d '\r\n') || return 1
  t1=$(now_ms)
  [[ "$tp" =~ ^[0-9]{13}$ ]] || return 1
  echo $((tp - (t0 + t1) / 2))
}
kubectl_ci_date() { k -n "$CI_NS" exec jenkins-0 -c jenkins -- date +%s%3N; }
kubectl_argo_date() { k -n "$ARGO_NS" exec argocd-application-controller-0 -- date +%s%3N; }
SKEW_J=$(clock_skew kubectl_ci_date || echo "?")
SKEW_A=$(clock_skew kubectl_argo_date || echo "?")
md "" "- 시계 차이(노드 시각 − 이 컴퓨터, ms): Jenkins 컨트롤러(worker-cpu-1) **$SKEW_J**, Argo CD(worker-cpu-2) **$SKEW_A**. 이 값이 1000ms를 넘으면 아래 단계 사이 시간을 그대로 믿지 않는다."
md "- 지금 ConfigMap ci-latest: tag \`$(cm_get tag)\`, commit \`$(cm_get commit | cut -c1-7)\`, built_at \`$(cm_get built_at)\`"

# --- 9) 1. 기준선: Gitea의 코드를 "변경 전" 상태로 ---
log "1. baseline"
md "" "## 1. 기준선 (변경 전 코드가 CI로 만들어져 배포된 상태)"
HEAD_BEFORE=$("$SOURCE_SH" head)
LAST0=$(last_build)
BASE_COMMIT=$("$SOURCE_SH" tree "$WORK/base" "e2e baseline: code before the latency histogram ($BASE_SHORT)" "${CI_PATHS[@]}" --keep "$VALUES_FILE")
if [[ "$BASE_COMMIT" != "$HEAD_BEFORE" ]]; then
  # Gitea의 코드가 변경 전 사본과 달랐다 → 새 기준선 커밋. 그 커밋의 CI·태그 커밋이 끝나기를 기다린다 (기준선 실행도 한 번의 완전한 흐름이다).
  md "- Gitea main의 코드가 기준선과 달라 기준선 커밋 \`${BASE_COMMIT:0:7}\`을 올렸다 (이전 head \`${HEAD_BEFORE:0:7}\`)."
  MS["base.commit"]=$(now_ms)
  wait_new_build "$LAST0" "$POLL_WAIT" || stuck "Jenkins did not start a build for the baseline commit within $((POLL_WAIT / 60)) minutes"
  B_BUILD=$NEW_BUILD
  wait_build_done "$B_BUILD" "$BUILD_WAIT" || stuck "baseline build #$B_BUILD did not finish"
  collect_build base "$B_BUILD"
  [[ "$BUILD_RESULT" == SUCCESS ]] || stuck "the baseline build #$B_BUILD ended $BUILD_RESULT (see its log: kubectl -n $CI_NS exec jenkins-0 -- ... /job/$JOB/$B_BUILD/consoleText)"
  B_END=$(jq -r '.startTimeMillis + .durationMillis' "$WORK/wf-$B_BUILD.json")
  md "- 기준선 빌드 #$B_BUILD: $BUILD_RESULT, 커밋부터 빌드 끝까지 $(secs "${MS[base.commit]}" "$B_END")초 (태그 커밋 포함)"
  B_TAG_SHA=$(console_field "$B_BUILD" 'tag-commit [0-9a-f]{40}' | sed 's/tag-commit //')
  [[ -n "$B_TAG_SHA" ]] || stuck "the baseline build has no tag commit"
  expect_skip_build base "$B_BUILD" "${MS["base.st.배포 값.end"]}" "$B_TAG_SHA"
else
  md "- Gitea main의 코드는 이미 기준선과 같다 (head \`${HEAD_BEFORE:0:7}\`)."
fi
check "Gitea 저장소 main의 파일 목록($(repo_files | wc -l)개)에 *.env, kubeconfig, secrets, .generated, 키·인증서 파일이 없다" no_secret_files
block "Gitea 저장소 main의 최상위 경로별 파일 수" "$(repo_files | cut -d/ -f1 | sort | uniq -c)"
CI_TAG=$(cm_get tag)
CI_COMMIT=$(cm_get commit)
CI_DIGEST=$(cm_get 'infer-worker\.digest')
VALUES_TAG=$(values_tag)
md "- CI가 마지막으로 만든 이미지: \`infer-worker:$CI_TAG\` ($CI_DIGEST), GitOps 값의 image.tag: \`$VALUES_TAG\`"
check "배포 값의 image.tag가 CI가 만든 태그다 (사람이 넣은 v0.2 같은 태그가 아니다)" test "$VALUES_TAG" = "$CI_TAG"
check "ConfigMap ci-latest의 digest가 레지스트리와 같다" test "$CI_DIGEST" = "$(reg_digest infer-worker "$CI_TAG")"
# Application: 없으면 만든다 (GPU 1개). 값의 replicas가 0이면 GitOps 방식으로 1로 올린다.
if ! k -n "$ARGO_NS" get application "$APP" >/dev/null 2>&1; then
  log "creating the Application (starts the GPU pod)"
  APP_STARTED=1
  T_APP=$(now_ms)
  "$DEPLOY_SH" app
  wait_for 900 synced_head "$("$SOURCE_SH" head)" || stuck "the Application did not become Synced + Healthy"
  wait_for 600 one_ready_pod || stuck "no Ready inference pod after the first sync"
  MS[first.sync]=$(($(now_ms) - T_APP))
  md "- Application이 없어 만들었다: 만든 뒤 Synced + Healthy + 파드 Ready까지 $(awk -v m="${MS[first.sync]}" 'BEGIN { printf "%.1f", m / 1000 }')초 (이미지를 노드로 처음 받는 시간이 들어 있다)"
else
  APP_STARTED=1
  if [[ "$("$SOURCE_SH" show "$VALUES_FILE" | sed -n 's/^  replicas: //p')" == 0 ]]; then
    "$SOURCE_SH" edit "$VALUES_FILE" 's/^  replicas: .*/  replicas: 1/' "e2e: start the inference pod again (replicas 1)" >/dev/null
  fi
  wait_for 900 synced_head "$("$SOURCE_SH" head)" || stuck "the Application is not Synced + Healthy at the Git head"
  wait_for 600 one_ready_pod || stuck "no Ready inference pod"
fi
OLD_POD=$(newest_pod)
OLD_UID=$(pod_field "$OLD_POD" '{.metadata.uid}')
OLD_DIGEST=$(pod_digest "$OLD_POD")
OLD_TAG=$(pod_image_tag "$OLD_POD")
OLD_NODE=$(pod_field "$OLD_POD" '{.spec.nodeName}')
check "기준선 파드($OLD_POD)가 Ready, 노드 gpu-host, 이미지 태그 $CI_TAG" test "$OLD_NODE:$OLD_TAG" = "gpu-host:$CI_TAG"
check "기준선 파드의 digest가 CI가 기록한 digest와 같다" test "$OLD_DIGEST" = "$CI_DIGEST"
old_has_no_bucket() { local m; m=$(infer_metrics); ! grep -q '^k3slab_infer_request_seconds_bucket' <<<"$m"; }
check "기준선 파드의 /metrics에 지연 버킷(k3slab_infer_request_seconds_bucket)이 없다" old_has_no_bucket
OLD_GEN=$(k -n "$APP_NS" get deploy "$APP" -o jsonpath='{.metadata.generation}')
OLD_HIST=$(app_q '.status.history[-1].id')
TAGS_BEFORE=$(bash "$REGISTRY_SH" tags infer-worker | sort | tr '\n' ' ')
OLD_TAG_DIGEST=$(reg_digest infer-worker "$OLD_TAG")
block "시험 시작 상태" "Gitea head   : $("$SOURCE_SH" head)
Application  : $(app_state)
파드         : $OLD_POD (uid $OLD_UID)
이미지       : infer-worker:$OLD_TAG @ $OLD_DIGEST
레지스트리   : infer-worker 태그 = $TAGS_BEFORE"

# --- 10) 2. 성공 경로 ---
log "2. success path: commit the histogram change"
md "" "## 2. 성공 경로: 지연 히스토그램 변경 커밋 하나"
C_AFTER=$(last_build)
C_DEV_SHA=$("$SOURCE_SH" tree "$WORK/dev" "metrics: export request latency as a histogram (k3slab_infer_request_seconds_bucket)" "${CI_PATHS[@]}" --keep "$VALUES_FILE")
MS[ok.commit]=$(now_ms)
[[ "$C_DEV_SHA" != "$BASE_COMMIT" ]] || stuck "the change commit was not created (the repository already had the change)"
md "- 커밋 \`${C_DEV_SHA:0:7}\` (변경: ${CHANGE_FILES[*]}) 를 Gitea main에 올렸다. 시각 $(hms "${MS[ok.commit]}")"
wait_new_build "$C_AFTER" "$POLL_WAIT" || stuck "Jenkins did not start a build within $((POLL_WAIT / 60)) minutes after the commit (polling every minute)"
OK_BUILD=$NEW_BUILD
log "build #$OK_BUILD started $(secs "${MS[ok.commit]}" "$(now_ms)")s after the commit"
wait_build_done "$OK_BUILD" "$BUILD_WAIT" || stuck "build #$OK_BUILD did not finish within $((BUILD_WAIT / 60)) minutes"
collect_build ok "$OK_BUILD"
[[ "$BUILD_RESULT" == SUCCESS ]] || stuck "build #$OK_BUILD ended $BUILD_RESULT (expected SUCCESS)"
OK_LINE=$(console_field "$OK_BUILD" 'source=git commit=[0-9a-f]{40} image tag=git-[0-9a-f]{7}')
OK_BUILT_COMMIT=$(sed -E 's/.*commit=([0-9a-f]{40}) .*/\1/' <<<"$OK_LINE")
NEW_TAG=$(sed -E 's/.*image tag=(git-[0-9a-f]{7})/\1/' <<<"$OK_LINE")
TAG_SHA=$(console_field "$OK_BUILD" 'tag-commit [0-9a-f]{40}' | sed 's/tag-commit //')
OK_DIGEST=$(cm_get 'infer-worker\.digest')
check "빌드 #$OK_BUILD가 사람 손 없이 시작됐다 (원인: ${INFO[ok.cause]:-?})" grep -qi 'scm' <<<"${INFO[ok.cause]}"
check "Jenkins가 빌드한 커밋이 올린 커밋($C_DEV_SHA)과 같다" test "$OK_BUILT_COMMIT" = "$C_DEV_SHA"
tag_is_new() { [[ "$NEW_TAG" == "git-${C_DEV_SHA:0:7}" && "$NEW_TAG" != "$OLD_TAG" ]]; }
check "이미지 태그가 git-<커밋 7자리> ($NEW_TAG)이고 이전 태그($OLD_TAG)와 다르다" tag_is_new
check "레지스트리의 새 태그 digest가 ConfigMap ci-latest의 digest와 같다 ($OK_DIGEST)" all_eq "$(reg_digest infer-worker "$NEW_TAG")" "$OK_DIGEST" "$(cm_get tag)" "$NEW_TAG" "$(cm_get commit)" "$C_DEV_SHA"
check "이전 태그($OLD_TAG)의 digest는 그대로다 (태그를 덮어쓰지 않았다)" test "$(reg_digest infer-worker "$OLD_TAG")" = "$OLD_TAG_DIGEST"
check "새 digest가 이전 digest와 다르다" test "$OK_DIGEST" != "$OLD_DIGEST"
[[ -n "$TAG_SHA" ]] || stuck "the build log has no 'tag-commit <sha>' line (the stage '배포 값' did not run)"
MS[ok.tag_commit]=${MS["ok.st.배포 값.end"]:-0}
# Gitea에서 태그 커밋 확인: 맨 위가 CI 봇의 커밋, 그 아래가 올린 커밋, 배포 값 파일의 태그가 새 태그
LOG3=$("$SOURCE_SH" log 3)
TOP_SHA=$(cut -f1 <<<"$(head -1 <<<"$LOG3")")
TOP_AUTHOR=$(cut -f2 <<<"$(head -1 <<<"$LOG3")")
TOP_SUBJECT=$(cut -f4 <<<"$(head -1 <<<"$LOG3")")
SECOND_SHA=$(cut -f1 <<<"$(sed -n 2p <<<"$LOG3")")
GIT_TAG_TIME=$(cut -f3 <<<"$(head -1 <<<"$LOG3")")
check "Gitea main 맨 위가 CI 봇(k3slab ci)의 태그 커밋(${TAG_SHA:0:7})이고 제목에 새 태그와 [skip ci]가 있다" all_eq "$TOP_SHA" "$TAG_SHA" "$TOP_AUTHOR" "k3slab ci" "$TOP_SUBJECT" "ci: deploy infer-worker $NEW_TAG [skip ci]"
check "태그 커밋의 바로 아래가 올린 커밋(${C_DEV_SHA:0:7})이다" test "$SECOND_SHA" = "$C_DEV_SHA"
check "배포 값 파일의 image.tag가 새 태그($NEW_TAG)로 바뀌었다" test "$(values_tag)" = "$NEW_TAG"
block "Gitea main 최근 커밋 (커밋, 작성자, 시각, 제목)" "$LOG3"
md "- Gitea에 기록된 태그 커밋의 시각: $GIT_TAG_TIME (초 단위). Jenkins 단계 기록의 '배포 값' 끝: $(hms "${MS[ok.tag_commit]}")"
# 태그 커밋도 폴링에 잡혀 빌드가 하나 시작되지만 소스 단계가 건너뛴다 (expect_skip_build가 확인한다).
log "deploy: waiting for Argo CD (tag commit ${TAG_SHA:0:7})"
OLD_POD1=$OLD_POD
deploy_follow ok "$TAG_SHA" "$OLD_POD1"
expect_skip_build ok "$OK_BUILD" "${MS[ok.tag_commit]}" "$TAG_SHA"
NEW_POD=${INFO[ok.pod]}
check "Argo CD가 자동 동기화로 태그 커밋(${TAG_SHA:0:7})을 배포했다 (initiatedBy.automated)" test "${INFO[ok.argo_auto]}" = true
new_pod_ok() { [[ "$(pod_field "$NEW_POD" '{.spec.nodeName}')" == gpu-host && "$(live_pods | wc -l)" == 1 && "$NEW_POD" != "$OLD_POD" ]] && pod_ready "$NEW_POD"; }
check "새 파드($NEW_POD)가 Ready이고 gpu-host에서 돈다, 예전 파드는 사라지고 파드는 1개" new_pod_ok
check "새 파드의 이미지 태그가 $NEW_TAG" test "$(pod_image_tag "$NEW_POD")" = "$NEW_TAG"
check "새 파드가 실제로 도는 digest(imageID)가 CI가 기록한 digest와 같다" test "${INFO[ok.pod_digest]}" = "$OK_DIGEST"
ok_has_buckets() {
  local m
  m=$(infer_metrics)
  [[ "$(grep -c '^k3slab_infer_request_seconds_bucket{le=' <<<"$m")" == 13 ]] && grep -q '^# TYPE k3slab_infer_request_seconds histogram$' <<<"$m"
}
check "새 파드의 /metrics가 지연 히스토그램(버킷 13개, TYPE histogram)을 낸다" ok_has_buckets
old_names_kept() {
  local m n
  m=$(infer_metrics)
  for n in 'k3slab_infer_info{' 'k3slab_infer_queue_length ' 'k3slab_infer_requests_total{result="ok"}' 'k3slab_infer_batch_size_bucket{le="1"}' \
    'k3slab_infer_batch_compute_seconds_sum ' 'k3slab_infer_request_seconds_sum ' 'k3slab_infer_request_seconds_count '; do
    grep -qF -- "$n" <<<"$m" || return 1
  done
}
check "예전 지표 이름(info, queue_length, requests_total, batch_size, batch_compute_seconds, request_seconds_sum/_count)이 그대로 있다" old_names_kept

# --- 11) 2-2. Prometheus: 히스토그램과 p50/p95 ---
log "2b. load and Prometheus"
md "" "### 2-2. 새 파드에 부하를 주고 Prometheus에서 p50/p95 읽기"
POD_SEL="pod=\"$NEW_POD\""
# 대시보드의 $release 변수 = 수집기가 붙이는 Helm 릴리스 라벨 (Argo CD가 배포하면 Application 이름 infer)
REL=$(prom_label "k3slab_infer_info{$POD_SEL}" release || true)
RELEASE_SEL="release=\"${REL:-$APP}\""
series_ok() { [[ "$(prom "count(k3slab_infer_request_seconds_bucket{$POD_SEL})")" == 13 ]]; }
wait_for 120 series_ok || stuck "Prometheus has no 13 latency bucket series for $NEW_POD within 2 minutes"
pf_open "$APP_NS" "svc/$APP" 8080 || stuck "cannot open a port-forward to svc/$APP"
LOAD_SECONDS=30
LOAD_START=$(now_ms)
run_load "$LOAD_SECONDS" 64
LOAD_END=$(now_ms)
pf_close
N200=$(awk '$1 == 200 {n++} END {print n + 0}' "$WORK/load.out")
NALL=$(wc -l <"$WORK/load.out")
awk '$1 == 200 {print $2}' "$WORK/load.out" >"$WORK/client-times.txt"
md "- 부하: \`curl --parallel-max 64\`로 ${LOAD_SECONDS}초 (port-forward 경유). 요청 $NALL개, 응답 200 **$N200**개. 시각 $(hms "$LOAD_START") – $(hms "$LOAD_END")"
sleep 15   # Prometheus가 부하 마지막 구간을 긁어 가도록 (수집 간격 5초)
PROM_COUNT=$(prom "k3slab_infer_request_seconds_count{$POD_SEL}")
PROM_INF=$(prom "k3slab_infer_request_seconds_bucket{$POD_SEL,le=\"+Inf\"}")
PROM_SUM=$(prom "k3slab_infer_request_seconds_sum{$POD_SEL}")
# 대시보드 '지연 p50 / p95' 패널과 같은 식 (변수 $release=infer, $win=1m)
Q50="histogram_quantile(0.5, sum by (le)(rate(k3slab_infer_request_seconds_bucket{$RELEASE_SEL}[1m])))"
Q95="histogram_quantile(0.95, sum by (le)(rate(k3slab_infer_request_seconds_bucket{$RELEASE_SEL}[1m])))"
QAVG="sum(rate(k3slab_infer_request_seconds_sum{$RELEASE_SEL}[1m])) / sum(rate(k3slab_infer_request_seconds_count{$RELEASE_SEL}[1m]))"
P50=$(prom "$Q50")
P95=$(prom "$Q95")
PAVG=$(prom "$QAVG")
CP50=$(pctl "$WORK/client-times.txt" 0.5)
CP95=$(pctl "$WORK/client-times.txt" 0.95)
# 버킷별 누적 개수 (le 순서대로)
BUCKETS=$(infer_metrics | sed -n 's/^k3slab_infer_request_seconds_bucket{le="\([^"]*\)"} \([0-9]*\)$/\1 \2/p')
block "새 파드의 버킷 (le, 누적 개수; /metrics)" "$BUCKETS"
block "Prometheus 쿼리 (대시보드 패널과 같은 식)" "p50  = $Q50  → ${P50:-없음} s
p95  = $Q95  → ${P95:-없음} s
평균 = $QAVG  → ${PAVG:-없음} s
_count (새 파드, 카운터)  = ${PROM_COUNT:-없음}   le=+Inf = ${PROM_INF:-없음}   _sum = ${PROM_SUM:-없음} s"
md "- 참고(비교용, 판정에 쓰지 않음): 클라이언트가 port-forward를 거쳐 잰 응답 시간 p50 $(awk -v v="${CP50:-0}" 'BEGIN { printf "%.2f", v * 1000 }') ms, p95 $(awk -v v="${CP95:-0}" 'BEGIN { printf "%.2f", v * 1000 }') ms (네트워크·port-forward 시간이 들어 있어 서버 값보다 크다)"
check "Prometheus의 지연 _count(${PROM_COUNT:-?})와 le=\"+Inf\"(${PROM_INF:-?})가 클라이언트가 센 200 응답 수($N200)와 같다" all_eq "${PROM_COUNT%.*}" "$N200" "${PROM_INF%.*}" "$N200"
nonempty_quantiles() { [[ -n "$P50" && -n "$P95" ]] && awk -v a="$P50" -v b="$P95" 'BEGIN { exit !(a > 0 && b >= a && b <= 2.5) }'; }
check "대시보드의 p50/p95 쿼리가 값을 낸다 (p50 ${P50:-없음} s, p95 ${P95:-없음} s: 0 < p50 ≤ p95 ≤ 2.5 s)" nonempty_quantiles
bucket_monotonic() { awk 'NR > 1 && $2 < prev {bad = 1} {prev = $2} END {exit bad}' <<<"$BUCKETS"; }
check "버킷 누적 개수가 줄지 않고 le=+Inf가 _count와 같다" bucket_monotonic

# --- 12) 3. 차단 경로 ---
if ((RUN_BLOCK)); then
  log "3. blocked path: a commit with a failing unit test"
  md "" "## 3. 차단 경로: 단위 시험이 실패하는 커밋"
  PRE_UID=$(pod_field "$NEW_POD" '{.metadata.uid}')
  PRE_GEN=$(k -n "$APP_NS" get deploy "$APP" -o jsonpath='{.metadata.generation}')
  PRE_HIST=$(app_q '.status.history[-1].id')
  PRE_TAG_VALUE=$(values_tag)
  PRE_CM_BUILT=$(cm_get built_at)
  PRE_TAGS=$(bash "$REGISTRY_SH" tags infer-worker | sort | tr '\n' ' ')
  PRE_TRAIN_TAGS=$(bash "$REGISTRY_SH" tags train-worker | sort | tr '\n' ' ')
  B_AFTER=$(last_build)
  BAD_SHA=$("$SOURCE_SH" edit "$BAD_FILE" "$BAD_SED" "e2e: break the latency bucket boundary (the unit test must fail)")
  MS[bad.commit]=$(now_ms)
  BAD_TAG="git-${BAD_SHA:0:7}"
  md "- 커밋 \`${BAD_SHA:0:7}\`: \`$BAD_FILE\`에 \`sed '$BAD_SED'\` (경계값이 한 칸 위 버킷으로 가는 실수, 빌드와 실행 검사는 통과하고 단위 시험만 잡는다). 시각 $(hms "${MS[bad.commit]}")"
  wait_new_build "$B_AFTER" "$POLL_WAIT" || stuck "Jenkins did not start a build for the failing commit within $((POLL_WAIT / 60)) minutes"
  BAD_BUILD=$NEW_BUILD
  wait_build_done "$BAD_BUILD" "$BUILD_WAIT" || stuck "build #$BAD_BUILD did not finish"
  collect_build bad "$BAD_BUILD"
  MS[bad.end]=$(jq -r '.startTimeMillis + .durationMillis' "$WORK/wf-$BAD_BUILD.json")
  check "빌드 #$BAD_BUILD가 FAILURE로 끝났다 ($BUILD_RESULT)" test "$BUILD_RESULT" = FAILURE
  check "C++ 단계가 단위 시험 실패로 멈췄다 (로그: '[cpp] FAIL: metrics unit test failed')" console_has "$BAD_BUILD" '[cpp] FAIL: metrics unit test failed'
  check "나머지 검사 단계(Python, 쉘, Helm)가 건너뛰어졌다" stages_skipped "$BAD_BUILD" Python 쉘 Helm
  check "이미지 단계와 배포 값 단계가 건너뛰어졌다" stages_skipped "$BAD_BUILD" 이미지 '배포 값'
  check "레지스트리에 infer-worker:$BAD_TAG, train-worker:$BAD_TAG가 생기지 않았다" test -z "$(reg_digest infer-worker "$BAD_TAG")$(reg_digest train-worker "$BAD_TAG")"
  check "레지스트리의 태그 목록이 그대로다 (infer-worker, train-worker)" all_eq "$(bash "$REGISTRY_SH" tags infer-worker | sort | tr '\n' ' ')" "$PRE_TAGS" "$(bash "$REGISTRY_SH" tags train-worker | sort | tr '\n' ' ')" "$PRE_TRAIN_TAGS"
  check "태그 커밋이 없다: Gitea main의 맨 위가 실패한 커밋(${BAD_SHA:0:7})이고 배포 값의 태그는 $PRE_TAG_VALUE 그대로" all_eq "$("$SOURCE_SH" head)" "$BAD_SHA" "$(values_tag)" "$PRE_TAG_VALUE"
  check "ConfigMap ci-latest가 바뀌지 않았다 (built_at $PRE_CM_BUILT, tag $(cm_get tag))" all_eq "$(cm_get built_at)" "$PRE_CM_BUILT" "$(cm_get tag)" "$NEW_TAG"
  # Argo CD는 실패한 커밋(코드만 바뀜)도 새 커밋으로 보지만 매니페스트가 같아 아무것도 배포하지 않는다
  wait_for 120 synced_head "$BAD_SHA" || true
  block "실패한 빌드 #$BAD_BUILD 로그 끝부분" "$(tail -14 "$WORK/console-$BAD_BUILD.txt")"
  wait_until_ms $((${MS[bad.end]} + SETTLE * 1000))
  check "실패한 커밋 뒤 ${SETTLE}초가 지나도 새 빌드가 없다(마지막 빌드는 #$BAD_BUILD)" test "$(last_build)" = "$BAD_BUILD"
  check "기존 파드($NEW_POD)가 그대로다 (같은 uid, 재시작 0, 같은 digest, 파드 1개)" all_eq "$(pod_field "$NEW_POD" '{.metadata.uid}')" "$PRE_UID" "$(pod_field "$NEW_POD" '{.status.containerStatuses[0].restartCount}')" 0 "$(pod_digest "$NEW_POD")" "$OK_DIGEST" "$(live_pods | wc -l)" 1
  check "Deployment 세대($PRE_GEN)와 Argo CD 배포 이력(마지막 id $PRE_HIST)이 그대로다" all_eq "$(k -n "$APP_NS" get deploy "$APP" -o jsonpath='{.metadata.generation}')" "$PRE_GEN" "$(app_q '.status.history[-1].id')" "$PRE_HIST"
  block "차단 뒤 상태" "Application : $(app_state)
파드        : $(live_pods | tr '\n' ' ') (uid $PRE_UID)
Gitea 최근 커밋:
$("$SOURCE_SH" log 3)"

  # 되돌리기: revert 커밋은 정상 코드라서 같은 파이프라인을 통과해 새 태그로 배포되어야 한다
  log "3b. revert the failing commit; the revert goes through the pipeline"
  md "" "### 3-2. 실패한 커밋을 되돌린다 (git revert) — 되돌린 커밋도 같은 파이프라인을 통과하는지"
  R_AFTER=$(last_build)
  REVERT_SHA=$("$SOURCE_SH" revert "$BAD_SHA")
  MS[rev.commit]=$(now_ms)
  md "- revert 커밋 \`${REVERT_SHA:0:7}\` (실패한 커밋 \`${BAD_SHA:0:7}\`을 되돌림). 시각 $(hms "${MS[rev.commit]}")"
  same_as_ok_code() { [[ "$("$SOURCE_SH" show "$BAD_FILE" "$REVERT_SHA" | sha256sum)" == "$("$SOURCE_SH" show "$BAD_FILE" "$C_DEV_SHA" | sha256sum)" ]]; }
  check "revert 뒤 $BAD_FILE이 성공 커밋(${C_DEV_SHA:0:7})의 내용과 같다" same_as_ok_code
  wait_new_build "$R_AFTER" "$POLL_WAIT" || stuck "Jenkins did not start a build for the revert commit within $((POLL_WAIT / 60)) minutes"
  REV_BUILD=$NEW_BUILD
  wait_build_done "$REV_BUILD" "$BUILD_WAIT" || stuck "build #$REV_BUILD did not finish"
  collect_build rev "$REV_BUILD"
  check "revert 커밋의 빌드 #$REV_BUILD가 SUCCESS ($BUILD_RESULT)" test "$BUILD_RESULT" = SUCCESS
  REV_TAG="git-${REVERT_SHA:0:7}"
  REV_TAG_SHA=$(console_field "$REV_BUILD" 'tag-commit [0-9a-f]{40}' | sed 's/tag-commit //')
  [[ -n "$REV_TAG_SHA" ]] || stuck "the revert build has no tag commit"
  MS[rev.tag_commit]=${MS["rev.st.배포 값.end"]:-0}
  deploy_follow rev "$REV_TAG_SHA" "$NEW_POD"
  expect_skip_build rev "$REV_BUILD" "${MS[rev.tag_commit]}" "$REV_TAG_SHA"
  REV_DIGEST=$(cm_get 'infer-worker\.digest')
  check "되돌린 커밋이 새 태그($REV_TAG)로 배포됐고 새 파드의 digest가 CI 기록($REV_DIGEST)과 같다" all_eq "$(pod_image_tag "${INFO[rev.pod]}")" "$REV_TAG" "${INFO[rev.pod_digest]}" "$REV_DIGEST" "$(cm_get tag)" "$REV_TAG"
  FINAL_POD=${INFO[rev.pod]}
else
  FINAL_POD=$NEW_POD
fi

# --- 13) 4. 단계별 시간 표 ---
# step_row 번호 이름 시각ms 이전시각ms 기준시각ms 근거 : 표의 한 줄
step_row() {
  md "| $1 | $2 | $(hms "$3") | $(secs "$5" "$3") | $( [[ -n "$4" ]] && secs "$4" "$3" || echo '–') | $6 |"
}
# steps_table 라벨 제목 : 8단계 표
steps_table() {
  local l=$1 t0 prev
  t0=${MS["$l.commit"]}
  md "" "$2" "" "| # | 단계 | 시각 | 커밋부터(초) | 직전 단계부터(초) | 무엇을 재나 |" "|---|---|---|---|---|---|"
  step_row 1 "커밋" "$t0" "" "$t0" "스크립트가 Gitea에 push를 끝낸 시각"
  prev=$t0
  step_row "–" "폴링 지연: 변경을 찾아 빌드 예약" "${MS["$l.queued"]}" "$prev" "$t0" "Jenkins가 Gitea를 1분마다 폴링해서 새 커밋을 찾고 빌드를 만든 시각 (웹훅 없음)"
  prev=${MS["$l.queued"]}
  step_row 2 "빌드 시작" "${MS["$l.start"]}" "$prev" "$t0" "빌드가 실행을 시작한 시각 (wfapi startTimeMillis, 대기열 시간 포함)"
  prev=${MS["$l.start"]}
  step_row 3 "검사 끝" "$(checks_end "$l")" "$prev" "$t0" "소스·C++·Python·쉘·Helm 중 가장 늦게 끝난 단계의 끝 (에이전트 파드 준비 시간 포함)"
  prev=$(checks_end "$l")
  step_row 4 "이미지 push 끝" "${MS["$l.st.이미지.end"]}" "$prev" "$t0" "이미지 단계(infer-worker·train-worker Kaniko 빌드, push, digest 확인, 결과 기록) 끝"
  prev=${MS["$l.st.이미지.end"]}
  step_row 5 "태그 커밋" "${MS["$l.st.배포 값.end"]}" "$prev" "$t0" "배포 값 단계 끝 = Gitea에 태그 커밋 push 완료 (에이전트 파드 준비 포함)"
  prev=${MS["$l.st.배포 값.end"]}
  step_row 6 "Argo CD sync 끝" "${MS["$l.argo_end"]}" "$prev" "$t0" "동기화 작업 finishedAt (Argo CD가 커밋을 알아채는 시간 + 매니페스트 생성 + 적용)"
  prev=${MS["$l.argo_end"]}
  step_row 7 "새 파드 Ready" "${MS["$l.pod_ready"]}" "$prev" "$t0" "새 파드의 Ready 조건 시각 (GPU 파드는 maxSurge 0이라 예전 파드를 먼저 내린다)"
  prev=${MS["$l.pod_ready"]}
  step_row 8 "새 digest 확인" "${MS["$l.digest_checked"]}" "$prev" "$t0" "파드 imageID의 digest = CI가 기록한 digest 확인"
  md "" "전체: 커밋부터 새 digest 확인까지 **$(secs "$t0" "${MS["$l.digest_checked"]}")초**."
}
# stage_table 라벨 : Jenkins 단계별 시작과 걸린 시간
stage_table() {
  local l=$1 st
  md "" "| Jenkins 단계 | 시작 | 걸린 시간(초) |" "|---|---|---|"
  for st in 소스 'C++' Python 쉘 Helm 이미지 '배포 값'; do
    [[ -n "${MS["$l.st.$st.start"]:-}" ]] || continue
    md "| $st | $(hms "${MS["$l.st.$st.start"]}") | $(secs "${MS["$l.st.$st.start"]}" "${MS["$l.st.$st.end"]}") |"
  done
}
log "report: tables"
md "" "## 4. 성공 경로의 단계별 시각과 걸린 시간"
steps_table ok "### 4-1. 커밋 → 새 digest 확인 (빌드 #$OK_BUILD, 새 태그 \`$NEW_TAG\`)"
stage_table ok
md "" "### 4-2. 나누어 본 구간" "" "| 구간 | 초 | 설명 |" "|---|---|---|" \
  "| 커밋 → Jenkins 빌드 예약 | $(secs "${MS[ok.commit]}" "${MS[ok.queued]}") | 폴링 간격(1분)이 만드는 지연. 0~60초 사이 값이 나온다 |" \
  "| 예약 → 빌드 시작 | $(secs "${MS[ok.queued]}" "${MS[ok.start]}") | 대기열 |" \
  "| 빌드 시작 → 소스 단계 시작 | $(secs "${MS[ok.start]}" "${MS["ok.st.소스.start"]}") | 검사 에이전트 파드가 gpu-host에 뜨는 시간 |" \
  "| 태그 커밋 → 봇 커밋의 건너뛴 빌드 #${SKIP_N[ok]} 예약 | $(secs "${MS[ok.tag_commit]}" "${MS[ok.skip.queued]}") | CI 봇의 태그 커밋도 폴링에 잡힌다. 소스 단계가 건너뛰어 NOT_BUILT로 끝난다(이 빌드가 파드를 하나 쓰는 시간: $(secs "${MS[ok.skip.start]}" "${MS[ok.skip.end]}")초) |" \
  "| 태그 커밋 → Argo CD sync 시작 | $(secs "${MS[ok.tag_commit]}" "${MS[ok.argo_start]}") | Argo CD가 새 커밋을 알아채는 시간(확인 주기 30초 + 저장소 읽기) |" \
  "| Argo CD sync 작업 (시작 → 끝) | $(secs "${MS[ok.argo_start]}" "${MS[ok.argo_end]}") | 매니페스트를 그려 적용하기까지 |" \
  "| sync 끝 → 새 파드 Ready | $(secs "${MS[ok.argo_end]}" "${MS[ok.pod_ready]}") | 예전 파드 종료 + 새 파드 시작 (이미지 pull 포함) |" \
  "| 태그 커밋 → 새 파드 Ready | $(secs "${MS[ok.tag_commit]}" "${MS[ok.pod_ready]}") | DNS 수정 전의 \"values 커밋 → 새 파드 Ready 55초\"와 같은 구간 |"
block "새 파드의 이미지 pull 이벤트 (노드에 이미지가 없었으므로 처음 받는다)" "$(k -n "$APP_NS" get events --field-selector "involvedObject.name=$NEW_POD" -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers 2>/dev/null | cut -c1-220)"
block "Argo CD 배포 이력 (id, 커밋, 배포 시각)" "$(app_q '.status.history[] | "\(.id)  \(.revision)  \(.deployedAt)"')"
if ((RUN_BLOCK)); then
  md "" "## 5. 차단 경로와 되돌림의 시간"
  md "" "- 실패한 커밋 \`${BAD_SHA:0:7}\`: 커밋부터 빌드 끝(FAILURE)까지 $(secs "${MS[bad.commit]}" "${MS[bad.end]}")초 (폴링 대기 $(secs "${MS[bad.commit]}" "${MS[bad.queued]}")초 + 시작부터 실패까지 $(secs "${MS[bad.start]}" "${MS[bad.end]}")초)"
  stage_table bad
  steps_table rev "### 5-2. revert 커밋도 같은 파이프라인으로 배포된다 (빌드 #$REV_BUILD, 새 태그 \`$REV_TAG\`)"
  stage_table rev
fi

# --- 14) 6. 정리: 첫 sync 다시 재기와 GPU 반납 ---
log "6. cleanup and first-sync re-measurement"
md "" "## 6. Argo CD sync 시간: DNS 수정 전과 후"
FINAL_TAG=$(values_tag)
"$DEPLOY_SH" app-down
APP_STARTED=0
check "Application 삭제 뒤 추론 파드가 모두 사라졌다 (GPU 반환)" test -z "$(k -n "$APP_NS" get pods --no-headers 2>/dev/null)"
if ((RESYNC)); then
  # 이미지(FINAL_TAG)는 이번 시험에서 gpu-host가 이미 받아 두었다 → 처음 sync(Application 생성 → Synced + Healthy)에서 이미지 pull이 빠진 시간을 잰다.
  T_APP2=$(now_ms)
  APP_STARTED=1
  "$DEPLOY_SH" app
  RESYNC_HEAD=$("$SOURCE_SH" head)
  wait_for 600 synced_head "$RESYNC_HEAD" || stuck "the re-created Application did not become Synced + Healthy"
  MS[resync.synced]=$(($(now_ms) - T_APP2))
  wait_for 300 one_ready_pod || stuck "no Ready pod after the re-created Application"
  MS[resync.ready]=$(($(now_ms) - T_APP2))
  RESYNC_POD=$(newest_pod)
  check "다시 만든 Application의 파드($RESYNC_POD)가 이미지 태그 $FINAL_TAG로 Ready" test "$(pod_image_tag "$RESYNC_POD")" = "$FINAL_TAG"
  block "다시 만든 파드의 이미지 pull 이벤트" "$(k -n "$APP_NS" get events --field-selector "involvedObject.name=$RESYNC_POD" -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers 2>/dev/null | cut -c1-220)"
  "$DEPLOY_SH" app-down
  APP_STARTED=0
  check "다시 만든 Application도 지웠고 추론 파드가 없다 (GPU 반환)" test -z "$(k -n "$APP_NS" get pods --no-headers 2>/dev/null)"
fi
GPU_AFTER=$(gpu_allocated || true)
md "" "| 측정 | DNS 수정 전 (\`docs/labs/argocd-20261122-1612.md\`) | DNS 수정 후 (이 시험) | 비고 |" "|---|---|---|---|" \
  "| 처음 sync: Application 생성 → Synced + Healthy (+ 파드 Ready) | 21초 (이미지가 노드에 있었다) | $( ((RESYNC)) && awk -v s="${MS[resync.synced]}" -v r="${MS[resync.ready]}" 'BEGIN { printf "Synced+Healthy %.1f초, 파드 Ready까지 %.1f초", s / 1000, r / 1000 }' || echo '재지 않음 (--no-resync)') | 이미지가 노드에 있는 상태로 다시 만들어 쟀다 (이 시험이 처음 만든 때의 시간은 위 1절, 이미지 pull 포함) |" \
  "| 새 리비전: values 커밋 → 새 파드 Ready | 55초 (maxBatch 8→4 커밋) | 성공 경로 $(secs "${MS[ok.tag_commit]}" "${MS[ok.pod_ready]}")초$( ((RUN_BLOCK)) && printf ', 되돌림 경로 %s초' "$(secs "${MS[rev.tag_commit]}" "${MS[rev.pod_ready]}")") | 구간의 정의는 같다(Git에 값 커밋이 들어간 뒤 새 파드 Ready). 이번에는 새 이미지를 노드가 처음 받는 시간이 더 들어 있다 |" \
  "| (참고) 태그 커밋 → Argo CD sync 시작 | 재지 않음 | 성공 경로 $(secs "${MS[ok.tag_commit]}" "${MS[ok.argo_start]}")초 | 확인 주기 30초 + 저장소 읽기 |"
md "" "- GPU: Application을 지워서(\`scripts/argocd-deploy.sh app-down\`) 추론 파드가 없다. gpu-host가 할당한 GPU: \`${GPU_AFTER:-?}\`"

# --- 15) 요약 ---
md "" "## 결과 요약" "" "PASS $PASS, FAIL $FAIL" ""
log "cicd e2e test: PASS $PASS, FAIL $FAIL (report: $REPORT)"
((FAIL == 0))
