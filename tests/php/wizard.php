<?php
/*
 * Tests for the "Add device" wizard (DeviceWizard.php). Included by run.php,
 * which provides check().
 */

namespace {
    require_once __DIR__ . '/../../src/opnsense/mvc/app/models/OPNsense/Vpnlink/DeviceWizard.php';

    use OPNsense\Vpnlink\DeviceWizard as W;

    /** records every call; $fail = method name that throws */
    class FakeWizardOps
    {
        public $calls = [];
        public $fail = null;
        public $loaded = true;
        public $priv;
        public $pub;
        public function __construct()
        {
            $this->priv = base64_encode(str_repeat("\x11", 31) . "\x40");
            $this->pub = base64_encode(str_repeat("\x22", 32));
        }
        private function rec($m, $args)
        {
            $this->calls[] = [$m, $args];
            if ($this->fail === $m) throw new \RuntimeException("$m broke");
        }
        public function generateKeypair() { $this->rec('generateKeypair', []); return [$this->priv, $this->pub]; }
        public function generatePsk() { $this->rec('generatePsk', []); return base64_encode(str_repeat("\x33", 32)); }
        public function createPeer(array $peer, $inst) { $this->rec('createPeer', [$peer, $inst]); return 'peer-uuid'; }
        public function deletePeer($uuid, $inst) { $this->rec('deletePeer', [$uuid, $inst]); }
        public function createLink(array $link) { $this->rec('createLink', [$link]); return 'link-uuid'; }
        public function deleteLink($uuid) { $this->rec('deleteLink', [$uuid]); }
        public function apply($syncDns) { $this->rec('apply', [$syncDns]); }
        public function peerLoaded($if, $pub, $ip) { $this->rec('peerLoaded', [$if, $pub, $ip]); return $this->loaded; }
        public function log($msg) { $this->rec('log', [$msg]); }
        public function names() { return array_column($this->calls, 0); }
    }

    function wiz_ctx(array $over = [])
    {
        return array_merge([
            'instances' => [
                'inst-0' => ['name' => 'HomeWG', 'if' => 'wg0', 'tunnel' => '10.10.0.1/24', 'port' => '51820', 'mtu' => '',
                             'pubkey' => base64_encode(str_repeat("\x44", 32)), 'peerCount' => 2, 'endpoint' => ''],
                'inst-1' => ['name' => 'Other', 'if' => 'wg1', 'tunnel' => '10.20.0.1/24', 'port' => '51821', 'mtu' => '1380',
                             'pubkey' => base64_encode(str_repeat("\x55", 32)), 'peerCount' => 0, 'endpoint' => 'vpn.example.net:51821'],
            ],
            'peerNames' => ['my-iphone', 'my-mbp'],
            'usedAddresses' => ['10.10.0.3/32', '10.10.0.2/32'],
            'links' => [
                ['uuid' => 'l1', 'name' => 'all', 'enabled' => '1', 'source' => '10.10.0.0/24', 'lanInterface' => 'opt1', 'cloneRules' => '1', 'access' => 'full'],
            ],
            'interfaceNets' => ['lan' => '192.168.1.0/24', 'opt1' => '192.168.70.0/24', 'opt2' => '192.168.50.0/24'],
            'pluginEnabled' => true,
            'defaultLan' => 'lan',
        ], $over);
    }

    function wiz_req(array $over = [])
    {
        return array_merge([
            'name' => 'work-laptop', 'instance' => 'inst-0', 'access' => 'internet', 'allowedNets' => '',
            'routing' => 'full', 'endpoint' => 'home.example.com', 'port' => '51820', 'dns' => '10.10.0.1',
            'keepalive' => '25', 'mtu' => '1420', 'psk' => '0', 'lanInterface' => '',
        ], $over);
    }

    // ── next free IP ──
    echo "wizard: next free IP\n";
    check('first gap after server and peers', W::nextFreeIp('10.10.0.1/24', ['10.10.0.2/32', '10.10.0.3/32'])['ip'] === '10.10.0.4');
    check('fills holes', W::nextFreeIp('10.10.0.1/24', ['10.10.0.2/32', '10.10.0.4/32'])['ip'] === '10.10.0.3');
    check('peer owning a network (site router) blocks the whole range', W::nextFreeIp('10.10.0.1/24', ['10.10.0.2/32,10.10.0.0/29'])['ip'] === '10.10.0.8');
    check('server address need not be .1', W::nextFreeIp('10.10.0.254/24', [])['ip'] === '10.10.0.1');
    check('IPv6 tunnel entries skipped, subnet reported', W::nextFreeIp('fd00::1/64,10.10.0.1/24', []) === ['ip' => '10.10.0.2', 'subnet' => '10.10.0.0/24']);
    check('all server addresses are skipped', W::nextFreeIp('10.10.0.1/24,10.10.0.2/24', [])['ip'] === '10.10.0.3');
    check('peers of other subnets / IPv6 ignored', W::nextFreeIp('10.10.0.1/24', ['10.20.0.2/32', 'fd00::2/128'])['ip'] === '10.10.0.2');
    check('never the broadcast address: full /30 -> null', W::nextFreeIp('10.10.0.1/30', ['10.10.0.2/32']) === null);
    check('/31 and /32 tunnels have no room', W::nextFreeIp('10.10.0.1/31', []) === null && W::nextFreeIp('10.10.0.1/32', []) === null);
    check('no IPv4 tunnel address -> null', W::nextFreeIp('fd00::1/64', []) === null);

    // ── names ──
    echo "wizard: name validation\n";
    check('valid name', W::validateName('work-laptop_2.home', ['other']) === null);
    check('empty rejected', W::validateName('', []) !== null);
    check('space / slash / newline rejected', W::validateName('a b', []) !== null && W::validateName('a/b', []) !== null && W::validateName("a\nb", []) !== null);
    check('must start alphanumeric', W::validateName('-x', []) !== null && W::validateName('.x', []) !== null);
    check('max 64 chars', W::validateName(str_repeat('a', 64), []) === null && W::validateName(str_repeat('a', 65), []) !== null);
    check('duplicate peer name rejected (case-insensitive)', W::validateName('My-iPhone', ['my-iphone']) !== null);
    [$e] = W::validate(wiz_req(['name' => 'my-mbp']), wiz_ctx());
    check('validate() reports duplicate name', isset($e['name']));
    [$e] = W::validate(wiz_req(['endpoint' => "evil\nDNS = 1.1.1.1", 'dns' => '1.1.1.1\n', 'port' => '0', 'mtu' => '99', 'keepalive' => 'x']), wiz_ctx());
    check('validate() rejects config injection and out-of-range values', isset($e['endpoint'], $e['dns'], $e['port'], $e['mtu'], $e['keepalive']));
    [$e] = W::validate(wiz_req(['access' => 'custom', 'allowedNets' => '']), wiz_ctx());
    check('custom access needs networks', isset($e['allowedNets']));
    [$e] = W::validate(wiz_req(['instance' => 'nope']), wiz_ctx());
    check('unknown instance rejected', isset($e['instance']));
    [$e, $in] = W::validate(wiz_req(['endpoint' => '[2001:db8::1]']), wiz_ctx());
    check('IPv6 endpoint accepted (brackets stripped)', !$e && $in['endpoint'] === '2001:db8::1');

    // ── config text ──
    echo "wizard: client config\n";
    $cfg = W::clientConfig([
        'privateKey' => 'PRIV=', 'address' => '10.10.0.8/32', 'dns' => '10.10.0.1', 'mtu' => '1420',
        'serverPublicKey' => 'SPUB=', 'psk' => 'PSK=', 'allowedIps' => '0.0.0.0/0',
        'endpointHost' => 'home.example.com', 'endpointPort' => '51820', 'keepalive' => 25,
    ]);
    check('full config rendered', $cfg === "[Interface]\nPrivateKey = PRIV=\nAddress = 10.10.0.8/32\nDNS = 10.10.0.1\nMTU = 1420\n\n" .
        "[Peer]\nPublicKey = SPUB=\nPresharedKey = PSK=\nAllowedIPs = 0.0.0.0/0\nEndpoint = home.example.com:51820\nPersistentKeepalive = 25\n");
    $cfg = W::clientConfig([
        'privateKey' => 'PRIV=', 'address' => '10.10.0.8/32', 'dns' => '', 'mtu' => '',
        'serverPublicKey' => 'SPUB=', 'psk' => '', 'allowedIps' => '10.10.0.0/24', 'endpointHost' => '2001:db8::1', 'endpointPort' => '51820', 'keepalive' => 0,
    ]);
    check('optional lines omitted, IPv6 endpoint bracketed', $cfg === "[Interface]\nPrivateKey = PRIV=\nAddress = 10.10.0.8/32\n\n" .
        "[Peer]\nPublicKey = SPUB=\nAllowedIPs = 10.10.0.0/24\nEndpoint = [2001:db8::1]:51820\n");
    $nets = ['lan' => '192.168.1.0/24', 'opt2' => '192.168.50.0/24'];
    check('full tunnel = 0.0.0.0/0', W::clientAllowedIps('full', 'custom', '10.10.0.0/24', $nets, 'opt2') === '0.0.0.0/0');
    check('split + full access = tunnel + all LANs', W::clientAllowedIps('split', 'full', '10.10.0.0/24', $nets, '') === '10.10.0.0/24, 192.168.1.0/24, 192.168.50.0/24');
    check('split + custom = tunnel + selected (interfaces resolved, CIDRs normalized, aliases skipped)',
        W::clientAllowedIps('split', 'custom', '10.10.0.0/24', $nets, 'opt2,10.5.5.5/16,MyAlias') === '10.10.0.0/24, 192.168.50.0/24, 10.5.0.0/16');
    check('split + internet = tunnel only', W::clientAllowedIps('split', 'internet', '10.10.0.0/24', $nets, '') === '10.10.0.0/24');
    check('file name sanitized to 15 chars', W::fileName('work laptop/very-long-name') === 'work-laptop-ver.conf');

    // ── link decision ──
    echo "wizard: link decision\n";
    $broad = ['uuid' => 'l1', 'name' => 'all', 'enabled' => '1', 'source' => '10.10.0.0/24', 'lanInterface' => 'opt1', 'cloneRules' => '1', 'access' => 'full'];
    $p = W::linkPlan('10.10.0.8', 'full', '', [$broad], '', 'dev');
    check('full + broad link: no link', $p['link'] === null && $p['covering']['uuid'] === 'l1');
    $p = W::linkPlan('10.10.0.8', 'internet', '', [$broad], 'lan', 'dev.x');
    check('internet + broad link: single-address link to the same LAN, clone/NAT/DNS off',
        $p['link']['source'] === '10.10.0.8' && $p['link']['lanInterface'] === 'opt1' && $p['link']['access'] === 'internet' &&
        $p['link']['cloneRules'] === '0' && $p['link']['autoNat'] === '0' && $p['link']['dnsSync'] === '0' && $p['link']['allowedNets'] === '');
    check('link name fits the link mask (no dots)', preg_match('/^[a-zA-Z0-9_ \-]{1,64}$/', $p['link']['name']) === 1);
    $p = W::linkPlan('10.10.0.8', 'custom', 'opt2,Printers', [$broad], '', 'dev');
    check('custom + broad link: allowed networks kept', $p['link']['access'] === 'custom' && $p['link']['allowedNets'] === 'opt2,Printers' && $p['link']['cloneRules'] === '0');
    $p = W::linkPlan('10.10.0.8', 'full', '', [], 'lan', 'dev');
    check('full, nothing covers: own complete link to the chosen LAN',
        $p['link']['lanInterface'] === 'lan' && $p['link']['cloneRules'] === '1' && $p['link']['autoNat'] === '1' && $p['link']['dnsSync'] === '1' && $p['link']['access'] === 'full');
    $p = W::linkPlan('10.10.0.8', 'internet', '', [], 'lan', 'dev');
    check('internet, nothing covers: complete link with restriction', $p['link']['cloneRules'] === '1' && $p['link']['access'] === 'internet');
    check('nothing covers and no LAN chosen: error', isset(W::linkPlan('10.10.0.8', 'full', '', [], '', 'dev')['error']));
    $any = ['name' => 'any', 'enabled' => '1', 'source' => 'any', 'lanInterface' => 'lan', 'cloneRules' => '1', 'access' => 'full'];
    check('"any" link covers', W::linkPlan('10.10.0.8', 'full', '', [$any], '', 'dev')['link'] === null);
    check('disabled broad link does not cover', W::linkPlan('10.10.0.8', 'full', '', [['enabled' => '0'] + $broad], 'lan', 'dev')['link']['lanInterface'] === 'lan');
    $peerLink = ['name' => 'slalom', 'enabled' => '1', 'source' => '10.10.0.5', 'lanInterface' => 'opt1', 'cloneRules' => '0', 'access' => 'internet'];
    check('another peer\'s link does not cover', W::linkPlan('10.10.0.8', 'full', '', [$peerLink], 'lan', 'dev')['link']['cloneRules'] === '1');
    $p2 = W::linkPlan('10.10.0.8', 'full', '', [array_merge($broad, ['access' => 'internet'])], '', 'dev');
    check('restricted broad link: warning that it applies', $p2['link'] === null && count($p2['warnings']) === 1);
    $noClone = ['name' => 'nc', 'enabled' => '1', 'source' => '10.10.0.0/24', 'lanInterface' => 'opt1', 'cloneRules' => '0', 'access' => 'internet'];
    check('covering link without cloning towards another LAN: error (would conflict)', isset(W::linkPlan('10.10.0.8', 'full', '', [$noClone], 'lan', 'dev')['error']));

    // ── defaults ──
    echo "wizard: defaults\n";
    $d = W::defaults(wiz_ctx(), '', '203.0.113.7');
    check('default instance = the one with most peers', $d['default'] === 'inst-0');
    check('instance defaults: next IP, DNS = tunnel IP, MTU fallback 1420, WAN endpoint',
        $d['instances'][0]['nextIp'] === '10.10.0.4' && $d['instances'][0]['dns'] === '10.10.0.1' && $d['instances'][0]['mtu'] === '1420' &&
        $d['instances'][0]['endpoint'] === '203.0.113.7' && $d['instances'][0]['endpointSource'] === 'wan');
    check('covering link reported', $d['instances'][0]['covered']['name'] === 'all' && $d['instances'][1]['covered'] === null);
    check('instance MTU and peer generator endpoint used', $d['instances'][1]['mtu'] === '1380' && $d['instances'][1]['endpoint'] === 'vpn.example.net');
    check('DDNS hostname wins', W::defaults(wiz_ctx(), 'home.example.com', '203.0.113.7')['instances'][1]['endpoint'] === 'home.example.com');

    // ── orchestration ──
    echo "wizard: run + rollback\n";
    $ops = new FakeWizardOps();
    $r = W::run($ops, wiz_ctx(), wiz_req(['psk' => '1']));
    check('success: status ok', $r['status'] === 'ok');
    check('success: order keys, peer, link, apply, verify', array_values(array_diff($ops->names(), ['log'])) === ['generateKeypair', 'generatePsk', 'createPeer', 'createLink', 'apply', 'peerLoaded']);
    $peer = $ops->calls[2][1][0];
    check('peer: public key, /32, empty server keepalive, attached to the instance',
        $peer['pubkey'] === $ops->pub && $peer['tunneladdress'] === '10.10.0.4/32' && $peer['keepalive'] === '' && $ops->calls[2][1][1] === 'inst-0' && $peer['psk'] !== '');
    check('config holds private key, address, server key, PSK, endpoint', str_contains($r['config'], 'PrivateKey = ' . $ops->priv) &&
        str_contains($r['config'], 'Address = 10.10.0.4/32') && str_contains($r['config'], 'PublicKey = ' . base64_encode(str_repeat("\x44", 32))) &&
        str_contains($r['config'], 'PresharedKey = ') && str_contains($r['config'], 'Endpoint = home.example.com:51820'));
    check('private key never handed to the backend (store/log/apply)', !str_contains(json_encode($ops->calls, JSON_UNESCAPED_SLASHES), $ops->priv));
    $rest = $r;
    unset($rest['config']);
    check('private key only in the config text of the reply', substr_count($r['config'], $ops->priv) === 1 && !str_contains(json_encode($rest, JSON_UNESCAPED_SLASHES), $ops->priv));
    check('summary: ip, access, loaded', $r['summary']['ip'] === '10.10.0.4' && $r['summary']['access'] === 'internet' && $r['summary']['peerLoaded'] === true);
    check('restricted link without DNS sync: apply without sync_dns', in_array(['apply', [false]], $ops->calls, true));

    $ops = new FakeWizardOps();
    $r = W::run($ops, wiz_ctx(), wiz_req(['access' => 'full']));
    check('full access under broad link: no link created', $r['status'] === 'ok' && !in_array('createLink', $ops->names()) && !in_array('generatePsk', $ops->names()));

    $ops = new FakeWizardOps();
    $r = W::run($ops, wiz_ctx(['links' => []]), wiz_req(['access' => 'full', 'lanInterface' => 'lan']));
    check('own complete link: apply with DNS sync', $r['status'] === 'ok' && in_array(['apply', [true]], $ops->calls, true));

    $ops = new FakeWizardOps();
    $ops->loaded = false;
    $r = W::run($ops, wiz_ctx(), wiz_req());
    check('peer not loaded: still ok, reported + warning, nothing rolled back', $r['status'] === 'ok' && $r['summary']['peerLoaded'] === false && count($r['warnings']) === 1 &&
        !in_array('deletePeer', $ops->names()));

    $ops = new FakeWizardOps();
    $ops->fail = 'createLink';
    $r = W::run($ops, wiz_ctx(), wiz_req());
    check('link fails: peer deleted, no apply', $r['status'] === 'failed' && in_array(['deletePeer', ['peer-uuid', 'inst-0']], $ops->calls, true) &&
        !in_array('apply', $ops->names()) && $r['rolledBack'] === true && !isset($r['config']));

    $ops = new FakeWizardOps();
    $ops->fail = 'apply';
    $r = W::run($ops, wiz_ctx(), wiz_req());
    $n = $ops->names();
    check('apply fails: link + peer deleted, applied again', $r['status'] === 'failed' && in_array('deleteLink', $n) && in_array('deletePeer', $n) &&
        array_search('deleteLink', $n) < array_search('deletePeer', $n) && count(array_keys($n, 'apply')) === 2);
    check('apply fails: error names the step and secret is not in the reply', str_contains($r['message'], 'apply') && !str_contains(json_encode($r, JSON_UNESCAPED_SLASHES), $ops->priv));

    $ops = new FakeWizardOps();
    $ops->fail = 'createPeer';
    $r = W::run($ops, wiz_ctx(), wiz_req());
    check('peer fails: nothing to delete', $r['status'] === 'failed' && !in_array('deletePeer', $ops->names()) && !in_array('createLink', $ops->names()));

    $ops = new class extends FakeWizardOps {
        public function createLink(array $link) { throw new \RuntimeException('link broke'); }
        public function deletePeer($uuid, $inst) { throw new \RuntimeException('peer stuck'); }
    };
    $r = W::run($ops, wiz_ctx(), wiz_req());
    check('incomplete rollback is reported', $r['status'] === 'failed' && $r['rolledBack'] === false && str_contains($r['message'], 'peer stuck'));

    $ops = new FakeWizardOps();
    $r = W::run($ops, wiz_ctx(), wiz_req(['name' => 'bad name']));
    check('validation failure: no side effects at all', $r['status'] === 'failed' && isset($r['validations']['name']) && $ops->calls === []);

    $ops = new class extends FakeWizardOps {
        public function generateKeypair() { return ['not a key', 'x']; }
    };
    $r = W::run($ops, wiz_ctx(), wiz_req());
    check('bad key generator output: nothing created', $r['status'] === 'failed' && !in_array('createPeer', $ops->names()));

    $full = wiz_ctx(['usedAddresses' => array_map(fn($i) => "10.10.0.$i/32", range(2, 254))]);
    $ops = new FakeWizardOps();
    check('no free address: error before keys', W::run($ops, $full, wiz_req())['status'] === 'failed' && $ops->calls === []);

    $ops = new FakeWizardOps();
    $r = W::run($ops, wiz_ctx(['pluginEnabled' => false]), wiz_req());
    check('plugin disabled: restricted device warns', $r['status'] === 'ok' && (bool)array_filter($r['warnings'], fn($w) => str_contains($w, 'disabled')));

    // ── static: the private key never reaches config, files or logs ──
    echo "wizard: private key handling (static)\n";
    $root = __DIR__ . '/../../src/opnsense/mvc/app';
    $wiz = file_get_contents("$root/models/OPNsense/Vpnlink/DeviceWizard.php");
    $be = file_get_contents("$root/models/OPNsense/Vpnlink/DeviceWizardBackend.php");
    $ctl = file_get_contents("$root/controllers/OPNsense/Vpnlink/Api/DeviceController.php");
    $code = fn($s) => implode("\n", array_filter(explode("\n", $s), fn($l) => !preg_match('#^\s*(\*|/\*|//)#', $l)));
    $uses = array_values(array_filter(explode("\n", $code($wiz)), fn($l) => str_contains($l, '$clientPrivateKey')));
    $allowed = array_filter($uses, fn($l) => preg_match('/=\s*\$ops->generateKeypair\(\)|preg_match\(self::KEY_RE, \(string\)\$clientPrivateKey\)|\'privateKey\'\s*=>\s*\$clientPrivateKey,|unset\(\$clientPrivateKey\)/', $l));
    check('DeviceWizard: private key only generated, checked, rendered, unset', count($uses) === 4 && count($allowed) === count($uses));
    check('DeviceWizard: no $ops call receives the private key', !preg_match('/\$ops->\w+\([^;]*(clientPrivateKey|privateKey)/', $code($wiz)));
    check('DeviceWizard: no syslog/file/error_log calls at all', !preg_match('/\b(syslog|error_log|file_put_contents|fwrite|fopen)\s*\(/', $code($wiz)));
    check('backend: peer "privkey" field never set', !preg_match('/[\'"]privkey[\'"]\s*=>|->privkey\s*=/', $code($be)));
    check('backend: no method takes a private key argument', !preg_match('/function \w+\([^)]*priv/i', $code($be)));
    check('backend: logs only via log(), never key material', preg_match_all('/\bsyslog\s*\(/', $code($be)) === 1 && !preg_match('/\b(error_log|file_put_contents|fwrite)\s*\(/', $code($be)) &&
        !preg_match('/syslog\([^;]*(priv|\$data|\$result)/i', $code($be)));
    check('backend: gen_keypair failure message does not include the output', !preg_match('/Exception\([^;]*\$data/', $code($be)));
    check('controller: no logging, no privkey', !preg_match('/\b(syslog|error_log|file_put_contents)\s*\(|privkey/', $code($ctl)));
}
