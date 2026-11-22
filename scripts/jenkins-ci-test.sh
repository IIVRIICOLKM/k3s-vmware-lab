#!/usr/bin/env bash
# Verifies the Jenkins CI on the cluster end to end (proposal: Jenkins build and test automation, weeks 10-12): the deployment,
# one successful pipeline run that builds both images, a rerun that must not rebuild, and two broken copies of the source
# (Python syntax error, failing unit test) that must stop before the image stage. Report: docs/labs/jenkins-ci-<date>.md
# Usage: scripts/jenkins-ci-test.sh [--images LIST]   (needs scripts/jenkins-deploy.sh done; the success run builds LIST, default both images)
#
# [한국어 설명] 클러스터 위 Jenkins CI를 처음부터 끝까지 확인하고 보고서로 남긴다.
#   ① 배포 상태: 컨트롤러 파드 Ready(worker-cpu-1, 고정 이미지, 승인된 자원, PVC 5Gi), 로그인 화면, 운영 작업 k3slab-ci,
#      익명 접근 거부, 비밀번호가 Git에 없음
#   ② 파이프라인 1회 성공: 작업 폴더 스냅샷(ConfigMap)으로 시험용 작업을 돌린다. 검사 4단계(C++, Python, 쉘, Helm)가 모두 PASS하고
#      이미지 2개가 만들어지는지, 레지스트리의 digest가 결과 기록(ci-result.json, ConfigMap ci-latest-local)과 같은지,
#      에이전트 파드가 gpu-host에서 돌고 끝나면 사라지는지 본다.
#   ③ 같은 소스를 한 번 더: 같은 태그를 다시 빌드하지 않고 같은 digest를 쓰는지 (태그는 덮어쓰지 않는다)
#   ④ 일부러 실패: 임시 사본에 Python 문법 오류를 넣으면 Python 단계에서 멈추고 이미지 단계는 건너뛰어져야 한다.
#      레지스트리에 그 태그가 생기지 않아야 한다. 단위 시험이 실패하는 사본도 같은 방식으로 본다.
#   ⑤ 메모리: worker-cpu-1의 사용량을 배포 전(jenkins-deploy.sh가 기록), 배포 직후, 파이프라인 도중(표본), 끝난 뒤로 비교한다.
#   시험용 사본은 임시 폴더에 만들고 저장소 파일은 건드리지 않는다. 비밀번호는 보고서에 쓰지 않는다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자와 상수 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
IMAGES="infer-worker,train-worker"
while (($# > 0)); do
  case "$1" in
    -h | --help) sed -n '2,5s/^# \{0,1\}//p' "$0"; exit 0 ;;
    --images) IMAGES=${2:-}; shift 2 ;;
    *) die "usage: scripts/jenkins-ci-test.sh [--images LIST] (see --help)" ;;
  esac
done
NS="ci"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
RUN="$REPO_ROOT/scripts/jenkins-run.sh"
REGISTRY="$REPO_ROOT/scripts/jenkins-registry.sh"
REPORT="$REPO_ROOT/docs/labs/jenkins-ci-$(date +%Y%m%d-%H%M).md"
MEMORY_BEFORE="$LAB_STATE_DIR/jenkins-memory-before.txt"
WORK=$(mktemp -d)
PASS=0
FAIL=0
SAMPLER_PID=""
mkdir -p "$(dirname "$REPORT")"
cleanup() {
  [[ -z "$SAMPLER_PID" ]] || kill "$SAMPLER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

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
# jx 경로 : 컨트롤러 파드 안에서 Jenkins API를 (관리자 계정으로) 부른다. 비밀번호는 파드 안 파일에서 읽는다.
jx() {
  k -n "$NS" exec jenkins-0 -c jenkins -- sh -c \
    'curl -sS -u "$(cat /run/secrets/additional/chart-admin-username):$(cat /run/secrets/additional/chart-admin-password)" "http://localhost:8080$1"' sh "$1"
}
# mem_node : worker-cpu-1의 사용 메모리 (MiB, kubectl top 기준)와 퍼센트
mem_node() { k top node worker-cpu-1 --no-headers | awk '{print $4 " (" $5 ")"}'; }
# in_log 로그파일 패턴 : 로그에 패턴이 있으면 성공
in_log() { grep -qF -- "$2" "$1"; }
# run_ci 이름 [jenkins-run.sh 인자...] : 파이프라인을 한 번 돌려 결과 JSON을 $WORK/<이름>.json에 남긴다 (실패해도 계속)
run_ci() {
  local name=$1
  shift
  "$RUN" --out "$WORK/$name.json" "$@" >"$WORK/$name.out" 2>&1 || true
  [[ -s "$WORK/$name.json" ]] || { tail -20 "$WORK/$name.out" >&2; die "jenkins-run.sh produced no result for $name"; }
}
# jf 이름 필드 : $WORK/<이름>.json에서 값 하나 (문자열·숫자)
jf() { jq -r "$2" "$WORK/$1.json"; }
# broken_copy 폴더 종류 : 작업 폴더의 스냅샷 파일을 임시 폴더로 복사하고 일부러 고장 낸다
broken_copy() {
  local dir=$1 kind=$2
  mkdir -p "$dir"
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard -- Jenkinsfile apps charts scripts infra tests |
    while IFS= read -r -d '' f; do [[ -f "$f" ]] && printf '%s\0' "$f"; done | xargs -0 cp --parents -t "$dir")
  case "$kind" in
    syntax) printf '\ndef broken(:\n' >>"$dir/apps/train/train.py" ;;
    unittest) sed -i 's/w > 16384/w > 8192/' "$dir/apps/train/train.py" ;; # parse_hidden의 상한을 바꿔 tests가 잡아야 한다
  esac
}

{
  printf '# Jenkins CI 시험 (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 생성: `scripts/jenkins-ci-test.sh`\n'
  printf -- '- 경로: 작업 폴더 스냅샷 → ConfigMap `ci-source-<해시>` → Jenkins(`ci` 네임스페이스, worker-cpu-1) → 에이전트 파드(gpu-host) → 검사 4단계 → Kaniko → 레지스트리\n'
  printf -- '- Jenkins: 공식 Helm 차트 5.13.3, 컨트롤러 이미지 `jenkins/jenkins:2.580.2-jdk25` (`infra/k8s/jenkins/values.yaml`)\n'
} >"$REPORT"

# --- 2) ① 배포 상태 ---
md "" "## 1. 배포 상태"
check "컨트롤러 파드 jenkins-0이 Ready" k -n "$NS" wait --for=condition=ready pod/jenkins-0 --timeout=60s
node=$(k -n "$NS" get pod jenkins-0 -o jsonpath='{.spec.nodeName}')
check "컨트롤러는 worker-cpu-1(platform 노드)에서 돈다 (실제: $node)" test "$node" = worker-cpu-1
img=$(k -n "$NS" get pod jenkins-0 -o jsonpath='{.spec.containers[?(@.name=="jenkins")].image}')
check "컨트롤러 이미지가 고정 태그다 (실제: $img)" test "$img" = docker.io/jenkins/jenkins:2.580.2-jdk25
res=$(k -n "$NS" get pod jenkins-0 -o jsonpath='{.spec.containers[?(@.name=="jenkins")].resources}')
check "컨트롤러 자원이 승인안과 같다: 요청 CPU 250m·메모리 768Mi, 한도 CPU 1·메모리 1Gi" \
  jq -e '.requests.cpu == "250m" and .requests.memory == "768Mi" and .limits.cpu == "1" and .limits.memory == "1Gi"' <<<"$res"
pvc=$(k -n "$NS" get pvc jenkins -o jsonpath='{.status.phase} {.status.capacity.storage}')
check "PVC jenkins가 Bound이고 5Gi다 (실제: $pvc)" test "$pvc" = "Bound 5Gi"
code=$(k -n "$NS" exec jenkins-0 -c jenkins -- curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/login)
check "로그인 화면이 열린다: HTTP $code" test "$code" = 200
code=$(k -n "$NS" exec jenkins-0 -c jenkins -- curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/api/json)
check "로그인하지 않으면 API를 쓸 수 없다 (익명 접근 HTTP $code)" test "$code" = 403
check "JCasC가 만든 운영 작업 k3slab-ci가 있다 (GitHub develop, 5분 폴링)" grep -q '"k3slab-ci"' <(jx '/api/json?tree=jobs%5Bname%5D')
# 플러그인 로드: values.yaml의 고정 목록("이름:버전" 73개)이 모두 로드됐는지. 로드에 실패한 플러그인은 목록에서 빠진다.
#   Declarative Pipeline이 빠지면 파이프라인이 단계 없이 SUCCESS로 끝나는 일이 있었다 (2026-11-22 첫 배포)
plugins=$(jx '/pluginManager/api/json?depth=1&tree=plugins%5BshortName,version,active%5D')
expected=$(sed -n 's/^    - \([a-z0-9-]*:[A-Za-z0-9._-]*\)$/\1/p' "$REPO_ROOT/infra/k8s/jenkins/values.yaml" | LC_ALL=C sort)
loaded=$(jq -r '.plugins[] | select(.active == true) | "\(.shortName):\(.version)"' <<<"$plugins" | LC_ALL=C sort)
missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$loaded") | tr '\n' ' ')
check "고정한 플러그인 $(wc -l <<<"$expected")개가 모두 그 버전으로 로드됐다 (빠진 것: ${missing:-없음})" test -n "$expected" -a -z "$missing"
check "관리자 비밀번호 파일의 권한이 600이다" test "$(stat -c %a "$LAB_SECRETS_DIR/jenkins.env")" = 600
pw=$(sed -n 's/^JENKINS_ADMIN_PASSWORD=//p' "$LAB_SECRETS_DIR/jenkins.env")
check "비밀번호가 저장소 파일 어디에도 없다" bash -c '! grep -rqF -- "$1" "$2" --exclude-dir=.git' _ "$pw" "$REPO_ROOT"
unset pw
block "kubectl -n ci get pods,pvc,svc -o wide" "$(k -n "$NS" get pods,pvc,svc -o wide)"
mem_after_deploy=$(mem_node || echo "n/a")

# --- 3) ② 파이프라인 1회 성공 (이미지 빌드 포함) ---
md "" "## 2. 파이프라인 1회 성공"
# 파이프라인이 도는 동안 worker-cpu-1 메모리와 ci 파드 자원을 15초마다 표본으로 남긴다
: >"$WORK/samples.txt"
(
  while true; do
    printf '%s node=%s | %s\n' "$(date +%T)" "$(mem_node 2>/dev/null || echo n/a)" \
      "$(k top pod -n "$NS" --no-headers 2>/dev/null | awk '{printf "%s=%s/%s ", $1, $2, $3}')" >>"$WORK/samples.txt"
    sleep 15
  done
) &
SAMPLER_PID=$!
log "success run (images: $IMAGES)"
run_ci ok --images "$IMAGES"
check "파이프라인이 SUCCESS로 끝났다 (빌드 #$(jf ok .build))" test "$(jf ok .result)" = SUCCESS
LOG_OK=$(jf ok .log)
for stage in cpp python shell helm; do
  line=$(grep -m1 "\[$stage\] PASS" "$LOG_OK" || true)
  check "검사 단계 $stage가 PASS: ${line#*\] }" test -n "$line"
done
TAG=$(jf ok .tag)
check "이미지 태그가 소스 해시 기반 src-<12자리>다 (실제: $TAG)" bash -c '[[ "$1" =~ ^src-[0-9a-f]{12}$ ]]' _ "$TAG"
IFS=',' read -ra want <<<"$IMAGES"
for name in "${want[@]}"; do
  rec=$(jf ok ".ci_result.images[] | select(.name == \"$name\") | .digest")
  reg=$(bash "$REGISTRY" digest "$name" "$TAG" || true)
  check "$name:$TAG를 만들었고 레지스트리 digest가 결과 기록과 같다 ($reg)" bash -c '[[ "$1" =~ ^sha256:[0-9a-f]{64}$ && "$1" == "$2" ]]' _ "$reg" "$rec"
  cm=$(k -n "$NS" get configmap ci-latest-local -o jsonpath="{.data.$name\\.digest}" 2>/dev/null || true)
  check "ConfigMap ci-latest-local의 $name digest가 같다" test "$cm" = "$rec"
done
check "ConfigMap ci-latest-local의 tag가 $TAG다" test "$(k -n "$NS" get configmap ci-latest-local -o jsonpath='{.data.tag}')" = "$TAG"
check "ci-result.json이 Jenkins 빌드 산출물로 남았다" test -n "$(jf ok '.ci_result.tag // empty')"
# 에이전트 파드가 어느 노드에서 돌았는지: 일정 배정(Scheduled) 이벤트 (이벤트는 약 1시간 남는다)
sched=$(k -n "$NS" get events --field-selector reason=Scheduled -o json |
  jq -r '.items[] | select(.involvedObject.name | startswith("k3slab-ci-local-")) | "\(.involvedObject.name) -> \(.message | sub(".* to "; ""))"' | sort -u)
check "에이전트 파드(검사, 이미지)가 gpu-host에 배정됐다" bash -c '[[ -n "$1" ]] && ! grep -v -- "-> gpu-host$" <<<"$1" | grep -q .' _ "$sched"
check "빌드가 끝나면 에이전트 파드가 모두 사라진다" wait_for 120 bash -c '[[ "$(KUBECONFIG="$1" K3S_CONFIG_FILE=/dev/null kubectl -n ci get pods -o name | grep -vc "^pod/jenkins-0$")" == 0 ]]' _ "$KUBECONFIG_FILE"
block "에이전트 파드 배치 (kubectl get events, reason=Scheduled)" "$sched"
block "ci-result.json (빌드 산출물)" "$(jq '.ci_result' "$WORK/ok.json")"
block "빌드 로그에서 단계별 결과" "$(grep -E '^\[?[0-9T:.Z-]*\]? ?[0-9:]{8} \[(cpp|python|shell|helm)\] (PASS|FAIL)|built registry|already exists' "$LOG_OK" | sed 's/^\[[^]]*\] //' || true)"

# --- 4) ③ 같은 소스 다시: 태그를 덮어쓰지 않는다 ---
md "" "## 3. 같은 소스를 한 번 더 (태그는 덮어쓰지 않는다)"
run_ci again --images "$IMAGES"
check "SUCCESS로 끝났다 (빌드 #$(jf again .build)), 소스 해시가 같아 같은 태그다" bash -c '[[ "$1" == SUCCESS && "$2" == "$3" ]]' _ "$(jf again .result)" "$(jf again .tag)" "$TAG"
for name in "${want[@]}"; do
  check "$name:$TAG는 이미 있어 다시 빌드하지 않았다" in_log "$(jf again .log)" "$name:$TAG already exists"
  check "$name의 digest가 처음과 같다" test "$(jf again ".ci_result.images[] | select(.name == \"$name\") | .digest")" = "$(jf ok ".ci_result.images[] | select(.name == \"$name\") | .digest")"
done

# --- 5) ④ 일부러 실패: 이미지 단계가 건너뛰어져야 한다 ---
md "" "## 4. 일부러 실패시킨 사본 (이미지 단계는 건너뛰어져야 한다)"
for kind in syntax unittest; do
  case "$kind" in
    syntax) title="Python 문법 오류 (apps/train/train.py 끝에 'def broken(:' 추가)"; stage_line='[python] FAIL: py_compile found a syntax error' ;;
    unittest) title="단위 시험 실패 (parse_hidden의 상한 16384 → 8192)"; stage_line='[python] FAIL: unit tests failed' ;;
  esac
  md "" "### 4-$kind. $title"
  broken_copy "$WORK/$kind" "$kind"
  run_ci "$kind" --source-dir "$WORK/$kind" --images "$IMAGES"
  L=$(jf "$kind" .log)
  T=$(jf "$kind" .tag)
  check "파이프라인이 FAILURE로 끝났다 (빌드 #$(jf "$kind" .build))" test "$(jf "$kind" .result)" = FAILURE
  check "Python 단계가 실패했다: $stage_line" in_log "$L" "$stage_line"
  check "쉘·Helm 단계는 건너뛰어졌다" bash -c 'grep -qF "Stage \"쉘\" skipped" "$1" && grep -qF "Stage \"Helm\" skipped" "$1"' _ "$L"
  check "이미지 단계가 건너뛰어졌다 (Stage \"이미지\" skipped due to earlier failure)" in_log "$L" 'Stage "이미지" skipped due to earlier failure(s)'
  for name in "${want[@]}"; do
    check "레지스트리에 $name:$T가 생기지 않았다" test -z "$(bash "$REGISTRY" digest "$name" "$T")"
  done
  block "실패한 빌드 로그 끝부분 (#$(jf "$kind" .build))" "$(grep -E "FAIL|rror|skipped|Finished" "$L" | sed 's/^\[[^]]*\] //' | tail -12)"
done

# --- 6) ⑤ 메모리 ---
kill "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=""
md "" "## 5. worker-cpu-1 메모리 (kubectl top, metrics-server 기준)"
before=$(sed -n '1!p' "$MEMORY_BEFORE" 2>/dev/null | awk '$1 == "worker-cpu-1" {print $4 " (" $5 ")"}')
now=$(mem_node || echo n/a)
md "" "| 시점 | worker-cpu-1 사용 메모리 |" "|---|---|" \
  "| Jenkins 배포 전 (\`scripts/jenkins-deploy.sh\`가 기록) | ${before:-기록 없음} |" \
  "| 배포 직후, 시험 시작 때 | $mem_after_deploy |" \
  "| 시험이 모두 끝난 직후 | $now |"
peak=$(grep -o 'node=[0-9]*Mi' "$WORK/samples.txt" 2>/dev/null | sed 's/node=//; s/Mi//' | sort -n | tail -1 || true)
md "" "- 파이프라인이 도는 동안 15초 간격 표본 $(wc -l <"$WORK/samples.txt") 개 중 최대 **${peak:-n/a} Mi**"
block "표본 (시각, 노드 메모리, ci 네임스페이스 파드 CPU/메모리)" "$(cat "$WORK/samples.txt" 2>/dev/null || true)"
block "kubectl top nodes (끝난 직후)" "$(k top nodes 2>&1 || true)"
block "kubectl top pod -n ci (끝난 직후)" "$(k top pod -n "$NS" 2>&1 || true)"

# --- 7) 요약 ---
md "" "## 요약" "" "**PASS $PASS / $((PASS + FAIL))**$([[ $FAIL -gt 0 ]] && echo " — FAIL $FAIL")"
log "PASS $PASS / $((PASS + FAIL)); report: ${REPORT#"$REPO_ROOT/"}"
((FAIL == 0))
