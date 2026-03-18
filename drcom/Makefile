include $(TOPDIR)/rules.mk

PKG_NAME:=drcom
PKG_VERSION:=1.0.0
PKG_RELEASE:=13

PKG_MAINTAINER:=ymylive
PKG_LICENSE:=AGPL-3.0-or-later
PKG_LICENSE_FILES:=src/LICENSE
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/drcom
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OpenWrt DrCOM client service with LuCI dashboard
  URL:=https://github.com/ymylive/drcom
  DEPENDS:=+luci-base
endef

define Package/drcom/description
 A general-purpose DrCOM client service for OpenWrt routers, based on the
 dogcom C implementation, bundled with a LuCI control panel, live logs,
 config validation, and automatic UDP 61440 port recovery.
endef

define Package/drcom/conffiles
/etc/drcom.conf
endef

define Package/drcom/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
if [ -x /etc/init.d/uhttpd ]; then
  /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
fi
if [ -x /etc/init.d/drcom ] && [ -x /usr/bin/drcom ]; then
  /etc/init.d/drcom enable >/dev/null 2>&1 || true
fi
exit 0
endef

define Package/drcom/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
if [ -x /etc/init.d/drcom ]; then
  /etc/init.d/drcom stop >/dev/null 2>&1 || true
fi
exit 0
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
endef

define Build/Compile
	+$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CPPFLAGS="$(TARGET_CPPFLAGS) -I$(PKG_BUILD_DIR)" \
		CFLAGS="$(TARGET_CFLAGS) -Wno-unused-result" \
		LDFLAGS="$(TARGET_LDFLAGS)" \
		TARGET="drcom"
endef

define Package/drcom/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/drcom $(1)/usr/bin/drcom
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_CONF) ./files/etc/drcom.conf $(1)/etc/drcom.conf
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/drcom $(1)/etc/init.d/drcom
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/drcom.lua $(1)/usr/lib/lua/luci/controller/drcom.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/drcom
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/drcom/form.htm $(1)/usr/lib/lua/luci/view/drcom/form.htm
endef

$(eval $(call BuildPackage,drcom))
