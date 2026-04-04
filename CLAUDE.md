# os-vpnlink — CLAUDE.md

## Project Overview
OPNsense plugin that automates NAT, DNS ACL, and policy routing for WireGuard VPN server clients.

## OPNsense Plugin Conventions

### Directory Naming (CRITICAL)
- OPNsense Phalcon router maps URL `/ui/vpnlink` → directory `Vpnlink` (ucfirst, NOT `VPNLink`)
- All MVC directories MUST be `OPNsense/Vpnlink/`, NOT `OPNsense/VPNLink/`
- PHP namespace: `OPNsense\Vpnlink` (matching directory case)
- Model class: `Vpnlink` in `Vpnlink.php`, XML mount: `//OPNsense/Vpnlink`

### FreeBSD / OPNsense Rules
- Use `sh`/`csh` syntax in scripts — no bash-isms
- FreeBSD paths: `/usr/local/etc/`, `/usr/local/opnsense/`
- No CDN libraries — bundle JS/CSS locally
- Clear Volt cache after template changes
- Controllers use lowercase 'c' in Phalcon routing

### Plugin Architecture
- `vpnlink.inc` — plugin hooks (`_firewall`, `_services`, `_configure`, `_syslog`)
- `vpnlink_firewall($fw)` — generates NAT + filter rules on every `filter reload`
- `vpnlink.py` — backend script for DNS ACL sync (Unbound + AdGuard)
- MVC pattern: Model XML → Controller PHP → View Volt
- configd actions bridge API to backend scripts

### WireGuard Integration
- WG is in OPNsense core since 24.1 (not plugins repo)
- Server model: `\OPNsense\Wireguard\Server` → `servers.server->iterateItems()`
- Client/peer model: `\OPNsense\Wireguard\Client` → `clients.client->iterateItems()`
- Peer `tunneladdress` format: `10.10.10.2/32` (NetMaskRequired, AsList)
- Server `peers` field: comma-separated Client UUIDs

## Development Workflow
```sh
# On OPNsense:
make uninstall    # Remove old version
make install      # Install + activate (clears cache, restarts configd/webgui)

# Verify:
pfctl -sn | grep VPNLink    # Check NAT rules
pfctl -sr | grep VPNLink    # Check filter rules
```

## Testing
- Test on physical OPNsense (user has production box)
- After install: hard-refresh browser (Ctrl+Shift+R)
- Check `/var/unbound/vpnlink_acl.conf` for DNS ACL
- WG client DNS should point to OPNsense IP for domain-based routing to work
