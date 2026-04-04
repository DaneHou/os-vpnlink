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

use OPNsense\Base\ApiMutableServiceControllerBase;
use OPNsense\Core\Config;

class ServiceController extends ApiMutableServiceControllerBase
{
    protected static $internalServiceClass = '\OPNsense\Vpnlink\Vpnlink';
    protected static $internalServiceEnabled = 'general.enabled';
    protected static $internalServiceName = 'vpnlink';

    /**
     * GET /api/vpnlink/service/healthcheck
     */
    public function healthcheckAction()
    {
        $backend = new \OPNsense\Core\Backend();
        $response = trim($backend->configdRun('vpnlink healthcheck'));
        $data = json_decode($response, true);
        return $data ?: ['checks' => [], 'error' => 'Failed to run healthcheck'];
    }

    /**
     * GET /api/vpnlink/service/log
     */
    public function logAction()
    {
        $backend = new \OPNsense\Core\Backend();
        $response = trim($backend->configdRun('vpnlink log'));
        $data = json_decode($response, true);
        return $data ?: ['entries' => [], 'error' => 'Failed to read log'];
    }

    public function reconfigureAction()
    {
        $result = ['status' => 'failed'];

        if ($this->request->isPost()) {
            session_write_close();

            // Auto-assign WireGuard interfaces if not yet assigned
            $assigned = $this->autoAssignWgInterfaces();

            $backend = new \OPNsense\Core\Backend();

            // Sync DNS ACL for WG subnets
            $backend->configdpRun('vpnlink sync_dns');

            // If we assigned new interfaces, reconfigure them
            if (!empty($assigned)) {
                $backend->configdpRun('interface reconfigure');
            }

            // Reload firewall to regenerate NAT/filter rules
            $backend->configdpRun('filter reload');

            $result = ['status' => 'ok', 'assigned' => $assigned];
        }

        return $result;
    }

    /**
     * Auto-assign VPN server interfaces in OPNsense if not already assigned.
     * Covers WireGuard, OpenVPN server, and other VPN types.
     * Required for pf filter rules to work on these interfaces.
     */
    private function autoAssignWgInterfaces()
    {
        $assigned = [];
        $vpnDevices = []; // devName => description

        // 1. WireGuard servers
        try {
            $serverModel = new \OPNsense\Wireguard\Server();
            foreach ($serverModel->servers->server->iterateItems() as $server) {
                if ((string)$server->enabled != '1') continue;
                $devName = 'wg' . (string)$server->instance;
                $vpnDevices[$devName] = (string)$server->name ?: $devName;
            }
        } catch (\Exception $e) {}

        // 2. OpenVPN servers
        $rawConfig = simplexml_load_file('/conf/config.xml');
        if ($rawConfig !== false && isset($rawConfig->openvpn->{'openvpn-server'})) {
            foreach ($rawConfig->openvpn->{'openvpn-server'} as $ovpn) {
                if ((string)($ovpn->disable ?? '') === '1') continue;
                $vpnid = (string)($ovpn->vpnid ?? '');
                if (!empty($vpnid)) {
                    $vpnDevices['ovpns' . $vpnid] = (string)($ovpn->description ?? 'OpenVPN') ?: ('ovpns' . $vpnid);
                }
            }
        }

        if (empty($vpnDevices)) return $assigned;

        // Check which are already assigned
        $config = Config::getInstance();
        $configObj = $config->object();

        $existingDevices = [];
        if (isset($configObj->interfaces)) {
            foreach ($configObj->interfaces->children() as $ifname => $ifcfg) {
                $existingDevices[(string)($ifcfg->if ?? '')] = $ifname;
            }
        }

        // Find next available optX number
        $maxOpt = 0;
        foreach (array_values($existingDevices) as $ifname) {
            if (preg_match('/^opt(\d+)$/', $ifname, $m)) {
                $maxOpt = max($maxOpt, intval($m[1]));
            }
        }

        // Assign unassigned VPN devices
        $configChanged = false;
        foreach ($vpnDevices as $devName => $serverName) {
            if (isset($existingDevices[$devName])) continue;

            $maxOpt++;
            $newIfName = 'opt' . $maxOpt;

            // Add to config.xml via SimpleXML
            $rawConfig = simplexml_load_file('/conf/config.xml');
            if ($rawConfig === false) continue;

            $newIf = $rawConfig->interfaces->addChild($newIfName);
            $newIf->addChild('if', $devName);
            $newIf->addChild('descr', !empty($serverName) ? $serverName : strtoupper($devName));
            $newIf->addChild('enable', '1');
            $newIf->addChild('lock', '1');
            $newIf->addChild('spoofmac', '');

            // Save config.xml
            $dom = new \DOMDocument('1.0');
            $dom->preserveWhiteSpace = false;
            $dom->formatOutput = true;
            $dom->loadXML($rawConfig->asXML());
            $dom->save('/conf/config.xml');

            // Reload config in OPNsense
            Config::getInstance()->forceReload();

            $assigned[$devName] = $newIfName;
            syslog(LOG_NOTICE, "VPNLink: auto-assigned {$devName} as {$newIfName} (VPNLink_{$serverName})");
        }

        return $assigned;
    }
}
