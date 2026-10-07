include $(TOPDIR)/rules.mk

PKG_NAME:=mayhem
PKG_VERSION:=$(if $(MAYHEM_VERSION),$(MAYHEM_VERSION),0.1.0)
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Ivan <antonov.vnch@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/mayhem
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Xray-based traffic routing
  URL:=https://github.com/$(if $(MAYHEM_REPO),$(MAYHEM_REPO),OWNER/project-mayhem)
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +kmod-nft-tproxy +ca-bundle +unzip +curl
  PKGARCH:=all
endef

define Package/mayhem/description
  Routes LAN traffic through Xray by sections and lists. xray itself is
  downloaded from the official XTLS releases with `mayhem xray-install`.
endef

define Package/mayhem/conffiles
/etc/config/mayhem
endef

define Build/Compile
endef

define Package/mayhem/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/usr/bin $(1)/usr/libexec/mayhem
	$(INSTALL_DIR) $(1)/usr/share/mayhem $(1)/usr/share/ucode/mayhem $(1)/lib/upgrade/keep.d
	$(INSTALL_CONF) ./files/etc/config/mayhem $(1)/etc/config/mayhem
	$(INSTALL_BIN) ./files/etc/init.d/mayhem $(1)/etc/init.d/mayhem
	$(INSTALL_BIN) ./files/usr/bin/mayhem $(1)/usr/bin/mayhem
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-mayhem $(1)/etc/uci-defaults/90-mayhem
	$(INSTALL_BIN) ./files/usr/libexec/mayhem/xray-run $(1)/usr/libexec/mayhem/xray-run
	$(INSTALL_BIN) ./files/usr/libexec/mayhem/scheduler $(1)/usr/libexec/mayhem/scheduler
	$(INSTALL_DATA) ./files/usr/share/mayhem/*.sh $(1)/usr/share/mayhem/
	$(INSTALL_DATA) ./files/usr/share/mayhem/*.uc $(1)/usr/share/mayhem/
	$(INSTALL_DATA) ./files/usr/share/ucode/mayhem/*.uc $(1)/usr/share/ucode/mayhem/
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/mayhem $(1)/lib/upgrade/keep.d/mayhem
	$(SED) 's/__MAYHEM_VERSION__/$(PKG_VERSION)/' $(1)/usr/share/mayhem/const.sh
endef

define Package/mayhem/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/mayhem stop >/dev/null 2>&1
/etc/init.d/mayhem disable >/dev/null 2>&1
exit 0
endef

define Package/mayhem/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /usr/libexec/mayhem/xray
rm -rf /var/run/mayhem
exit 0
endef

$(eval $(call BuildPackage,mayhem))
