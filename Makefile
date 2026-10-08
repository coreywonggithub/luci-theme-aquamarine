# Aquamarine: a network-console theme for LuCI, light and dark, phone first.
# Derived from luci-theme-bootstrap (Apache-2.0); see NOTICE.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-theme-aquamarine
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=Aquamarine theme (network console look, light and dark)
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE NOTICE
PKG_MAINTAINER:=Corey Wong <coreymails@gmail.com>
# luci.mk writes these two into the package, not PKG_MAINTAINER or a URL of ours
LUCI_MAINTAINER:=$(PKG_MAINTAINER)
LUCI_URL:=https://github.com/coreywonggithub/luci-theme-aquamarine

# On removal, hand LuCI back to a theme that is still installed: an active
# theme whose files are gone leaves every page an error.
define Package/luci-theme-aquamarine/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	uci -q delete luci.themes.Aquamarine
	uci -q delete luci.themes.AquamarineDark
	uci -q delete luci.themes.AquamarineLight
	case "$$(uci -q get luci.main.mediaurlbase)" in
	/luci-static/aquamarine*)
		next="$$(uci -q show luci.themes | sed -n "s/^luci\.themes\.[^=]*='\(.*\)'$$/\1/p" | head -n 1)"
		uci set luci.main.mediaurlbase="$${next:-/luci-static/bootstrap}"
		;;
	esac
	uci commit luci
}
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
