PLUGIN_NAME=	os-vpnlink
PLUGIN_VERSION=	1.0.0

PREFIX?=	/usr/local
DESTDIR?=

SCRIPTS_DIR=	$(DESTDIR)$(PREFIX)/opnsense/scripts/OPNsense/Vpnlink
MVC_DIR=	$(DESTDIR)$(PREFIX)/opnsense/mvc/app
ACTIONS_DIR=	$(DESTDIR)$(PREFIX)/opnsense/service/conf/actions.d
PLUGINS_DIR=	$(DESTDIR)$(PREFIX)/etc/inc/plugins.inc.d

.PHONY: all install install-plugin activate uninstall

all:
	@echo ""
	@echo "os-vpnlink — VPN Traffic Orchestrator for OPNsense"
	@echo ""
	@echo "Targets:"
	@echo "  make install          Install plugin and activate"
	@echo "  make install-plugin   Install plugin files only"
	@echo "  make activate         Clear caches, restart services"
	@echo "  make uninstall        Remove all plugin files"
	@echo ""

install: install-plugin activate
	@echo ""
	@echo "=== Installation complete ==="
	@echo "Go to: VPN > VPN Link"
	@echo ""

install-plugin:
	@echo ">>> Installing plugin files..."
	# Plugin hooks
	@mkdir -p $(PLUGINS_DIR)
	@cp src/etc/inc/plugins.inc.d/vpnlink.inc $(PLUGINS_DIR)/

	# MVC controllers
	@mkdir -p $(MVC_DIR)/controllers/OPNsense/Vpnlink/Api
	@mkdir -p $(MVC_DIR)/controllers/OPNsense/Vpnlink/forms
	@cp src/opnsense/mvc/app/controllers/OPNsense/Vpnlink/*.php \
		$(MVC_DIR)/controllers/OPNsense/Vpnlink/
	@cp src/opnsense/mvc/app/controllers/OPNsense/Vpnlink/Api/*.php \
		$(MVC_DIR)/controllers/OPNsense/Vpnlink/Api/
	@cp src/opnsense/mvc/app/controllers/OPNsense/Vpnlink/forms/*.xml \
		$(MVC_DIR)/controllers/OPNsense/Vpnlink/forms/

	# MVC models
	@mkdir -p $(MVC_DIR)/models/OPNsense/Vpnlink/ACL
	@mkdir -p $(MVC_DIR)/models/OPNsense/Vpnlink/Menu
	@cp src/opnsense/mvc/app/models/OPNsense/Vpnlink/Vpnlink.php \
		$(MVC_DIR)/models/OPNsense/Vpnlink/
	@cp src/opnsense/mvc/app/models/OPNsense/Vpnlink/Vpnlink.xml \
		$(MVC_DIR)/models/OPNsense/Vpnlink/
	@cp src/opnsense/mvc/app/models/OPNsense/Vpnlink/ACL/ACL.xml \
		$(MVC_DIR)/models/OPNsense/Vpnlink/ACL/
	@cp src/opnsense/mvc/app/models/OPNsense/Vpnlink/Menu/Menu.xml \
		$(MVC_DIR)/models/OPNsense/Vpnlink/Menu/

	# MVC views
	@mkdir -p $(MVC_DIR)/views/OPNsense/Vpnlink
	@if ls src/opnsense/mvc/app/views/OPNsense/Vpnlink/*.volt 1>/dev/null 2>&1; then \
		cp src/opnsense/mvc/app/views/OPNsense/Vpnlink/*.volt \
			$(MVC_DIR)/views/OPNsense/Vpnlink/; \
	fi

	# Backend scripts
	@mkdir -p $(SCRIPTS_DIR)
	@cp src/opnsense/scripts/OPNsense/Vpnlink/*.py $(SCRIPTS_DIR)/
	@chmod +x $(SCRIPTS_DIR)/*.py

	# JavaScript assets (Chart.js)
	@mkdir -p $(DESTDIR)$(PREFIX)/opnsense/www/js/vpnlink
	@cp src/opnsense/www/js/vpnlink/*.js $(DESTDIR)$(PREFIX)/opnsense/www/js/vpnlink/

	# configd actions
	@mkdir -p $(ACTIONS_DIR)
	@cp src/opnsense/service/conf/actions.d/actions_vpnlink.conf $(ACTIONS_DIR)/

	# Data directory
	@mkdir -p /var/db/vpnlink

	# Cron job for traffic collection (every minute)
	@echo "*/1 * * * * root /usr/local/bin/configctl vpnlink collect_traffic" > /etc/cron.d/vpnlink
	@service cron restart 2>/dev/null || true

	@echo ">>> Plugin files installed."

activate:
	@echo ">>> Activating plugin..."
	# Flush menu cache
	@rm -f /var/lib/php/tmp/opnsense_menu_cache.xml 2>/dev/null || true
	@rm -f /tmp/opnsense_menu_cache.xml 2>/dev/null || true
	# Verify plugin hooks load without PHP errors
	@echo ">>> Checking plugin for PHP errors..."
	@php -l $(PLUGINS_DIR)/vpnlink.inc 2>&1 || true
	@php -l $(MVC_DIR)/models/OPNsense/Vpnlink/Vpnlink.php 2>&1 || true
	# Restart configd to pick up new actions
	@service configd restart 2>/dev/null || true
	# Restart web GUI
	@configctl webgui restart 2>/dev/null || service php_fpm restart 2>/dev/null || true
	# Reload firewall to pick up new rules from vpnlink_firewall()
	@configctl filter reload 2>/dev/null || true
	@echo ""
	@echo ">>> Plugin activated."
	@echo ">>> Hard-refresh your browser (Ctrl+Shift+R) to see the menu."

uninstall:
	@echo ">>> Removing plugin files..."
	# Remove both old (VPNLink) and new (Vpnlink) directory names
	@rm -rf $(MVC_DIR)/controllers/OPNsense/Vpnlink
	@rm -rf $(MVC_DIR)/controllers/OPNsense/VPNLink
	@rm -rf $(MVC_DIR)/models/OPNsense/Vpnlink
	@rm -rf $(MVC_DIR)/models/OPNsense/VPNLink
	@rm -rf $(MVC_DIR)/views/OPNsense/Vpnlink
	@rm -rf $(MVC_DIR)/views/OPNsense/VPNLink
	@rm -rf $(SCRIPTS_DIR)
	@rm -rf $(DESTDIR)$(PREFIX)/opnsense/www/js/vpnlink
	@rm -rf $(DESTDIR)$(PREFIX)/opnsense/scripts/OPNsense/VPNLink
	@rm -f $(ACTIONS_DIR)/actions_vpnlink.conf
	@rm -f $(PLUGINS_DIR)/vpnlink.inc
	@rm -f /var/unbound/vpnlink_acl.conf /var/unbound/etc/vpnlink_acl.conf
	@rm -f /etc/cron.d/vpnlink
	@service cron restart 2>/dev/null || true
	@rm -f /var/lib/php/tmp/opnsense_menu_cache.xml 2>/dev/null || true
	@rm -f /tmp/opnsense_menu_cache.xml 2>/dev/null || true
	@service configd restart 2>/dev/null || true
	@configctl filter reload 2>/dev/null || true
	@echo ">>> Plugin removed. Reload firewall rules applied."
