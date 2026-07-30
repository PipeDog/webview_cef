#!/usr/bin/env bash
#
# Download CEF "Standard Distribution" tarballs into ~/.cef/tar/ for offline
# builds across all platforms.
#
# By default pod install / CMake downloads CEF from Spotify CDN, which can be
# very slow on some networks. Pre-downloading the tarballs with this script and
# placing them in ~/.cef/tar/ lets the build scripts skip the CDN step entirely.
#
# Usage:
#   bash cef_tar/download_cef_tars.sh                        # default macOS (arm64 + x86_64)
#   bash cef_tar/download_cef_tars.sh --platform windows      # Windows x64
#   bash cef_tar/download_cef_tars.sh --platform linux         # Linux x64
#   bash cef_tar/download_cef_tars.sh --platform linux-arm64   # Linux arm64
#
# Override the cache directory via CEF_TAR_CACHE_DIR (optional):
#   CEF_TAR_CACHE_DIR=/tmp/cef-cache bash cef_tar/download_cef_tars.sh
#
# The CEF version is read from third/download.cmake (single source of truth).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOWNLOAD_CMAKE="${REPO_ROOT}/third/download.cmake"
[ -f "${DOWNLOAD_CMAKE}" ] || { echo "error: cannot find ${DOWNLOAD_CMAKE}" >&2; exit 1; }

CEF_VERSION="$(sed -n 's/^[[:space:]]*set(CEF_VERSION[[:space:]]*"\(.*\)").*/\1/p' "${DOWNLOAD_CMAKE}" | head -1)"
[ -n "${CEF_VERSION}" ] || { echo "error: could not parse CEF_VERSION from ${DOWNLOAD_CMAKE}" >&2; exit 1; }

# --- parse --platform argument --------------------------------------------------
PLATFORM="macos"
while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      if [ $# -lt 2 ]; then
        echo "error: --platform requires a value (macos|windows|linux|linux-arm64)" >&2
        exit 1
      fi
      PLATFORM="$2"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      echo "usage: $0 [--platform macos|windows|linux|linux-arm64]" >&2
      exit 1
      ;;
  esac
done

# --- resolve target architectures ------------------------------------------------
case "${PLATFORM}" in
  macos)
    ARCHES=("arm64:macosarm64" "x86_64:macosx64")
    ;;
  windows)
    ARCHES=("x86_64:windows64")
    ;;
  linux)
    ARCHES=("x86_64:linux64")
    ;;
  linux-arm64)
    ARCHES=("aarch64:linuxarm64")
    ;;
  *)
    echo "error: unsupported platform: ${PLATFORM}" >&2
    echo "supported: macos | windows | linux | linux-arm64" >&2
    exit 1
    ;;
esac

# --- resolve cache directory ----------------------------------------------------
CACHE_DIR="${CEF_TAR_CACHE_DIR:-${HOME}/.cef/tar}"
mkdir -p "${CACHE_DIR}"

CDN="https://cef-builds.spotifycdn.com"

echo "CEF version: ${CEF_VERSION}"
echo "Platform:    ${PLATFORM}"
echo "Cache dir:   ${CACHE_DIR}"
echo ""

for entry in "${ARCHES[@]}"; do
  arch="${entry%%:*}"
  cef_arch="${entry##*:}"
  pkg="cef_binary_${CEF_VERSION}_${cef_arch}"
  tarball="${CACHE_DIR}/${pkg}.tar.bz2"
  url="${CDN}/$(printf '%s' "${pkg}.tar.bz2" | sed 's/+/%2B/g')"

  if [ -f "${tarball}" ]; then
    echo "==> ${pkg}.tar.bz2 already exists, skipping."
    continue
  fi

  echo "==> Downloading ${pkg}.tar.bz2 (${arch})..."

  # Write directly to the target file with -C - (resume support).  If the
  # download is interrupted the partial file stays on disk so the next run
  # can resume rather than restart 300 MB from scratch.  This is consistent
  # with macos/scripts/download_cef.sh.
  curl -L --fail --connect-timeout 30 --max-time 3600 \
       --retry 3 --retry-delay 5 \
       -C - -o "${tarball}" "${url}"

  echo "    Done."
done

echo ""
echo "All tarballs ready. Build scripts will automatically detect them in ${CACHE_DIR}."
