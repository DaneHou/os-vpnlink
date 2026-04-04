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

class LinkController extends ApiMutableModelControllerBase
{
    protected static $internalModelName = 'Vpnlink';
    protected static $internalModelClass = 'OPNsense\Vpnlink\Vpnlink';

    // CRUD for links
    public function searchLinkAction()
    {
        return $this->searchBase('links.link', ['enabled', 'name', 'source', 'lanInterface'], 'name');
    }

    public function getLinkAction($uuid = null)
    {
        return $this->getBase('link', 'links.link', $uuid);
    }

    public function addLinkAction()
    {
        return $this->addBase('link', 'links.link');
    }

    public function setLinkAction($uuid)
    {
        return $this->setBase('link', 'links.link', $uuid);
    }

    public function delLinkAction($uuid)
    {
        return $this->delBase('links.link', $uuid);
    }

    /**
     * GET /api/vpnlink/link/wgSources
     * Returns WG servers (subnets) and individual peers for the source picker.
     */
    public function wgSourcesAction()
    {
        $peers = [];
        $servers = [];

        try {
            $clientModel = new \OPNsense\Wireguard\Client();
            $serverModel = new \OPNsense\Wireguard\Server();

            $peerServerMap = [];
            foreach ($serverModel->servers->server->iterateItems() as $serverUuid => $server) {
                if ((string)$server->enabled != '1') {
                    continue;
                }

                $serverName = (string)$server->name;
                $serverIf = 'wg' . (string)$server->instance;
                $tunnelAddr = (string)$server->tunneladdress;

                $serverSubnet = null;
                if (!empty($tunnelAddr)) {
                    foreach (array_map('trim', explode(',', $tunnelAddr)) as $addr) {
                        if (strpos($addr, ':') !== false) continue;
                        $parts = explode('/', $addr);
                        if (count($parts) == 2) {
                            $ipLong = ip2long($parts[0]);
                            $prefix = intval($parts[1]);
                            if ($ipLong !== false && $prefix > 0 && $prefix <= 32) {
                                $mask = ~0 << (32 - $prefix);
                                $serverSubnet = long2ip($ipLong & $mask) . '/' . $prefix;
                            }
                        }
                    }
                }

                if ($serverSubnet) {
                    $servers[] = [
                        'name'      => $serverName,
                        'interface' => $serverIf,
                        'subnet'    => $serverSubnet,
                    ];
                }

                $serverIdx = count($servers) - 1;
                foreach (array_filter(array_map('trim', explode(',', (string)$server->peers))) as $peerUuid) {
                    $peerServerMap[$peerUuid] = ['serverName' => $serverName, 'serverIdx' => $serverIdx];
                }
            }

            foreach ($clientModel->clients->client->iterateItems() as $uuid => $peer) {
                if ((string)$peer->enabled != '1') continue;
                $name = (string)$peer->name;
                $tunnelAddress = (string)$peer->tunneladdress;
                if (empty($name) || empty($tunnelAddress)) continue;

                foreach (array_filter(array_map('trim', explode(',', $tunnelAddress))) as $addr) {
                    if (strpos($addr, ':') !== false) continue;
                    $ip = explode('/', $addr)[0];
                    $serverInfo = $peerServerMap[$uuid] ?? null;
                    $peers[] = [
                        'name'   => $name,
                        'ip'     => $ip,
                        'server' => $serverInfo ? $serverInfo['serverName'] : null,
                    ];
                }
            }
        } catch (\Exception $e) {
            return ['status' => 'error', 'message' => $e->getMessage()];
        }

        return ['status' => 'ok', 'servers' => $servers, 'peers' => $peers];
    }

    /**
     * GET /api/vpnlink/link/lanInterfaces
     * Returns available LAN interfaces for the target picker.
     */
    public function lanInterfacesAction()
    {
        $interfaces = [];
        $config = Config::getInstance()->object();

        if (isset($config->interfaces)) {
            foreach ($config->interfaces->children() as $ifname => $ifcfg) {
                $ifdev = (string)$ifcfg->if;
                if ($ifname === 'wan' || $ifname === 'lo0' || strpos($ifdev, 'wg') === 0) continue;
                if ((string)($ifcfg->enable ?? '0') != '1' && $ifname !== 'lan') continue;

                $descr = (string)($ifcfg->descr ?? strtoupper($ifname));
                $ipaddr = (string)($ifcfg->ipaddr ?? '');
                $subnet = (string)($ifcfg->subnet ?? '');
                $cidr = (!empty($ipaddr) && !empty($subnet)) ? $ipaddr . '/' . $subnet : '';

                $interfaces[] = ['name' => $ifname, 'descr' => $descr, 'cidr' => $cidr];
            }
        }

        return ['status' => 'ok', 'interfaces' => $interfaces];
    }
}
