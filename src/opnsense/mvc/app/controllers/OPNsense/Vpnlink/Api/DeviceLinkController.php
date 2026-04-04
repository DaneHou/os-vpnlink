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

namespace OPNsense\Vpnlink\Api;

use OPNsense\Base\ApiMutableModelControllerBase;
use OPNsense\Core\Config;

class DeviceLinkController extends ApiMutableModelControllerBase
{
    protected static $internalModelName = 'Vpnlink';
    protected static $internalModelClass = 'OPNsense\Vpnlink\Vpnlink';

    public function searchDeviceLinkAction()
    {
        return $this->searchBase(
            'devicelinks.devicelink',
            ['enabled', 'name', 'tunnelIp', 'gateway', 'targetAlias', 'description'],
            'name'
        );
    }

    public function getDeviceLinkAction($uuid = null)
    {
        return $this->getBase('devicelink', 'devicelinks.devicelink', $uuid);
    }

    public function addDeviceLinkAction()
    {
        return $this->addBase('devicelink', 'devicelinks.devicelink');
    }

    public function setDeviceLinkAction($uuid)
    {
        return $this->setBase('devicelink', 'devicelinks.devicelink', $uuid);
    }

    public function delDeviceLinkAction($uuid)
    {
        return $this->delBase('devicelinks.devicelink', $uuid);
    }

    /**
     * List WireGuard peers from the core model.
     * Returns all configured peers with their names and tunnel IPs.
     * Used by the UI to populate device selector dropdown.
     *
     * GET /api/vpnlink/devicelink/wgPeers
     */
    public function wgPeersAction()
    {
        $peers = [];
        $servers = [];

        try {
            $clientModel = new \OPNsense\Wireguard\Client();
            $serverModel = new \OPNsense\Wireguard\Server();

            // Build server list + peer lookup
            $peerServerMap = [];
            foreach ($serverModel->servers->server->iterateItems() as $serverUuid => $server) {
                if ((string)$server->enabled != '1') {
                    continue;
                }

                $serverName = (string)$server->name;
                $serverIf = 'wg' . (string)$server->instance;
                $tunnelAddr = (string)$server->tunneladdress;

                // Extract server subnet (e.g. "10.10.10.1/24" -> "10.10.10.0/24")
                $serverSubnet = null;
                if (!empty($tunnelAddr)) {
                    $addrs = array_map('trim', explode(',', $tunnelAddr));
                    foreach ($addrs as $addr) {
                        if (strpos($addr, ':') !== false) {
                            continue;
                        }
                        $parts = explode('/', $addr);
                        if (count($parts) == 2) {
                            $ip = $parts[0];
                            $prefix = intval($parts[1]);
                            $ipLong = ip2long($ip);
                            if ($ipLong !== false && $prefix > 0 && $prefix <= 32) {
                                $mask = ~0 << (32 - $prefix);
                                $serverSubnet = long2ip($ipLong & $mask) . '/' . $prefix;
                            }
                        }
                    }
                }

                if ($serverSubnet) {
                    $servers[] = [
                        'uuid'      => $serverUuid,
                        'name'      => $serverName,
                        'interface' => $serverIf,
                        'subnet'    => $serverSubnet,
                        'peerCount' => 0,
                    ];
                }

                $peerUuids = array_filter(array_map('trim', explode(',', (string)$server->peers)));
                $serverIdx = count($servers) - 1;
                foreach ($peerUuids as $peerUuid) {
                    $peerServerMap[$peerUuid] = [
                        'serverName' => $serverName,
                        'serverInterface' => $serverIf,
                        'serverIdx' => $serverIdx,
                    ];
                }
            }

            // Iterate all peers
            foreach ($clientModel->clients->client->iterateItems() as $uuid => $peer) {
                if ((string)$peer->enabled != '1') {
                    continue;
                }

                $name = (string)$peer->name;
                $tunnelAddress = (string)$peer->tunneladdress;

                if (empty($name) || empty($tunnelAddress)) {
                    continue;
                }

                // Extract IPv4 tunnel addresses
                $addresses = array_filter(array_map('trim', explode(',', $tunnelAddress)));
                $ipv4Addrs = [];
                foreach ($addresses as $addr) {
                    if (strpos($addr, ':') === false) {
                        $ip = explode('/', $addr)[0];
                        $ipv4Addrs[] = $ip;
                    }
                }

                if (empty($ipv4Addrs)) {
                    continue;
                }

                $serverInfo = $peerServerMap[$uuid] ?? null;

                // Count peers per server
                if ($serverInfo && isset($servers[$serverInfo['serverIdx']])) {
                    $servers[$serverInfo['serverIdx']]['peerCount']++;
                }

                $peers[] = [
                    'uuid'       => $uuid,
                    'name'       => $name,
                    'tunnelIps'  => $ipv4Addrs,
                    'tunnelIp'   => $ipv4Addrs[0],
                    'rawAddress' => $tunnelAddress,
                    'server'     => $serverInfo ? $serverInfo['serverName'] : null,
                    'interface'  => $serverInfo ? $serverInfo['serverInterface'] : null,
                ];
            }
        } catch (\Exception $e) {
            return ['status' => 'error', 'message' => 'WireGuard model not available: ' . $e->getMessage()];
        }

        return ['status' => 'ok', 'peers' => $peers, 'servers' => $servers];
    }

    /**
     * List available gateways from OPNsense routing config.
     * Used by the UI to populate gateway selector dropdown.
     *
     * GET /api/vpnlink/devicelink/gateways
     */
    public function gatewaysAction()
    {
        $gateways = [];
        $config = Config::getInstance()->object();

        // Read gateways from config
        if (isset($config->gateways) && isset($config->gateways->gateway_item)) {
            foreach ($config->gateways->gateway_item as $gw) {
                $name = (string)$gw->name;
                $interface = (string)$gw->interface;
                $gateway = (string)$gw->gateway;
                $descr = (string)($gw->descr ?? '');
                $disabled = (string)($gw->disabled ?? '0');

                if ($disabled == '1') {
                    continue;
                }

                $gateways[] = [
                    'name'      => $name,
                    'interface' => $interface,
                    'gateway'   => $gateway,
                    'descr'     => $descr,
                ];
            }
        }

        return ['status' => 'ok', 'gateways' => $gateways];
    }
}
