# os-vpnlink — VPN Traffic Orchestrator for OPNsense

> Make VPN clients behave exactly like devices on your LAN.
> Automatic NAT, firewall rules, DNS — zero manual configuration.

## The Problem

Setting up a WireGuard server on OPNsense is easy. Making it actually *useful* requires 30+ minutes of manual configuration:

- Switch to Hybrid NAT mode, create outbound NAT rules per VPN subnet
- Add VPN subnets to Unbound DNS access lists (or fight the [boot race condition](https://github.com/opnsense/core/issues/4142))
- Create firewall pass rules on the VPN interface
- Duplicate all your LAN policy routing rules (gateway selection, alias-based routing) on the VPN interface
- Configure NAT on every VPN gateway interface

Every time you add a new VPN client or change your network, you do it all over again.

## The Solution

VPN Link automates everything. Pick a VPN source, pick a LAN to mirror, done.

Your VPN clients get the same DNS, same routing rules, same gateway policies as devices on that LAN. The plugin reads your LAN's firewall rules and clones them to the VPN interface automatically.

## Features

- **One-click setup** — VPN source to LAN destination, that's it
- **Auto NAT** on all exit interfaces (WAN, LAN, VPN gateways) — auto-discovers OpenVPN and other gateway interfaces
- **Firewall rule cloning** — mirrors LAN policy routing (gateway selection, alias-based rules) onto the VPN interface
- **DNS ACL sync** — Unbound + AdGuard Home auto-detect and configuration
- **Per-link advanced options** — toggle rule cloning, NAT, DNS sync independently
- **Traffic monitoring** — Chart.js dashboards with per-peer speed and history
- **Health check status page** — green/red indicators for every component
- **Log viewer** with filtering
- **Auto interface assignment** — WireGuard interfaces are auto-assigned in OPNsense on Apply
- **Multi-peer, multi-server support**

## Supported VPN Types

| VPN | Status | Interface |
|-----|--------|-----------|
| WireGuard | Supported | wg* |
| OpenVPN Server | Planned (v1.x) | ovpns* |
| IPsec | Planned (v1.x) | enc0, ipsec* |
| OpenConnect | Planned (v2.0) | ocserv* |
| Tailscale | Under consideration | tailscale0 |
| ZeroTier | Under consideration | zt* |

The core NAT + firewall rule cloning logic is protocol-agnostic. Only the tunnel discovery differs per VPN type.

## Installation

```sh
# On your OPNsense box:
git clone https://github.com/DaneHou/os-vpnlink.git
cd os-vpnlink
make install
```

To update:
```sh
cd os-vpnlink
git pull
make uninstall
make install
```

To remove:
```sh
cd os-vpnlink
make uninstall
```

## Quick Start

1. **VPN > VPN Link > Links** — Enable the plugin, click Apply
2. **Add Link** — Source: your WireGuard server/peers, Destination: your LAN
3. **WireGuard peer config** — Set DNS to the WG interface IP (e.g. `10.10.0.1`)
4. **Done** — VPN clients now mirror the selected LAN

### Important: DNS Configuration

VPN clients **must** use the WireGuard interface IP as their DNS server (e.g. `10.10.0.1`), **not** the LAN IP (e.g. `192.168.68.1`). This is because the kernel uses the WG interface IP as the response source address — iOS and other clients reject DNS responses from mismatched IPs.

## Pages

### Links
The main configuration page. Each link maps a VPN source (WireGuard server or individual peers) to a LAN destination. Multi-select supported for sources.

### Status
Health check dashboard with card-based indicators:
- WireGuard tunnels and connected peers
- Interface assignment status
- NAT and filter rule counts (expandable to see actual rules)
- DNS ACL status
- AdGuard Home detection

### Monitor
Real-time traffic monitoring:
- Summary cards (download/upload speed, today's traffic, peer count)
- Traffic chart with selectable ranges (1h, 6h, 24h, 7d, 30d)
- Per-peer traffic table with names resolved from WireGuard config

### Log
Plugin log viewer with search/filter functionality.

## Requirements

- OPNsense 24.1+ (WireGuard in core)
- WireGuard server configured with static peers
- AdGuard Home (optional — auto-detected)

## How It Works

### Architecture

```
User clicks Apply
    │
    ├── vpnlink_firewall($fw)     ← called on every filter reload
    │   ├── Discover WG tunnels   ← reads WireGuard Server model
    │   ├── Clone LAN rules       ← reads config.xml MVC firewall rules
    │   │   └── registerFilterRule() per cloned rule (policy routing, pass/block)
    │   └── Generate NAT          ← registerSNatRule() on WAN, LAN, all gateways
    │
    ├── vpnlink.py sync_dns       ← called via configd
    │   ├── Unbound ACL           ← writes /var/unbound/etc/vpnlink_acl.conf
    │   ├── unbound-control       ← runtime ACL injection
    │   └── AdGuard bind_hosts    ← patches AdGuard config if detected
    │
    └── Auto-assign WG interface  ← ServiceController creates optX if needed
```

### Key Design Decisions

- **Rule cloning, not routing tricks**: We clone the LAN's actual firewall rules to the VPN interface, preserving gateway selection and alias-based routing. This means if you add a new rule to your LAN, VPN clients inherit it on the next Apply.

- **NAT everywhere**: Every exit interface (WAN, LAN, OpenVPN gateways) gets an outbound NAT rule. This is discovered automatically from the gateway configuration.

- **No loopback NAT**: DNS queries to OPNsense's own IPs are processed locally — stateful connection tracking handles return traffic without NAT.

- **Runtime DNS injection**: Unbound's template system deletes custom files on restart. We use `unbound-control access_control` for runtime ACL injection alongside the config file.

## FAQ

### Why must DNS point to the WG interface IP, not the LAN IP?

When a VPN client queries `192.168.68.1:53` through the WG tunnel, the response comes from `10.10.0.1:53` (the WG interface IP, selected by the kernel for the outgoing interface). iOS and other clients reject DNS responses where the source IP doesn't match the queried server.

### Does it work with AdGuard Home?

Yes. The plugin auto-detects AdGuard Home and ensures it listens on WG interface IPs. The DNS chain is: VPN client → AdGuard (port 53) → Unbound → upstream.

### Why do I need to assign the WireGuard interface?

OPNsense's pf firewall silently drops filter rules on unassigned interfaces. The plugin auto-assigns WG interfaces on Apply (creates `optX` entries in the interface configuration).

### Can I use policy routing (e.g., route specific domains through a VPN gateway)?

Yes — that's a core feature. The plugin clones your LAN's firewall rules including gateway-based policy routing. If your LAN routes `BA_HOSTS` alias through `BA_VPNV4` gateway, your VPN clients will too.

## Community Demand

This plugin addresses long-standing community pain points:
- [20+ forum posts](https://forum.opnsense.org/index.php?topic=27449.0) about VPN policy routing
- [Active core bug #4142](https://github.com/opnsense/core/issues/4142) — Unbound DNS race condition with VPN interfaces
- [Users building Home Assistant integrations](https://www.apalrd.net/posts/2022/ha_fwrules/) just to toggle per-device VPN routing
- Zero existing plugins covering this scope

## Roadmap

### v1.0 (Current)
- WireGuard server → LAN mirroring
- Auto NAT + firewall rule cloning + DNS ACL
- Monitor with traffic charts
- Status health checks + Log viewer

### v1.x (Planned)
- OpenVPN Server support
- IPsec support
- Multi WG server testing
- Rule conflict detection
- DNS configuration wizard

### v2.0 (Future)
- OpenConnect support
- Tailscale/ZeroTier support
- Per-peer LAN policies
- Traffic alerts
- Real-time traffic (WebSocket)

## License

BSD 2-Clause License. See [LICENSE](LICENSE).

## Author

DaneBA — [GitHub](https://github.com/DaneHou/os-vpnlink)
