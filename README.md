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
| OpenVPN Server | Supported | ovpns* |
| IPsec | Supported | enc0, ipsec* |
| OpenConnect | Supported | tun*, ocserv* |
| Tailscale | Supported | tailscale0 |
| ZeroTier | Supported | zt* |

The core NAT + firewall rule cloning logic is protocol-agnostic. Tunnel discovery auto-detects all six VPN types from a single UI.

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

## Why This Plugin Exists

### The Manual Pain

OPNsense's official [WireGuard Selective Routing guide](https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html) requires **11 manual steps** for a single tunnel: peer config, instance config, interface assignment, gateway creation, host alias, RFC1918 alias, inverted-destination firewall rule, floating rule, outbound NAT, and optional kill switch. For IPv6, duplicate most steps. For multiple tunnels, repeat everything.

Community blog guides run to 6,000+ words and 30-minute reads just for basic policy-based routing.

### Community Demand

Forum threads spanning 2018-2024 show sustained, unresolved frustration:

- ["Completely lost and slowly going insane!"](https://forum.opnsense.org/index.php?topic=20370.0) — user unable to get WireGuard routing working
- ["Multiple Wireguard VPN Gateways with Unbound DNS"](https://forum.opnsense.org/index.php?topic=39061.0) — 16-step community guide; commenter: *"What on earth does this mean? I got stuck here"*
- ["Wireguard NAT rules required?"](https://forum.opnsense.org/index.php?topic=30780.0) — requesting feature parity with OpenVPN (which auto-creates NAT, WireGuard does not)
- ["Selective Routing - Why Step 9?"](https://forum.opnsense.org/index.php?topic=32074.0) — 14 posts trying to understand a single configuration step
- [pfSense: "Setup Docs Incomplete"](https://forum.netgate.com/topic/184254/) — *"I spent hours trying to set up Wireguard, following the guide precisely several times"*
- [GitHub #4142](https://github.com/opnsense/core/issues/4142) — Unbound DNS race condition with VPN interfaces, open since May 2020, still unresolved upstream

### Top Pain Points VPN Link Solves

1. **NAT not automated for WireGuard** — OpenVPN auto-creates outbound NAT; WireGuard does not. VPN Link generates NAT on all exit interfaces automatically.
2. **DNS ACL breaks on reboot** — Unbound starts before the WG interface exists, dropping DNS access. VPN Link uses runtime injection (`unbound-control`) to survive restarts.
3. **Selective routing requires deep networking knowledge** — RFC1918 aliases, inverted destinations, floating rules, hybrid NAT mode. VPN Link clones your existing LAN rules in one click.
4. **Multi-tunnel multiplies complexity** — every additional tunnel repeats all 11 steps. VPN Link handles unlimited tunnels from one UI.
5. **WireGuard gives zero error feedback** — misconfigured tunnels silently blackhole traffic. VPN Link's health check dashboard shows exactly what's working and what isn't.
6. **No unified management across VPN types** — WireGuard, OpenVPN, IPsec, Tailscale, ZeroTier each have separate workflows. VPN Link discovers all six from a single interface.

### No Competing Solution

| Project | Scope | Limitations |
|---------|-------|-------------|
| [OPNsensePIAWireguard](https://github.com/FingerlessGlov3s/OPNsensePIAWireguard) (241 stars) | PIA-specific WG automation | CLI-only, single provider, no NAT/DNS/firewall automation |
| os-tailscale | Tailscale only | No policy routing, no NAT automation |
| os-zerotier | ZeroTier only | Known CPU/routing issues |
| **os-vpnlink** | **All 6 VPN types** | **NAT + DNS ACL + firewall rule cloning + policy routing + monitoring** |

VPN Link is the first and only OPNsense plugin that automates NAT, DNS ACL, firewall rule cloning, and policy routing from a GUI — across multiple VPN protocols.

## Roadmap

### v1.0 (Current)
- VPN source → LAN mirroring for all 6 VPN types (WireGuard, OpenVPN, IPsec, Tailscale, ZeroTier, OpenConnect)
- Auto NAT + firewall rule cloning + DNS ACL
- Traffic monitoring with per-peer charts (1h-30d)
- Status health checks + Log viewer
- Auto interface assignment

### v1.x (Planned)
- Multi WG server testing
- Rule conflict detection
- DNS configuration wizard
- Kill switch toggle per link

### v2.0 (Future)
- Per-peer LAN policies
- Traffic alerts and thresholds
- Real-time traffic (WebSocket)
- Peer QR code generation

## License

BSD 2-Clause License. See [LICENSE](LICENSE).

## Author

DaneBA — [GitHub](https://github.com/DaneHou/os-vpnlink)
