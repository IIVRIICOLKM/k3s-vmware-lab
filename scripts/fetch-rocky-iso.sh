#!/usr/bin/env bash
# Downloads Rocky Linux 9.8 DVD media and verifies the signed upstream CHECKSUM plus the pinned size and SHA-256.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
umask 077

CHECKSUM_BASE_URL="https://download.rockylinux.org/pub/rocky/9/isos/x86_64"
# The Korean Rocky mirror is substantially faster from this host. Trust still comes from the official signed CHECKSUM;
# override only the byte source with ROCKY_DOWNLOAD_BASE_URL when another mirror is preferable.
DOWNLOAD_BASE_URL="${ROCKY_DOWNLOAD_BASE_URL:-https://mirror3.krfoss.org/rocky/9/isos/x86_64}"
KEY_URL="https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9"
ISO="$LAB_ISO_DIR/$PIN_ROCKY_ISO_FILENAME"
PART="$ISO.part"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$LAB_ISO_DIR"

log "fetch Rocky signing key and signed CHECKSUM"
curl --fail --location --silent --show-error "$KEY_URL" -o "$TMP/rocky.key"
curl --fail --location --silent --show-error "$CHECKSUM_BASE_URL/CHECKSUM" -o "$TMP/CHECKSUM"
curl --fail --location --silent --show-error "$CHECKSUM_BASE_URL/CHECKSUM.asc" -o "$TMP/CHECKSUM.asc"

fingerprint=$(gpg --show-keys --with-colons "$TMP/rocky.key" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
[[ "$fingerprint" == "$PIN_ROCKY_GPG_FINGERPRINT" ]] || die "Rocky signing key fingerprint is $fingerprint, expected $PIN_ROCKY_GPG_FINGERPRINT"
gpg --batch --quiet --no-default-keyring --keyring "$TMP/rocky.gpg" --import "$TMP/rocky.key"
gpgv --keyring "$TMP/rocky.gpg" "$TMP/CHECKSUM.asc" "$TMP/CHECKSUM"

signed_sha=$(sed -n "s/^SHA256 ($PIN_ROCKY_ISO_FILENAME) = //p" "$TMP/CHECKSUM")
[[ "$signed_sha" == "$PIN_ROCKY_ISO_SHA256" ]] || die "signed upstream SHA-256 is '$signed_sha', expected $PIN_ROCKY_ISO_SHA256"

if [[ -f "$ISO" && "$(stat -c %s "$ISO")" == "$PIN_ROCKY_ISO_SIZE" && "$(sha256sum "$ISO" | cut -d' ' -f1)" == "$PIN_ROCKY_ISO_SHA256" ]]; then
  chmod 0644 "$ISO"
  log "already verified: $ISO"
  exit 0
fi

log "download $PIN_ROCKY_ISO_FILENAME (${PIN_ROCKY_ISO_SIZE} bytes; resumable)"
curl --fail --location --continue-at - --output "$PART" "$DOWNLOAD_BASE_URL/$PIN_ROCKY_ISO_FILENAME"
[[ "$(stat -c %s "$PART")" == "$PIN_ROCKY_ISO_SIZE" ]] || die "$PART has the wrong size"
[[ "$(sha256sum "$PART" | cut -d' ' -f1)" == "$PIN_ROCKY_ISO_SHA256" ]] || die "$PART failed SHA-256 verification"
mv "$PART" "$ISO"
chmod 0644 "$ISO"
cp "$TMP/CHECKSUM" "$LAB_ISO_DIR/Rocky-9.8-CHECKSUM"
cp "$TMP/CHECKSUM.asc" "$LAB_ISO_DIR/Rocky-9.8-CHECKSUM.asc"
chmod 0644 "$LAB_ISO_DIR/Rocky-9.8-CHECKSUM" "$LAB_ISO_DIR/Rocky-9.8-CHECKSUM.asc"
log "verified ISO ready: $ISO"
