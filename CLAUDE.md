# os-vpnlink — CLAUDE.md

## Project Overview
OPNsense plugin that automates NAT, DNS ACL, and policy routing for WireGuard VPN server clients.

## OPNsense Plugin Conventions

### Naming (CRITICAL — Phalcon routing is strict)
- OPNsense Phalcon router maps URL segments via `ucfirst()` ONLY
- Directory: URL `vpnlink` → directory `Vpnlink` (NOT `VPNLink`)
- API controller: URL `devicelink` → class `DevicelinkController` (NOT `DeviceLinkController`)
- Rule: **NO camelCase in directory or controller class names** — only ucfirst of the URL segment
- PHP namespace: `OPNsense\Vpnlink` (matching directory case)
- Model class: `Vpnlink` in `Vpnlink.php`, XML mount: `//OPNsense/Vpnlink`
- Action names CAN be camelCase: URL `searchDeviceLink` → `searchDeviceLinkAction()` (actions are different)

### FreeBSD / OPNsense Rules
- Use `sh`/`csh` syntax in scripts — no bash-isms (OPNsense shell is csh!)
- FreeBSD paths: `/usr/local/etc/`, `/usr/local/opnsense/`
- No CDN libraries — bundle JS/CSS locally
- Clear Volt cache after template changes

### Config & Model Access (CRITICAL — many pitfalls)
- `property_exists()` returns FALSE on BaseModel objects — use try-catch + `iterateItems()` instead
- `Config::getInstance()->object()` does NOT expose `filter->rule` (legacy firewall rules)
- Firewall rules are at `OPNsense->Firewall->Filter->rules->rule` in config.xml (MVC path)
- Use `simplexml_load_file('/conf/config.xml')` to read raw XML for firewall rules
- MVC model fields: `destination_net`, `source_net`, `description` (NOT `destination->address`, `descr`)
- MVC rule state/action: `enabled` (1/0) and `action` (pass/block/reject/match) — NOT legacy `disabled`/`type`; order by `sequence`
- Legacy rule addresses: `source|destination->network` (e.g. `lan`, `opt2`) OR `->address` OR `<any/>` — read `network` first

### Firewall Rule Generation
- `registerFilterRule()` requires OPNsense-assigned interface names (opt1, opt3), NOT device names (igc2, wg0)
- Unassigned interfaces (like raw wg0) silently drop all filter rules
- Plugin auto-assigns WG interfaces on Apply (ServiceController::autoAssignWgInterfaces)
- `proto any` is INVALID pf syntax — omit protocol for "match all"
- `inet6` rules with IPv4 source addresses = pf error ("rule expands to no valid combination")
- NAT target `wg0ip` / `opt6ip` fails if interface has no OPNsense-managed IP — WG IPs are managed by WG, not OPNsense
- OpenVPN dynamic gateways may NOT appear in `gateways->gateway_item` — scan interface assignments for `ovpn*` devices

### Rule Cloning Semantics (vpnlink.inc)
- VPN client = anonymous LAN device: clone rules whose source is any / LAN net / LAN CIDR, or a negated alias; skip host/alias-specific sources
- Skip: disabled, direction out, floating, inet6-only, `match`; pass rules with sched/tagged/tcpflags/tos/prio (would widen)
- `inet46` → cloned as `inet`; ports only for tcp/udp; no "default pass all" fallback (fail closed)
- Dedup key per source (`iface:lan:source`) — every device in a link needs its own rules

### Egress Gateway / Kill Switch
- Link fields: `gateway` (name, empty = as LAN), `killSwitch`, `natOnLan`
- Override splits cloned "pass to any" rules: `to (self),RFC1918,100.64/10,169.254/16` without gateway, then `to any` via gateway
- Unknown gateway → override ignored (core would emit rule without route-to = WAN leak)
- Kill switch: `tag VPNLINK_KS<n>` on cloned pass rules + prio 199000 `block out quick tagged` on physical uplinks except the gateway's interface
- Gateways: `\OPNsense\Routing\Gateways::gatewaysIndexedByName()` (includes dynamic), fallback to config `gateway_item`; groups from `gateways->gateway_group`

### DNS Integration
- Unbound custom includes: `/var/unbound/etc/*.conf` (NOT `/var/unbound/`)
- DNS ACL only covers WG *server* subnets referenced by enabled links with `dnsSync` (never all wg* — outbound provider tunnels); removed when plugin disabled
- AdGuard Home: check `bind_hosts` in config — `0.0.0.0` means all interfaces
- WG client DNS MUST point to WG interface IP (e.g. `10.10.0.1`), NOT LAN IP (192.168.1.1)
  - Reason: kernel uses wg0 IP as response source → iOS rejects mismatched source IP
- iOS requires matching DNS response source IP, otherwise marks VPN as "no internet"

### Multi-VPN Discovery
- `vpnlink_discover_wg_tunnels()` in `vpnlink.inc` handles ALL 6 VPN types (despite "wg" in name)
- `LinkController::wgSourcesAction()` enumerates: WireGuard servers/peers, OpenVPN servers, IPsec tunnels, Tailscale, ZeroTier, OpenConnect
- OpenVPN: reads `tunnel_network` from config.xml, scans interface assignments for `ovpn*` devices
- IPsec: scans interface assignments for `enc0`/`ipsec*` devices
- Tailscale/ZeroTier/OpenConnect: detected via interface assignments (`tailscale0`, `zt*`, `tun*`/`ocserv*`)

### WireGuard Integration
- WG is in OPNsense core since 24.1 (not plugins repo)
- Server model: `\OPNsense\Wireguard\Server` → `servers.server->iterateItems()` (NOT `General`)
- Client/peer model: `\OPNsense\Wireguard\Client` → `clients.client->iterateItems()`
- Peer `tunneladdress` format: `10.10.10.2/32` (NetMaskRequired, AsList)
- Server `peers` field: comma-separated Client UUIDs

## Development Workflow
```sh
# On OPNsense:
make uninstall    # Remove old version
make install      # Install + activate

# Verify:
pfctl -sn | grep 10.10           # NAT rules (descriptions not in pfctl output!)
pfctl -sr | grep wg0             # Filter rules
grep VPNLink /var/log/system/latest.log | tail -20  # Plugin logs
cat /tmp/rules.debug | grep 10.10   # Rules before pf compilation
configctl vpnlink status          # Backend status
```

## Testing
- `make test` — runs anywhere (php ≥ 8.0 + python3): `tests/php/run.php` mocks OPNsense classes, fixture `tests/php/fixtures/config.xml`; `tests/python/test_backend.py` (unittest)
- `vpnlink.inc` reads config via `vpnlink_raw_config()` (override path with `VPNLINK_CONFIG_XML`); `vpnlink.py` via `CONFIG_XML`
- Add a fixture rule + check for every rule-generation change; CI runs on push (.github/workflows/test.yml)
- Then test on physical OPNsense (user has production box)
- After install: hard-refresh browser (Ctrl+Shift+R)
- WG client DNS: use WG interface IP (10.10.0.1), NOT LAN IP
- Check `/var/unbound/etc/vpnlink_acl.conf` for DNS ACL
- `pfctl -f /tmp/rules.debug` to check for pf syntax errors
