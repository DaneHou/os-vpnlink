# Changelog

## v1.3.0 (2026-11-26)

### Changes
- **AdGuardHome.yaml: only bind_hosts is touched.** The bind_hosts change used to load the whole file and write it back with `yaml.safe_dump`, which reformatted everything (and could disturb the upstream list App Router keeps there). It now edits only the bind_hosts lines; every other byte stays as it was. Before writing, the result is parsed as YAML and must hold exactly the intended bind_hosts with everything else unchanged, otherwise nothing is written.
- **Writes are UTF-8** regardless of the locale configd runs in.
- **Cron follows Apply**: enabling or disabling VPN Link rewrites root's crontab right away (`cron restart` when the traffic collector job is missing or left over), instead of at the next boot.

## v1.2.0 (2026-11-26)

### Changes
- **One cron mechanism**: the per-minute traffic collector comes only from `vpnlink_cron()`. The Makefile no longer edits root's crontab by hand (its `grep -v vpnlink` could also drop unrelated lines); install and uninstall run `configctl cron restart` instead.

## v1.1.3 (2026-11-26)

### Fixes
- **AdGuard Home restart**: `service AdGuardHome restart` does not exist (the rc.d name is `adguardhome`), so bind_hosts changes only applied at the next AdGuard restart. Uses `configctl adguardhome restart`.
- **Safe AdGuardHome.yaml writes**: the bind_hosts change and restart hold the AdGuardHome.yaml lock shared with App Router; if AdGuard Home does not stay up, the `.vpnlink.bak` copy is restored and AdGuard restarted again.

## v1.1.2 (2026-11-26)

### Fixes
- **Traffic history**: the history endpoint passed its range to `configdRun`, whose second argument is the detach flag; it now uses `configdpRun`.

## v1.1.1 (2026-11-21)

### Features
- **Healthcheck follows the plugin health contract** (os-netbaseline 2.3): every item carries `severity` (`medium` default); "Connected Peers" is `severity: info` (idle peers are normal), "AdGuard Home" is `ok: null` when AdGuard is not installed (optional, not a fault). With the plugin disabled, failing items are reported as `ok: null` "(plugin disabled)". The Status page and status bar count only `ok: false` items that are not `info` as issues.
- **Add device wizard** (Links page, *Add device*): creates a WireGuard peer with server-side generated keys on the next free tunnel address, attaches it to the instance, adds the VPN Link link the chosen access level needs (none for *Full* under a broad link; a single-address link to the same LAN with cloning/NAT/DNS off for *Internet only* / custom; a complete link if nothing covers the address), applies (template reload + `wireguard configure` + filter reload), verifies the peer is loaded and returns the client config as text, `.conf` download and QR code (bundled MIT qrcode-generator). Rolls back the peer/link if a later step fails. The client private key is returned once and never stored or logged. New endpoints `api/vpnlink/device/defaults` and `api/vpnlink/device/add` (ACL updated).
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
