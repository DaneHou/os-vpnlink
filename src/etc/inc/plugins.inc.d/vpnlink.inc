<?php

/*
 * Copyright (c) 2024-2026 DaneBA
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

function vpnlink_enabled()
{
    $mdl = new \OPNsense\VPNLink\VPNLink();
    return (string)$mdl->general->enabled == '1';
}

/**
 * Register with OPNsense service manager.
 */
function vpnlink_services()
{
    $services = [];

    if (!vpnlink_enabled()) {
        return $services;
    }

    $services[] = [
        'description' => 'VPN Link Orchestrator',
        'configd' => [
            'start'   => ['vpnlink start'],
            'restart' => ['vpnlink restart'],
            'stop'    => ['vpnlink stop'],
        ],
        'name' => 'vpnlink',
    ];

    return $services;
}

/**
 * Boot handler: apply rules after VPN interfaces come up.
 */
function vpnlink_configure()
{
    return [
        'vpn' => ['vpnlink_vpn_event:3'],
    ];
}

function vpnlink_vpn_event($verbose = false)
{
    if (!vpnlink_enabled()) {
        return;
    }

    service_log('VPNLink: VPN event detected, syncing DNS ACL...', $verbose);
    configd_run('vpnlink sync_dns');
    service_log("done.\n", $verbose);
}

/**
 * Register syslog target.
 */
function vpnlink_syslog()
{
    return [
        'vpnlink' => ['facility' => ['vpnlink']],
    ];
}

/**
 * ============================================================================
 * CORE FIREWALL HOOK
 * ============================================================================
 *
 * Called on every `filter reload`. Generates all NAT and filter rules.
 *
 * Solves 4 problems:
 *
 * 1. DNS Access & Loopback NAT
 *    - Pass rule on WG interface to allow DNS to reach OPNsense (self)
 *    - Loopback SNAT so DNS replies route back through the WG tunnel
 *
 * 2. Outbound NAT on EVERY exit interface
 *    - WAN, LAN, OpenVPN gateways, any interface the traffic may cross
 *    - WG client IP is masqueraded to the exit interface IP
 *
 * 3. Per-device Traffic Steering
 *    - DeviceLink rules: specific WG client IP -> specific gateway
 *    - Optional target alias: only matching destinations use the gateway
 *
 * 4. Automation
 *    - All rules auto-generated from model config, zero manual setup
 */
function vpnlink_firewall($fw)
{
    if (!vpnlink_enabled()) {
        return;
    }

    $mdl = new \OPNsense\VPNLink\VPNLink();
    $mode = (string)$mdl->general->mode;
    $autoNat = (string)$mdl->general->autoNat == '1';
    $lanInterface = (string)$mdl->general->lanInterface;
    $lanSubnets = (string)$mdl->general->lanSubnets;
    $natInterfaces = (string)$mdl->general->natInterfaces;

    // Discover WireGuard tunnel interfaces and their subnets
    $tunnels = vpnlink_discover_wg_tunnels();

    if (empty($tunnels)) {
        return;
    }

    // Build list of interfaces to NAT on
    $natIfList = vpnlink_get_nat_interfaces($natInterfaces, $lanInterface);

    foreach ($tunnels as $tunnel) {
        $wgIf = $tunnel['interface'];
        $wgSubnet = $tunnel['subnet'];
        $wgDescr = $tunnel['description'] ?? $wgIf;

        // ──────────────────────────────────────────────────────────────
        // [Req 1] Pass rule on WG interface — allow all inbound traffic
        // ──────────────────────────────────────────────────────────────
        $fw->registerFilterRule(
            1,
            [
                'interface'  => $wgIf,
                'direction'  => 'in',
                'descr'      => 'VPNLink: Pass inbound on ' . $wgDescr,
                '#ref'       => 'ui/vpnlink',
            ],
            [
                'type'       => 'pass',
                'quick'      => true,
                'statetype'  => 'keep',
            ]
        );

        // ──────────────────────────────────────────────────────────────
        // [Req 1] Loopback NAT — DNS & services on OPNsense itself
        // When WG client queries 192.168.68.1 (LAN2 IP), the packet
        // enters via WG but the destination is OPNsense's own LAN IP.
        // SNAT on loopback ensures reply state tracks correctly.
        // ──────────────────────────────────────────────────────────────
        if ($autoNat) {
            // NAT on the WG interface itself for traffic to (self)
            // This handles DNS queries to any OPNsense-owned IP
            $fw->registerSNatRule(
                40,
                [
                    'interface'   => $wgIf,
                    'source'      => ['network' => $wgSubnet],
                    'destination' => ['any' => true],
                    'target'      => $wgIf . 'ip',
                    'descr'       => 'VPNLink: Loopback NAT on ' . $wgDescr,
                    'log'         => false,
                    '#ref'        => 'ui/vpnlink',
                ]
            );
        }

        if ($mode === 'lan_equal') {
            // ──────────────────────────────────────────────────────────
            // [Req 2] Outbound NAT on EVERY exit interface
            // Masquerade WG client traffic so it looks like it came
            // from that interface's IP. This is critical for:
            //   - WAN: internet access
            //   - LAN2: access LAN resources, inherit firewall rules
            //   - ovpnc1: traffic steered to VPN gateway
            //   - Any other interface in the path
            // ──────────────────────────────────────────────────────────
            if ($autoNat) {
                foreach ($natIfList as $natIf) {
                    $fw->registerSNatRule(
                        50,
                        [
                            'interface'   => $natIf,
                            'source'      => ['network' => $wgSubnet],
                            'destination' => ['any' => true],
                            'target'      => $natIf . 'ip',
                            'descr'       => 'VPNLink: NAT ' . $wgDescr . ' on ' . $natIf,
                            'log'         => false,
                            '#ref'        => 'ui/vpnlink',
                        ]
                    );
                }
            }

        } elseif ($mode === 'intranet') {
            // Intranet Only: restrict to specified LAN subnets
            if (!empty($lanSubnets)) {
                $subnets = array_map('trim', explode(',', $lanSubnets));
                foreach ($subnets as $subnet) {
                    if (empty($subnet)) {
                        continue;
                    }
                    $fw->registerFilterRule(
                        1,
                        [
                            'interface'  => $wgIf,
                            'from'       => $wgSubnet,
                            'to'         => $subnet,
                            'direction'  => 'in',
                            'descr'      => 'VPNLink: Intranet ' . $wgDescr . ' -> ' . $subnet,
                            '#ref'       => 'ui/vpnlink',
                        ],
                        [
                            'type'       => 'pass',
                            'quick'      => true,
                            'statetype'  => 'keep',
                        ]
                    );
                }
            }

            // NAT on LAN interfaces for intranet traffic
            if ($autoNat) {
                $lanIfs = array_map('trim', explode(',', $lanInterface));
                foreach ($lanIfs as $lif) {
                    if (empty($lif)) {
                        continue;
                    }
                    $fw->registerSNatRule(
                        50,
                        [
                            'interface'   => $lif,
                            'source'      => ['network' => $wgSubnet],
                            'destination' => ['any' => true],
                            'target'      => $lif . 'ip',
                            'descr'       => 'VPNLink: Intranet NAT ' . $wgDescr . ' on ' . $lif,
                            'log'         => false,
                            '#ref'        => 'ui/vpnlink',
                        ]
                    );
                }
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // [Req 3] Per-device Traffic Steering (DeviceLink rules)
    //
    // For each device link:
    //   - If gateway is set: create a filter rule that forces the device's
    //     traffic through that gateway (pf route-to)
    //   - If targetAlias is set: only matching destinations use the gateway
    //   - If targetAlias is empty: ALL traffic from that device uses the gateway
    // ──────────────────────────────────────────────────────────────────
    vpnlink_generate_device_steering($fw, $mdl, $tunnels);
}

/**
 * Generate per-device steering rules from DeviceLink model.
 */
function vpnlink_generate_device_steering($fw, $mdl, $tunnels)
{
    if (!property_exists($mdl, 'devicelinks') ||
        !property_exists($mdl->devicelinks, 'devicelink')) {
        return;
    }

    // Find the WG interface for a given device IP
    // We need to know which WG interface the device connects through
    foreach ($mdl->devicelinks->devicelink->iterateItems() as $link) {
        if ((string)$link->enabled != '1') {
            continue;
        }

        $deviceName = (string)$link->name;
        $tunnelIp = (string)$link->tunnelIp;
        $gateway = (string)$link->gateway;
        $targetAlias = (string)$link->targetAlias;
        $descr = (string)$link->description ?: $deviceName;

        if (empty($tunnelIp) || empty($gateway)) {
            continue;
        }

        // Determine which WG interface this device is on
        $wgIf = vpnlink_find_wg_interface_for_ip($tunnelIp, $tunnels);
        if ($wgIf === null) {
            // Can't determine interface, use first tunnel
            $wgIf = !empty($tunnels) ? $tunnels[0]['interface'] : null;
        }

        if ($wgIf === null) {
            continue;
        }

        // Normalize IP (add /32 if no CIDR)
        if (strpos($tunnelIp, '/') === false) {
            $sourceIp = $tunnelIp;
        } else {
            $sourceIp = $tunnelIp;
        }

        // Build the filter rule with gateway routing
        $ruleConfig = [
            'interface'  => $wgIf,
            'from'       => $sourceIp,
            'direction'  => 'in',
            'gateway'    => $gateway,
            'descr'      => 'VPNLink: Steer ' . $descr . ' via ' . $gateway,
            '#ref'       => 'ui/vpnlink',
        ];

        // If target alias is set, only match those destinations
        if (!empty($targetAlias)) {
            $ruleConfig['to'] = '$' . $targetAlias;
            $ruleConfig['descr'] .= ' (dest: ' . $targetAlias . ')';
        }

        // Register at high priority so it matches before the general pass rule
        // Priority 100000 = force gateway rules range
        $fw->registerFilterRule(
            100000,
            $ruleConfig,
            [
                'type'       => 'pass',
                'quick'      => true,
                'statetype'  => 'keep',
            ]
        );
    }
}

/**
 * Find which WG interface a device IP belongs to.
 */
function vpnlink_find_wg_interface_for_ip($deviceIp, $tunnels)
{
    // Strip CIDR if present
    $ip = explode('/', $deviceIp)[0];
    $ipLong = ip2long($ip);

    if ($ipLong === false) {
        return null;
    }

    foreach ($tunnels as $tunnel) {
        $parts = explode('/', $tunnel['subnet']);
        if (count($parts) != 2) {
            continue;
        }
        $netLong = ip2long($parts[0]);
        $prefix = intval($parts[1]);
        $mask = $prefix == 0 ? 0 : (~0 << (32 - $prefix));

        if (($ipLong & $mask) == ($netLong & $mask)) {
            return $tunnel['interface'];
        }
    }

    return null;
}

/**
 * Build the complete list of interfaces to generate outbound NAT on.
 *
 * Merges:
 *   - User-specified natInterfaces (e.g. "wan,ovpnc1,ovpnc2")
 *   - User-specified lanInterface (e.g. "opt1")
 *   - Always includes 'wan' as fallback
 */
function vpnlink_get_nat_interfaces($natInterfaces, $lanInterface)
{
    $ifList = [];

    // Always include WAN
    $ifList[] = 'wan';

    // Add LAN interface(s)
    if (!empty($lanInterface)) {
        foreach (array_map('trim', explode(',', $lanInterface)) as $lif) {
            if (!empty($lif) && !in_array($lif, $ifList)) {
                $ifList[] = $lif;
            }
        }
    }

    // Add explicitly configured NAT interfaces (VPN gateways, etc.)
    if (!empty($natInterfaces)) {
        foreach (array_map('trim', explode(',', $natInterfaces)) as $nif) {
            if (!empty($nif) && !in_array($nif, $ifList)) {
                $ifList[] = $nif;
            }
        }
    }

    return $ifList;
}

// ============================================================================
// WireGuard Tunnel Discovery
// ============================================================================

/**
 * Discover WireGuard server tunnels and their assigned subnets.
 */
function vpnlink_discover_wg_tunnels()
{
    $tunnels = [];

    try {
        $wg = new \OPNsense\Wireguard\General();
    } catch (\Exception $e) {
        syslog(LOG_WARNING, 'VPNLink: WireGuard model not found: ' . $e->getMessage());
        return vpnlink_discover_wg_from_interfaces();
    }

    if (property_exists($wg, 'servers') && property_exists($wg->servers, 'server')) {
        foreach ($wg->servers->server->iterateItems() as $server) {
            if ((string)$server->enabled != '1') {
                continue;
            }

            $tunnelAddress = (string)$server->tunneladdress;
            if (empty($tunnelAddress)) {
                continue;
            }

            $addresses = array_map('trim', explode(',', $tunnelAddress));
            foreach ($addresses as $addr) {
                if (strpos($addr, ':') !== false) {
                    continue;
                }

                $subnet = vpnlink_addr_to_network($addr);
                if ($subnet === null) {
                    continue;
                }

                $ifName = 'wg' . (string)$server->instance;
                $tunnels[] = [
                    'interface'   => $ifName,
                    'subnet'      => $subnet,
                    'description' => (string)$server->name ?: $ifName,
                ];
            }
        }
    }

    if (empty($tunnels)) {
        $tunnels = vpnlink_discover_wg_from_interfaces();
    }

    return $tunnels;
}

/**
 * Fallback: discover WG tunnels from OPNsense interface assignments.
 */
function vpnlink_discover_wg_from_interfaces()
{
    $tunnels = [];
    $config = \OPNsense\Core\Config::getInstance()->object();

    if (!isset($config->interfaces)) {
        return $tunnels;
    }

    foreach ($config->interfaces->children() as $ifname => $ifcfg) {
        $ifdev = (string)$ifcfg->if;
        if (strpos($ifdev, 'wg') !== 0) {
            continue;
        }

        $ipaddr = (string)($ifcfg->ipaddr ?? '');
        $subnet_bits = (string)($ifcfg->subnet ?? '');

        if (!empty($ipaddr) && !empty($subnet_bits)) {
            $network = vpnlink_addr_to_network($ipaddr . '/' . $subnet_bits);
            if ($network !== null) {
                $tunnels[] = [
                    'interface'   => $ifname,
                    'subnet'      => $network,
                    'description' => (string)($ifcfg->descr ?? $ifdev),
                ];
            }
        }
    }

    return $tunnels;
}

/**
 * Convert a host/prefix address to its network address.
 * e.g. "10.10.10.1/24" -> "10.10.10.0/24"
 */
function vpnlink_addr_to_network($addr)
{
    $parts = explode('/', $addr);
    if (count($parts) != 2) {
        return null;
    }

    $ip = $parts[0];
    $prefix = intval($parts[1]);

    if ($prefix < 0 || $prefix > 32) {
        return null;
    }

    $ipLong = ip2long($ip);
    if ($ipLong === false) {
        return null;
    }

    $mask = $prefix == 0 ? 0 : (~0 << (32 - $prefix));
    $network = long2ip($ipLong & $mask);

    return $network . '/' . $prefix;
}
