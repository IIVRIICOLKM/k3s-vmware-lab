#!/usr/bin/env bash
# Jenkins stage "C++": builds the inference worker without CUDA (make CUDA=0) and smoke-tests the binary.
# cpp-httplib is fetched at the version and SHA-256 written in apps/infer/Dockerfile (one source of truth), because the
# header is not in the repo. The build runs in a temporary copy, so the checked-out tree stays clean.
# Usage: scripts/jenkins-stage-cpp.sh        (needs g++, make, curl; the Jenkins agent image gcc:15.3.0-trixie has them)
#
# [한국어 설명] Jenkins "C++" 단계: apps/infer를 CUDA 없이(make CUDA=0) 빌드하고, 만든 바이너리를 실제로 띄워 본다.
#   1) apps/infer를 임시 폴더로 복사한다 (빌드 결과물 .o와 httplib.h로 작업 트리를 더럽히지 않기 위해).
#   2) httplib.h(cpp-httplib)를 받는다. 버전과 SHA-256은 apps/infer/Dockerfile의 ARG 값을 읽어 쓴다
#      → 이미지 빌드와 같은 파일로 검사하고, 값을 두 곳에 적지 않는다. SHA-256이 다르면 즉시 실패.
#   3) make CUDA=0 으로 빌드한다 (CUDA toolkit이 없는 에이전트에서도 돈다. backend_cuda.cu는 컴파일하지 않는다).
#   4) 실행 검사: 가중치 0, 편향만 3번 클래스가 1인 모델(K3SM, 64→10)을 만들어 워커를 띄우고
#      /healthz, /infer(class 3이 나와야 함), 잘못된 입력(400), /metrics, 모델 파일이 없을 때 종료 코드를 확인한다.
#   Python 없이 bash와 curl만 쓴다 (gcc 이미지에 있는 것).
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail

# --- 1) 도움말과 경로 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit 0
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/apps/infer"
WORK=$(mktemp -d)
WORKER_PID=""

# log 메시지 / fail 메시지 : 한 줄 출력 / 실패 출력 후 종료
log() { printf '%s [cpp] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { log "FAIL: $*" >&2; exit 1; }
# cleanup : 어떻게 끝나든 워커 프로세스를 멈추고 임시 폴더를 지운다 (trap EXIT)
cleanup() {
  [[ -z "$WORKER_PID" ]] || kill "$WORKER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- 2) 소스 복사와 httplib.h 내려받기 ---
[[ -f "$SRC/Makefile" ]] || fail "$SRC/Makefile not found"
cp "$SRC"/Makefile "$SRC"/*.h "$SRC"/*.cpp "$SRC"/*.cu "$WORK"/
# dockerfile_arg 이름 : Dockerfile의 "ARG 이름=값" 줄에서 값을 읽는다
dockerfile_arg() { sed -n "s/^ARG $1=//p" "$SRC/Dockerfile" | head -1; }
HTTPLIB_VERSION=$(dockerfile_arg HTTPLIB_VERSION)
HTTPLIB_SHA256=$(dockerfile_arg HTTPLIB_SHA256)
[[ -n "$HTTPLIB_VERSION" && -n "$HTTPLIB_SHA256" ]] || fail "apps/infer/Dockerfile has no HTTPLIB_VERSION / HTTPLIB_SHA256 ARG"
log "cpp-httplib $HTTPLIB_VERSION (pinned in apps/infer/Dockerfile)"
curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/httplib.h" \
  "https://raw.githubusercontent.com/yhirose/cpp-httplib/${HTTPLIB_VERSION}/httplib.h"
echo "${HTTPLIB_SHA256}  $WORK/httplib.h" | sha256sum -c - >/dev/null || fail "httplib.h does not match the pinned SHA-256"

# --- 3) 빌드 ---
# -j 코어 수: 에이전트 파드의 메모리 한도(2Gi)에 맞춰 최대 2개. httplib.h를 포함한 파일 하나가 약 1GB를 쓸 수 있다.
JOBS=$(($(nproc) < 2 ? $(nproc) : 2))
log "make -j$JOBS CUDA=0 (g++ $(g++ -dumpfullversion))"
make -C "$WORK" -j"$JOBS" CUDA=0 >"$WORK/build.log" 2>&1 || {
  tail -40 "$WORK/build.log" >&2
  fail "make CUDA=0 failed"
}
BIN="$WORK/k3slab-infer"
[[ -x "$BIN" ]] || fail "make finished but $BIN is missing"
log "built $(basename "$BIN") ($(stat -c %s "$BIN") bytes), compiler warnings: $(grep -c 'warning:' "$WORK/build.log" || true)"

# --- 4) 단위 시험: /metrics 코드 (지연 히스토그램) ---
# tests/infer는 이미지 빌드 폴더(apps/infer) 밖에 있다. 소스는 위에서 복사한 임시 폴더의 것을 쓴다(빌드한 것과 같은 코드).
#   httplib.h가 필요 없는 파일만 컴파일한다(main.cpp·worker.cpp는 넣지 않는다). 프레임워크 없이 CHECK 매크로로 검사한다.
TEST_SRC="$REPO_ROOT/tests/infer/test_metrics.cpp"
[[ -f "$TEST_SRC" ]] || fail "$TEST_SRC not found"
g++ -std=c++20 -O1 -Wall -Wextra -I "$WORK" "$TEST_SRC" "$WORK/metrics.cpp" "$WORK/config.cpp" "$WORK/util.cpp" -pthread \
  -o "$WORK/test_metrics" >"$WORK/test-build.log" 2>&1 || {
  tail -30 "$WORK/test-build.log" >&2
  fail "tests/infer/test_metrics.cpp does not compile"
}
"$WORK/test_metrics" >"$WORK/test-run.log" 2>&1 || {
  cat "$WORK/test-run.log" >&2
  fail "metrics unit test failed (tests/infer/test_metrics.cpp)"
}
log "metrics unit test: $(tail -1 "$WORK/test-run.log")"

# --- 5) 실행 검사 ---
# le32 숫자 : 부호 없는 32비트 정수를 little-endian 4바이트로 출력 (K3SM 형식)
#   먼저 "\x0a" 같은 글자를 만들고 %b로 실제 바이트로 바꾼다 (printf 서식에 변수를 직접 넣지 않으려는 방식)
le32() { printf '%b' "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)))"; }
# make_model 경로 : 레이어 하나(64→10), 가중치 전부 0, 편향은 3번 클래스만 1.0. 그래서 입력과 상관없이 class 3이 나온다.
make_model() {
  {
    printf 'K3SM'
    le32 1 # 형식 버전
    le32 1 # 레이어 수
    le32 10 # out
    le32 64 # in
    head -c $((10 * 64 * 4)) /dev/zero
    local c
    for c in 0 1 2 3 4 5 6 7 8 9; do
      if ((c == 3)); then printf '\x00\x00\x80\x3f'; else printf '\x00\x00\x00\x00'; fi
    done
  } >"$1"
}
make_model "$WORK/model.k3sm"
PORT=$((20000 + RANDOM % 20000))
URL="http://127.0.0.1:$PORT"
MODEL_PATH="$WORK/model.k3sm" PORT=$PORT DEVICE=cpu WORK_MS=0 MODEL_VERSION=ci-smoke "$BIN" >"$WORK/worker.log" 2>&1 &
WORKER_PID=$!
# 준비될 때까지 최대 10초 기다린다 (워커가 죽었으면 바로 실패)
ready=""
for _ in $(seq 50); do
  kill -0 "$WORKER_PID" 2>/dev/null || { cat "$WORK/worker.log" >&2; fail "worker exited during start"; }
  if curl -fsS -m 2 "$URL/healthz" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.2
done
[[ -n "$ready" ]] || { cat "$WORK/worker.log" >&2; fail "worker did not answer /healthz within 10 s"; }
log "worker up: $(head -1 "$WORK/worker.log" | cut -c1-120)"

# 정상 요청: 입력 64개(전부 0) → 200, class 3, device cpu, model_version ci-smoke
body="{\"x\":[$(printf '0,%.0s' $(seq 63))0]}"
reply=$(curl -sS -m 5 -w '\n%{http_code}' -H 'Content-Type: application/json' -d "$body" "$URL/infer")
code=${reply##*$'\n'}
json=${reply%$'\n'*}
[[ "$code" == 200 ]] || fail "POST /infer returned $code: $json"
[[ "$json" == *'"class":3,'* ]] || fail "expected class 3, got: $json"
[[ "$json" == *'"device":"cpu"'* && "$json" == *'"model_version":"ci-smoke"'* ]] || fail "unexpected reply: $json"
log "POST /infer -> 200 class 3 (device cpu)"
# 잘못된 입력: 숫자 2개 → 400, 요청이 큐에 들어가지 않는다
code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H 'Content-Type: application/json' -d '{"x":[1,2]}' "$URL/infer")
[[ "$code" == 400 ]] || fail "short input should return 400, got $code"
log "POST /infer with 2 numbers -> 400"
# 메트릭: 기기와 요청 개수(정상 1, 잘못된 입력 1)
metrics=$(curl -fsS -m 5 "$URL/metrics")
grep -q 'k3slab_infer_info{device="cpu"' <<<"$metrics" || fail "/metrics has no device=cpu info line"
grep -q 'k3slab_infer_requests_total{result="ok"} 1$' <<<"$metrics" || fail "/metrics should count 1 ok request"
grep -q 'k3slab_infer_requests_total{result="bad_request"} 1$' <<<"$metrics" || fail "/metrics should count 1 bad request"
log "GET /metrics: device=cpu, ok=1, bad_request=1"
# 지연 히스토그램: 정상 요청 1건이 버킷·합계·개수에 들어갔는지 (le="+Inf"와 _count가 같고 1이어야 한다. 경계값 시험은 위 단위 시험이 한다)
grep -q '^# TYPE k3slab_infer_request_seconds histogram$' <<<"$metrics" || fail "/metrics should declare k3slab_infer_request_seconds as a histogram"
grep -q '^k3slab_infer_request_seconds_bucket{le="+Inf"} 1$' <<<"$metrics" || fail "/metrics: latency bucket le=+Inf should be 1"
grep -q '^k3slab_infer_request_seconds_count 1$' <<<"$metrics" || fail "/metrics: latency _count should be 1"
[[ "$(grep -c '^k3slab_infer_request_seconds_bucket{le="' <<<"$metrics")" == 13 ]] || fail "/metrics should have 13 latency buckets (12 bounds + +Inf)"
log "GET /metrics: latency histogram has 13 buckets, +Inf = _count = 1"
# 종료: SIGTERM을 보내면 정상 종료(코드 0)해야 한다
kill -TERM "$WORKER_PID"
wait "$WORKER_PID" && exit_code=0 || exit_code=$?
WORKER_PID=""
[[ "$exit_code" == 0 ]] || fail "worker should exit 0 on SIGTERM, got $exit_code"
log "SIGTERM -> exit 0"
# 모델 파일이 없으면 시작하지 않고 0이 아닌 코드로 끝나야 한다 (잘못된 배포를 빨리 드러낸다)
if MODEL_PATH="$WORK/none.k3sm" PORT=$PORT DEVICE=cpu "$BIN" >"$WORK/missing.log" 2>&1; then
  fail "worker started without a model file"
fi
grep -q 'startup failed' "$WORK/missing.log" || fail "missing model should print 'startup failed'"
log "missing model -> refuses to start"
log "PASS: C++ build (CUDA=0), metrics unit test and smoke test"
