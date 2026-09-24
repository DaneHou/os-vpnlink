# Changelog

## Unreleased

### Security
- **Rule cloning**: MVC firewall rules were read with legacy field names (`type`/`disabled`), so MVC *block* rules were cloned as *pass* and disabled rules were cloned too. Now reads `action`/`enabled` for MVC rules and orders them by `sequence`.
- **Rule cloning**: legacy rules with a network destination (e.g. "to OPT2 net") became "to any". The `network` destination is now kept.
- **Rule cloning**: rules for specific LAN hosts/aliases (e.g. "Admin PC → GUI") are no longer given to every VPN client; VPN clients are treated as anonymous LAN devices.
- **Rule cloning**: pass rules with qualifiers that can't be copied (schedule, tagged, TCP flags, …) are skipped instead of being widened. Outbound-only and floating rules are no longer cloned as inbound.
- **Rule cloning**: removed the "default pass all" fallback. A LAN with no rules is default-deny, so its VPN mirror is default-deny too.
- **Source validation**: link sources must be valid IPv4 addresses or CIDRs (model mask + hook). Sources outside every VPN tunnel are skipped rather than attached to the first tunnel.
- **Interface auto-assign**: writes through `Config::save()` (locking + backups) instead of rewriting `/conf/config.xml` directly. `interface reconfigure` now gets the interface name.
- **DNS ACL**: only covers VPN server subnets referenced by enabled links that have DNS sync turned on. It no longer covers every `wg*` interface (outbound provider tunnels were included before). The ACL is removed when the plugin is disabled.
- **Backend**: removed the root-owned debug log at `/tmp/vpnlink_debug.log`, which was exposed to symlink attacks. ACL and AdGuard config are now written atomically, and AdGuard gets a `.vpnlink.bak` backup with its key order kept.
- **UI**: HTML-escape config-derived strings (peer/server names, interface descriptions, health-check details) to prevent stored XSS.

### Fixes
- Traffic collector ignores a second run in the same minute (avoids double-counted deltas).
- Health check no longer hard-codes `wg0`, and the DNS ACL check compares against the required subnets.
- Per-reload debug logging lowered to LOG_DEBUG.

## v1.0.0 (2026-04-04)

### Features
- **Core**: VPN source → LAN mirroring with automatic NAT, firewall rule cloning, and DNS ACL
- **Multi-VPN**: Auto-discovers WireGuard, OpenVPN, IPsec, Tailscale, ZeroTier, and OpenConnect tunnels
- **Links page**: Multi-select source (servers/peers across all VPN types) with selectpicker dropdowns, single-select LAN destination
- **Status page**: Card-based health check dashboard with expandable rule details
- **Monitor page**: Traffic charts (Chart.js) with per-peer speed/volume tracking, range selector (1h-30d)
- **Log page**: Filtered log viewer for VPNLink syslog entries
- **DNS**: Unbound ACL + AdGuard Home auto-detection and runtime injection via unbound-control
- **NAT**: Auto-discovers all gateway interfaces (WAN, LAN, OpenVPN, etc.)
- **Interface**: Auto-assigns WireGuard interfaces in OPNsense on Apply
- **Per-link options**: Toggle clone rules, auto NAT, DNS sync independently
- **Traffic collector**: Cron-based SQLite storage with hourly aggregation
