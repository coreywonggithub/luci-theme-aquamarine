#!/bin/bash
# Build the OpenWrt 24.10 package (.ipk) of Aquamarine from the files of its 25.12 package (.apk), with
# the 24.10 SDK's own ipkg-build and fakeroot, and the control data and scripts that the SDK's
# include/package-pack.mk writes (control, the postinst and prerm wrappers, LuCI's postinst-pkg, our postrm).
#
#   tools/make-ipk.sh <luci-theme-aquamarine-VERSION.apk> <24.10 SDK dir> <apk tool> <output dir>
#
# Why not "make package/luci-theme-aquamarine/compile" in the 24.10 SDK: it first compiles luci-base's
# target dependencies (ucode-mod-html, rpcd-mod-luci, lucihttp), which need OpenWrt's base sources that the
# SDK does not carry (tried 2026-10-08, also with IGNORE_ERRORS=1). The theme has nothing compiled: its CSS
# and JS are minified by LuCI's csstidy and jsmin, the same tools in both releases, and its files are the
# same on 24.10 and 25.12.
set -euo pipefail
[ $# -eq 4 ] || { sed -n '2,13p' "$0"; exit 2; }
APK_FILE="$(readlink -f "$1")"
SDK="$(readlink -f "$2")"
APK_TOOL="$3"
OUT="$(readlink -f "$4")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAME=luci-theme-aquamarine

mk() { sed -n "s/^$1:=//p" "$REPO/Makefile" | head -n 1; }
VERSION="$(mk PKG_VERSION)-r$(mk PKG_RELEASE)"
case "$(basename "$APK_FILE")" in
"$NAME-$VERSION.apk") ;;
*) echo "expected $NAME-$VERSION.apk (the Makefile's version), got $(basename "$APK_FILE")" >&2; exit 1 ;;
esac

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pkg" "$OUT"
"$APK_TOOL" extract --allow-untrusted --destination "$T/pkg" "$APK_FILE" >/dev/null
rm -rf "$T/pkg/lib/apk"     # apk's own record of the package, not one of its files

C="$T/pkg/CONTROL"
mkdir -p "$C"
# the fields package-pack.mk writes, in its order (values as the SDK's metadata had them, 2026-10-08)
{
	echo "Package: $NAME"
	echo "Version: $VERSION"
	echo "Depends: libc, luci-base"
	echo "Source: feeds/aquamarine/$NAME"
	echo "SourceName: $NAME"
	echo "License: $(mk PKG_LICENSE)"
	echo "LicenseFiles: $(mk PKG_LICENSE_FILES)"
	echo "Section: luci"
	echo "SourceDateEpoch: $(git -C "$REPO" log -1 --format=%ct)"
	echo "URL: $(mk LUCI_URL)"
	echo "Maintainer: $(mk PKG_MAINTAINER)"
	echo "Architecture: all"
	echo "Installed-Size: 0"
	echo "Description:  $(mk LUCI_TITLE)"
} >"$C/control"
cat >"$C/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF
cat >"$C/prerm" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF
# LuCI's own postinst (luci.mk, Package/$(PKG_NAME)/postinst), run by default_postinst
cat >"$C/postinst-pkg" <<'EOF'
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
EOF
# our postrm, from the Makefile's define block ($$ is make's way of writing $)
sed -n "/^define Package\/$NAME\/postrm/,/^endef/p" "$REPO/Makefile" | sed '1d;$d' | sed 's/\$\$/$/g' >"$C/postrm"
grep -q 'luci.themes.Aquamarine' "$C/postrm" || { echo "could not read the postrm from the Makefile" >&2; exit 1; }
chmod 0755 "$C/postinst" "$C/prerm" "$C/postrm"
chmod 0644 "$C/control" "$C/postinst-pkg"

export PKG_SOURCE_DATE_EPOCH="$(git -C "$REPO" log -1 --format=%ct)"
H="$SDK/staging_dir/host"
"$H/bin/fakeroot" -l "$H/lib/libfakeroot.so" -f "$H/bin/faked" -- sh -c "chown -R 0:0 '$T/pkg' && PATH='$H/bin':\$PATH TOPDIR='$SDK' bash '$SDK/scripts/ipkg-build' '$T/pkg' '$OUT'"
# the SDK's tools first on PATH, as OpenWrt's makefiles do: the build box's own tar reads owners past this
# fakeroot and recorded uid 1000 for every file (2026-10-08)
ls -l "$OUT/${NAME}_${VERSION}_all.ipk"
