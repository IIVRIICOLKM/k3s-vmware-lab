#!/usr/bin/env bash
# Jenkins stage "Python": byte-compiles every .py under apps/train and tests/train, checks that the Dockerfile copies each module and
# that requirements.txt is pinned with hashes, then runs the unit tests in tests/train (unittest; no GPU, DB or network).
# Usage: scripts/jenkins-stage-python.sh [python]   (default: python3 or python; it must import torch and numpy)
#
# [한국어 설명] Jenkins "Python" 단계: 학습 코드(apps/train) 문법 검사와 단위 시험.
#   1) py_compile: apps/train 아래와 tests/train 아래 모든 .py를 컴파일해 문법 오류를 찾는다.
#      결과물(__pycache__)은 임시 폴더로 보내서(PYTHONPYCACHEPREFIX) 작업 트리를 더럽히지 않는다.
#   2) Dockerfile 검사: apps/train의 모듈(.py)이 Dockerfile의 COPY에 빠짐없이 들어 있는지 본다.
#      train.py가 import하는 새 모듈을 COPY에 안 넣으면 이미지는 빌드되지만 파드에서 ImportError로 죽는다.
#   3) requirements.txt 검사: 모든 줄이 "==버전"과 "--hash=sha256:"을 가졌는지 본다 (Dockerfile이 --require-hashes로 설치).
#   4) 단위 시험: python -m unittest discover -s tests/train -t tests/train (저장소 최상위에서 실행).
#      시험은 apps/train 밖(tests/train)에 둔다: scripts/image-build.sh가 하위 폴더가 있는 빌드 폴더를 거부하기 때문이다.
#      시험 파일이 스스로 apps/train을 import 경로에 넣는다.
#      학습 이미지와 같은 PyTorch 이미지(pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime)에서 돈다 → 운영과 같은 torch·Python.
#      PyMySQL은 필요 없다: 시험은 가짜 DB 연결을 쓴다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail

# --- 1) 도움말과 준비 ---
# sed -n '2,4s/^# \{0,1\}//p' "$0" : 이 파일 2~4번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,4s/^# \{0,1\}//p' "$0"
  exit 0
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAIN="$REPO_ROOT/apps/train"
TESTS="$REPO_ROOT/tests/train"
PY=${1:-$(command -v python3 || command -v python || true)}
PYCACHE=$(mktemp -d)
trap 'rm -rf "$PYCACHE"' EXIT
export PYTHONPYCACHEPREFIX="$PYCACHE"

# log 메시지 / fail 메시지 : 한 줄 출력 / 실패 출력 후 종료
log() { printf '%s [python] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { log "FAIL: $*" >&2; exit 1; }

[[ -n "$PY" ]] || fail "no python3 found"
"$PY" -c 'import torch, numpy' 2>/dev/null || fail "$PY cannot import torch and numpy (run this stage in the PyTorch image)"
log "$("$PY" --version 2>&1), torch $("$PY" -c 'import torch; print(torch.__version__)'), numpy $("$PY" -c 'import numpy; print(numpy.__version__)')"

# --- 2) 문법 검사 (py_compile) ---
mapfile -t files < <(find "$TRAIN" "$TESTS" -name '*.py' -not -path '*/__pycache__/*' | sort)
((${#files[@]} > 0)) || fail "no .py files under apps/train"
[[ -d "$TESTS" ]] || fail "$TESTS not found"
# 이미지 빌드 폴더(apps/train)에는 하위 폴더가 없어야 한다 (scripts/image-build.sh는 파일만 있는 폴더만 받는다)
[[ -z "$(find "$TRAIN" -mindepth 1 -type d -not -name __pycache__ -print -quit)" ]] || fail "apps/train has a subfolder; scripts/image-build.sh would refuse it"
"$PY" -m py_compile "${files[@]}" || fail "py_compile found a syntax error"
log "py_compile OK: ${#files[@]} files"

# --- 3) Dockerfile과 requirements.txt 검사 ---
# 이미지에 들어가야 하는 모듈 = apps/train 바로 아래의 .py (시험은 tests/train에 있어 이미지와 무관하다)
for f in "$TRAIN"/*.py; do
  name=$(basename "$f")
  grep -E '^COPY .*[[:space:]]' "$TRAIN/Dockerfile" | grep -qw -- "$name" ||
    fail "apps/train/Dockerfile does not COPY $name (the pod would fail with ImportError)"
done
log "Dockerfile copies every module in apps/train"
# 주석과 빈 줄을 뺀 각 줄이 "이름==버전 --hash=sha256:..." 형식인지
while IFS= read -r line; do
  [[ "$line" =~ ^[A-Za-z0-9_.-]+==[A-Za-z0-9_.+-]+[[:space:]]+--hash=sha256:[0-9a-f]{64}$ ]] ||
    fail "requirements.txt line is not 'name==version --hash=sha256:<hex>': $line"
done < <(grep -Ev '^[[:space:]]*(#|$)' "$TRAIN/requirements.txt")
log "requirements.txt is pinned with hashes"

# --- 4) 단위 시험 ---
log "unittest tests/train"
(cd "$REPO_ROOT" && "$PY" -m unittest discover -s tests/train -t tests/train -v) 2>&1 | tee "$PYCACHE/unittest.log" | tail -n 8 || true
# tee 뒤의 종료 코드는 tail의 것이라 믿을 수 없다 → 로그의 마지막 판정 줄로 확인한다
grep -Eq '^OK$|^OK \(' "$PYCACHE/unittest.log" || {
  # 실패하면 앞에서 잘라 낸 부분까지 로그 전체를 보여 준다 (어떤 시험이 왜 실패했는지 Jenkins 콘솔에서 바로 보이게)
  cat "$PYCACHE/unittest.log" >&2
  fail "unit tests failed: $(grep -cE '^(FAIL|ERROR):' "$PYCACHE/unittest.log" || true) failing test(s)"
}
ran=$(grep -E '^Ran [0-9]+ tests?' "$PYCACHE/unittest.log" | head -1)
log "PASS: $ran"
