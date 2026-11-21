# Changelog

## Unreleased

### Features
- **Access control, other direction**: restricted links also block connections *to* the peer from the firewall and private networks (selected networks excepted), so a restricted peer is isolated both ways.
- **Access control per link**: *Full* (default, unchanged), *Internet only*, or *Internet + selected networks* (interface networks, IPv4 networks, aliases). Restricted sources may still use DNS on the firewall; the firewall itself and all other private ranges are blocked. The rules come before interface-group rules and every cloned rule, so a single peer can be restricted inside a broader link. Existing links keep full access (no rule changes).

### Fixes
- **Gateways on 26.x**: static gateways moved to the MVC model (`//OPNsense/Gateways/gateway_item`). Outbound-NAT auto-discovery read only the old `//gateways/gateway_item` path, so it missed the real gateways (and could pick up a stale leftover entry). It now uses the Gateways model (incl. dynamic tunnel gateways), falling back to `//OPNsense/Gateways` and then the legacy path. Gateway groups are parsed in both the legacy (`GW|tier|trigger`) and 26.x (`item`..`item5`, comma-separated) formats.
- **DNS ACL runtime update**: `unbound-control` is now called with `-c /var/unbound/unbound.conf` (OPNsense's control socket is defined there; without it the call fails against 127.0.0.1:8953). Failures are logged to syslog and fall back to an Unbound restart instead of being silently ignored.

## v1.1.0 (2026-09-24)

### Features
- **Egress gateway per link**: route a device's or a server's internet traffic via a chosen gateway or gateway group. Local/private destinations bypass it.
- **Kill switch per link**: tag + floating `block out` on physical uplinks, so traffic never exits via WAN directly, even with the gateway down.
- **NAT towards LAN** toggle, so LAN hosts can see real VPN client IPs.
- **Conflict detection** now works on IP ranges (e.g. `10.10.0.5` vs `10.10.0.0/24`). The UI no longer offers "save anyway", which the server rejected anyway.
- Unit tests (`make test`) and GitHub Actions CI.

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
- Links with several devices on the same WG interface only generated rules for the first device.
- Traffic collector ignores a second run in the same minute (avoids double-counted deltas).
- Health check no longer hard-codes `wg0`, and the DNS ACL check compares against the required subnets.
- Per-reload debug logging lowered to LOG_DEBUG.

### Docs
- README: per-VPN-type support matrix, IPv4-only note, rule-cloning semantics, egress/kill switch design.
- Example addresses and gateway names in docs and tests replaced with generic ones.

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
