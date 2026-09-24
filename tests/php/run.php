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
        public function __construct() { throw new \RuntimeException('no model in tests: use config fallback'); }
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

    echo "\n{$count} checks, {$failures} failed\n";
    exit($failures ? 1 : 0);
}
