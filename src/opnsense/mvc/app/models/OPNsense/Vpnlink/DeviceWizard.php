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

/**
 * "Add device" wizard: creates a WireGuard peer on an instance, the VPN Link
 * link it needs (if any), applies everything and renders the client config.
 *
 * This class is pure logic (no framework calls) so it can be unit tested.
 * Every side effect goes through an $ops object: DeviceWizardBackend on the
 * firewall, a fake in tests. It must provide:
 *
 *   generateKeypair(): [string $private, string $public]
 *   generatePsk(): string
 *   createPeer(array $peer, string $instanceUuid): string   uuid of the new peer
 *   deletePeer(string $uuid, string $instanceUuid): void
 *   createLink(array $link): string                          uuid of the new link
 *   deleteLink(string $uuid): void
 *   apply(bool $syncDns): void       template reload + wireguard configure (+ DNS) + filter reload
 *   peerLoaded(string $wgIf, string $publicKey, string $ip): bool
 *   log(string $message): void
 *
 * SECRET HANDLING (client private key):
 *   The key only lives in a local variable of run() and in the config text
 *   returned by run(). It is never handed to $ops, so it is never stored in
 *   config.xml (the peer's "privkey" field stays empty), never written to a
 *   file and never logged. The GUI shows it once; after that it is gone.
 */
final class DeviceWizard
{
    /** WireGuard peer names: same characters as the core model, must start alphanumeric */
    const NAME_RE = '/^[A-Za-z0-9][A-Za-z0-9_.\-]{0,63}$/';
    /** allowedNets, same as the Vpnlink model mask */
    const NETS_RE = '/^[a-zA-Z0-9_\.\/]{1,64}( *, *[a-zA-Z0-9_\.\/]{1,64})*$/';
    const HOST_RE = '/^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*$/';
    const KEY_RE = '/^[A-Za-z0-9+\/]{42}[AEIMQUYcgkosw480]=$/';
    const DEFAULT_MTU = 1420;
    const DEFAULT_KEEPALIVE = 25;

    // ───────────────────────── IPv4 helpers ─────────────────────────

    /** "a.b.c.d[/n]" -> [network as int, prefix] or null (IPv4 only) */
    public static function parseCidr($s)
    {
        $parts = explode('/', trim((string)$s));
        if (count($parts) > 2 || filter_var($parts[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
            return null;
        }
        $prefix = 32;
        if (count($parts) === 2) {
            if (!ctype_digit($parts[1]) || (int)$parts[1] > 32) return null;
            $prefix = (int)$parts[1];
        }
        $mask = $prefix === 0 ? 0 : (0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF;
        return [ip2long($parts[0]) & $mask, $prefix];
    }

    /** true if IPv4 $ip lies inside $cidr ("any" contains everything) */
    public static function contains($cidr, $ip)
    {
        if (trim((string)$cidr) === 'any') return true;
        $net = self::parseCidr($cidr);
        $addr = self::parseCidr($ip);
        if ($net === null || $addr === null) return false;
        $mask = $net[1] === 0 ? 0 : (0xFFFFFFFF << (32 - $net[1])) & 0xFFFFFFFF;
        return ($addr[0] & $mask) === $net[0];
    }

    /** first IPv4 entry of a tunneladdress list, e.g. "10.10.0.1/24,fd00::1/64" -> ["10.10.0.1", "10.10.0.0/24"] */
    public static function serverAddress($tunnelCsv)
    {
        foreach (array_filter(array_map('trim', explode(',', (string)$tunnelCsv))) as $addr) {
            $net = self::parseCidr($addr);
            if ($net === null || strpos($addr, '/') === false) continue;
            return [explode('/', $addr)[0], long2ip($net[0]) . '/' . $net[1]];
        }
        return null;
    }

    /**
     * Next free host address in the instance's tunnel network.
     * Skips the network/broadcast address, every address of the instance
     * itself and every address/network already used by a peer (any instance:
     * $used is a list of tunneladdress strings).
     * Returns ["ip" => "10.10.0.8", "subnet" => "10.10.0.0/24"] or null.
     */
    public static function nextFreeIp($serverTunnelCsv, array $used)
    {
        $server = self::serverAddress($serverTunnelCsv);
        if ($server === null) return null;
        [$netLong, $prefix] = self::parseCidr($server[1]);
        if ($prefix > 30) return null;

        $taken = [];
        // the instance's own address(es): single hosts, not their whole networks
        foreach (array_filter(array_map('trim', explode(',', (string)$serverTunnelCsv))) as $addr) {
            $host = self::parseCidr(explode('/', $addr)[0]);
            if ($host !== null) $taken[] = $host;
        }
        // peers: every address/network they route (a site peer may own a whole /24)
        foreach ($used as $csv) {
            foreach (array_filter(array_map('trim', explode(',', (string)$csv))) as $addr) {
                $net = self::parseCidr($addr);
                if ($net !== null) $taken[] = $net;
            }
        }

        $size = 1 << (32 - $prefix);
        for ($i = 1; $i < $size - 1; $i++) {
            $cand = $netLong + $i;
            $free = true;
            foreach ($taken as [$tNet, $tPrefix]) {
                $mask = $tPrefix === 0 ? 0 : (0xFFFFFFFF << (32 - $tPrefix)) & 0xFFFFFFFF;
                if (($cand & $mask) === $tNet) { $free = false; break; }
            }
            if ($free) return ['ip' => long2ip($cand), 'subnet' => $server[1]];
        }
        return null;
    }

    // ───────────────────────── validation ─────────────────────────

    /** error text or null; names are compared case-insensitively with all existing WireGuard peers */
    public static function validateName($name, array $existingNames)
    {
        $name = (string)$name;
        if (!preg_match(self::NAME_RE, $name)) {
            return 'Use 1-64 letters, digits, dot, dash or underscore, starting with a letter or digit.';
        }
        foreach ($existingNames as $n) {
            if (strcasecmp((string)$n, $name) === 0) return 'A WireGuard peer with this name already exists.';
        }
        return null;
    }

    private static function validIp($s)
    {
        return filter_var($s, FILTER_VALIDATE_IP) !== false;
    }

    private static function intIn($v, $min, $max)
    {
        $v = trim((string)$v);
        return ctype_digit($v) && (int)$v >= $min && (int)$v <= $max;
    }

    /**
     * Validate + normalize the wizard input.
     * $ctx: see run(). Returns [errors (field => message), normalized input].
     */
    public static function validate(array $req, array $ctx)
    {
        $e = [];
        $in = [];
        $in['name'] = trim((string)($req['name'] ?? ''));
        if (($err = self::validateName($in['name'], $ctx['peerNames'] ?? [])) !== null) $e['name'] = $err;

        $in['instance'] = (string)($req['instance'] ?? '');
        if (!isset($ctx['instances'][$in['instance']])) $e['instance'] = 'Select an enabled WireGuard instance.';

        $in['access'] = (string)($req['access'] ?? 'full');
        if (!in_array($in['access'], ['full', 'internet', 'custom'], true)) $e['access'] = 'Unknown access level.';
        $nets = array_values(array_filter(array_map('trim', explode(',', (string)($req['allowedNets'] ?? '')))));
        $in['allowedNets'] = $in['access'] === 'custom' ? implode(',', array_unique($nets)) : '';
        if ($in['access'] === 'custom') {
            if ($in['allowedNets'] === '') {
                $e['allowedNets'] = 'Select at least one network, or choose Internet only.';
            } elseif (!preg_match(self::NETS_RE, $in['allowedNets'])) {
                $e['allowedNets'] = 'Use interface names, IPv4 networks or alias names, separated by commas.';
            }
        }

        $in['routing'] = (string)($req['routing'] ?? 'full');
        if (!in_array($in['routing'], ['full', 'split'], true)) $e['routing'] = 'Choose full or split tunnel.';

        $in['endpoint'] = trim((string)($req['endpoint'] ?? ''));
        $host = trim($in['endpoint'], '[]');
        if (!self::validIp($host) && !preg_match(self::HOST_RE, $host)) {
            $e['endpoint'] = 'Enter the hostname or IP address clients connect to.';
        }
        $in['endpoint'] = $host;

        $in['port'] = trim((string)($req['port'] ?? ''));
        if (!self::intIn($in['port'], 1, 65535)) $e['port'] = 'Port must be 1-65535.';

        $dns = array_values(array_filter(array_map('trim', explode(',', (string)($req['dns'] ?? '')))));
        foreach ($dns as $d) {
            if (!self::validIp($d)) { $e['dns'] = 'DNS: comma-separated IP addresses.'; break; }
        }
        $in['dns'] = implode(', ', $dns);

        $in['keepalive'] = trim((string)($req['keepalive'] ?? ''));
        if ($in['keepalive'] !== '' && !self::intIn($in['keepalive'], 0, 65535)) $e['keepalive'] = 'Keepalive: 0-65535 seconds (0 = off).';

        $in['mtu'] = trim((string)($req['mtu'] ?? ''));
        if ($in['mtu'] !== '' && !self::intIn($in['mtu'], 1280, 9300)) $e['mtu'] = 'MTU: 1280-9300.';

        $in['psk'] = in_array((string)($req['psk'] ?? '0'), ['1', 'true', 'on'], true);

        $in['lanInterface'] = trim((string)($req['lanInterface'] ?? ''));
        if ($in['lanInterface'] !== '' && !preg_match('/^[a-zA-Z0-9_]{1,32}$/', $in['lanInterface'])) {
            $e['lanInterface'] = 'Invalid interface.';
        }
        return [$e, $in];
    }

    // ───────────────────────── link decision ─────────────────────────

    /** enabled links whose sources contain $ip ("any" or a covering network/host) */
    public static function coveringLinks($ip, array $links)
    {
        $result = [];
        foreach ($links as $l) {
            if ((string)($l['enabled'] ?? '1') !== '1') continue;
            foreach (array_filter(array_map('trim', explode(',', (string)($l['source'] ?? '')))) as $src) {
                if (self::contains($src, $ip)) { $result[] = $l; break; }
            }
        }
        return $result;
    }

    /**
     * Which VPN Link link the new device needs.
     *
     * A link with "Clone firewall rules" that covers the address (e.g. the whole
     * 10.10.0.0/24 -> opt1, or "any") already gives the device internet, NAT and
     * DNS. Then:
     *   - Full:               no link at all.
     *   - Internet / custom:  a link for the single address to the SAME LAN
     *                         (a different LAN would be a source conflict) with
     *                         clone/NAT/DNS off: it only adds the access rules
     *                         (prio 299xxx, before the broad link's cloned rules);
     *                         internet traffic falls through to the broad link.
     * Without such a link the device needs a complete link of its own (clone,
     * NAT, DNS on) to $fallbackLan.
     *
     * Returns ["link" => array|null, "covering" => link|null, "warnings" => [...]]
     * or ["error" => "..."].
     */
    public static function linkPlan($ip, $access, $allowedNets, array $links, $fallbackLan, $name)
    {
        $warnings = [];
        $covering = self::coveringLinks($ip, $links);
        $broad = null;
        foreach ($covering as $l) {
            if ((string)($l['cloneRules'] ?? '1') !== '0') { $broad = $l; break; }
        }
        foreach ($covering as $l) {
            if (in_array((string)($l['access'] ?? 'full'), ['internet', 'custom'], true)) {
                $warnings[] = 'Link "' . ($l['name'] ?? '') . '" restricts ' . $l['source'] . ', which includes this device: its restriction applies too.';
            }
        }

        $link = [
            'enabled'     => '1',
            'name'        => substr(str_replace('.', '-', (string)$name), 0, 64),
            'source'      => $ip,
            'killSwitch'  => '0',
            'gateway'     => '',
            'natOnLan'    => '1',
            'access'      => $access,
            'allowedNets' => $access === 'custom' ? (string)$allowedNets : '',
        ];

        if ($broad !== null) {
            if ($access === 'full') {
                return ['link' => null, 'covering' => $broad, 'warnings' => $warnings];
            }
            return ['link' => $link + [
                'lanInterface' => (string)$broad['lanInterface'],
                'cloneRules'   => '0',
                'autoNat'      => '0',
                'dnsSync'      => '0',
            ], 'covering' => $broad, 'warnings' => $warnings];
        }

        if ((string)$fallbackLan === '') {
            return ['error' => 'No link covers ' . $ip . ' yet: choose the LAN the device should mirror.'];
        }
        // A covering link without rule cloning to another LAN would conflict with ours
        foreach ($covering as $l) {
            if ((string)$l['lanInterface'] !== (string)$fallbackLan) {
                return ['error' => 'Link "' . ($l['name'] ?? '') . '" already covers ' . $ip . ' towards ' . $l['lanInterface'] .
                    ': choose that LAN or edit the link.'];
            }
        }
        return ['link' => $link + [
            'lanInterface' => (string)$fallbackLan,
            'cloneRules'   => '1',
            'autoNat'      => '1',
            'dnsSync'      => '1',
        ], 'covering' => null, 'warnings' => $warnings];
    }

    // ───────────────────────── client config ─────────────────────────

    /**
     * AllowedIPs for the client. Full tunnel: everything. Split: the tunnel
     * network plus the home networks the device may reach (all LAN networks for
     * Full access, the selected networks that resolve to an IPv4 network for
     * custom, nothing else for Internet only = DNS through the tunnel only).
     * $interfaceNets: interface name => network CIDR.
     */
    public static function clientAllowedIps($routing, $access, $tunnelSubnet, array $interfaceNets, $allowedNets)
    {
        if ($routing !== 'split') return '0.0.0.0/0';
        $nets = [$tunnelSubnet];
        if ($access === 'full') {
            $nets = array_merge($nets, array_values($interfaceNets));
        } elseif ($access === 'custom') {
            foreach (array_filter(array_map('trim', explode(',', (string)$allowedNets))) as $n) {
                if (isset($interfaceNets[$n])) {
                    $nets[] = $interfaceNets[$n];
                } elseif (($c = self::parseCidr($n)) !== null && $c[1] > 0) {
                    $nets[] = long2ip($c[0]) . '/' . $c[1];
                }   // aliases can't be resolved here; the user can add them by hand
            }
        }
        return implode(', ', array_values(array_unique(array_filter($nets))));
    }

    /** wg-quick style client config */
    public static function clientConfig(array $c)
    {
        $lines = ['[Interface]', 'PrivateKey = ' . $c['privateKey'], 'Address = ' . $c['address']];
        if (($c['dns'] ?? '') !== '') $lines[] = 'DNS = ' . $c['dns'];
        if (($c['mtu'] ?? '') !== '') $lines[] = 'MTU = ' . $c['mtu'];
        $lines[] = '';
        $lines[] = '[Peer]';
        $lines[] = 'PublicKey = ' . $c['serverPublicKey'];
        if (($c['psk'] ?? '') !== '') $lines[] = 'PresharedKey = ' . $c['psk'];
        $lines[] = 'AllowedIPs = ' . $c['allowedIps'];
        $host = strpos($c['endpointHost'], ':') !== false ? '[' . $c['endpointHost'] . ']' : $c['endpointHost'];
        $lines[] = 'Endpoint = ' . $host . ':' . $c['endpointPort'];
        if ((int)($c['keepalive'] ?? 0) > 0) $lines[] = 'PersistentKeepalive = ' . (int)$c['keepalive'];
        return implode("\n", $lines) . "\n";
    }

    /** file name WireGuard apps accept as tunnel name (max 15 chars) */
    public static function fileName($name)
    {
        $base = substr(preg_replace('/[^A-Za-z0-9_=+.\-]/', '-', (string)$name), 0, 15);
        return ($base === '' ? 'wireguard' : $base) . '.conf';
    }

    // ───────────────────────── defaults ─────────────────────────

    /**
     * Form defaults per enabled instance.
     * $ctx: see run(); $ddnsHost: hostname of an enabled os-ddclient account or '';
     * $wanIp: WAN address or ''.
     */
    public static function defaults(array $ctx, $ddnsHost, $wanIp)
    {
        $instances = [];
        $default = null;
        $most = -1;
        foreach ($ctx['instances'] as $uuid => $inst) {
            $server = self::serverAddress($inst['tunnel']);
            $next = self::nextFreeIp($inst['tunnel'], $ctx['usedAddresses'] ?? []);
            $cover = null;
            $defaultLan = $ctx['defaultLan'] ?? '';
            if ($next !== null) {
                foreach (self::coveringLinks($next['ip'], $ctx['links'] ?? []) as $l) {
                    if ((string)($l['cloneRules'] ?? '1') !== '0') {
                        $cover = ['name' => (string)$l['name'], 'lanInterface' => (string)$l['lanInterface'], 'source' => (string)$l['source']];
                        break;
                    }
                }
            }
            if ($server !== null) {
                // the LAN of an existing (e.g. restricted single-peer) link on this instance
                foreach ($ctx['links'] ?? [] as $l) {
                    $first = trim(explode(',', (string)$l['source'])[0]);
                    if ($first !== 'any' && self::contains($server[1], explode('/', $first)[0])) {
                        $defaultLan = (string)$l['lanInterface'];
                        break;
                    }
                }
            }
            $peerHost = '';
            if (!empty($inst['endpoint'])) {
                // core "peer generator" default endpoint, e.g. "vpn.example.com:51820"
                $peerHost = preg_replace('/:\d+$/', '', trim($inst['endpoint'], ' '));
                $peerHost = trim($peerHost, '[]');
            }
            $endpoint = $ddnsHost !== '' ? $ddnsHost : ($peerHost !== '' ? $peerHost : (string)$wanIp);
            $instances[] = [
                'uuid'       => $uuid,
                'name'       => $inst['name'],
                'interface'  => $inst['if'],
                'subnet'     => $server ? $server[1] : '',
                'address'    => $server ? $server[0] : '',
                'nextIp'     => $next ? $next['ip'] : '',
                'port'       => (string)$inst['port'],
                'mtu'        => (string)$inst['mtu'] !== '' ? (string)$inst['mtu'] : (string)self::DEFAULT_MTU,
                'dns'        => $server ? $server[0] : '',
                'peers'      => (int)$inst['peerCount'],
                'endpoint'   => $endpoint,
                'endpointSource' => $ddnsHost !== '' ? 'ddns' : ($peerHost !== '' ? 'peer generator' : ($wanIp !== '' ? 'wan' : '')),
                'covered'    => $cover,
                'defaultLan' => $defaultLan,
            ];
            if ((int)$inst['peerCount'] > $most) { $most = (int)$inst['peerCount']; $default = $uuid; }
        }
        return [
            'status'        => 'ok',
            'instances'     => $instances,
            'default'       => $default,
            'keepalive'     => (string)self::DEFAULT_KEEPALIVE,
            'pluginEnabled' => !empty($ctx['pluginEnabled']),
        ];
    }

    // ───────────────────────── orchestration ─────────────────────────

    /**
     * Run the wizard.
     *
     * $ctx = [
     *   'instances'     => [uuid => [name, if, tunnel, port, mtu, pubkey, peerCount, endpoint]],  enabled only
     *   'peerNames'     => [...] all WireGuard peer names,
     *   'usedAddresses' => [...] tunneladdress of every peer,
     *   'links'         => [[uuid, name, enabled, source, lanInterface, cloneRules, access], ...],
     *   'interfaceNets' => [ifname => cidr] LAN networks (split tunnel),
     *   'pluginEnabled' => bool,
     * ]
     * Every step after the peer is created is rolled back on failure.
     */
    public static function run($ops, array $ctx, array $req)
    {
        [$errors, $in] = self::validate($req, $ctx);
        if ($errors) return ['status' => 'failed', 'validations' => $errors];

        $inst = $ctx['instances'][$in['instance']];
        if (!preg_match(self::KEY_RE, (string)$inst['pubkey'])) {
            return ['status' => 'failed', 'message' => 'The instance has no valid public key.'];
        }
        $free = self::nextFreeIp($inst['tunnel'], $ctx['usedAddresses'] ?? []);
        if ($free === null) {
            return ['status' => 'failed', 'message' => 'No free address left in the tunnel network of ' . $inst['name'] . '.'];
        }
        $plan = self::linkPlan($free['ip'], $in['access'], $in['allowedNets'], $ctx['links'] ?? [], $in['lanInterface'], $in['name']);
        if (isset($plan['error'])) return ['status' => 'failed', 'validations' => ['lanInterface' => $plan['error']]];
        $warnings = $plan['warnings'];
        if (empty($ctx['pluginEnabled']) && ($plan['link'] !== null || $in['access'] !== 'full')) {
            $warnings[] = 'VPN Link is disabled: the link (and its access restriction) only takes effect once the plugin is enabled and applied.';
        }

        // 1. keys (nothing created yet, nothing to roll back)
        try {
            // $clientPrivateKey: never passed to $ops / stored / logged, only rendered into the reply below
            [$clientPrivateKey, $clientPublicKey] = $ops->generateKeypair();
            $psk = $in['psk'] ? (string)$ops->generatePsk() : '';
        } catch (\Throwable $e) {
            return ['status' => 'failed', 'message' => 'Could not generate keys: ' . $e->getMessage()];
        }
        if (!preg_match(self::KEY_RE, (string)$clientPrivateKey) || !preg_match(self::KEY_RE, (string)$clientPublicKey) ||
            ($psk !== '' && !preg_match(self::KEY_RE, $psk))) {
            return ['status' => 'failed', 'message' => 'Key generation returned an unexpected result.'];
        }

        // 2.-5. peer, link, apply; undo on failure
        $created = ['peer' => null, 'link' => null];
        $applying = false;
        $step = 'create the WireGuard peer';
        try {
            $created['peer'] = $ops->createPeer([
                'name'          => $in['name'],
                'pubkey'        => $clientPublicKey,
                'psk'           => $psk,
                'tunneladdress' => $free['ip'] . '/32',
                'keepalive'     => '',   // the client keeps the tunnel alive, not the server
            ], $in['instance']);
            $ops->log("device wizard: peer '{$in['name']}' {$free['ip']} added to {$inst['name']}");

            if ($plan['link'] !== null) {
                $step = 'create the VPN Link link';
                $created['link'] = $ops->createLink($plan['link']);
                $ops->log("device wizard: link for {$free['ip']} -> {$plan['link']['lanInterface']} ({$in['access']})");
            }

            $step = 'apply the configuration';
            $applying = true;
            $ops->apply($plan['link'] !== null && $plan['link']['dnsSync'] === '1');
        } catch (\Throwable $e) {
            $rollback = self::rollback($ops, $created, $in['instance'], $applying);
            $ops->log("device wizard: failed to {$step} for '{$in['name']}', rolled back" . ($rollback ? ' with errors' : ''));
            return [
                'status'         => 'failed',
                'message'        => 'Could not ' . $step . ': ' . $e->getMessage() .
                    ($rollback ? ' Rollback incomplete: ' . implode('; ', $rollback) : ' Nothing was changed.'),
                'rolledBack'     => empty($rollback),
            ];
        }

        // 6. verify that the running WireGuard instance knows the peer
        try {
            $loaded = (bool)$ops->peerLoaded($inst['if'], $clientPublicKey, $free['ip']);
        } catch (\Throwable $e) {
            $loaded = false;
        }
        if (!$loaded) {
            $warnings[] = 'The peer is saved but not loaded on ' . $inst['if'] . ' yet: check VPN > WireGuard and click Apply there.';
        }

        $dns = $in['dns'];
        $config = self::clientConfig([
            'privateKey'      => $clientPrivateKey,
            'address'         => $free['ip'] . '/32',
            'dns'             => $dns,
            'mtu'             => $in['mtu'],
            'serverPublicKey' => $inst['pubkey'],
            'psk'             => $psk,
            'allowedIps'      => self::clientAllowedIps($in['routing'], $in['access'], $free['subnet'], $ctx['interfaceNets'] ?? [], $in['allowedNets']),
            'endpointHost'    => $in['endpoint'],
            'endpointPort'    => $in['port'],
            'keepalive'       => $in['keepalive'] === '' ? 0 : (int)$in['keepalive'],
        ]);
        unset($clientPrivateKey);

        return [
            'status'   => 'ok',
            // contains the private key: shown once by the GUI, not kept anywhere on the firewall
            'config'   => $config,
            'filename' => self::fileName($in['name']),
            'summary'  => [
                'name'       => $in['name'],
                'instance'   => $inst['name'],
                'interface'  => $inst['if'],
                'ip'         => $free['ip'],
                'access'     => $in['access'],
                'allowedNets' => $in['allowedNets'],
                'routing'    => $in['routing'],
                'link'       => $plan['link'] !== null ? 'created (' . $plan['link']['lanInterface'] . ')' :
                    'not needed (covered by "' . $plan['covering']['name'] . '")',
                'peerLoaded' => $loaded,
                'psk'        => $psk !== '',
            ],
            'warnings' => $warnings,
        ];
    }

    /** undo created objects (link first, then peer), re-apply if apply had started; returns error texts */
    public static function rollback($ops, array $created, $instanceUuid, $reapply)
    {
        $errors = [];
        if ($created['link'] !== null) {
            try { $ops->deleteLink($created['link']); } catch (\Throwable $e) { $errors[] = 'link: ' . $e->getMessage(); }
        }
        if ($created['peer'] !== null) {
            try { $ops->deletePeer($created['peer'], $instanceUuid); } catch (\Throwable $e) { $errors[] = 'peer: ' . $e->getMessage(); }
        }
        if ($reapply) {
            try { $ops->apply($created['link'] !== null); } catch (\Throwable $e) { $errors[] = 'apply: ' . $e->getMessage(); }
        }
        return $errors;
    }
}
