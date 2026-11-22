#!/usr/bin/env bash
# Runs the same checks as the Jenkins pipeline's check stages, on this machine and without a cluster:
# C++ build and smoke test, Python compile and unit tests, shell syntax and ShellCheck, Helm lint and template.
# Usage: scripts/jenkins-check.sh [--python PYTHON] [cpp|python|shell|helm ...]   (default: all four)
#
# [한국어 설명] Jenkins 검사 단계와 같은 검사를 이 컴퓨터에서 클러스터 없이 돌린다. 코드를 올리기 전에 미리 보는 용도다.
#   각 단계의 명령은 scripts/jenkins-stage-<이름>.sh이고 Jenkinsfile이 부르는 것과 같은 파일이라, 결과도 같다.
#   - 한 단계가 실패해도 나머지를 계속 돌려 마지막에 표로 보여 준다. 하나라도 실패하면 종료 코드 1이다.
#   - Python 단계는 torch와 numpy가 있는 Python이 필요하다 (Jenkins에서는 학습 이미지의 PyTorch를 쓴다).
#     이 컴퓨터의 python3에 torch가 없으면 --python <경로>로 알려 준다. 없고 안 알려 주면 그 단계는 SKIP으로 표시한다(실패 아님).
#   - 필요한 도구: g++, make, curl, bash, ShellCheck와 Helm(없으면 고정 버전을 받는다)
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail

# --- 1) 인자 ---
# sed -n '2,4s/^# \{0,1\}//p' "$0" : 이 파일 2~4번째 줄(영문 설명)을 도움말로 출력
usage() {
  sed -n '2,4s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON=""
STAGES=()
while (($# > 0)); do
  case "$1" in
    -h | --help) usage 0 ;;
    --python) PYTHON=${2:-}; shift 2 ;;
    cpp | python | shell | helm) STAGES+=("$1"); shift ;;
    *) usage 2 ;;
  esac
done
((${#STAGES[@]} > 0)) || STAGES=(cpp python shell helm)

# --- 2) 단계 실행 ---
# python 단계에 쓸 인터프리터를 고른다: --python 값, 없으면 torch와 numpy를 읽을 수 있는 python3
if [[ -z "$PYTHON" ]] && python3 -c 'import torch, numpy' 2>/dev/null; then PYTHON=$(command -v python3); fi
declare -A RESULT=()
failed=0
for s in "${STAGES[@]}"; do
  printf '\n=== %s ===\n' "$s"
  if [[ "$s" == python && -z "$PYTHON" ]]; then
    RESULT[$s]="SKIP (no Python with torch and numpy; use --python)"
    continue
  fi
  args=()
  [[ "$s" == python ]] && args=("$PYTHON")
  start=$SECONDS
  if bash "$REPO_ROOT/scripts/jenkins-stage-$s.sh" "${args[@]}"; then
    RESULT[$s]="PASS ($((SECONDS - start)) s)"
  else
    RESULT[$s]="FAIL ($((SECONDS - start)) s)"
    failed=$((failed + 1))
  fi
done

# --- 3) 요약 ---
printf '\n=== summary ===\n'
for s in "${STAGES[@]}"; do printf '%-8s %s\n' "$s" "${RESULT[$s]}"; done
((failed == 0))
