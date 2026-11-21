<?php
/*
 * Tests for src/etc/inc/plugins.inc.d/vpnlink.inc — run with: php tests/php/run.php
 * OPNsense framework classes are replaced by small mocks below.
 */

namespace OPNsense\Core {
    class Config
    {
        public static $xml;
        private static $inst;
        public static function getInstance() { return self::$inst ??= new self(); }
        public function object() { return self::$xml; }
    }
}

namespace OPNsense\Wireguard {
    class Server
    {
        public $servers;
        public function __construct()
        {
            $items = [];
            foreach (\OPNsense\Core\Config::$xml->OPNsense->wireguard->server->servers->server as $i => $s) {
                $items[] = $s;
            }
            $this->servers = (object)['server' => new \MockArray($items)];
        }
    }
}

namespace OPNsense\Routing {
    class Gateways
    {
        /** null = model unavailable (exercise the config.xml fallback) */
        public static $byName = null;
        public function __construct()
        {
            if (self::$byName === null) {
                throw new \RuntimeException('no model in tests: use config fallback');
            }
        }
        public function gatewaysIndexedByName() { return self::$byName; }
    }
}

namespace OPNsense\Vpnlink {
    class Vpnlink
    {
        public static $fixtureLinks = [];
        public $general;
        public $links;
        public function __construct()
        {
            $this->general = (object)['enabled' => '1'];
            $this->links = (object)['link' => new \MockArray(self::$fixtureLinks)];
        }
    }
}

namespace {
    class MockArray
    {
        private $items;
        public function __construct($items) { $this->items = $items; }
        public function iterateItems() { foreach ($this->items as $k => $v) yield "uuid-$k" => $v; }
    }

    /** records everything the hook registers */
    class MockFw
    {
        public $filter = [];
        public $nat = [];
        public function registerFilterRule($prio, $conf, $defaults = null)
        {
            $r = array_merge($defaults ?? [], $conf);
            unset($r['#ref']);
            $this->filter[] = ['prio' => $prio] + $r;
        }
        public function registerSNatRule($prio, $conf) { $this->nat[] = $conf; }
        public function descrs() { return array_column($this->filter, 'descr'); }
    }

    define('VPNLINK_CONFIG_XML', __DIR__ . '/fixtures/config.xml');
    require __DIR__ . '/../../src/etc/inc/plugins.inc.d/vpnlink.inc';
    \OPNsense\Core\Config::$xml = simplexml_load_file(VPNLINK_CONFIG_XML);

    function mklink(array $over = [])
    {
        return (object)array_merge([
            'enabled' => '1', 'name' => 'test', 'source' => '10.10.0.0/24', 'lanInterface' => 'lan',
            'cloneRules' => '1', 'autoNat' => '1', 'dnsSync' => '1',
            'gateway' => '', 'killSwitch' => '0', 'natOnLan' => '1',
            'access' => 'full', 'allowedNets' => '',
        ], $over);
    }

    function run_hook(array $links)
    {
        \OPNsense\Vpnlink\Vpnlink::$fixtureLinks = $links;
        $fw = new MockFw();
        vpnlink_firewall($fw);
        return $fw;
    }

    function by_descr($fw, $needle)
    {
        return array_values(array_filter($fw->filter, fn($r) => str_contains($r['descr'], $needle)));
    }

    $failures = 0;
    $count = 0;
    function check($name, $cond)
    {
        global $failures, $count;
        $count++;
        if ($cond) { echo "  ok   $name\n"; } else { $failures++; echo "  FAIL $name\n"; }
    }

    // ── rule cloning ──
    echo "rule cloning\n";
    $fw = new MockFw();
    vpnlink_clone_lan_rules($fw, \OPNsense\Core\Config::$xml, 'lan', 'opt1', '10.10.0.0/24');
    $d = $fw->descrs();
    check('MVC block rule stays block', by_descr($fw, 'block GUI')[0]['type'] === 'block');
    check('multi-interface MVC rule (lan,opt2) is cloned', count(by_descr($fw, 'block GUI')) === 1);
    check('MVC rules follow sequence order', array_search('VPNLink [lan]: block non-kids to Blocked', $d) < array_search('VPNLink [lan]: block GUI', $d)
        && array_search('VPNLink [lan]: block GUI', $d) < array_search('VPNLink [lan]: default allow', $d));
    check('MVC rules come before legacy rules', array_search('VPNLink [lan]: default allow', $d) < array_search('VPNLink [lan]: legacy lan to opt2 only', $d));
    check('host-specific pass rule skipped', !by_descr($fw, 'admin pc'));
    check('negated host source block is kept', (bool)by_descr($fw, 'non-kids'));
    check('disabled MVC rule skipped', !by_descr($fw, 'mvc disabled'));
    check('disabled legacy rule skipped', !by_descr($fw, 'legacy disabled'));
    check('floating rule skipped', !by_descr($fw, 'floating'));
    check('scheduled pass rule skipped', !by_descr($fw, 'scheduled'));
    check('outbound rule skipped', !by_descr($fw, 'out rule'));
    check('inet6-only rule skipped', !by_descr($fw, 'v6 only'));
    check('inet46 cloned as inet', by_descr($fw, 'default allow')[0]['ipprotocol'] === 'inet');
    check('legacy network destination kept', by_descr($fw, 'legacy lan to opt2')[0]['to'] === 'opt2');
    check('gateway of LAN rule kept', by_descr($fw, 'hosts via VPN gateway')[0]['gateway'] === 'VPN_GW_V4');
    check('port only with tcp/udp', by_descr($fw, 'block GUI')[0]['to_port'] === '443' && !isset(by_descr($fw, 'default allow')[0]['to_port']));
    check('source replaced by VPN subnet', count(array_filter($fw->filter, fn($r) => $r['from'] !== '10.10.0.0/24')) === 0);

    // ── gateway override ──
    echo "gateway override\n";
    $fw = new MockFw();
    vpnlink_clone_lan_rules($fw, \OPNsense\Core\Config::$xml, 'lan', 'opt1', '10.10.0.2', ['gateway' => 'VPN_GROUP']);
    $local = by_descr($fw, 'default allow (local)');
    $via = by_descr($fw, 'default allow (via VPN_GROUP)');
    check('"to any" pass split into local + via gateway', count($local) === 1 && count($via) === 1);
    check('local part has no gateway and targets private nets', !isset($local[0]['gateway']) && str_contains($local[0]['to'], '192.168.0.0/16') && str_contains($local[0]['to'], '(self)'));
    check('local part comes first', $local[0]['prio'] < $via[0]['prio']);
    check('internet part uses override gateway', $via[0]['gateway'] === 'VPN_GROUP');
    check('rule with own gateway untouched', by_descr($fw, 'hosts via VPN gateway')[0]['gateway'] === 'VPN_GW_V4');
    check('specific destination untouched', !isset(by_descr($fw, 'legacy lan to opt2')[0]['gateway']));
    check('block rules never get a gateway', !isset(by_descr($fw, 'block GUI')[0]['gateway']));

    // ── full hook ──
    echo "firewall hook\n";
    $fw = run_hook([mklink(['source' => '10.10.0.2, 10.10.0.3'])]);
    $froms = array_unique(array_column($fw->filter, 'from'));
    sort($froms);
    check('every device in a link gets its own rules', $froms === ['10.10.0.2', '10.10.0.3']);
    check('rules on assigned interface opt1', count(array_filter($fw->filter, fn($r) => $r['interface'] !== 'opt1')) === 0);
    $natIfs = array_column($fw->nat, 'interface');
    check('NAT on wan, lan and VPN gateway interface', in_array('wan', $natIfs) && in_array('lan', $natIfs) && in_array('opt3', $natIfs));

    $fw = run_hook([mklink(['natOnLan' => '0'])]);
    check('natOnLan=0 drops NAT on the LAN', !in_array('lan', array_column($fw->nat, 'interface')) && in_array('wan', array_column($fw->nat, 'interface')));

    $fw = run_hook([mklink(['source' => '10.10.0.2,192.168.1.50,1.2.3.4/99'])]);
    check('sources outside tunnels / invalid are dropped', array_unique(array_column($fw->filter, 'from')) === ['10.10.0.2']);

    $fw = run_hook([mklink(['source' => 'any'])]);
    check('"any" expands to tunnel subnets', array_unique(array_column($fw->filter, 'from')) === ['10.10.0.0/24']);

    $fw = run_hook([mklink(['gateway' => 'NOPE'])]);
    check('unknown gateway override is ignored (no route-to to nowhere)', !by_descr($fw, '(via NOPE)') && !by_descr($fw, '(local)'));

    // ── kill switch ──
    echo "kill switch\n";
    $fw = run_hook([mklink(['source' => '10.10.0.2', 'gateway' => 'VPN_GW_V4', 'killSwitch' => '1'])]);
    $ks = by_descr($fw, 'kill switch');
    check('block-out rule on WAN', count($ks) === 1 && $ks[0]['interface'] === 'wan' && $ks[0]['direction'] === 'out' && $ks[0]['type'] === 'block');
    check('no block on the gateway\'s own interface', !array_filter($ks, fn($r) => $r['interface'] === 'opt3'));
    $tag = $ks[0]['tagged'];
    $pass = array_filter($fw->filter, fn($r) => ($r['type'] ?? '') === 'pass');
    check('every cloned pass rule carries the tag', count($pass) > 0 && count(array_filter($pass, fn($r) => ($r['tag'] ?? '') === $tag)) === count($pass));
    check('kill switch evaluated before user floating rules', $ks[0]['prio'] < 200000);

    $fw = run_hook([mklink(['killSwitch' => '0'])]);
    check('no tag without kill switch', !array_filter($fw->filter, fn($r) => isset($r['tag'])));

    // ── per-link access ──
    echo "access control\n";
    $access = fn($fw) => array_values(array_filter($fw->filter, fn($r) => str_starts_with($r['descr'], 'VPNLink access:')));
    $full = run_hook([mklink()]);
    $legacy = mklink();
    unset($legacy->access, $legacy->allowedNets);
    check('full access (default) adds no access rules', !$access($full));
    check('link without access field (old config) behaves exactly like before', run_hook([$legacy])->filter === $full->filter && run_hook([$legacy])->nat === $full->nat);
    check('unknown access value falls back to full', !$access(run_hook([mklink(['access' => 'bogus'])])));

    $fw = run_hook([mklink(['source' => '10.10.0.4', 'access' => 'internet'])]);
    $a = $access($fw);
    $dns = by_descr($fw, 'DNS to firewall');
    $blockSelf = by_descr($fw, 'block firewall');
    $blockPriv = by_descr($fw, 'block private networks');
    check('internet only: DNS, block firewall, block private (no allow rule)', count($a) === 3 && count($dns) === 1 && count($blockSelf) === 1 && count($blockPriv) === 1);
    check('DNS pass is tcp/udp 53 to (self)', $dns[0]['type'] === 'pass' && $dns[0]['protocol'] === 'tcp/udp' && $dns[0]['to'] === '(self)' && $dns[0]['to_port'] === '53');
    check('firewall itself blocked', $blockSelf[0]['type'] === 'block' && $blockSelf[0]['to'] === '(self)');
    check('private ranges blocked', $blockPriv[0]['type'] === 'block' && $blockPriv[0]['to'] === '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16');
    check('access rules are inet, quick, inbound on the WG interface, from the source', count(array_filter($a, fn($r) =>
        $r['ipprotocol'] === 'inet' && $r['quick'] === true && $r['direction'] === 'in' && $r['interface'] === 'opt1' && $r['from'] === '10.10.0.4')) === 3);
    $cloned = array_values(array_filter($fw->filter, fn($r) => str_starts_with($r['descr'], 'VPNLink [')));
    check('LAN rules still cloned (internet keeps policy routing)', count($cloned) > 0 && (bool)by_descr($fw, 'default allow'));
    check('access rules before every cloned rule', max(array_column($a, 'prio')) < min(array_column($cloned, 'prio')));
    check('access rules before interface-group rules (300000) but after user floating rules (200000)', min(array_column($a, 'prio')) >= 200000 && max(array_column($a, 'prio')) < 300000);
    check('order: DNS < block firewall < block private', $dns[0]['prio'] < $blockSelf[0]['prio'] && $blockSelf[0]['prio'] < $blockPriv[0]['prio']);

    $fw = run_hook([mklink(['source' => '10.10.0.4', 'access' => 'custom', 'allowedNets' => 'opt2, 192.168.50.0/24,Printers,WebPorts,wan,any,(self),nope,0.0.0.0/0,1.2.3.4/0,fd00::/8'])]);
    $allow = by_descr($fw, 'allow selected networks');
    check('custom: one allow rule with the valid entries only', count($allow) === 1 && $allow[0]['to'] === 'opt2,192.168.50.0/24,Printers' && $allow[0]['type'] === 'pass');
    check('custom: firewall blocked before allowed LAN (LAN net contains the firewall IP)', by_descr($fw, 'block firewall')[0]['prio'] < $allow[0]['prio']);
    check('custom: allowed before private block', $allow[0]['prio'] < by_descr($fw, 'block private networks')[0]['prio']);
    check('custom with nothing valid = internet only', !by_descr(run_hook([mklink(['access' => 'custom', 'allowedNets' => 'nope'])]), 'allow selected'));
    check('allowedNets ignored unless custom', !by_descr(run_hook([mklink(['access' => 'internet', 'allowedNets' => 'opt2'])]), 'allow selected'));

    $fw = run_hook([mklink(['source' => '10.10.0.4', 'access' => 'custom', 'allowedNets' => 'opt2', 'gateway' => 'VPN_GW_V4', 'killSwitch' => '1'])]);
    $tag = by_descr($fw, 'kill switch')[0]['tagged'];
    check('allow rule carries the kill switch tag', (by_descr($fw, 'allow selected')[0]['tag'] ?? '') === $tag);
    check('access rules never use a gateway', !array_filter($access($fw), fn($r) => isset($r['gateway'])));

    // restricted peer inside a broader full-access link to the same LAN
    $fw = run_hook([mklink(['source' => '10.10.0.0/24']), mklink(['name' => 'guest', 'source' => '10.10.0.4', 'access' => 'internet'])]);
    $broad = array_values(array_filter($fw->filter, fn($r) => $r['from'] === '10.10.0.0/24'));
    check('restriction of a peer precedes the broad link\'s rules', count($access($fw)) === 3 && max(array_column($access($fw), 'prio')) < min(array_column($broad, 'prio')));
    check('broad link gets no access rules', !array_filter($access($fw), fn($r) => $r['from'] !== '10.10.0.4'));

    $fw = run_hook([mklink(['source' => '10.10.0.4', 'access' => 'internet', 'cloneRules' => '0'])]);
    check('restriction applies even without rule cloning', count($access($fw)) === 3);

    // ── helpers ──
    echo "helpers\n";
    check('valid ip', vpnlink_valid_ipv4_source('10.0.0.1') === '10.0.0.1');
    check('valid cidr normalized', vpnlink_valid_ipv4_source('10.0.0.1/08') === '10.0.0.1/8');
    check('invalid prefix', vpnlink_valid_ipv4_source('1.2.3.4/33') === null);
    check('garbage', vpnlink_valid_ipv4_source('a.b.c.d') === null);
    check('overlap host in subnet', vpnlink_ranges_overlap('10.10.0.5', '10.10.0.0/24'));
    check('overlap any', vpnlink_ranges_overlap('any', '10.1.1.1'));
    check('no overlap', !vpnlink_ranges_overlap('10.10.0.5', '10.10.1.0/24'));
    check('overlap /0', vpnlink_ranges_overlap('0.0.0.0/0', '192.168.1.1'));


    // ── gateway discovery (26.x layout) ──
    echo "gateways (26.x)\n";
    $x26 = simplexml_load_string('<opnsense>
      <interfaces><wan><if>igc0</if></wan><lan><if>igc1</if></lan><opt4><if>igc4</if></opt4>
        <opt7><if>pgw0</if></opt7><opt8><if>ovpnc2</if></opt8></interfaces>
      <gateways>
        <gateway_item><name>STALE_LEGACY</name><interface>opt4</interface></gateway_item>
        <gateway_group><name>NEW_GROUP</name><item>WAN_DHCP</item><item2>VPN26,MISSING</item2></gateway_group>
        <gateway_group><name>OLD_GROUP</name><item>WAN_DHCP|1|address</item><item>VPN26|2|address</item></gateway_group>
      </gateways>
      <OPNsense><Gateways>
        <gateway_item><name>WAN_DHCP</name><interface>wan</interface><ipprotocol>inet</ipprotocol></gateway_item>
        <gateway_item><name>WAN_DHCP6</name><interface>wan</interface><ipprotocol>inet6</ipprotocol><disabled>1</disabled></gateway_item>
        <gateway_item><name>VPN26</name><interface>opt8</interface><ipprotocol>inet</ipprotocol></gateway_item>
      </Gateways></OPNsense>
    </opnsense>');
    $gws = vpnlink_gateway_list($x26);
    check('fallback reads //OPNsense/Gateways', isset($gws['WAN_DHCP'], $gws['VPN26']));
    check('stale legacy //gateways item ignored when MVC path exists', !isset($gws['STALE_LEGACY']));
    check('disabled gateway skipped in fallback', !isset($gws['WAN_DHCP6']));
    check('tunnel gateway is not an uplink', $gws['VPN26']['uplink'] === false && $gws['WAN_DHCP']['uplink'] === true);
    check('26.x group tiers (item, item2 csv) resolved', ($gws['NEW_GROUP']['interfaces'] ?? null) === ['wan', 'opt8']);
    check('legacy group items (GW|tier|trigger) resolved', ($gws['OLD_GROUP']['interfaces'] ?? null) === ['wan', 'opt8']);

    $legacyOnly = simplexml_load_string('<opnsense><interfaces><wan><if>igc0</if></wan></interfaces>
      <gateways><gateway_item><name>OLD_GW</name><interface>wan</interface></gateway_item></gateways></opnsense>');
    check('legacy //gateways used when MVC path absent', isset(vpnlink_gateway_list($legacyOnly)['OLD_GW']));

    // model available: dynamic gateways (not in config.xml) are included
    \OPNsense\Routing\Gateways::$byName = [
        'WAN_DHCP' => ['interface' => 'wan', 'if' => 'igc0', 'ipprotocol' => 'inet'],
        'FRP_GW'   => ['interface' => 'opt7', 'if' => 'pgw0', 'ipprotocol' => 'inet'],
    ];
    $gws = vpnlink_gateway_list($x26);
    check('model gateways used when available', array_keys(array_filter($gws, fn($g) => empty($g['group']))) === ['WAN_DHCP', 'FRP_GW']);

    $saved = \OPNsense\Core\Config::$xml;
    \OPNsense\Core\Config::$xml = $x26;
    $ifs = vpnlink_auto_discover_nat_interfaces('lan');
    check('NAT discovery includes dynamic model gateway interface', in_array('opt7', $ifs, true));
    check('NAT discovery skips stale legacy-only interface', !in_array('opt4', $ifs, true));
    check('NAT discovery keeps wan + lan + ovpn', in_array('wan', $ifs) && in_array('lan', $ifs) && in_array('opt8', $ifs));
    \OPNsense\Routing\Gateways::$byName = null;
    $ifs = vpnlink_auto_discover_nat_interfaces('lan');
    check('NAT discovery without model reads //OPNsense/Gateways', $ifs === ['wan', 'lan', 'opt8']);
    \OPNsense\Core\Config::$xml = $saved;

    echo "\n{$count} checks, {$failures} failed\n";
    exit($failures ? 1 : 0);
}
