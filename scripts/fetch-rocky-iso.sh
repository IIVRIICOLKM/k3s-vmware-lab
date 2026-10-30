#!/usr/bin/env bash
# Downloads Rocky Linux 9.8 DVD media and verifies the signed upstream CHECKSUM plus the pinned size and SHA-256.
#
# [한국어 설명] Rocky Linux 9.8 DVD ISO를 내려받고 3단계로 검증한다.
#   ① Rocky 공식 서명 키의 지문(fingerprint)이 고정값 PIN_ROCKY_GPG_FINGERPRINT와 같은지
#   ② 공식 CHECKSUM 파일이 그 키로 서명됐는지 (gpgv)
#   ③ 서명된 CHECKSUM 속 SHA-256, 그리고 받은 파일의 실제 크기·SHA-256이 고정값과 같은지
#   [언제]   entry.sh 2단계
#   [결과]   ~/.local/share/k3s-vmware-lab/iso-cache/Rocky-9.8-x86_64-dvd.iso
#   [재실행] 이미 검증된 ISO가 있으면 다운로드 생략. 끊긴 다운로드(.part)는 이어받는다.

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"
# umask 077 : 이 스크립트가 새로 만드는 파일은 기본적으로 소유자만 읽고 쓸 수 있게 함
umask 077

# --- 1) 주소·경로 설정 ---
# 신뢰의 기준(서명 키·CHECKSUM·서명)은 항상 공식 서버에서 받고, 용량이 큰 ISO만 빠른 국내 미러에서 받는다.
CHECKSUM_BASE_URL="https://download.rockylinux.org/pub/rocky/9/isos/x86_64"
# The Korean Rocky mirror is substantially faster from this host. Trust still comes from the official signed CHECKSUM;
# override only the byte source with ROCKY_DOWNLOAD_BASE_URL when another mirror is preferable.
DOWNLOAD_BASE_URL="${ROCKY_DOWNLOAD_BASE_URL:-https://mirror3.krfoss.org/rocky/9/isos/x86_64}"
KEY_URL="https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9"
ISO="$LAB_ISO_DIR/$PIN_ROCKY_ISO_FILENAME"
# PART : 다운로드 중인 임시 파일. 검증을 모두 통과해야 최종 이름(ISO)으로 바뀐다.
# TMP  : 키·CHECKSUM을 받을 임시 폴더. trap ... EXIT 로 스크립트가 어떻게 끝나든 삭제한다.
PART="$ISO.part"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$LAB_ISO_DIR"

# --- 2) 서명 키, CHECKSUM, CHECKSUM 서명(.asc) 다운로드 ---
# curl --fail : 404 같은 HTTP 에러면 실패 처리 / --location : 리다이렉트를 따라감 / -o : 파일로 저장
log "fetch Rocky signing key and signed CHECKSUM"
curl --fail --location --silent --show-error "$KEY_URL" -o "$TMP/rocky.key"
curl --fail --location --silent --show-error "$CHECKSUM_BASE_URL/CHECKSUM" -o "$TMP/CHECKSUM"
curl --fail --location --silent --show-error "$CHECKSUM_BASE_URL/CHECKSUM.asc" -o "$TMP/CHECKSUM.asc"

# --- 3) 서명 검증 ---
# gpg --show-keys --with-colons : 키를 설치하지 않고 정보만 기계용 형식(콜론 구분)으로 출력
#   → "fpr"로 시작하는 줄의 10번째 칸이 지문. 고정값과 다르면 중단 (가짜 키 방지)
# 확인된 키만 넣은 임시 키링(rocky.gpg)을 만들고, gpgv로 CHECKSUM.asc가 CHECKSUM의 올바른 서명인지 검증
#   (서명이 틀리면 gpgv가 실패 → set -e로 즉시 종료)
fingerprint=$(gpg --show-keys --with-colons "$TMP/rocky.key" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
[[ "$fingerprint" == "$PIN_ROCKY_GPG_FINGERPRINT" ]] || die "Rocky signing key fingerprint is $fingerprint, expected $PIN_ROCKY_GPG_FINGERPRINT"
gpg --batch --quiet --no-default-keyring --keyring "$TMP/rocky.gpg" --import "$TMP/rocky.key"
gpgv --keyring "$TMP/rocky.gpg" "$TMP/CHECKSUM.asc" "$TMP/CHECKSUM"

# --- 4) 서명된 CHECKSUM에서 ISO 해시를 꺼내 고정값과 비교 ---
# sed : "SHA256 (Rocky-9.8-x86_64-dvd.iso) = 해시" 줄에서 앞부분을 지우고 해시만 출력
signed_sha=$(sed -n "s/^SHA256 ($PIN_ROCKY_ISO_FILENAME) = //p" "$TMP/CHECKSUM")
[[ "$signed_sha" == "$PIN_ROCKY_ISO_SHA256" ]] || die "signed upstream SHA-256 is '$signed_sha', expected $PIN_ROCKY_ISO_SHA256"

# --- 5) 이미 받아 둔 ISO의 크기·해시가 맞으면 여기서 끝 (재실행 시 빠른 경로) ---
if [[ -f "$ISO" && "$(stat -c %s "$ISO")" == "$PIN_ROCKY_ISO_SIZE" && "$(sha256sum "$ISO" | cut -d' ' -f1)" == "$PIN_ROCKY_ISO_SHA256" ]]; then
  chmod 0644 "$ISO"
  log "already verified: $ISO"
  exit 0
fi

# --- 6) 다운로드 → 크기·해시 검증 → 최종 이름으로 변경 ---
# --continue-at - : 이미 받은 .part 파일 크기를 보고 끊긴 지점부터 이어받기
log "download $PIN_ROCKY_ISO_FILENAME (${PIN_ROCKY_ISO_SIZE} bytes; resumable)"
curl --fail --location --continue-at - --output "$PART" "$DOWNLOAD_BASE_URL/$PIN_ROCKY_ISO_FILENAME"
[[ "$(stat -c %s "$PART")" == "$PIN_ROCKY_ISO_SIZE" ]] || die "$PART has the wrong size"
[[ "$(sha256sum "$PART" | cut -d' ' -f1)" == "$PIN_ROCKY_ISO_SHA256" ]] || die "$PART failed SHA-256 verification"
mv "$PART" "$ISO"
chmod 0644 "$ISO"
# 나중에 다시 검증할 수 있도록 CHECKSUM과 서명 파일도 ISO 옆에 보관
cp "$TMP/CHECKSUM" "$LAB_ISO_DIR/Rocky-9.8-CHECKSUM"
cp "$TMP/CHECKSUM.asc" "$LAB_ISO_DIR/Rocky-9.8-CHECKSUM.asc"
chmod 0644 "$LAB_ISO_DIR/Rocky-9.8-CHECKSUM" "$LAB_ISO_DIR/Rocky-9.8-CHECKSUM.asc"
log "verified ISO ready: $ISO"
