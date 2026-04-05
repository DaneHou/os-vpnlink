# Changelog

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
