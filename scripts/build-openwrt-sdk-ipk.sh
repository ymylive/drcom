#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT=""
OPENWRT_RELEASE=""
TARGET=""
SUBTARGET=""
PKGARCH_HINT=""
SDK_ROOT=""
OUTPUT_DIR=""
WORK_ROOT=""

curl_retry() {
  curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry 5 \
    --retry-delay 3 \
    --retry-all-errors \
    "$@"
}

normalize_pkgarch() {
  local value
  value="$(printf '%s' "$1" | tr '+' '_')"
  case "$value" in
    mips64_*_64|mips64el_*_64)
      value="${value%_64}"
      ;;
  esac
  printf '%s' "$value"
}

usage() {
  cat <<'EOF'
Usage:
  build-openwrt-sdk-ipk.sh \
    --package-root <path> \
    --release <release> \
    --target <target> \
    --subtarget <subtarget> \
    --output-dir <path> \
    [--pkgarch <pkgarch>] \
    [--sdk-root <path>] \
    [--work-root <path>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-root) PACKAGE_ROOT="$2"; shift 2 ;;
    --release) OPENWRT_RELEASE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --subtarget) SUBTARGET="$2"; shift 2 ;;
    --pkgarch) PKGARCH_HINT="$2"; shift 2 ;;
    --sdk-root) SDK_ROOT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --work-root) WORK_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$PACKAGE_ROOT" || -z "$OPENWRT_RELEASE" || -z "$TARGET" || -z "$SUBTARGET" || -z "$OUTPUT_DIR" ]]; then
  usage
  exit 1
fi

PACKAGE_ROOT="$(cd "$PACKAGE_ROOT" && pwd)"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
WORK_ROOT="${WORK_ROOT:-$PACKAGE_ROOT/../.work}"
WORK_ROOT="$(mkdir -p "$WORK_ROOT" && cd "$WORK_ROOT" && pwd)"

resolve_sdk_root() {
  if [[ -n "$SDK_ROOT" ]]; then
    SDK_ROOT="$(cd "$SDK_ROOT" && pwd)"
    return 0
  fi

  local base_url sha256sums sdk_line sdk_sha256 sdk_file sdk_url
  base_url="https://downloads.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${TARGET}/${SUBTARGET}/"
  sha256sums="$(curl_retry "${base_url}sha256sums")"
  sdk_line="$(printf '%s\n' "$sha256sums" | grep -E "openwrt-sdk-${OPENWRT_RELEASE}-${TARGET}-${SUBTARGET}_.+\\.Linux-x86_64\\.tar\\.(zst|xz|gz)$" | head -n 1 || true)"
  if [[ -z "$sdk_line" ]]; then
    echo "Failed to discover SDK archive for ${TARGET}/${SUBTARGET} on OpenWrt ${OPENWRT_RELEASE}" >&2
    exit 1
  fi
  sdk_sha256="${sdk_line%% *}"
  sdk_file="${sdk_line##* }"
  sdk_file="${sdk_file#\*}"
  sdk_url="${base_url}${sdk_file}"

  local cache_dir archive_name archive_path extract_dir detected_root
  cache_dir="$WORK_ROOT/sdk-cache"
  mkdir -p "$cache_dir"
  archive_name="$(basename "$sdk_url")"
  archive_path="$cache_dir/$archive_name"

  if [[ ! -f "$archive_path" ]]; then
    curl_retry "$sdk_url" --output "$archive_path"
  fi

  echo "${sdk_sha256}  ${archive_path}" | sha256sum --check --status

  extract_dir="$WORK_ROOT/sdk-${TARGET}-${SUBTARGET}"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  case "$archive_name" in
    *.tar.zst) tar --zstd -xf "$archive_path" -C "$extract_dir" ;;
    *.tar.xz) tar -xJf "$archive_path" -C "$extract_dir" ;;
    *.tar.gz) tar -xzf "$archive_path" -C "$extract_dir" ;;
    *) echo "Unsupported SDK archive: $archive_name" >&2; exit 1 ;;
  esac

  detected_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -name 'openwrt-sdk-*' | head -n 1)"
  if [[ -z "$detected_root" ]]; then
    echo "Failed to locate extracted SDK root." >&2
    exit 1
  fi
  SDK_ROOT="$detected_root"
}

read_pkg_value() {
  local key="$1"
  sed -n "s/^${key}:=//p" "$PACKAGE_ROOT/Makefile" | head -n 1
}

read_target_value() {
  local key="$1"
  local file value
  for file in \
    "$SDK_ROOT/target/linux/$TARGET/$SUBTARGET/target.mk" \
    "$SDK_ROOT/target/linux/$TARGET/Makefile"
  do
    [[ -f "$file" ]] || continue
    value="$(sed -n "s/^${key}:=//p" "$file" | head -n 1)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 1
}

resolve_target_flags() {
  local target_arch cpu_type
  target_arch="$(read_target_value ARCH || true)"
  cpu_type="$(read_target_value CPU_TYPE || true)"

  TARGET_CPPFLAGS="-I."
  TARGET_CFLAGS="-std=gnu99 -Wno-unused-result"
  TARGET_LDFLAGS=""

  case "${target_arch}:${cpu_type}" in
    mips64:mips64r2|mips64el:mips64r2)
      TARGET_CFLAGS="$TARGET_CFLAGS -mips64r2 -mtune=mips64r2 -mabi=64 -mno-branch-likely"
      TARGET_LDFLAGS="-mips64r2 -mabi=64 -mno-branch-likely"
      ;;
    mips64:octeonplus)
      TARGET_CFLAGS="$TARGET_CFLAGS -march=octeon+ -mabi=64 -mno-branch-likely"
      TARGET_LDFLAGS="-march=octeon+ -mabi=64 -mno-branch-likely"
      ;;
  esac
}

resolve_sdk_root

PKG_NAME="$(read_pkg_value PKG_NAME)"
PKG_VERSION="$(read_pkg_value PKG_VERSION)"
PKG_RELEASE="$(read_pkg_value PKG_RELEASE)"
PKG_FULL_VERSION="${PKG_VERSION}-${PKG_RELEASE}"

if [[ -z "$PKG_NAME" || -z "$PKG_VERSION" || -z "$PKG_RELEASE" ]]; then
  echo "Failed to parse package metadata from Makefile." >&2
  exit 1
fi

TOOLCHAIN_DIR="$(find "$SDK_ROOT/staging_dir" -mindepth 1 -maxdepth 1 -type d -name 'toolchain-*' | head -n 1)"
if [[ -z "$TOOLCHAIN_DIR" ]]; then
  echo "Failed to locate toolchain directory in SDK." >&2
  exit 1
fi

SDK_PKGARCH="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES=\"\([^\"]*\)\"/\1/p' "$SDK_ROOT/.config" 2>/dev/null | head -n 1 || true)"
if [[ -z "$SDK_PKGARCH" ]]; then
  SDK_PKGARCH="$(basename "$TOOLCHAIN_DIR")"
  SDK_PKGARCH="${SDK_PKGARCH#toolchain-}"
  SDK_PKGARCH="${SDK_PKGARCH%%_gcc-*}"
fi
if [[ -z "$SDK_PKGARCH" ]]; then
  echo "Failed to determine package architecture from SDK." >&2
  exit 1
fi

if [[ -n "$PKGARCH_HINT" ]]; then
  if [[ "$(normalize_pkgarch "$PKGARCH_HINT")" != "$(normalize_pkgarch "$SDK_PKGARCH")" ]]; then
    echo "pkgarch mismatch: expected $PKGARCH_HINT, got $SDK_PKGARCH" >&2
    exit 1
  fi
  SDK_PKGARCH="$PKGARCH_HINT"
else
  SDK_PKGARCH="$(normalize_pkgarch "$SDK_PKGARCH")"
fi

CC="$(find "$TOOLCHAIN_DIR/bin" -maxdepth 1 -type f -name '*-gcc' | head -n 1)"
if [[ -z "$CC" ]]; then
  echo "Failed to locate cross compiler in SDK." >&2
  exit 1
fi
STRIP="${CC%-gcc}-strip"
export STAGING_DIR="$TOOLCHAIN_DIR"
resolve_target_flags

BUILD_DIR="$WORK_ROOT/build-${TARGET}-${SUBTARGET}"
SRC_BUILD_DIR="$BUILD_DIR/src"
PKG_BUILD_DIR="$BUILD_DIR/pkg"

rm -rf "$BUILD_DIR"
mkdir -p "$SRC_BUILD_DIR" "$PKG_BUILD_DIR/CONTROL"
cp -a "$PACKAGE_ROOT/src/." "$SRC_BUILD_DIR/"

make -C "$SRC_BUILD_DIR" clean >/dev/null 2>&1 || true
make -C "$SRC_BUILD_DIR" \
  CC="$CC" \
  TARGET="drcom" \
  CPPFLAGS="$TARGET_CPPFLAGS" \
  CFLAGS="$TARGET_CFLAGS" \
  LDFLAGS="$TARGET_LDFLAGS" \
  >/dev/null

if [[ -x "$STRIP" ]]; then
  "$STRIP" "$SRC_BUILD_DIR/drcom" || true
fi

mkdir -p \
  "$PKG_BUILD_DIR/usr/bin" \
  "$PKG_BUILD_DIR/etc" \
  "$PKG_BUILD_DIR/etc/init.d" \
  "$PKG_BUILD_DIR/usr/lib/lua/luci/controller" \
  "$PKG_BUILD_DIR/usr/lib/lua/luci/view/drcom"

cp "$SRC_BUILD_DIR/drcom" "$PKG_BUILD_DIR/usr/bin/drcom"
cp "$PACKAGE_ROOT/files/etc/drcom.conf" "$PKG_BUILD_DIR/etc/drcom.conf"
cp "$PACKAGE_ROOT/files/etc/init.d/drcom" "$PKG_BUILD_DIR/etc/init.d/drcom"
cp "$PACKAGE_ROOT/files/usr/lib/lua/luci/controller/drcom.lua" "$PKG_BUILD_DIR/usr/lib/lua/luci/controller/drcom.lua"
cp "$PACKAGE_ROOT/files/usr/lib/lua/luci/view/drcom/form.htm" "$PKG_BUILD_DIR/usr/lib/lua/luci/view/drcom/form.htm"

sed -i 's/\r$//' \
  "$PKG_BUILD_DIR/etc/drcom.conf" \
  "$PKG_BUILD_DIR/etc/init.d/drcom" \
  "$PKG_BUILD_DIR/usr/lib/lua/luci/controller/drcom.lua" \
  "$PKG_BUILD_DIR/usr/lib/lua/luci/view/drcom/form.htm"

chmod 0755 "$PKG_BUILD_DIR/usr/bin/drcom" "$PKG_BUILD_DIR/etc/init.d/drcom"

INSTALLED_SIZE="$(( $(du -sk "$PKG_BUILD_DIR" | awk '{print $1}') * 1024 ))"

cat > "$PKG_BUILD_DIR/CONTROL/control" <<EOF
Package: $PKG_NAME
Version: $PKG_FULL_VERSION
Depends: luci-base
Section: net
Category: Network
Title: OpenWrt DrCOM client service with LuCI dashboard
Maintainer: ymylive
Architecture: $SDK_PKGARCH
Installed-Size: $INSTALLED_SIZE
Description: General-purpose DrCOM client service for OpenWrt routers with LuCI dashboard, live logs and automatic UDP 61440 port recovery.
EOF

cat > "$PKG_BUILD_DIR/CONTROL/conffiles" <<'EOF'
/etc/drcom.conf
EOF

cat > "$PKG_BUILD_DIR/CONTROL/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
if [ -x /etc/init.d/uhttpd ]; then
  /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
fi
if [ -x /etc/init.d/drcom ] && [ -x /usr/bin/drcom ]; then
  /etc/init.d/drcom enable >/dev/null 2>&1 || true
fi
exit 0
EOF

cat > "$PKG_BUILD_DIR/CONTROL/prerm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
if [ -x /etc/init.d/drcom ]; then
  /etc/init.d/drcom stop >/dev/null 2>&1 || true
fi
exit 0
EOF

chmod 0755 "$PKG_BUILD_DIR/CONTROL/postinst" "$PKG_BUILD_DIR/CONTROL/prerm"

"$SDK_ROOT/scripts/ipkg-build" "$PKG_BUILD_DIR" "$OUTPUT_DIR" >/dev/null

OUTPUT_IPK="$OUTPUT_DIR/${PKG_NAME}_${PKG_FULL_VERSION}_${SDK_PKGARCH}.ipk"
if [[ ! -f "$OUTPUT_IPK" ]]; then
  echo "Expected output package not found: $OUTPUT_IPK" >&2
  exit 1
fi

sha256sum "$OUTPUT_IPK" > "${OUTPUT_IPK}.sha256"
echo "$OUTPUT_IPK"
