include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mayhem
PKG_VERSION:=$(if $(MAYHEM_VERSION),$(MAYHEM_VERSION),0.1.0)
PKG_RELEASE:=1

LUCI_TITLE:=LuCI interface for Mayhem
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +mayhem
LUCI_PKGARCH:=all

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Ivan <antonov.vnch@gmail.com>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
