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
    if (!vpnlink_enabled()) return [];
    return [[
        'description' => 'VPN Link',
        'configd' => ['start' => ['vpnlink start'], 'restart' => ['vpnlink restart'], 'stop' => ['vpnlink stop']],
        'name' => 'vpnlink',
    ]];
}

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

/**
 * Core firewall hook.
 *
 * Reads each link (WG source → LAN interface) and generates:
 *   - Pass rule on WG interface
 *   - Loopback NAT (DNS access)
 *   - Outbound NAT on the target LAN + WAN + all gateway interfaces
 */
function vpnlink_firewall($fw)
{
    if (!vpnlink_enabled()) return;

    $mdl = new \OPNsense\Vpnlink\Vpnlink();
    $tunnels = vpnlink_discover_wg_tunnels();
    if (empty($tunnels)) return;

    // Collect all unique LAN interfaces from links
    $processedWgIfs = [];

    if (property_exists($mdl, 'links') && property_exists($mdl->links, 'link')) {
        foreach ($mdl->links->link->iterateItems() as $link) {
            if ((string)$link->enabled != '1') continue;

            $source = (string)$link->source;       // e.g. "10.10.0.0/24" or "10.10.0.2"
            $lanIf = (string)$link->lanInterface;   // e.g. "opt1"
            $linkName = (string)$link->name;
            if (empty($source) || empty($lanIf)) continue;

            // Find which WG interface this source belongs to
            $wgIf = vpnlink_find_wg_interface_for_ip($source, $tunnels);
            if ($wgIf === null && !empty($tunnels)) {
                $wgIf = $tunnels[0]['interface'];
            }
            if ($wgIf === null) continue;

            // Determine the source subnet/IP for NAT rules
            $wgSource = $source;

            // Pass rule on WG interface (once per interface)
            if (!in_array($wgIf, $processedWgIfs)) {
                $fw->registerFilterRule(1, [
                    'interface' => $wgIf, 'direction' => 'in',
                    'descr' => 'VPNLink: Pass inbound on ' . $wgIf,
                    '#ref' => 'ui/vpnlink',
                ], ['type' => 'pass', 'quick' => true, 'statetype' => 'keep']);

                $processedWgIfs[] = $wgIf;
            }

            // Loopback NAT on WG interface (DNS to OPNsense's own IPs)
            $fw->registerSNatRule(40, [
                'interface' => $wgIf,
                'source'    => ['network' => $wgSource],
                'destination' => ['any' => true],
                'target'    => $wgIf . 'ip',
                'descr'     => 'VPNLink: Loopback ' . $linkName,
                'log' => false, '#ref' => 'ui/vpnlink',
            ]);

            // Outbound NAT on target LAN + WAN + all gateway interfaces
            $natIfList = vpnlink_auto_discover_nat_interfaces($lanIf);
            foreach ($natIfList as $natIf) {
                $fw->registerSNatRule(50, [
                    'interface' => $natIf,
                    'source'    => ['network' => $wgSource],
                    'destination' => ['any' => true],
                    'target'    => $natIf . 'ip',
                    'descr'     => 'VPNLink: ' . $linkName . ' NAT on ' . $natIf,
                    'log' => false, '#ref' => 'ui/vpnlink',
                ]);
            }
        }
    }
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
    if (isset($config->gateways) && isset($config->gateways->gateway_item)) {
        foreach ($config->gateways->gateway_item as $gw) {
            if ((string)($gw->disabled ?? '0') == '1') continue;
            $gwIf = (string)$gw->interface;
            if (!empty($gwIf) && !in_array($gwIf, $ifList)) {
                $ifList[] = $gwIf;
            }
        }
    }
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

function vpnlink_discover_wg_tunnels()
{
    $tunnels = [];
    try {
        $wg = new \OPNsense\Wireguard\General();
    } catch (\Exception $e) {
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
                    'interface' => 'wg' . (string)$server->instance,
                    'subnet'    => $subnet,
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
        $bits = (string)($ifcfg->subnet ?? '');
        if (!empty($ipaddr) && !empty($bits)) {
            $net = vpnlink_addr_to_network($ipaddr . '/' . $bits);
            if ($net !== null) {
                $tunnels[] = ['interface' => $ifname, 'subnet' => $net, 'description' => (string)($ifcfg->descr ?? (string)$ifcfg->if)];
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
