include $(TOPDIR)/rules.mk

PKG_NAME:=jludrcom
PKG_VERSION:=1.0.0
PKG_RELEASE:=12

PKG_MAINTAINER:=ymylive
PKG_LICENSE:=AGPL-3.0-or-later
PKG_LICENSE_FILES:=src/LICENSE
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/jludrcom
  SECTION:=net
  CATEGORY:=Network
  TITLE:=JLU DrCOM client with LuCI dashboard
  URL:=https://github.com/ymylive/drcom
  DEPENDS:=+luci-base
endef

define Package/jludrcom/description
 A DrCOM client package for JLU routers, based on the dogcom C implementation,
 bundled with a LuCI control panel, live logs, config validation, and automatic
 UDP 61440 port recovery.
endef

define Package/jludrcom/conffiles
/etc/drcom.conf
endef

define Package/jludrcom/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
if [ -x /etc/init.d/uhttpd ]; then
  /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
fi
if [ -x /etc/init.d/jludrcom ] && [ -x /usr/bin/jludrcom ]; then
  /etc/init.d/jludrcom enable >/dev/null 2>&1 || true
fi
exit 0
endef

define Package/jludrcom/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
if [ -x /etc/init.d/jludrcom ]; then
  /etc/init.d/jludrcom stop >/dev/null 2>&1 || true
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
		TARGET="jludrcom"
endef

define Package/jludrcom/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/jludrcom $(1)/usr/bin/jludrcom
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_CONF) ./files/etc/drcom.conf $(1)/etc/drcom.conf
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/jludrcom $(1)/etc/init.d/jludrcom
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/jludrcom.lua $(1)/usr/lib/lua/luci/controller/jludrcom.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/jludrcom
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/jludrcom/form.htm $(1)/usr/lib/lua/luci/view/jludrcom/form.htm
endef

$(eval $(call BuildPackage,jludrcom))
