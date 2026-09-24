<?php

/*
 * Copyright (c) 2024-2026 The os-vpnlink contributors
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 */

/**
 * Raw config.xml (legacy sections like filter->rule aren't exposed via Config).
 * VPNLINK_CONFIG_XML may be defined to point elsewhere (tests).
 */
function vpnlink_raw_config()
{
    $path = defined('VPNLINK_CONFIG_XML') ? VPNLINK_CONFIG_XML : '/conf/config.xml';
    return @simplexml_load_file($path);
}

/**
 * True if two link sources ("any", IPv4 or IPv4/CIDR) share any address.
 * Two CIDRs overlap iff they are equal under the shorter prefix.
 */
function vpnlink_ranges_overlap($a, $b)
{
    if ($a === 'any' || $b === 'any') return true;
    $pa = explode('/', $a);
    $pb = explode('/', $b);
    $ipa = ip2long($pa[0]);
    $ipb = ip2long($pb[0]);
    if ($ipa === false || $ipb === false) return $a === $b;
    $prefix = min(isset($pa[1]) ? (int)$pa[1] : 32, isset($pb[1]) ? (int)$pb[1] : 32);
    $mask = $prefix === 0 ? 0 : ((0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF);
    return ($ipa & $mask) === ($ipb & $mask);
}

function vpnlink_enabled()
{
    $mdl = new \OPNsense\Vpnlink\Vpnlink();
    return (string)$mdl->general->enabled == '1';
}

// NOTE: No vpnlink_services() — VPN Link is not a daemon.
// It's a rule generator that runs on filter reload. Dashboard shows
// WireGuard service status instead. The Links page has its own status bar.

function vpnlink_configure()
{
    return ['vpn' => ['vpnlink_vpn_event:3']];
}

function vpnlink_vpn_event($verbose = false)
{
    if (!vpnlink_enabled()) return;
    service_log('VPNLink: syncing DNS ACL...', $verbose);
    configd_run('vpnlink sync_dns');
    service_log("done.\n", $verbose);
}

function vpnlink_syslog()
{
    return ['vpnlink' => ['facility' => ['vpnlink']]];
}

function vpnlink_cron()
{
    $jobs = [];
    if (vpnlink_enabled()) {
        $jobs[] = [
            'description' => 'VPN Link traffic collector',
            'autocron' => ['/usr/local/sbin/configctl vpnlink collect_traffic', '*'],
        ];
    }
    return $jobs;
}

/**
 * Core firewall hook — full automation.
 *
 * For each link (WG source → LAN destination):
 *   1. Clone the LAN's firewall rules onto the WG interface (mirror)
 *   2. Add a default pass-all as fallback
 *   3. Generate loopback NAT (DNS)
 *   4. Generate outbound NAT on all exit interfaces
 *
 * When plugin is disabled, all rules vanish automatically.
 */
function vpnlink_firewall($fw)
{
    syslog(LOG_DEBUG, 'VPNLink: firewall hook called');

    if (!vpnlink_enabled()) {
        syslog(LOG_DEBUG, 'VPNLink: plugin disabled, skipping');
        return;
    }

    $mdl = new \OPNsense\Vpnlink\Vpnlink();
    $tunnels = vpnlink_discover_wg_tunnels();
    if (empty($tunnels)) {
        syslog(LOG_WARNING, 'VPNLink: no WG tunnels discovered');
        return;
    }
    syslog(LOG_DEBUG, 'VPNLink: found ' . count($tunnels) . ' tunnel(s)');

    $config = \OPNsense\Core\Config::getInstance()->object();
    $processed = [];
    $linkCount = 0;
    $linkIdx = 0;
    $gateways = null;   // lazily loaded, only needed for gateway override / kill switch

    try {
        foreach ($mdl->links->link->iterateItems() as $link) {
            $linkCount++;
        }
    } catch (\Exception $e) {
        syslog(LOG_ERR, 'VPNLink: error reading links: ' . $e->getMessage());
        return;
    }

    if ($linkCount === 0) {
        syslog(LOG_NOTICE, 'VPNLink: no links configured');
        return;
    }
    syslog(LOG_NOTICE, 'VPNLink: processing ' . $linkCount . ' link(s)');

    foreach ($mdl->links->link->iterateItems() as $link) {
        if ((string)$link->enabled != '1') continue;

        $sourceRaw = (string)$link->source;
        $lanIf = (string)$link->lanInterface;
        $linkName = (string)$link->name;
        $doCloneRules = (string)($link->cloneRules ?? '1') !== '0';
        $doAutoNat = (string)($link->autoNat ?? '1') !== '0';
        $natOnLan = (string)($link->natOnLan ?? '1') !== '0';
        $killSwitch = (string)($link->killSwitch ?? '0') === '1';
        $gwOverride = trim((string)($link->gateway ?? ''));
        $linkIdx++;
        if (empty($sourceRaw) || empty($lanIf)) continue;

        if (($gwOverride !== '' || $killSwitch) && $gateways === null) {
            $gateways = vpnlink_gateway_list($config);
        }
        if ($gwOverride !== '' && !isset($gateways[$gwOverride])) {
            // Unknown gateway: core would emit the rule without route-to (= default route),
            // so drop the override rather than silently leaking via WAN.
            syslog(LOG_WARNING, "VPNLink: link '{$linkName}': gateway {$gwOverride} not found, override ignored");
            $gwOverride = '';
        }
        if (($gwOverride !== '' || $killSwitch) && !$doCloneRules) {
            syslog(LOG_WARNING, "VPNLink: link '{$linkName}': gateway override / kill switch need 'Clone firewall rules'");
        }
        $cloneOpts = [
            'gateway' => $gwOverride,
            'tag'     => $killSwitch ? 'VPNLINK_KS' . $linkIdx : '',
        ];

        syslog(LOG_NOTICE, "VPNLink: link '{$linkName}': source={$sourceRaw} -> lan={$lanIf} (clone={$doCloneRules}, nat={$doAutoNat})");

        // Resolve sources
        $sources = [];
        $srcList = array_filter(array_map('trim', explode(',', $sourceRaw)));
        if (in_array('any', $srcList, true)) {
            foreach ($tunnels as $t) {
                $sources[] = ['wgIf' => $t['interface'], 'subnet' => $t['subnet'], 'descr' => $t['description']];
            }
        } else {
            foreach ($srcList as $src) {
                // Never hand unvalidated text to the rule generator
                $src = vpnlink_valid_ipv4_source($src);
                if ($src === null) {
                    syslog(LOG_WARNING, "VPNLink: link '{$linkName}': ignoring invalid source entry");
                    continue;
                }
                // Only generate rules/NAT for addresses that belong to a known VPN tunnel,
                // otherwise a typo (e.g. a LAN IP) would get NAT/filter rules on a random tunnel.
                $wgIf = vpnlink_find_wg_interface_for_ip($src, $tunnels);
                if ($wgIf === null) {
                    syslog(LOG_WARNING, "VPNLink: link '{$linkName}': {$src} is not inside any VPN tunnel subnet, skipped");
                    continue;
                }
                $sources[] = ['wgIf' => $wgIf, 'subnet' => $src, 'descr' => $linkName];
            }
        }

        $natIfList = vpnlink_auto_discover_nat_interfaces($lanIf);
        if (!$natOnLan) {
            // LAN hosts then see the real VPN client IP (they route back via the firewall anyway)
            $natIfList = array_values(array_diff($natIfList, [$lanIf]));
        }

        if ($killSwitch && $doCloneRules) {
            vpnlink_register_kill_switch($fw, $cloneOpts['tag'], $gateways, $gwOverride, $linkName);
        }
        syslog(LOG_DEBUG, 'VPNLink: NAT interfaces: ' . implode(',', $natIfList) . ' | sources: ' . count($sources));

        foreach ($sources as $src) {
            $wgIf = $src['wgIf'];           // device name: wg0
            $wgSource = $src['subnet'];
            $desc = $src['descr'];

            // Resolve WG device name → OPNsense assigned interface or group
            $wgAssigned = vpnlink_resolve_wg_interface($wgIf);
            syslog(LOG_DEBUG, "VPNLink: generating rules for {$wgSource} on {$wgIf} (assigned: {$wgAssigned})");

            // ── 1. Clone LAN firewall rules onto WG interface ──
            // (keyed per source: every device in a link needs its own rules, the
            //  rules are scoped by `from`)
            $key = $wgAssigned . ':' . $lanIf . ':' . $wgSource;
            if ($doCloneRules && !isset($processed[$key])) {
                vpnlink_clone_lan_rules($fw, $config, $lanIf, $wgAssigned, $wgSource, $cloneOpts);
                $processed[$key] = true;
            }

            if ($doAutoNat) {
                // NOTE: No loopback NAT on WG interface needed.
                // DNS/services on OPNsense's own IPs are processed locally —
                // stateful connection tracking handles return traffic.

                // ── Outbound NAT on all exit interfaces ──
                foreach ($natIfList as $natIf) {
                    $fw->registerSNatRule(50, [
                        'interface' => $natIf,
                        'source'    => ['network' => $wgSource],
                        'destination' => ['any' => true],
                        'target'    => $natIf . 'ip',
                        'descr'     => 'VPNLink: ' . $desc . ' NAT on ' . $natIf,
                        'log' => false, '#ref' => 'ui/vpnlink',
                    ]);
                }
            } // end if ($doAutoNat)
        }
    }
}

/**
 * Clone firewall rules from a LAN interface to a WG interface.
 *
 * Reads existing rules on $lanIf from config.xml, and generates
 * equivalent rules on $wgIf with source scoped to $wgSource.
 *
 * This is the core "mirror" logic — WG clients inherit the same
 * policy routing (gateway selection), alias-based rules, and
 * pass/block decisions as LAN devices.
 *
 * A VPN client is treated as an anonymous LAN device: rules aimed at
 * specific LAN hosts/aliases are NOT inherited (otherwise e.g. an
 * "admin PC may reach the GUI" rule would open the GUI to every VPN
 * client). Anything we cannot translate faithfully fails closed.
 *
 * $opts['gateway']: egress override. Cloned pass rules that go "to any" via
 *   the default route are split into "to private/local nets" (no gateway, so
 *   LAN/firewall access keeps working) + "to any" via the override gateway.
 *   Rules that already pick a gateway, or target specific destinations, keep theirs.
 * $opts['tag']: kill switch tag put on every cloned pass rule (see
 *   vpnlink_register_kill_switch()).
 */
function vpnlink_clone_lan_rules($fw, $config, $lanIf, $wgIf, $wgSource, $opts = [])
{
    $gwOverride = $opts['gateway'] ?? '';
    $tag = $opts['tag'] ?? '';
    syslog(LOG_DEBUG, "VPNLink: cloning rules from {$lanIf} to {$wgIf} for {$wgSource}");
    $clonedCount = 0;
    $seq = 0;

    $lanNet = vpnlink_interface_network($config, $lanIf);

    foreach (vpnlink_read_filter_rules() as $rule) {
        if (!vpnlink_rule_applies_to_interface($rule, $lanIf)) continue;
        if (!$rule['enabled']) continue;
        // Only inbound rules make sense on the WG side; outbound LAN rules don't translate
        if (!in_array($rule['direction'], ['in', 'any'], true)) continue;
        // WG sources are IPv4 only; inet6 rules with IPv4 source = pf error
        if ($rule['ipprotocol'] === 'inet6') continue;
        if (!in_array($rule['action'], ['pass', 'block', 'reject'], true)) continue;

        $isPass = $rule['action'] === 'pass';

        // Does this rule's source match an anonymous LAN device?
        $srcGeneric = vpnlink_is_generic_source($rule['source'], $lanIf, $lanNet);
        $srcMatches = $rule['source_not'] ? !$srcGeneric : $srcGeneric;
        if (!$srcMatches) {
            syslog(LOG_DEBUG, "VPNLink: skip host-specific rule '{$rule['descr']}' (source={$rule['source']})");
            continue;
        }

        // Qualifiers we do not translate would widen a pass rule — skip it (fail closed).
        // For block/reject, dropping the qualifier only makes the rule stricter.
        if ($isPass && !empty($rule['unsupported'])) {
            syslog(LOG_NOTICE, "VPNLink: skip pass rule '{$rule['descr']}' on {$lanIf}: uses " . implode(',', $rule['unsupported']));
            continue;
        }

        $seq++;
        $proto = strtolower($rule['protocol']);

        $ruleConfig = [
            'interface'  => $wgIf,
            'direction'  => 'in',
            'from'       => $wgSource,
            'descr'      => 'VPNLink [' . $lanIf . ']: ' . $rule['descr'],
            '#ref'       => 'ui/vpnlink',
        ];

        if ($proto !== '' && $proto !== 'any') $ruleConfig['protocol'] = $proto;
        // Ports are only valid for tcp/udp
        if (in_array($proto, ['tcp', 'udp', 'tcp/udp'], true)) {
            if ($rule['source_port'] !== '') $ruleConfig['from_port'] = $rule['source_port'];
            if ($rule['destination_port'] !== '') $ruleConfig['to_port'] = $rule['destination_port'];
        }
        if ($proto === 'icmp' && $rule['icmptype'] !== '') $ruleConfig['icmptype'] = $rule['icmptype'];
        if ($isPass && $rule['gateway'] !== '') $ruleConfig['gateway'] = $rule['gateway'];
        if ($rule['destination'] !== '' && $rule['destination'] !== 'any') {
            $ruleConfig['to'] = $rule['destination'];
            if ($rule['destination_not']) $ruleConfig['to_not'] = true;
        }
        if ($rule['log']) $ruleConfig['log'] = true;

        $defaults = [
            'ipprotocol' => 'inet',   // inet46 would expand to an invalid inet6 rule with an IPv4 source
            'type'       => $rule['action'],
            'quick'      => $rule['quick'],
            'statetype'  => 'keep',
        ];

        if ($isPass && $tag !== '') $ruleConfig['tag'] = $tag;

        $overrideable = $isPass && $gwOverride !== '' && $rule['gateway'] === '';
        if ($overrideable && !isset($ruleConfig['to'])) {
            // local destinations first, without route-to
            $localRule = $ruleConfig;
            $localRule['to'] = vpnlink_local_nets();
            $localRule['descr'] .= ' (local)';
            $fw->registerFilterRule(399900 + $seq, $localRule, $defaults);
            $seq++;
            $ruleConfig['gateway'] = $gwOverride;
            $ruleConfig['descr'] .= ' (via ' . $gwOverride . ')';
        } elseif ($overrideable && !empty($ruleConfig['to_not'])) {
            // "to !X" rules (the usual selective-routing pattern) already exclude local nets
            $ruleConfig['gateway'] = $gwOverride;
        }

        // Use priority 399900 + sequence to keep order before user's manual WG rules
        $fw->registerFilterRule(399900 + $seq, $ruleConfig, $defaults);
        $clonedCount++;
    }

    // No fallback pass-all: a LAN without (applicable) rules is default-deny,
    // so the mirrored VPN clients must be too.
    if ($clonedCount === 0) {
        syslog(LOG_WARNING, "VPNLink: no applicable rules on {$lanIf}; {$wgSource} on {$wgIf} gets no pass rules (default deny)");
    }

    syslog(LOG_NOTICE, "VPNLink: cloned {$clonedCount} rules from {$lanIf} to {$wgIf} for {$wgSource}");
}

/**
 * Destinations that never take the override gateway: the firewall itself + private ranges.
 * (plain function instead of a constant: plugin files can be included more than once)
 */
function vpnlink_local_nets()
{
    return '(self),10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16';
}

/**
 * All known gateways: name => ['interface' => logical ifname, 'proto' => inet|inet6, 'uplink' => bool].
 * Gateway groups are included with the union of their members' interfaces.
 * Uses the Gateways model (includes dynamic OpenVPN/WG gateways) and falls back
 * to the static config entries on older releases.
 */
function vpnlink_gateway_list($config)
{
    $devOf = [];
    if (isset($config->interfaces)) {
        foreach ($config->interfaces->children() as $ifname => $ifcfg) {
            $devOf[$ifname] = (string)($ifcfg->if ?? '');
        }
    }
    $isTunnel = function ($dev) {
        return (bool)preg_match('/^(wg|ovpn|gre|gif|ipsec|enc|tun|tap|tailscale|zt|ocserv)/', $dev);
    };

    $result = [];
    try {
        foreach ((new \OPNsense\Routing\Gateways())->gatewaysIndexedByName() as $name => $gw) {
            $if = (string)($gw['interface'] ?? '');
            $result[$name] = [
                'interfaces' => [$if],
                'proto'      => (string)($gw['ipprotocol'] ?? 'inet'),
                'uplink'     => !$isTunnel((string)($gw['if'] ?? ($devOf[$if] ?? ''))),
            ];
        }
    } catch (\Throwable $e) {
        $items = [];
        if (isset($config->OPNsense->Gateways->gateway_item)) $items = $config->OPNsense->Gateways->gateway_item;
        elseif (isset($config->gateways->gateway_item)) $items = $config->gateways->gateway_item;
        foreach ($items as $gw) {
            $if = (string)$gw->interface;
            $result[(string)$gw->name] = [
                'interfaces' => [$if],
                'proto'      => (string)($gw->ipprotocol ?? 'inet') ?: 'inet',
                'uplink'     => !$isTunnel($devOf[$if] ?? ''),
            ];
        }
    }

    // gateway groups: <item>GWNAME|tier|trigger</item>
    if (isset($config->gateways->gateway_group)) {
        foreach ($config->gateways->gateway_group as $grp) {
            $ifs = [];
            $proto = 'inet';
            foreach ($grp->item as $item) {
                $member = explode('|', (string)$item)[0];
                if (isset($result[$member])) {
                    $ifs = array_merge($ifs, $result[$member]['interfaces']);
                    $proto = $result[$member]['proto'];
                }
            }
            $result[(string)$grp->name] = ['interfaces' => array_values(array_unique($ifs)), 'proto' => $proto, 'uplink' => false, 'group' => true];
        }
    }
    return $result;
}

/**
 * Kill switch: packets from the link's pass rules carry $tag; block them from
 * leaving on any physical uplink (WAN, WAN2, ...) other than the one the
 * override gateway uses. Same approach as the OPNsense selective-routing
 * how-to (tag + floating "block out tagged"), so it holds even when a gateway
 * is down and route-to silently falls back to the default route.
 */
function vpnlink_register_kill_switch($fw, $tag, $gateways, $gwOverride, $linkName)
{
    $allowed = $gwOverride !== '' ? ($gateways[$gwOverride]['interfaces'] ?? []) : [];
    $uplinks = ['wan'];
    foreach ((array)$gateways as $gw) {
        if (!empty($gw['uplink'])) $uplinks = array_merge($uplinks, $gw['interfaces']);
    }
    $blockOn = array_values(array_diff(array_unique(array_filter($uplinks)), $allowed));

    foreach ($blockOn as $ifname) {
        $fw->registerFilterRule(199000, [
            'interface' => $ifname,
            'direction' => 'out',
            'tagged'    => $tag,
            'descr'     => 'VPNLink: kill switch for ' . $linkName,
            'log'       => true,
            '#ref'      => 'ui/vpnlink',
        ], ['type' => 'block', 'quick' => true, 'ipprotocol' => 'inet']);
    }
    syslog(LOG_DEBUG, "VPNLink: kill switch '{$linkName}' blocks egress on " . implode(',', $blockOn));
}

/**
 * Read all interface filter rules from config.xml, normalized to one format.
 *
 * MVC rules (OPNsense->Firewall->Filter, 24.x+ automation / 26.x interface rules)
 * use enabled/action/source_net/destination_net and are ordered by `sequence`.
 * Legacy rules (filter->rule) use disabled/type/source{}/destination{} in file order.
 * MVC rules are registered before legacy rules by core, so they come first here too.
 */
function vpnlink_read_filter_rules()
{
    $rawConfig = vpnlink_raw_config();
    if ($rawConfig === false) {
        syslog(LOG_ERR, 'VPNLink: failed to read /conf/config.xml');
        return [];
    }

    $mvcRules = [];
    if (isset($rawConfig->OPNsense->Firewall->Filter->rules->rule)) {
        foreach ($rawConfig->OPNsense->Firewall->Filter->rules->rule as $r) {
            $unsupported = [];
            foreach (['sched', 'tagged', 'received-on', 'tcpflags1', 'tcpflags2', 'tos', 'prio'] as $f) {
                if ((string)($r->{$f} ?? '') !== '') $unsupported[] = $f;
            }
            $mvcRules[] = [
                'sequence'         => (int)($r->sequence ?? 0),
                'enabled'          => (string)($r->enabled ?? '1') === '1',
                'action'           => (string)($r->action ?? '') ?: 'pass',
                'quick'            => (string)($r->quick ?? '1') !== '0',
                'interface'        => (string)($r->interface ?? ''),
                'interfacenot'     => (string)($r->interfacenot ?? '0') === '1',
                'direction'        => (string)($r->direction ?? '') ?: 'in',
                'ipprotocol'       => (string)($r->ipprotocol ?? '') ?: 'inet',
                'protocol'         => (string)($r->protocol ?? ''),
                'icmptype'         => (string)($r->icmptype ?? ''),
                'source'           => (string)($r->source_net ?? '') ?: 'any',
                'source_not'       => (string)($r->source_not ?? '0') === '1',
                'source_port'      => (string)($r->source_port ?? ''),
                'destination'      => (string)($r->destination_net ?? '') ?: 'any',
                'destination_not'  => (string)($r->destination_not ?? '0') === '1',
                'destination_port' => (string)($r->destination_port ?? ''),
                'gateway'          => (string)($r->gateway ?? ''),
                'log'              => (string)($r->log ?? '0') === '1',
                'descr'            => (string)($r->description ?? ''),
                'unsupported'      => $unsupported,
            ];
        }
        // stable sort by sequence (core evaluates MVC rules in sequence order)
        // usort is stable since PHP 8.0, so equal sequences keep config order
        usort($mvcRules, function ($a, $b) {
            return $a['sequence'] <=> $b['sequence'];
        });
    }

    $legacyRules = [];
    if (isset($rawConfig->filter->rule)) {
        foreach ($rawConfig->filter->rule as $r) {
            if (isset($r->floating) && (string)$r->floating !== '') continue; // floating rules stay floating
            $unsupported = [];
            foreach (['sched', 'tagged', 'os', 'tcpflags1', 'tcpflags2', 'tos', 'prio'] as $f) {
                if ((string)($r->{$f} ?? '') !== '') $unsupported[] = $f;
            }
            $legacyRules[] = [
                'enabled'          => !isset($r->disabled) || (string)$r->disabled === '0',
                'action'           => (string)($r->type ?? '') ?: 'pass',
                'quick'            => true,
                'interface'        => (string)($r->interface ?? ''),
                'interfacenot'     => isset($r->interfacenot) && (string)$r->interfacenot !== '0',
                'direction'        => (string)($r->direction ?? '') ?: 'in',
                'ipprotocol'       => (string)($r->ipprotocol ?? '') ?: 'inet',
                'protocol'         => (string)($r->protocol ?? ''),
                'icmptype'         => (string)($r->icmptype ?? ''),
                'source'           => vpnlink_legacy_address($r->source ?? null),
                'source_not'       => isset($r->source->not),
                'source_port'      => (string)($r->source->port ?? ''),
                'destination'      => vpnlink_legacy_address($r->destination ?? null),
                'destination_not'  => isset($r->destination->not),
                'destination_port' => (string)($r->destination->port ?? ''),
                'gateway'          => (string)($r->gateway ?? ''),
                'log'              => isset($r->log) && (string)$r->log !== '0',
                'descr'            => (string)($r->descr ?? ''),
                'unsupported'      => $unsupported,
            ];
        }
    }

    return array_merge($mvcRules, $legacyRules);
}

/**
 * Legacy <source>/<destination> → address string understood by core
 * (network name like "lan"/"lanip"/"(self)", alias name, or IP/CIDR).
 */
function vpnlink_legacy_address($node)
{
    if ($node === null) return 'any';
    if ((string)($node->network ?? '') !== '') return (string)$node->network;
    if ((string)($node->address ?? '') !== '') return (string)$node->address;
    return 'any';
}

function vpnlink_rule_applies_to_interface($rule, $ifname)
{
    $ifs = array_filter(array_map('trim', explode(',', $rule['interface'])));
    $listed = in_array($ifname, $ifs, true);
    return $rule['interfacenot'] ? !$listed : $listed;
}

/**
 * True if a rule source covers "any device on this LAN" (any, "lan" network,
 * or the LAN's literal CIDR) rather than specific hosts/aliases.
 */
function vpnlink_is_generic_source($source, $lanIf, $lanNet)
{
    $items = array_filter(array_map('trim', explode(',', $source)));
    if (empty($items)) return true;
    foreach ($items as $item) {
        if ($item === 'any' || $item === $lanIf) return true;
        if ($lanNet !== null && vpnlink_addr_to_network($item) === $lanNet) return true;
    }
    return false;
}

/**
 * Network (CIDR) of an assigned interface with a static IPv4, or null.
 */
function vpnlink_interface_network($config, $ifname)
{
    if (!isset($config->interfaces->{$ifname})) return null;
    $ifcfg = $config->interfaces->{$ifname};
    $ip = (string)($ifcfg->ipaddr ?? '');
    $bits = (string)($ifcfg->subnet ?? '');
    if ($ip === '' || $bits === '') return null;
    return vpnlink_addr_to_network($ip . '/' . $bits);
}

/**
 * Validate a single IPv4 address or IPv4 CIDR. Returns the normalized
 * string, or null when invalid.
 */
function vpnlink_valid_ipv4_source($src)
{
    $parts = explode('/', $src);
    if (count($parts) > 2) return null;
    if (filter_var($parts[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) return null;
    if (count($parts) === 1) return $parts[0];
    if (!ctype_digit($parts[1]) || (int)$parts[1] > 32) return null;
    return $parts[0] . '/' . (int)$parts[1];
}

/**
 * Resolve VPN device name to OPNsense assigned interface name.
 * If assigned (e.g. opt5), return that. Otherwise try group names.
 */
function vpnlink_resolve_wg_interface($devName)
{
    $config = \OPNsense\Core\Config::getInstance()->object();
    if (isset($config->interfaces)) {
        foreach ($config->interfaces->children() as $ifname => $ifcfg) {
            if ((string)($ifcfg->if ?? '') === $devName) {
                syslog(LOG_DEBUG, "VPNLink: {$devName} is assigned as {$ifname}");
                return $ifname;
            }
        }
    }

    // Not assigned — try interface group based on VPN type
    if (strpos($devName, 'wg') === 0) {
        syslog(LOG_NOTICE, "VPNLink: {$devName} not assigned, using 'wireguard' group");
        return 'wireguard';
    } elseif (strpos($devName, 'ovpns') === 0) {
        syslog(LOG_NOTICE, "VPNLink: {$devName} not assigned, using 'openvpn' group");
        return 'openvpn';
    }

    syslog(LOG_WARNING, "VPNLink: {$devName} not assigned and no group available");
    return $devName;
}

/**
 * Auto-discover all interfaces to NAT on: WAN + target LAN + all gateways.
 */
function vpnlink_auto_discover_nat_interfaces($lanInterface)
{
    $ifList = ['wan'];
    if (!empty($lanInterface) && !in_array($lanInterface, $ifList)) {
        $ifList[] = $lanInterface;
    }

    $config = \OPNsense\Core\Config::getInstance()->object();

    // 1. Add gateway interfaces from config
    if (isset($config->gateways) && isset($config->gateways->gateway_item)) {
        foreach ($config->gateways->gateway_item as $gw) {
            if ((string)($gw->disabled ?? '0') == '1') continue;
            $gwIf = (string)$gw->interface;
            if (!empty($gwIf) && !in_array($gwIf, $ifList)) {
                $ifList[] = $gwIf;
            }
        }
    }

    // 2. Add all OpenVPN/tunnel interfaces (dynamic gateways not in gateway_item)
    if (isset($config->interfaces)) {
        foreach ($config->interfaces->children() as $ifname => $ifcfg) {
            $ifdev = (string)($ifcfg->if ?? '');
            // Match OpenVPN (ovpnc*, ovpns*), GRE, GIF, IPsec tunnel interfaces
            if (preg_match('/^(ovpn|gre|gif|ipsec)/', $ifdev)) {
                if (!in_array($ifname, $ifList)) {
                    $ifList[] = $ifname;
                }
            }
        }
    }

    syslog(LOG_DEBUG, 'VPNLink: auto-discovered NAT interfaces: ' . implode(',', $ifList));
    return $ifList;
}

function vpnlink_find_wg_interface_for_ip($deviceIp, $tunnels)
{
    $ip = explode('/', $deviceIp)[0];
    $ipLong = ip2long($ip);
    if ($ipLong === false) return null;

    foreach ($tunnels as $t) {
        $parts = explode('/', $t['subnet']);
        if (count($parts) != 2) continue;
        $netLong = ip2long($parts[0]);
        $prefix = intval($parts[1]);
        $mask = $prefix == 0 ? 0 : (~0 << (32 - $prefix));
        if (($ipLong & $mask) == ($netLong & $mask)) return $t['interface'];
    }
    return null;
}

/**
 * Discover ALL VPN server tunnels — WireGuard, OpenVPN, IPsec, OpenConnect, etc.
 */
function vpnlink_discover_wg_tunnels()
{
    $tunnels = [];

    // ── 1. WireGuard (core since 24.1) ──
    try {
        $serverModel = new \OPNsense\Wireguard\Server();
        foreach ($serverModel->servers->server->iterateItems() as $server) {
            if ((string)$server->enabled != '1') continue;
            $tunnelAddress = (string)$server->tunneladdress;
            if (empty($tunnelAddress)) continue;

            foreach (array_map('trim', explode(',', $tunnelAddress)) as $addr) {
                if (strpos($addr, ':') !== false) continue;
                $subnet = vpnlink_addr_to_network($addr);
                if ($subnet === null) continue;
                $tunnels[] = [
                    'interface' => 'wg' . (string)$server->instance,
                    'subnet'    => $subnet,
                    'description' => (string)$server->name ?: ('wg' . (string)$server->instance),
                    'type'      => 'wireguard',
                ];
            }
        }
    } catch (\Exception $e) {
        syslog(LOG_WARNING, 'VPNLink: WG Server model failed: ' . $e->getMessage());
    }

    // ── 2. OpenVPN Server (core) ──
    $rawConfig = vpnlink_raw_config();
    if ($rawConfig !== false && isset($rawConfig->openvpn)) {
        if (isset($rawConfig->openvpn->{'openvpn-server'})) {
            foreach ($rawConfig->openvpn->{'openvpn-server'} as $ovpn) {
                $mode = (string)($ovpn->mode ?? '');
                $disabled = (string)($ovpn->disable ?? '');
                if ($disabled === '1') continue;

                $tunnelNet = (string)($ovpn->tunnel_network ?? '');
                $vpnid = (string)($ovpn->vpnid ?? '');
                $descr = (string)($ovpn->description ?? 'OpenVPN Server');

                if (!empty($tunnelNet) && !empty($vpnid)) {
                    $subnet = vpnlink_addr_to_network($tunnelNet);
                    if ($subnet !== null) {
                        $tunnels[] = [
                            'interface' => 'ovpns' . $vpnid,
                            'subnet'    => $subnet,
                            'description' => $descr ?: ('ovpns' . $vpnid),
                            'type'      => 'openvpn',
                        ];
                    }
                }
            }
        }
    }

    // ── 3. IPsec (core) — discover from interface assignments ──
    // IPsec tunnels use enc0 or ipsec* interfaces
    $config = \OPNsense\Core\Config::getInstance()->object();
    if (isset($config->interfaces)) {
        foreach ($config->interfaces->children() as $ifname => $ifcfg) {
            $ifdev = (string)($ifcfg->if ?? '');
            $ipaddr = (string)($ifcfg->ipaddr ?? '');
            $bits = (string)($ifcfg->subnet ?? '');

            if (preg_match('/^(enc|ipsec)/', $ifdev) && !empty($ipaddr) && !empty($bits)) {
                $net = vpnlink_addr_to_network($ipaddr . '/' . $bits);
                if ($net !== null) {
                    $tunnels[] = [
                        'interface' => $ifname,
                        'subnet'    => $net,
                        'description' => (string)($ifcfg->descr ?? $ifdev),
                        'type'      => 'ipsec',
                    ];
                }
            }
        }
    }

    // ── 4. Generic: any other VPN-like interface (Tailscale, ZeroTier, OpenConnect, etc.) ──
    if (isset($config->interfaces)) {
        foreach ($config->interfaces->children() as $ifname => $ifcfg) {
            $ifdev = (string)($ifcfg->if ?? '');
            $ipaddr = (string)($ifcfg->ipaddr ?? '');
            $bits = (string)($ifcfg->subnet ?? '');

            // Match tun*, tap*, tailscale*, zt*, ocserv* — but not already discovered
            if (preg_match('/^(tun|tap|tailscale|zt|zerotier|ocserv)/', $ifdev) && !empty($ipaddr) && !empty($bits)) {
                // Check not already in tunnels
                $already = false;
                foreach ($tunnels as $t) {
                    if ($t['interface'] === $ifname) { $already = true; break; }
                }
                if ($already) continue;

                $net = vpnlink_addr_to_network($ipaddr . '/' . $bits);
                if ($net !== null) {
                    $type = 'other';
                    if (strpos($ifdev, 'tailscale') === 0) $type = 'tailscale';
                    elseif (strpos($ifdev, 'zt') === 0 || strpos($ifdev, 'zerotier') === 0) $type = 'zerotier';
                    elseif (strpos($ifdev, 'ocserv') === 0) $type = 'openconnect';

                    $tunnels[] = [
                        'interface' => $ifname,
                        'subnet'    => $net,
                        'description' => (string)($ifcfg->descr ?? $ifdev),
                        'type'      => $type,
                    ];
                }
            }
        }
    }

    // ── Fallback: WG from interface assignments (if model failed) ──
    $hasWg = false;
    foreach ($tunnels as $t) { if ($t['type'] === 'wireguard') { $hasWg = true; break; } }
    if (!$hasWg) {
        if (isset($config->interfaces)) {
            foreach ($config->interfaces->children() as $ifname => $ifcfg) {
                if (strpos((string)$ifcfg->if, 'wg') !== 0) continue;
                $ipaddr = (string)($ifcfg->ipaddr ?? '');
                $bits = (string)($ifcfg->subnet ?? '');
                if (!empty($ipaddr) && !empty($bits)) {
                    $net = vpnlink_addr_to_network($ipaddr . '/' . $bits);
                    if ($net !== null) {
                        $tunnels[] = ['interface' => $ifname, 'subnet' => $net, 'description' => (string)($ifcfg->descr ?? (string)$ifcfg->if), 'type' => 'wireguard'];
                    }
                }
            }
        }
    }

    syslog(LOG_DEBUG, 'VPNLink: discovered ' . count($tunnels) . ' VPN tunnel(s): ' .
        implode(', ', array_map(function($t) { return $t['type'] . ':' . $t['interface']; }, $tunnels)));

    return $tunnels;
}

function vpnlink_addr_to_network($addr)
{
    $parts = explode('/', $addr);
    if (count($parts) != 2) return null;
    $prefix = intval($parts[1]);
    if ($prefix < 0 || $prefix > 32) return null;
    $ipLong = ip2long($parts[0]);
    if ($ipLong === false) return null;
    $mask = $prefix == 0 ? 0 : (~0 << (32 - $prefix));
    return long2ip($ipLong & $mask) . '/' . $prefix;
}
