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
    $mdl = new \OPNsense\Vpnlink\Vpnlink();
    return (string)$mdl->general->enabled == '1';
}

function vpnlink_services()
{
    if (!vpnlink_enabled()) {
        return [];
    }
    return [[
        'description' => 'VPN Link Orchestrator',
        'configd' => [
            'start'   => ['vpnlink start'],
            'restart' => ['vpnlink restart'],
            'stop'    => ['vpnlink stop'],
        ],
        'name' => 'vpnlink',
    ]];
}

function vpnlink_configure()
{
    return ['vpn' => ['vpnlink_vpn_event:3']];
}

function vpnlink_vpn_event($verbose = false)
{
    if (!vpnlink_enabled()) {
        return;
    }
    service_log('VPNLink: syncing DNS ACL...', $verbose);
    configd_run('vpnlink sync_dns');
    service_log("done.\n", $verbose);
}

function vpnlink_syslog()
{
    return ['vpnlink' => ['facility' => ['vpnlink']]];
}

/**
 * Core firewall hook — generates all NAT and filter rules.
 *
 * WG clients mirror the selected LAN: same NAT, same DNS, same routing.
 * Everything is auto-detected — user only picks Enable + LAN interface.
 */
function vpnlink_firewall($fw)
{
    if (!vpnlink_enabled()) {
        return;
    }

    $mdl = new \OPNsense\Vpnlink\Vpnlink();
    $lanInterface = (string)$mdl->general->lanInterface;
    $tunnels = vpnlink_discover_wg_tunnels();

    if (empty($tunnels)) {
        return;
    }

    // Auto-discover all interfaces to NAT on (WAN + LAN + all gateways)
    $natIfList = vpnlink_auto_discover_nat_interfaces($lanInterface);

    foreach ($tunnels as $tunnel) {
        $wgIf = $tunnel['interface'];
        $wgSubnet = $tunnel['subnet'];
        $wgDescr = $tunnel['description'] ?? $wgIf;

        // Pass all inbound traffic on WG interface
        $fw->registerFilterRule(1, [
            'interface' => $wgIf,
            'direction' => 'in',
            'descr'     => 'VPNLink: Pass inbound on ' . $wgDescr,
            '#ref'      => 'ui/vpnlink',
        ], ['type' => 'pass', 'quick' => true, 'statetype' => 'keep']);

        // Loopback NAT on WG interface (DNS to OPNsense's own IPs)
        $fw->registerSNatRule(40, [
            'interface'   => $wgIf,
            'source'      => ['network' => $wgSubnet],
            'destination' => ['any' => true],
            'target'      => $wgIf . 'ip',
            'descr'       => 'VPNLink: Loopback NAT on ' . $wgDescr,
            'log'         => false,
            '#ref'        => 'ui/vpnlink',
        ]);

        // Outbound NAT on EVERY exit interface
        foreach ($natIfList as $natIf) {
            $fw->registerSNatRule(50, [
                'interface'   => $natIf,
                'source'      => ['network' => $wgSubnet],
                'destination' => ['any' => true],
                'target'      => $natIf . 'ip',
                'descr'       => 'VPNLink: NAT ' . $wgDescr . ' on ' . $natIf,
                'log'         => false,
                '#ref'        => 'ui/vpnlink',
            ]);
        }
    }

    // Per-device steering (advanced, optional)
    vpnlink_generate_device_steering($fw, $mdl, $tunnels);
}

/**
 * Auto-discover all interfaces to NAT on.
 * Always includes WAN + selected LAN + all gateway interfaces.
 */
function vpnlink_auto_discover_nat_interfaces($lanInterface)
{
    $ifList = ['wan'];

    if (!empty($lanInterface) && !in_array($lanInterface, $ifList)) {
        $ifList[] = $lanInterface;
    }

    // Auto-discover all gateway interfaces (OpenVPN, WireGuard clients, etc.)
    $config = \OPNsense\Core\Config::getInstance()->object();
    if (isset($config->gateways) && isset($config->gateways->gateway_item)) {
        foreach ($config->gateways->gateway_item as $gw) {
            if ((string)($gw->disabled ?? '0') == '1') {
                continue;
            }
            $gwIf = (string)$gw->interface;
            if (!empty($gwIf) && !in_array($gwIf, $ifList)) {
                $ifList[] = $gwIf;
            }
        }
    }

    return $ifList;
}

/**
 * Per-device steering rules from DeviceLink model.
 */
function vpnlink_generate_device_steering($fw, $mdl, $tunnels)
{
    if (!property_exists($mdl, 'devicelinks') ||
        !property_exists($mdl->devicelinks, 'devicelink')) {
        return;
    }

    foreach ($mdl->devicelinks->devicelink->iterateItems() as $link) {
        if ((string)$link->enabled != '1') {
            continue;
        }

        $tunnelIp = (string)$link->tunnelIp;
        $gateway = (string)$link->gateway;
        if (empty($tunnelIp) || empty($gateway)) {
            continue;
        }

        $descr = (string)$link->description ?: (string)$link->name;
        $wgIf = vpnlink_find_wg_interface_for_ip($tunnelIp, $tunnels);
        if ($wgIf === null) {
            $wgIf = !empty($tunnels) ? $tunnels[0]['interface'] : null;
        }
        if ($wgIf === null) {
            continue;
        }

        $ruleConfig = [
            'interface' => $wgIf,
            'from'      => $tunnelIp,
            'direction' => 'in',
            'gateway'   => $gateway,
            'descr'     => 'VPNLink: Steer ' . $descr . ' via ' . $gateway,
            '#ref'      => 'ui/vpnlink',
        ];

        $targetAlias = (string)$link->targetAlias;
        if (!empty($targetAlias)) {
            $ruleConfig['to'] = '$' . $targetAlias;
        }

        $fw->registerFilterRule(100000, $ruleConfig, [
            'type' => 'pass', 'quick' => true, 'statetype' => 'keep',
        ]);
    }
}

function vpnlink_find_wg_interface_for_ip($deviceIp, $tunnels)
{
    $ip = explode('/', $deviceIp)[0];
    $ipLong = ip2long($ip);
    if ($ipLong === false) {
        return null;
    }

    foreach ($tunnels as $tunnel) {
        $parts = explode('/', $tunnel['subnet']);
        if (count($parts) != 2) continue;
        $netLong = ip2long($parts[0]);
        $prefix = intval($parts[1]);
        $mask = $prefix == 0 ? 0 : (~0 << (32 - $prefix));
        if (($ipLong & $mask) == ($netLong & $mask)) {
            return $tunnel['interface'];
        }
    }
    return null;
}

// ── WireGuard Tunnel Discovery ──

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
            if ((string)$server->enabled != '1') continue;
            $tunnelAddress = (string)$server->tunneladdress;
            if (empty($tunnelAddress)) continue;

            foreach (array_map('trim', explode(',', $tunnelAddress)) as $addr) {
                if (strpos($addr, ':') !== false) continue;
                $subnet = vpnlink_addr_to_network($addr);
                if ($subnet === null) continue;

                $tunnels[] = [
                    'interface'   => 'wg' . (string)$server->instance,
                    'subnet'      => $subnet,
                    'description' => (string)$server->name ?: ('wg' . (string)$server->instance),
                ];
            }
        }
    }

    return empty($tunnels) ? vpnlink_discover_wg_from_interfaces() : $tunnels;
}

function vpnlink_discover_wg_from_interfaces()
{
    $tunnels = [];
    $config = \OPNsense\Core\Config::getInstance()->object();
    if (!isset($config->interfaces)) return $tunnels;

    foreach ($config->interfaces->children() as $ifname => $ifcfg) {
        if (strpos((string)$ifcfg->if, 'wg') !== 0) continue;
        $ipaddr = (string)($ifcfg->ipaddr ?? '');
        $subnet_bits = (string)($ifcfg->subnet ?? '');
        if (!empty($ipaddr) && !empty($subnet_bits)) {
            $network = vpnlink_addr_to_network($ipaddr . '/' . $subnet_bits);
            if ($network !== null) {
                $tunnels[] = [
                    'interface'   => $ifname,
                    'subnet'      => $network,
                    'description' => (string)($ifcfg->descr ?? (string)$ifcfg->if),
                ];
            }
        }
    }
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
