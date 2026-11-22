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

namespace OPNsense\Vpnlink;

use OPNsense\Core\Backend;
use OPNsense\Core\Config;
use OPNsense\Wireguard\Client;
use OPNsense\Wireguard\Server;

/**
 * Side effects of the "Add device" wizard (see DeviceWizard for the contract).
 *
 * The client's private key never reaches this class: generateKeypair() hands
 * it straight back to DeviceWizard::run(), and no method here takes it as an
 * argument. Nothing in here writes it to config.xml, a file or syslog.
 */
class DeviceWizardBackend
{
    /** data DeviceWizard::run()/defaults() work on */
    public function context()
    {
        require_once('/usr/local/etc/inc/plugins.inc.d/vpnlink.inc');
        $ctx = ['instances' => [], 'peerNames' => [], 'usedAddresses' => [], 'links' => [],
                'interfaceNets' => [], 'pluginEnabled' => false];

        foreach ((new Server())->servers->server->iterateItems() as $uuid => $srv) {
            if ((string)$srv->enabled !== '1') continue;
            $ctx['instances'][$uuid] = [
                'name'      => (string)$srv->name,
                'if'        => 'wg' . (string)$srv->instance,
                'tunnel'    => (string)$srv->tunneladdress,
                'port'      => (string)$srv->port,
                'mtu'       => (string)$srv->mtu,
                'pubkey'    => (string)$srv->pubkey,
                'peerCount' => count(array_filter(explode(',', (string)$srv->peers))),
                'endpoint'  => (string)$srv->endpoint,
            ];
        }
        foreach ((new Client())->clients->client->iterateItems() as $peer) {
            $ctx['peerNames'][] = (string)$peer->name;
            $ctx['usedAddresses'][] = (string)$peer->tunneladdress;
        }

        $mdl = new Vpnlink();
        $ctx['pluginEnabled'] = (string)$mdl->general->enabled === '1';
        foreach ($mdl->links->link->iterateItems() as $uuid => $l) {
            $ctx['links'][] = [
                'uuid'         => $uuid,
                'name'         => (string)$l->name,
                'enabled'      => (string)$l->enabled,
                'source'       => (string)$l->source,
                'lanInterface' => (string)$l->lanInterface,
                'cloneRules'   => (string)$l->cloneRules,
                'access'       => (string)$l->access,
            ];
        }

        // LAN networks (same selection as LinkController::lanInterfacesAction)
        $config = Config::getInstance()->object();
        if (isset($config->interfaces)) {
            foreach ($config->interfaces->children() as $ifname => $ifcfg) {
                if ($ifname === 'wan' || $ifname === 'lo0') continue;
                if (preg_match('/^(wg|ovpn|enc|ipsec|tailscale|zt|zerotier|ocserv|tun|tap|gif|gre)/', (string)$ifcfg->if)) continue;
                if ((string)($ifcfg->enable ?? '0') !== '1' && $ifname !== 'lan') continue;
                $net = vpnlink_interface_network($config, $ifname);
                if ($net !== null) $ctx['interfaceNets'][$ifname] = $net;
            }
            $ctx['defaultLan'] = isset($config->interfaces->lan) ? 'lan' : '';
        }
        return $ctx;
    }

    /** first hostname of an enabled os-ddclient account, or '' */
    public function ddnsHostname()
    {
        try {
            if (!class_exists('\OPNsense\DynDNS\DynDNS')) return '';
            $mdl = new \OPNsense\DynDNS\DynDNS();
            if ((string)$mdl->general->enabled !== '1') return '';
            foreach ($mdl->accounts->account->iterateItems() as $acct) {
                if ((string)$acct->enabled !== '1') continue;
                foreach (array_filter(array_map('trim', explode(',', (string)$acct->hostnames))) as $h) {
                    if (strpos($h, '*') === false && strpos($h, '@') === false) return $h;
                }
            }
        } catch (\Throwable $e) {
        }
        return '';
    }

    /** primary IPv4 address of the WAN interface, or '' */
    public function wanAddress()
    {
        try {
            $data = json_decode((new Backend())->configdRun('interface address'), true);
            foreach ($data['wan'] ?? [] as $a) {
                if (($a['family'] ?? '') === 'inet' && !empty($a['address'])) return (string)$a['address'];
            }
        } catch (\Throwable $e) {
        }
        return '';
    }

    /**
     * New client keypair. PHP sodium when available (no process, no configd),
     * else the core configd action "wireguard gen_keypair" (wg genkey | wg pubkey,
     * JSON {"privkey","pubkey","status"}). The private key is returned to the
     * caller only: not logged, not stored.
     */
    public function generateKeypair()
    {
        if (function_exists('sodium_crypto_scalarmult_base')) {
            $priv = random_bytes(32);
            // clamp like "wg genkey"
            $priv[0] = chr(ord($priv[0]) & 248);
            $priv[31] = chr((ord($priv[31]) & 127) | 64);
            $pub = sodium_crypto_scalarmult_base($priv);
            $result = [base64_encode($priv), base64_encode($pub)];
            sodium_memzero($priv);
            return $result;
        }
        $data = json_decode(trim((new Backend())->configdRun('wireguard gen_keypair')), true);
        if (!is_array($data) || ($data['status'] ?? '') !== 'ok' || empty($data['privkey']) || empty($data['pubkey'])) {
            // never include $data in the message: it may hold a private key
            throw new \RuntimeException('wireguard gen_keypair failed');
        }
        return [(string)$data['privkey'], (string)$data['pubkey']];
    }

    public function generatePsk()
    {
        if (function_exists('sodium_crypto_scalarmult_base')) {
            return base64_encode(random_bytes(32));
        }
        $psk = trim((new Backend())->configdRun('wireguard gen_psk'));
        if ($psk === '') throw new \RuntimeException('wireguard gen_psk failed');
        return $psk;
    }

    /**
     * Add the peer to the core WireGuard model and attach it to the instance.
     * $peer holds public data only (name, pubkey, psk, tunneladdress,
     * keepalive); the "privkey" field of the peer stays empty.
     */
    public function createPeer(array $peer, $instanceUuid)
    {
        $cfg = Config::getInstance();
        $cfg->lock();
        try {
            $client = new Client();
            $node = $client->clients->client->add();
            $uuid = $node->getAttribute('uuid');
            $node->setNodes([
                'enabled'       => '1',
                'name'          => $peer['name'],
                'pubkey'        => $peer['pubkey'],
                'psk'           => $peer['psk'],
                'tunneladdress' => $peer['tunneladdress'],
                'keepalive'     => $peer['keepalive'],
            ]);
            $errors = [];
            foreach ($client->performValidation() as $msg) {
                $errors[] = $msg->getMessage();
            }
            if ($errors) throw new \RuntimeException('peer validation: ' . implode(' ', $errors));
            $client->serializeToConfig(false, true);

            $server = new Server();
            $srv = $server->getNodeByReference('servers.server.' . $instanceUuid);
            if ($srv === null) throw new \RuntimeException('WireGuard instance not found');
            $peers = array_filter(explode(',', (string)$srv->peers));
            $peers[] = $uuid;
            $srv->peers = implode(',', array_unique($peers));
            // the relation check would not see the new peer reliably; core skips it the same way
            $server->serializeToConfig(false, true);

            $cfg->save();
            return $uuid;
        } catch (\Throwable $e) {
            $this->discard($cfg);
            throw $e;
        }
    }

    /** drop unsaved in-memory changes: lock() reloads from disk when we don't hold the lock */
    private function discard($cfg)
    {
        $cfg->unlock();
        $cfg->lock();
        $cfg->unlock();
    }

    public function deletePeer($uuid, $instanceUuid)
    {
        $cfg = Config::getInstance();
        $cfg->lock();
        try {
            $server = new Server();
            foreach ($server->servers->server->iterateItems() as $srv) {
                $peers = array_filter(explode(',', (string)$srv->peers));
                if (in_array($uuid, $peers, true)) {
                    $srv->peers = implode(',', array_diff($peers, [$uuid]));
                }
            }
            $server->serializeToConfig(false, true);
            $client = new Client();
            $client->clients->client->del($uuid);
            $client->serializeToConfig(false, true);
            $cfg->save();
        } catch (\Throwable $e) {
            $this->discard($cfg);
            throw $e;
        }
    }

    public function createLink(array $link)
    {
        $cfg = Config::getInstance();
        $cfg->lock();
        try {
            $mdl = new Vpnlink();
            $node = $mdl->links->link->add();
            $uuid = $node->getAttribute('uuid');
            $node->setNodes($link);
            $errors = [];
            foreach ($mdl->performValidation() as $msg) {
                $errors[] = $msg->getMessage();
            }
            if ($errors) throw new \RuntimeException('link validation: ' . implode(' ', $errors));
            $mdl->serializeToConfig();
            $cfg->save();
            return $uuid;
        } catch (\Throwable $e) {
            $this->discard($cfg);
            throw $e;
        }
    }

    public function deleteLink($uuid)
    {
        $cfg = Config::getInstance();
        $cfg->lock();
        try {
            $mdl = new Vpnlink();
            $mdl->links->link->del($uuid);
            $mdl->serializeToConfig(false, true);
            $cfg->save();
        } catch (\Throwable $e) {
            $this->discard($cfg);
            throw $e;
        }
    }

    /**
     * Load the new peer: "wireguard configure" alone does not regenerate
     * wgX.conf, the template has to be reloaded first (same as the core
     * WireGuard Apply). Then DNS ACL (new link with DNS sync) and the filter.
     */
    public function apply($syncDns)
    {
        $backend = new Backend();
        $this->checkConfigd('template reload', $backend->configdRun('template reload ' . escapeshellarg('OPNsense/Wireguard')));
        $this->checkConfigd('wireguard configure', $backend->configdpRun('wireguard configure'));
        if ($syncDns) {
            $this->checkConfigd('vpnlink sync_dns', $backend->configdpRun('vpnlink sync_dns'));
        }
        $this->checkConfigd('filter reload', $backend->configdpRun('filter reload'));
    }

    private function checkConfigd($what, $out)
    {
        if (preg_match('/^(Execute error|Action not (found|allowed))/i', trim((string)$out)) ||
            ($what === 'template reload' && stripos((string)$out, 'error') !== false)) {
            throw new \RuntimeException($what . ' failed');
        }
    }

    /** true when "wg show" lists the public key on $wgIf with $ip/32 allowed */
    public function peerLoaded($wgIf, $publicKey, $ip)
    {
        for ($try = 0; $try < 3; $try++) {
            if ($try > 0) sleep(1);
            $data = json_decode((new Backend())->configdRun('wireguard show'), true);
            foreach ($data['records'] ?? [] as $r) {
                if (($r['type'] ?? '') !== 'peer' || ($r['if'] ?? '') !== $wgIf || ($r['public-key'] ?? '') !== $publicKey) continue;
                $allowed = array_map('trim', explode(',', (string)($r['allowed-ips'] ?? '')));
                if (in_array($ip . '/32', $allowed, true)) return true;
            }
        }
        return false;
    }

    public function log($message)
    {
        syslog(LOG_NOTICE, 'VPNLink: ' . $message);
    }
}
