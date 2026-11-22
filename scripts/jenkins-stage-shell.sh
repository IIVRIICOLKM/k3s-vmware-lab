#!/usr/bin/env bash
# Jenkins stage "Shell": bash -n (syntax) on every *.sh in the repo, then ShellCheck at a pinned version.
# Gate: ShellCheck findings of level warning or error fail the stage (SC2034 "unused variable" is excluded: the shared
# library scripts/lib/common.sh defines variables that the scripts sourcing it use). Notes and style hints are only counted.
# Usage: scripts/jenkins-stage-shell.sh   (needs bash, curl, tar, xz; the agent image gcc:15.3.0-trixie has them)
#
# [한국어 설명] Jenkins "쉘" 단계: 저장소의 모든 *.sh 검사.
#   1) bash -n : 실행하지 않고 문법만 검사한다.
#   2) ShellCheck(v0.11.0 고정): 없으면 GitHub 릴리스에서 받아 SHA-256을 확인하고 쓴다.
#      PATH에 있어도 버전이 다르면 쓰지 않는다 (같은 판정을 보장하기 위해).
#   3) 판정 기준: warning 이상이 있으면 실패. SC2034(안 쓰는 변수)는 뺀다 —
#      scripts/lib/common.sh는 다른 스크립트가 source해서 쓰는 변수를 정의하므로 정상인데 경고가 나온다.
#      note/style 수준은 개수만 알려 준다 (이미 있는 스크립트를 이 단계에서 고치지 않는다).
#   -x : source한 파일도 따라간다. 경로가 변수로 만들어져 못 따라가는 경우(SC1091)는 info 수준이라 판정에 영향이 없다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail

# --- 1) 도움말과 상수 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit 0
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELLCHECK_VERSION="0.11.0"
SHELLCHECK_URL="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
SHELLCHECK_SHA256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# log 메시지 / fail 메시지 : 한 줄 출력 / 실패 출력 후 종료
log() { printf '%s [shell] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { log "FAIL: $*" >&2; exit 1; }

# --- 2) 검사할 파일 목록 ---
# .git 폴더와 의존 폴더(node_modules 등)는 건너뛴다. 이 저장소의 쉘 스크립트는 모두 *.sh 이다.
mapfile -t scripts < <(cd "$REPO_ROOT" && find . -name '*.sh' -not -path './.git/*' -not -path '*/node_modules/*' | sort | sed 's|^\./||')
((${#scripts[@]} > 0)) || fail "no *.sh files found"
log "${#scripts[@]} shell scripts"

# --- 3) bash -n (문법) ---
bad=0
for s in "${scripts[@]}"; do
  bash -n "$REPO_ROOT/$s" 2>"$TMP/syntax.err" || { log "syntax error in $s: $(head -3 "$TMP/syntax.err")" >&2; bad=$((bad + 1)); }
done
((bad == 0)) || fail "$bad script(s) have syntax errors"
log "bash -n OK"

# --- 4) ShellCheck 준비: 같은 버전이 있으면 그것, 없으면 받아서 해시 확인 ---
SC=""
if command -v shellcheck >/dev/null 2>&1 && shellcheck --version | grep -q "^version: ${SHELLCHECK_VERSION}$"; then
  SC=$(command -v shellcheck)
else
  log "downloading ShellCheck v$SHELLCHECK_VERSION"
  curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/sc.tar.xz" "$SHELLCHECK_URL" || fail "cannot download ShellCheck"
  echo "${SHELLCHECK_SHA256}  $TMP/sc.tar.xz" | sha256sum -c - >/dev/null || fail "ShellCheck download does not match the pinned SHA-256"
  tar -xJf "$TMP/sc.tar.xz" -C "$TMP"
  SC="$TMP/shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
fi
log "ShellCheck $("$SC" --version | sed -n 's/^version: //p')"

# --- 5) ShellCheck 실행 ---
# 판정: warning 이상(SC2034 제외). 파일 경로가 한 줄에 하나씩 나오도록 gcc 형식으로 출력한다.
cd "$REPO_ROOT"
if "$SC" -x -S warning -e SC2034 -f gcc "${scripts[@]}" >"$TMP/gate.txt" 2>&1; then
  log "ShellCheck gate OK (warning level or above, SC2034 excluded)"
else
  cat "$TMP/gate.txt" >&2
  fail "ShellCheck found $(grep -c ': \(warning\|error\):' "$TMP/gate.txt" || true) problem(s)"
fi
# 참고용: style/info 수준 개수 (판정에는 쓰지 않는다)
hints=$("$SC" -x -S style -f gcc "${scripts[@]}" 2>&1 | grep -c ': \(note\|style\|info\):' || true)
log "PASS: ${#scripts[@]} scripts (style/info hints, not gated: $hints)"
