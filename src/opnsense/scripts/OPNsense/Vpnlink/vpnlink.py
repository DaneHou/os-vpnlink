#!/usr/local/bin/python3

"""
VPN Link — Backend service script.

Handles DNS ACL synchronization for WireGuard tunnel subnets.
Supports both Unbound-only and AdGuard Home + Unbound setups:

  - Unbound only:  WG client -> Unbound (:53) -> upstream
  - AdGuard setup: WG client -> AdGuard (:53) -> Unbound (:5353) -> upstream

For Unbound: generates access-control directives in an include file.
For AdGuard: patches AdGuard's bind_hosts to include WG interface IPs
             so it accepts DNS queries from the WG subnet.

Usage:
    vpnlink.py start        Apply DNS ACL and firewall rules
    vpnlink.py stop         Remove DNS ACL file
    vpnlink.py restart      Re-apply everything
    vpnlink.py status       Show current state
    vpnlink.py sync_dns     Sync DNS ACL (Unbound + AdGuard if detected)
"""

import json
import os
import subprocess
import sys
import ipaddress
import copy

CONFIG_XML = '/conf/config.xml'
UNBOUND_ACL_FILE = '/var/unbound/etc/vpnlink_acl.conf'
ADGUARD_CONFIG_PATHS = [
    '/usr/local/AdGuardHome/AdGuardHome.yaml',
    '/var/db/adguardhome/AdGuardHome.yaml',
    '/usr/local/etc/adguardhome/AdGuardHome.yaml',
]
WG_SHOW_CMD = '/usr/bin/wg'


def discover_wg_subnets():
    """Discover WireGuard tunnel subnets from wg show output and interface config."""
    subnets = set()

    # Method 1: Parse `wg show` for interface addresses
    try:
        result = subprocess.run(
            [WG_SHOW_CMD, 'show', 'interfaces'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            interfaces = result.stdout.strip().split()
            for iface in interfaces:
                addrs = get_interface_addresses(iface)
                for addr in addrs:
                    try:
                        network = ipaddress.ip_network(addr, strict=False)
                        if network.version == 4:
                            subnets.add(str(network))
                    except ValueError:
                        pass
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # Method 2: Read from OPNsense config.xml via configd
    if not subnets:
        subnets = discover_from_config()

    return sorted(subnets)


def get_interface_addresses(iface):
    """Get IP addresses assigned to a network interface."""
    addresses = []
    try:
        result = subprocess.run(
            ['ifconfig', iface],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                line = line.strip()
                if line.startswith('inet '):
                    parts = line.split()
                    ip = parts[1]
                    # Look for netmask
                    if 'netmask' in parts:
                        idx = parts.index('netmask')
                        netmask_hex = parts[idx + 1]
                        # Convert hex netmask to prefix length
                        try:
                            mask_int = int(netmask_hex, 16)
                            prefix = bin(mask_int).count('1')
                            addresses.append('{}/{}'.format(ip, prefix))
                        except ValueError:
                            addresses.append('{}/24'.format(ip))
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return addresses


def discover_from_config():
    """Fallback: read WireGuard config from OPNsense config.xml."""
    subnets = set()
    config_path = '/conf/config.xml'

    if not os.path.exists(config_path):
        return subnets

    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse(config_path)
        root = tree.getroot()

        # Look for interfaces with wg* device names
        interfaces = root.find('interfaces')
        if interfaces is not None:
            for iface in interfaces:
                if_dev = iface.find('if')
                if if_dev is not None and if_dev.text and if_dev.text.startswith('wg'):
                    ipaddr = iface.find('ipaddr')
                    subnet = iface.find('subnet')
                    if ipaddr is not None and subnet is not None:
                        if ipaddr.text and subnet.text:
                            try:
                                addr = '{}/{}'.format(ipaddr.text, subnet.text)
                                network = ipaddress.ip_network(addr, strict=False)
                                if network.version == 4:
                                    subnets.add(str(network))
                            except ValueError:
                                pass
    except Exception as e:
        syslog_msg('Error reading config: {}'.format(e))

    return subnets


def read_config():
    """Parse /conf/config.xml, returns the root element or None."""
    try:
        import xml.etree.ElementTree as ET
        return ET.parse(CONFIG_XML).getroot()
    except Exception as e:
        syslog_msg('Error reading config: {}'.format(e))
        return None


def wg_servers_from_config(root):
    """Enabled WireGuard server instances: [(device, subnet), ...] (IPv4 only)."""
    servers = []
    node = root.find('OPNsense/wireguard/server/servers') if root is not None else None
    if node is None:
        return servers
    for srv in node.findall('server'):
        if (srv.findtext('enabled') or '0') != '1':
            continue
        instance = (srv.findtext('instance') or '').strip()
        if not instance.isdigit():
            continue
        for addr in (srv.findtext('tunneladdress') or '').split(','):
            try:
                net = ipaddress.ip_network(addr.strip(), strict=False)
            except ValueError:
                continue
            if net.version == 4:
                servers.append(('wg' + instance, str(net)))
    return servers


def dns_sync_targets():
    """
    Work out which subnets need DNS access and which WG devices serve them.

    Only VPN *server* tunnels referenced by an enabled link with DNS sync on
    are included. Blindly allowing every wg* interface would also open the
    resolver to outbound VPN-provider tunnels (wg client connections).

    Returns (enabled, subnets, devices).
    """
    root = read_config()
    if root is None:
        return False, [], []
    vpnlink = root.find('OPNsense/Vpnlink')
    if vpnlink is None or (vpnlink.findtext('general/enabled') or '0') != '1':
        return False, [], []

    servers = wg_servers_from_config(root)
    if not servers:
        # model not found (older layout) — fall back to live wg interfaces
        servers = [(dev, net) for dev in list_wg_interfaces() for net in interface_subnets(dev)]

    subnets, devices = set(), set()
    links = vpnlink.find('links')
    for link in (links.findall('link') if links is not None else []):
        if (link.findtext('enabled') or '1') != '1' or (link.findtext('dnsSync') or '1') != '1':
            continue
        for src in (link.findtext('source') or '').split(','):
            src = src.strip()
            if src == 'any':
                for dev, net in servers:
                    subnets.add(net)
                    devices.add(dev)
                continue
            try:
                net = ipaddress.ip_network(src, strict=False)
            except ValueError:
                continue
            if net.version != 4:
                continue
            subnets.add(str(net))
            for dev, srv_net in servers:
                if net.subnet_of(ipaddress.ip_network(srv_net)):
                    devices.add(dev)
    return True, sorted(subnets), sorted(devices)


def list_wg_interfaces():
    try:
        result = subprocess.run([WG_SHOW_CMD, 'show', 'interfaces'],
                                capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            return result.stdout.strip().split()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return []


def interface_subnets(iface):
    nets = []
    for addr in get_interface_addresses(iface):
        try:
            net = ipaddress.ip_network(addr, strict=False)
        except ValueError:
            continue
        if net.version == 4:
            nets.append(str(net))
    return nets


def generate_unbound_acl(subnets):
    """Write Unbound access-control directives for WG subnets."""
    lines = [
        '# Auto-generated by VPN Link — do not edit manually',
        '# Allows WireGuard VPN clients to query Unbound DNS',
        '',
    ]

    for subnet in subnets:
        lines.append('access-control: {} allow'.format(subnet))

    lines.append('')

    acl_dir = os.path.dirname(UNBOUND_ACL_FILE)
    if not os.path.isdir(acl_dir):
        try:
            os.makedirs(acl_dir, exist_ok=True)
        except OSError:
            return False

    try:
        write_file_atomic(UNBOUND_ACL_FILE, '\n'.join(lines))
        return True
    except (IOError, OSError) as e:
        syslog_msg('Error writing {}: {}'.format(UNBOUND_ACL_FILE, e))
        return False


def write_file_atomic(path, content, mode=0o644):
    """Write via temp file + rename so readers never see a half-written file."""
    tmp_path = '{}.vpnlink.tmp'.format(path)
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
    # O_EXCL|O_NOFOLLOW: never follow a planted symlink/hardlink
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, 'w') as f:
        f.write(content)
    os.chmod(tmp_path, mode)
    os.rename(tmp_path, path)


def remove_unbound_acl():
    """Remove the Unbound ACL file."""
    try:
        if os.path.exists(UNBOUND_ACL_FILE):
            os.unlink(UNBOUND_ACL_FILE)
    except IOError:
        pass


def apply_unbound_acl_runtime(subnets):
    """Add ACL entries to running Unbound via unbound-control (no restart needed)."""
    for subnet in subnets:
        try:
            subprocess.run(
                ['unbound-control', 'access_control', subnet, 'allow'],
                capture_output=True, timeout=5
            )
            _dbg('unbound-control: added {}'.format(subnet))
        except (subprocess.TimeoutExpired, FileNotFoundError) as e:
            _dbg('unbound-control failed: {}'.format(e))


def reload_unbound():
    """Restart Unbound to pick up ACL changes."""
    try:
        subprocess.run(
            ['configctl', 'unbound', 'restart'],
            capture_output=True, timeout=30
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        try:
            subprocess.run(
                ['service', 'unbound', 'restart'],
                capture_output=True, timeout=30
            )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass


# ── AdGuard Home integration ──────────────────────────────────────────


def detect_adguard():
    """Detect if AdGuard Home is installed. Returns config path or None."""
    for path in ADGUARD_CONFIG_PATHS:
        if os.path.exists(path):
            return path

    # Check if AdGuard process is running
    try:
        result = subprocess.run(
            ['pgrep', '-f', 'AdGuardHome'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            # Try to find config via process args
            ps_result = subprocess.run(
                ['ps', 'aux'],
                capture_output=True, text=True, timeout=5
            )
            for line in ps_result.stdout.splitlines():
                if 'AdGuardHome' in line and '-c' in line:
                    parts = line.split()
                    for i, p in enumerate(parts):
                        if p == '-c' and i + 1 < len(parts):
                            cfg = parts[i + 1]
                            if os.path.exists(cfg):
                                return cfg
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    return None


def get_dns_topology():
    """Always auto-detect DNS topology."""
    return 'auto'


def get_wg_interface_ips():
    """Get the IP addresses of all WireGuard interfaces (the server-side IPs)."""
    ips = []
    try:
        result = subprocess.run(
            [WG_SHOW_CMD, 'show', 'interfaces'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            interfaces = result.stdout.strip().split()
            for iface in interfaces:
                addrs = get_interface_addresses(iface)
                for addr in addrs:
                    ip = addr.split('/')[0]
                    ips.append(ip)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return ips


def sync_adguard_binds(adguard_config_path, wg_ips):
    """
    Ensure AdGuard Home listens on WG interface IPs.

    AdGuard's bind_hosts controls which IPs it accepts DNS queries on.
    We add WG interface IPs so VPN clients can reach AdGuard.

    Returns True if config was changed and AdGuard needs restart.
    """
    try:
        import yaml
    except ImportError:
        # PyYAML not available — try manual patching
        return sync_adguard_binds_manual(adguard_config_path, wg_ips)

    try:
        with open(adguard_config_path, 'r') as f:
            config = yaml.safe_load(f)
    except Exception as e:
        syslog_msg('AdGuard: Error reading config: {}'.format(e))
        return False

    if not isinstance(config, dict) or 'dns' not in config:
        syslog_msg('AdGuard: Invalid config format')
        return False

    dns = config['dns']
    bind_hosts = dns.get('bind_hosts') or []
    if not isinstance(bind_hosts, list):
        syslog_msg('AdGuard: unexpected bind_hosts format, not touching config')
        return False

    # If bind_hosts contains 0.0.0.0 it's already listening on all interfaces
    if '0.0.0.0' in bind_hosts:
        syslog_msg('AdGuard: Already bound to 0.0.0.0, no changes needed')
        return False

    original_binds = list(bind_hosts)
    changed = False

    for ip in wg_ips:
        if ip not in bind_hosts:
            bind_hosts.append(ip)
            changed = True

    if not changed:
        return False

    dns['bind_hosts'] = bind_hosts
    config['dns'] = dns

    try:
        import shutil
        st = os.stat(adguard_config_path)
        shutil.copy2(adguard_config_path, adguard_config_path + '.vpnlink.bak')
        write_file_atomic(
            adguard_config_path,
            yaml.safe_dump(config, default_flow_style=False, sort_keys=False, allow_unicode=True),
            mode=st.st_mode & 0o777,
        )
        os.chown(adguard_config_path, st.st_uid, st.st_gid)
        syslog_msg('AdGuard: Added WG IPs to bind_hosts: {} (was: {})'.format(
            bind_hosts, original_binds))
        return True
    except Exception as e:
        syslog_msg('AdGuard: Error writing config: {}'.format(e))
        return False


def sync_adguard_binds_manual(adguard_config_path, wg_ips):
    """Fallback: patch AdGuard config without PyYAML (simple text-based)."""
    try:
        with open(adguard_config_path, 'r') as f:
            content = f.read()
    except IOError:
        return False

    # Check if already bound to all
    if '0.0.0.0' in content and 'bind_hosts' in content:
        return False

    changed = False
    for ip in wg_ips:
        marker = '  - {}'.format(ip)
        if marker not in content and ip not in content:
            # Find bind_hosts section and append
            # This is fragile but works as fallback
            syslog_msg('AdGuard: PyYAML not available. Please manually add {} to bind_hosts in {}'.format(
                ip, adguard_config_path))
            changed = True

    return False  # Don't auto-modify without YAML parser


def restart_adguard():
    """Restart AdGuard Home service."""
    try:
        subprocess.run(
            ['service', 'AdGuardHome', 'restart'],
            capture_output=True, timeout=30
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        try:
            subprocess.run(
                ['configctl', 'adguardhome', 'restart'],
                capture_output=True, timeout=30
            )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass


def syslog_msg(msg, debug=False):
    """Log a message to syslog."""
    try:
        import syslog
        syslog.openlog('vpnlink', syslog.LOG_PID, syslog.LOG_LOCAL4)
        syslog.syslog(syslog.LOG_DEBUG if debug else syslog.LOG_INFO, msg)
    except Exception:
        pass


def resolve_dns_topology():
    """Determine effective DNS topology (auto-detect or user setting)."""
    setting = get_dns_topology()

    if setting != 'auto':
        adguard_cfg = detect_adguard() if setting == 'adguard_unbound' else None
        return setting, adguard_cfg

    # Auto-detect
    adguard_cfg = detect_adguard()
    if adguard_cfg:
        return 'adguard_unbound', adguard_cfg
    return 'unbound', None


def cmd_start():
    """Apply DNS ACL (Unbound + AdGuard if applicable)."""
    cmd_sync_dns()


def cmd_stop():
    """Remove DNS ACL."""
    remove_unbound_acl()
    reload_unbound()
    syslog_msg('Stopped: DNS ACL removed')


def cmd_restart():
    """Re-apply everything."""
    cmd_stop()
    cmd_start()


def cmd_status():
    """Show current status."""
    subnets = discover_wg_subnets()
    acl_exists = os.path.exists(UNBOUND_ACL_FILE)
    topology, adguard_cfg = resolve_dns_topology()

    status = {
        'running': acl_exists,
        'subnets': subnets,
        'acl_file': UNBOUND_ACL_FILE,
        'acl_exists': acl_exists,
        'dns_topology': topology,
        'adguard_detected': adguard_cfg is not None,
        'adguard_config': adguard_cfg,
        'wg_interface_ips': get_wg_interface_ips(),
    }

    print(json.dumps(status, indent=2))


def _dbg(msg):
    """Debug messages go to syslog (never to a predictable /tmp path as root)."""
    syslog_msg(msg, debug=True)

def wg_device_ips(devices):
    """Server-side IPs of the given WG devices."""
    return [addr.split('/')[0] for dev in devices for addr in get_interface_addresses(dev)]


def cmd_sync_dns():
    """Sync DNS ACL — Unbound + AdGuard if detected (called on VPN events / Apply)."""
    enabled, subnets, devices = dns_sync_targets()

    old_content = ''
    if os.path.exists(UNBOUND_ACL_FILE):
        with open(UNBOUND_ACL_FILE, 'r') as f:
            old_content = f.read()
    old_subnets = set(line.split()[1] for line in old_content.splitlines()
                      if line.startswith('access-control:') and len(line.split()) >= 3)

    if not enabled or not subnets:
        # plugin disabled or nothing to allow: withdraw our ACL
        if old_content:
            remove_unbound_acl()
            reload_unbound()
            syslog_msg('DNS ACL removed ({})'.format('disabled' if not enabled else 'no DNS-synced links'))
        return

    generate_unbound_acl(subnets)
    if old_subnets - set(subnets):
        # runtime entries can only be added, so drop stale ones with a restart
        reload_unbound()
    else:
        # Inject ACL directly into running Unbound (no restart needed)
        apply_unbound_acl_runtime(subnets)
    syslog_msg('DNS ACL applied for subnets: {}'.format(', '.join(subnets)))

    # Sync AdGuard bind_hosts (only the VPN server interfaces we serve)
    topology, adguard_cfg = resolve_dns_topology()
    if topology == 'adguard_unbound' and adguard_cfg:
        wg_ips = wg_device_ips(devices)
        if wg_ips:
            changed = sync_adguard_binds(adguard_cfg, wg_ips)
            if changed:
                restart_adguard()
                syslog_msg('AdGuard bind_hosts updated for WG IPs: {}'.format(
                    ', '.join(wg_ips)))


def cmd_healthcheck():
    """Comprehensive health check for the Status tab."""
    checks = []
    subnets = discover_wg_subnets()
    topology, adguard_cfg = resolve_dns_topology()

    # 1. WG Subnets
    checks.append({
        'name': 'WireGuard Tunnels',
        'ok': len(subnets) > 0,
        'detail': ', '.join(subnets) if subnets else 'No tunnels discovered',
    })

    # 2. WG Peers (from wg show)
    peers = []
    try:
        result = subprocess.run([WG_SHOW_CMD, 'show', 'all', 'dump'],
                                capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines()[1:]:  # skip header
                parts = line.split('\t')
                if len(parts) >= 9:
                    endpoint = parts[3] if parts[3] != '(none)' else None
                    handshake = int(parts[5]) if parts[5] != '0' else 0
                    allowed_ips = parts[4]
                    rx, tx = int(parts[6]), int(parts[7])
                    if endpoint:
                        import time
                        ago = int(time.time()) - handshake if handshake else 0
                        peers.append({
                            'endpoint': endpoint,
                            'allowed_ips': allowed_ips,
                            'handshake_ago': ago,
                            'rx_bytes': rx,
                            'tx_bytes': tx,
                        })
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    checks.append({
        'name': 'Connected Peers',
        'ok': len(peers) > 0,
        'detail': '{} peer(s) connected'.format(len(peers)),
        'peers': peers,
    })

    # 3. WG Interface Assignment
    assigned = None
    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse('/conf/config.xml')
        root = tree.getroot()
        interfaces = root.find('interfaces')
        if interfaces is not None:
            for iface in interfaces:
                if_dev = iface.find('if')
                descr = iface.find('descr')
                if if_dev is not None and if_dev.text and if_dev.text.startswith('wg'):
                    assigned = {'name': iface.tag, 'device': if_dev.text,
                                'descr': descr.text if descr is not None else ''}
    except Exception:
        pass

    checks.append({
        'name': 'WG Interface Assigned',
        'ok': assigned is not None,
        'detail': '{} -> {} ({})'.format(assigned['device'], assigned['name'], assigned['descr']) if assigned else 'Not assigned — filter rules will not work',
    })

    # 4. NAT Rules
    nat_rules = []
    try:
        result = subprocess.run(['pfctl', '-sn'], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            for subnet in subnets:
                if subnet.split('/')[0] in line and 'nat' in line:
                    nat_rules.append(line.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    checks.append({
        'name': 'NAT Rules',
        'ok': len(nat_rules) > 0,
        'detail': '{} active'.format(len(nat_rules)),
        'rules': nat_rules,
    })

    # 5. Filter Rules
    filter_rules = []
    wg_devs = list_wg_interfaces()
    try:
        result = subprocess.run(['pfctl', '-sr'], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if 'pass' in line and any(' on {} '.format(dev) in line for dev in wg_devs):
                filter_rules.append(line.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    checks.append({
        'name': 'Filter Rules',
        'ok': len(filter_rules) > 0,
        'detail': '{} active on {}'.format(len(filter_rules), ', '.join(wg_devs) or 'WireGuard'),
        'rules': filter_rules,
    })

    # 6. DNS ACL — compare the include file with what the links require
    _, want_subnets, _ = dns_sync_targets()
    have_subnets = set()
    if os.path.exists(UNBOUND_ACL_FILE):
        with open(UNBOUND_ACL_FILE, 'r') as f:
            for line in f:
                if line.startswith('access-control:') and len(line.split()) >= 3:
                    have_subnets.add(line.split()[1])
    missing = [n for n in want_subnets if n not in have_subnets]
    if not want_subnets:
        acl_ok, acl_detail = True, 'No links with DNS sync'
    elif missing:
        acl_ok, acl_detail = False, 'Missing for {} — run Apply'.format(', '.join(missing))
    else:
        acl_ok, acl_detail = True, 'Active for {} (file: {})'.format(', '.join(want_subnets), UNBOUND_ACL_FILE)

    checks.append({
        'name': 'DNS ACL (Unbound)',
        'ok': acl_ok,
        'detail': acl_detail,
    })

    # 7. AdGuard
    checks.append({
        'name': 'AdGuard Home',
        'ok': adguard_cfg is not None,
        'detail': 'Detected at {}'.format(adguard_cfg) if adguard_cfg else 'Not detected (using Unbound only)',
    })

    print(json.dumps({'checks': checks}, indent=2))


def cmd_log():
    """Return recent VPNLink syslog entries."""
    entries = []
    log_file = '/var/log/system/latest.log'
    if os.path.exists(log_file):
        try:
            with open(log_file, 'r') as f:
                for line in f:
                    if 'VPNLink' in line or 'vpnlink' in line:
                        # Extract timestamp and message
                        parts = line.strip().split(' ', 5)
                        if len(parts) >= 6:
                            ts = parts[1] if len(parts[1]) > 10 else ''
                            msg = parts[-1] if 'VPNLink' in parts[-1] else line.strip()
                            # Clean up syslog format
                            if 'VPNLink:' in msg:
                                msg = msg[msg.index('VPNLink:'):]
                            entries.append({'timestamp': ts, 'message': msg})
        except IOError:
            pass

    # Return last 100 entries, newest first
    entries = entries[-100:]
    entries.reverse()
    print(json.dumps({'entries': entries}, indent=2))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: vpnlink.py {start|stop|restart|status|sync_dns|healthcheck|log}')
        sys.exit(1)

    cmd = sys.argv[1]
    commands = {
        'start': cmd_start,
        'stop': cmd_stop,
        'restart': cmd_restart,
        'status': cmd_status,
        'sync_dns': cmd_sync_dns,
        'healthcheck': cmd_healthcheck,
        'log': cmd_log,
    }

    if cmd in commands:
        commands[cmd]()
    else:
        print('Unknown command: {}'.format(cmd))
        sys.exit(1)
