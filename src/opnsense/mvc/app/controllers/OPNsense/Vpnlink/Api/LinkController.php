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
        return $this->searchBase('links.link', ['enabled', 'name', 'source', 'lanInterface', 'cloneRules', 'autoNat', 'dnsSync'], 'name');
    }

    public function getLinkAction($uuid = null)
    {
        return $this->getBase('link', 'links.link', $uuid);
    }

    public function addLinkAction()
    {
        $conflict = $this->checkSourceConflict(null);
        if ($conflict) return $conflict;
        return $this->addBase('link', 'links.link');
    }

    public function setLinkAction($uuid)
    {
        $conflict = $this->checkSourceConflict($uuid);
        if ($conflict) return $conflict;
        return $this->setBase('link', 'links.link', $uuid);
    }

    /**
     * Check if any source in the submitted link overlaps with existing links
     * that point to a DIFFERENT destination. Returns error response or null.
     */
    private function checkSourceConflict($excludeUuid)
    {
        if (!$this->request->isPost()) return null;
        $post = $this->request->getPost('link');
        if (!$post || empty($post['source'])) return null;

        $newSources = array_map('trim', explode(',', $post['source']));
        $newLanIf = $post['lanInterface'] ?? '';

        try {
            $mdl = $this->getModel();
            foreach ($mdl->links->link->iterateItems() as $uuid => $link) {
                if ($excludeUuid && $uuid === $excludeUuid) continue;
                if ((string)$link->enabled !== '1') continue;

                $existLanIf = (string)$link->lanInterface;
                if ($existLanIf === $newLanIf) continue; // same destination = no conflict

                $existSources = array_map('trim', explode(',', (string)$link->source));
                foreach ($newSources as $ns) {
                    if ($ns === 'any' || in_array('any', $existSources) || in_array($ns, $existSources)) {
                        // Conflict found — return warning (not blocking, just info)
                        return [
                            'result' => 'failed',
                            'validations' => [
                                'link.source' => 'Source "' . $ns . '" already linked to ' . $existLanIf .
                                    ' in "' . (string)$link->name . '". This may cause conflicting rules.'
                            ]
                        ];
                    }
                }
            }
        } catch (\Exception $e) {}

        return null;
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

        // ── Also discover OpenVPN servers ──
        $rawConfig = simplexml_load_file('/conf/config.xml');
        if ($rawConfig !== false && isset($rawConfig->openvpn)) {
            if (isset($rawConfig->openvpn->{'openvpn-server'})) {
                foreach ($rawConfig->openvpn->{'openvpn-server'} as $ovpn) {
                    if ((string)($ovpn->disable ?? '') === '1') continue;
                    $tunnelNet = (string)($ovpn->tunnel_network ?? '');
                    $vpnid = (string)($ovpn->vpnid ?? '');
                    $descr = (string)($ovpn->description ?? 'OpenVPN');
                    if (!empty($tunnelNet) && !empty($vpnid)) {
                        $parts = explode('/', $tunnelNet);
                        if (count($parts) == 2) {
                            $ipLong = ip2long($parts[0]);
                            $prefix = intval($parts[1]);
                            if ($ipLong !== false) {
                                $mask = ~0 << (32 - $prefix);
                                $subnet = long2ip($ipLong & $mask) . '/' . $prefix;
                                $servers[] = [
                                    'name' => $descr ?: ('OpenVPN ' . $vpnid),
                                    'interface' => 'ovpns' . $vpnid,
                                    'subnet' => $subnet,
                                    'type' => 'openvpn',
                                ];
                            }
                        }
                    }
                }
            }
        }

        // ── Discover IPsec / Tailscale / ZeroTier / OpenConnect from interface assignments ──
        $configObj = Config::getInstance()->object();
        if (isset($configObj->interfaces)) {
            foreach ($configObj->interfaces->children() as $ifname => $ifcfg) {
                $ifdev = (string)($ifcfg->if ?? '');
                $ipaddr = (string)($ifcfg->ipaddr ?? '');
                $bits = (string)($ifcfg->subnet ?? '');
                $descr = (string)($ifcfg->descr ?? $ifdev);

                if (preg_match('/^(enc|ipsec|tailscale|zt|zerotier|ocserv|tun|tap)/', $ifdev) && !empty($ipaddr) && !empty($bits)) {
                    // Skip OpenVPN client interfaces (ovpnc*) — those are gateways, not sources
                    if (strpos($ifdev, 'ovpnc') === 0) continue;
                    // Skip already discovered
                    $skip = false;
                    foreach ($servers as $s) { if ($s['interface'] === $ifname) { $skip = true; break; } }
                    if ($skip) continue;

                    $ipLong = ip2long($ipaddr);
                    $prefix = intval($bits);
                    if ($ipLong !== false && $prefix > 0) {
                        $mask = ~0 << (32 - $prefix);
                        $subnet = long2ip($ipLong & $mask) . '/' . $prefix;

                        $type = 'other';
                        if (strpos($ifdev, 'enc') === 0 || strpos($ifdev, 'ipsec') === 0) $type = 'ipsec';
                        elseif (strpos($ifdev, 'tailscale') === 0) $type = 'tailscale';
                        elseif (strpos($ifdev, 'zt') === 0) $type = 'zerotier';
                        elseif (strpos($ifdev, 'ocserv') === 0) $type = 'openconnect';

                        $servers[] = [
                            'name' => $descr,
                            'interface' => $ifname,
                            'subnet' => $subnet,
                            'type' => $type,
                        ];
                    }
                }
            }
        }

        return ['status' => 'ok', 'servers' => $servers, 'peers' => $peers];
    }

    /**
     * GET /api/vpnlink/link/lanInterfaces
     * Returns available LAN interfaces for the target picker.
     * Excludes VPN source interfaces (WG, OpenVPN server, IPsec, etc.)
     */
    public function lanInterfacesAction()
    {
        $interfaces = [];
        $config = Config::getInstance()->object();

        if (isset($config->interfaces)) {
            foreach ($config->interfaces->children() as $ifname => $ifcfg) {
                $ifdev = (string)$ifcfg->if;
                // Skip WAN, loopback, and ALL VPN interfaces
                if ($ifname === 'wan' || $ifname === 'lo0') continue;
                if (preg_match('/^(wg|ovpn|enc|ipsec|tailscale|zt|zerotier|ocserv|tun|tap|gif|gre)/', $ifdev)) continue;
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
