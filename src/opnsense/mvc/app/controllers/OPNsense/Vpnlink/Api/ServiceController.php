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
     * Auto-assign WireGuard device interfaces (wg0, wg1, ...) in OPNsense
     * if they're not already assigned. This is required for pf filter rules
     * to work on WG interfaces.
     *
     * @return array  List of newly assigned interfaces ['wg0' => 'opt5', ...]
     */
    private function autoAssignWgInterfaces()
    {
        $assigned = [];

        try {
            $serverModel = new \OPNsense\Wireguard\Server();
        } catch (\Exception $e) {
            return $assigned;
        }

        // Collect WG device names that need assignment
        $wgDevices = [];
        try {
            foreach ($serverModel->servers->server->iterateItems() as $server) {
                if ((string)$server->enabled != '1') continue;
                $devName = 'wg' . (string)$server->instance;
                $wgDevices[$devName] = (string)$server->name ?: $devName;
            }
        } catch (\Exception $e) {
            return $assigned;
        }

        if (empty($wgDevices)) return $assigned;

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

        // Assign unassigned WG devices
        $configChanged = false;
        foreach ($wgDevices as $devName => $serverName) {
            if (isset($existingDevices[$devName])) continue;

            $maxOpt++;
            $newIfName = 'opt' . $maxOpt;

            // Add to config.xml via SimpleXML
            $rawConfig = simplexml_load_file('/conf/config.xml');
            if ($rawConfig === false) continue;

            $newIf = $rawConfig->interfaces->addChild($newIfName);
            $newIf->addChild('if', $devName);
            $newIf->addChild('descr', 'VPNLink_' . $serverName);
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
