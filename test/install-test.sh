#!/bin/bash
# Install, switch and remove luci-theme-aquamarine inside an OpenWrt x86-64 root
# filesystem, and check what each step leaves in /etc/config/luci. Unprivileged
# (user and mount namespaces) and offline; needs Linux on x86-64. The package is
# architecture-independent, so the x86-64 root filesystem stands in for any router.
#
#   test/install-test.sh <rootfs.tar.gz> <luci-theme-aquamarine.apk | .ipk>
#
# OpenWrt 25.12 uses apk, 24.10 opkg; the test uses whichever the root filesystem
# has. NOSCRIPTS=1 removes the package without its scripts, as a package with no
# removal script would: steps 4 and 5 must then fail (that is the negative test).
set -euo pipefail
[ $# -eq 2 ] || { sed -n '2,12p' "$0"; exit 2; }
ROOTFS="$(readlink -f "$1")"
PKG="$(readlink -f "$2")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

unshare -r tar -xzf "$ROOTFS" -C "$T" 2>/dev/null || true
[ -x "$T/bin/sh" ] || { echo "not an OpenWrt root filesystem: $ROOTFS" >&2; exit 2; }
cp "$PKG" "$T/tmp/pkg.${PKG##*.}"
cp "$REPO/root/etc/uci-defaults/30_luci-theme-aquamarine" "$T/tmp/first-boot-script"

cat >"$T/tmp/steps.sh" <<'EOF'
#!/bin/sh
fail=0
check() {
	if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fail=1; fi
}
active() { uci -q get luci.main.mediaurlbase; }
pkg=$(ls /tmp/pkg.*)
if command -v apk >/dev/null; then
	install() { apk add --allow-untrusted --no-network "$pkg" >/tmp/pm.log 2>&1; }
	remove() { apk del $NOSCRIPTS_FLAG luci-theme-aquamarine >/tmp/pm.log 2>&1; }
	[ "$NOSCRIPTS" = 1 ] && NOSCRIPTS_FLAG=--no-scripts
else
	install() { opkg install "$pkg" >/tmp/pm.log 2>&1; }
	remove() { opkg remove $NOSCRIPTS_FLAG luci-theme-aquamarine >/tmp/pm.log 2>&1; }
	[ "$NOSCRIPTS" = 1 ] && NOSCRIPTS_FLAG=--noaction-scripts
fi

# a fresh system's first boot: every first-boot script runs once
for f in /etc/uci-defaults/*; do
	[ -f "$f" ] || continue
	( . "$f" ) >/dev/null 2>&1 && rm -f "$f"
done
before=$(active)
echo "      before: active theme $before"

# 1. install on a running system
install || { echo "FAIL  1 install: $(tail -n 3 /tmp/pm.log)"; exit 1; }
check "1 install: Aquamarine registered" "$(uci -q get luci.themes.Aquamarine)" /luci-static/aquamarine
check "1 install: AquamarineDark registered" "$(uci -q get luci.themes.AquamarineDark)" /luci-static/aquamarine-dark
check "1 install: AquamarineLight registered" "$(uci -q get luci.themes.AquamarineLight)" /luci-static/aquamarine-light
check "1 install: it becomes the active theme" "$(active)" /luci-static/aquamarine
check "1 install: its first-boot script ran and was removed" "$(ls /etc/uci-defaults | grep -c aquamarine)" 0
for v in aquamarine aquamarine-dark aquamarine-light; do
	check "1 install: /www/luci-static/$v has the stylesheet" "$(ls /www/luci-static/$v/aquamarine.css 2>/dev/null)" "/www/luci-static/$v/aquamarine.css"
	check "1 install: template folder $v has a header" "$(ls /usr/share/ucode/luci/template/themes/$v/header.ut 2>/dev/null)" "/usr/share/ucode/luci/template/themes/$v/header.ut"
done

# 2. a firmware upgrade that keeps settings runs the first-boot script again, without PKG_UPGRADE
uci set luci.main.mediaurlbase="$before"; uci commit luci
( . /tmp/first-boot-script ) >/dev/null 2>&1
check "2 rerun: another theme chosen stays chosen" "$(active)" "$before"

# 3. an upgrade from a version without the variants adds them, and leaves the choice alone
uci -q delete luci.themes.AquamarineDark; uci commit luci
( PKG_UPGRADE=1; . /tmp/first-boot-script ) >/dev/null 2>&1
check "3 upgrade: a missing variant is added" "$(uci -q get luci.themes.AquamarineDark)" /luci-static/aquamarine-dark
check "3 upgrade: the choice stays" "$(active)" "$before"

# 4. removal while another theme is active
remove || { echo "FAIL  4 remove: $(tail -n 3 /tmp/pm.log)"; exit 1; }
check "4 remove: Aquamarine unregistered" "$(uci -q get luci.themes.Aquamarine)" ""
check "4 remove: variants unregistered" "$(uci -q get luci.themes.AquamarineDark)$(uci -q get luci.themes.AquamarineLight)" ""
check "4 remove: the active theme is untouched" "$(active)" "$before"
check "4 remove: no files left" "$(ls -d /www/luci-static/aquamarine* /usr/share/ucode/luci/template/themes/aquamarine* 2>/dev/null | wc -l)" 0

# 5. reinstall, pick the fixed-dark variant, remove: LuCI must fall back to a theme still installed
install || { echo "FAIL  5 reinstall: $(tail -n 3 /tmp/pm.log)"; exit 1; }
check "5 reinstall: active again" "$(active)" /luci-static/aquamarine
uci set luci.main.mediaurlbase=/luci-static/aquamarine-dark; uci commit luci
remove || { echo "FAIL  5 remove: $(tail -n 3 /tmp/pm.log)"; exit 1; }
now=$(active)
check "5 remove: falls back away from Aquamarine" "$(echo "$now" | grep -c aquamarine)" 0
check "5 remove: the fallback theme is installed" "$(ls -d "/www$now" 2>/dev/null)" "/www$now"
check "5 remove: the fallback theme is registered" "$(uci -q show luci.themes | grep -c "='$now'")" 1

[ $fail = 0 ] && echo "all steps passed" || echo "SOME STEPS FAILED"
exit $fail
EOF

unshare -rmpf bash -c '
	mount --rbind /dev "$1/dev" && mount -t proc proc "$1/proc" && mkdir -p "$1/var/lock" "$1/tmp/run" &&
	env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin NOSCRIPTS="${NOSCRIPTS:-0}" chroot "$1" /bin/sh /tmp/steps.sh
' _ "$T"
