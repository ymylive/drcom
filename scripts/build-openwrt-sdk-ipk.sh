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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PKG_NAME="${OUTPUT_PKG_NAME:-drcom_openwrt}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1773321366}"

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

PKG_VERSION="$(read_pkg_value PKG_VERSION)"
PKG_RELEASE="$(read_pkg_value PKG_RELEASE)"
PKG_FULL_VERSION="${PKG_VERSION}-${PKG_RELEASE}"

if [[ -z "$PKG_VERSION" || -z "$PKG_RELEASE" ]]; then
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
STAGE_DIR="$BUILD_DIR/stage"
CONTROL_DIR="$BUILD_DIR/control"

rm -rf "$BUILD_DIR"
mkdir -p "$SRC_BUILD_DIR" "$STAGE_DIR" "$CONTROL_DIR"
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
  "$STAGE_DIR/usr/bin" \
  "$STAGE_DIR/etc" \
  "$STAGE_DIR/etc/init.d" \
  "$STAGE_DIR/usr/lib/lua/luci/controller" \
  "$STAGE_DIR/usr/lib/lua/luci/view/$OUTPUT_PKG_NAME"

cp "$SRC_BUILD_DIR/drcom" "$STAGE_DIR/usr/bin/$OUTPUT_PKG_NAME"
cp "$PACKAGE_ROOT/files/etc/drcom.conf" "$STAGE_DIR/etc/drcom.conf"
cp "$PACKAGE_ROOT/files/etc/init.d/drcom" "$STAGE_DIR/etc/init.d/$OUTPUT_PKG_NAME"
cp "$PACKAGE_ROOT/files/usr/lib/lua/luci/controller/drcom.lua" "$STAGE_DIR/usr/lib/lua/luci/controller/$OUTPUT_PKG_NAME.lua"
cp "$PACKAGE_ROOT/files/usr/lib/lua/luci/view/drcom/form.htm" "$STAGE_DIR/usr/lib/lua/luci/view/$OUTPUT_PKG_NAME/form.htm"

sed -i 's/\r$//' \
  "$STAGE_DIR/etc/drcom.conf" \
  "$STAGE_DIR/etc/init.d/$OUTPUT_PKG_NAME" \
  "$STAGE_DIR/usr/lib/lua/luci/controller/$OUTPUT_PKG_NAME.lua" \
  "$STAGE_DIR/usr/lib/lua/luci/view/$OUTPUT_PKG_NAME/form.htm"

python3 - "$STAGE_DIR/etc/init.d/$OUTPUT_PKG_NAME" "$STAGE_DIR/usr/lib/lua/luci/controller/$OUTPUT_PKG_NAME.lua" "$OUTPUT_PKG_NAME" <<'PY'
from pathlib import Path
import sys

init_path = Path(sys.argv[1])
controller_path = Path(sys.argv[2])
package_name = sys.argv[3]

replacements = (
    ("/etc/" + package_name + ".conf", "/etc/drcom.conf"),
    ("/tmp/" + package_name + ".log", "/tmp/drcom.log"),
    ("/tmp/" + package_name + "-port-state", "/tmp/drcom-port-state"),
)

for path in (init_path, controller_path):
    text = path.read_text(encoding="utf-8").replace("drcom", package_name)
    for old, new in replacements:
        text = text.replace(old, new)
    path.write_text(text, encoding="utf-8", newline="\n")
PY

python3 - "$STAGE_DIR/usr/lib/lua/luci/view/$OUTPUT_PKG_NAME/form.htm" "$OUTPUT_PKG_NAME" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
package_name = sys.argv[2]
text = path.read_text(encoding="utf-8").replace("jludrcom.language", f"{package_name}.language")
path.write_text(text, encoding="utf-8", newline="\n")
PY

chmod 0755 "$STAGE_DIR/usr/bin/$OUTPUT_PKG_NAME" "$STAGE_DIR/etc/init.d/$OUTPUT_PKG_NAME"

INSTALLED_SIZE="$(( $(du -sk "$STAGE_DIR" | awk '{print $1}') * 1024 ))"

cat > "$CONTROL_DIR/control" <<EOF
Package: $OUTPUT_PKG_NAME
Version: $PKG_FULL_VERSION
Depends: libc, luci-base
Source: feeds/base/$OUTPUT_PKG_NAME
SourceName: $OUTPUT_PKG_NAME
License: AGPL-3.0-or-later
Section: net
SourceDateEpoch: $SOURCE_DATE_EPOCH
Maintainer: $OUTPUT_PKG_NAME maintainers
Architecture: $SDK_PKGARCH
Installed-Size: $INSTALLED_SIZE
Description: DrCOM client (dogcom C implementation) with the enhanced LuCI dashboard and compatibility package layout.
EOF

cat > "$CONTROL_DIR/conffiles" <<'EOF'
/etc/drcom.conf
EOF

cat > "$CONTROL_DIR/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF

cat > "$CONTROL_DIR/postinst-pkg" <<EOF
#!/bin/sh
[ -n "\$IPKG_INSTROOT" ] || {
  /etc/init.d/$OUTPUT_PKG_NAME enable >/dev/null 2>&1 || true
  /etc/init.d/$OUTPUT_PKG_NAME restart >/dev/null 2>&1 || true
  [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
}
exit 0
EOF

cat > "$CONTROL_DIR/prerm" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF

cat > "$CONTROL_DIR/prerm-pkg" <<EOF
#!/bin/sh
[ -n "\$IPKG_INSTROOT" ] || {
  /etc/init.d/$OUTPUT_PKG_NAME stop >/dev/null 2>&1 || true
}
exit 0
EOF

chmod 0755 \
  "$CONTROL_DIR/postinst" \
  "$CONTROL_DIR/postinst-pkg" \
  "$CONTROL_DIR/prerm" \
  "$CONTROL_DIR/prerm-pkg"

OUTPUT_IPK="$OUTPUT_DIR/${OUTPUT_PKG_NAME}_${PKG_FULL_VERSION}_${SDK_PKGARCH}.ipk"
rm -f "$OUTPUT_IPK" "${OUTPUT_IPK}.sha256"
python3 "$SCRIPT_DIR/build-legacy-ipk.py" \
  --stage-dir "$STAGE_DIR" \
  --control-dir "$CONTROL_DIR" \
  --output "$OUTPUT_IPK" \
  --source-date-epoch "$SOURCE_DATE_EPOCH" >/dev/null

echo "$OUTPUT_IPK"
