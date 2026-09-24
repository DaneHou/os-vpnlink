"""
Tests for the configd backend scripts. Run with:
    python3 -m unittest discover -s tests/python
"""
import os
import sqlite3
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'src', 'opnsense', 'scripts', 'OPNsense', 'Vpnlink'))
import vpnlink  # noqa: E402
import collect_traffic  # noqa: E402


CONFIG = """
<opnsense><OPNsense>
  <wireguard><server><servers>
    <server><enabled>1</enabled><instance>0</instance><tunneladdress>10.10.0.1/24,fd00::1/64</tunneladdress></server>
    <server><enabled>0</enabled><instance>2</instance><tunneladdress>10.30.0.1/24</tunneladdress></server>
  </servers></server></wireguard>
  <Vpnlink><general><enabled>{enabled}</enabled></general><links>{links}</links></Vpnlink>
</OPNsense></opnsense>
"""


def link(source, dns='1', enabled='1'):
    return '<link><enabled>{}</enabled><source>{}</source><dnsSync>{}</dnsSync></link>'.format(enabled, source, dns)


class DnsSyncTargets(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = os.path.join(self.tmp.name, 'config.xml')
        patcher = mock.patch.object(vpnlink, 'CONFIG_XML', self.cfg)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def write(self, links, enabled='1'):
        with open(self.cfg, 'w') as f:
            f.write(CONFIG.format(enabled=enabled, links=''.join(links)))

    def test_only_linked_sources_with_dns_sync(self):
        self.write([link('10.10.0.5'), link('10.10.0.0/24', dns='0')])
        self.assertEqual(vpnlink.dns_sync_targets(), (True, ['10.10.0.5/32'], ['wg0']))

    def test_any_uses_enabled_server_subnets_only(self):
        self.write([link('any')])
        self.assertEqual(vpnlink.dns_sync_targets(), (True, ['10.10.0.0/24'], ['wg0']))

    def test_disabled_plugin_yields_nothing(self):
        self.write([link('any')], enabled='0')
        self.assertEqual(vpnlink.dns_sync_targets(), (False, [], []))

    def test_disabled_link_and_garbage_ignored(self):
        self.write([link('10.10.0.9', enabled='0'), link('not-an-ip')])
        self.assertEqual(vpnlink.dns_sync_targets(), (True, [], []))

    def test_missing_config_fails_closed(self):
        self.assertEqual(vpnlink.dns_sync_targets(), (False, [], []))


class AtomicWrite(unittest.TestCase):
    def test_refuses_planted_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            target = os.path.join(d, 'acl.conf')
            victim = os.path.join(d, 'victim')
            open(victim, 'w').write('keep')
            os.symlink(victim, target + '.vpnlink.tmp')
            vpnlink.write_file_atomic(target, 'new')
            self.assertEqual(open(target).read(), 'new')
            self.assertEqual(open(victim).read(), 'keep')


@unittest.skipUnless(__import__('importlib').util.find_spec('yaml'), 'PyYAML not installed')
class AdGuardBinds(unittest.TestCase):
    def write(self, body):
        d = tempfile.mkdtemp()
        path = os.path.join(d, 'AdGuardHome.yaml')
        with open(path, 'w') as f:
            f.write(textwrap.dedent(body))
        return path

    def test_adds_ip_keeps_order_and_backup(self):
        path = self.write("""
            http:
              address: 0.0.0.0:3000
            dns:
              bind_hosts:
                - 192.168.1.1
              port: 53
        """)
        with mock.patch.object(vpnlink, 'syslog_msg'):
            self.assertTrue(vpnlink.sync_adguard_binds(path, ['10.10.0.1']))
        content = open(path).read()
        self.assertIn('10.10.0.1', content)
        self.assertLess(content.index('http:'), content.index('dns:'))  # key order kept
        self.assertTrue(os.path.exists(path + '.vpnlink.bak'))

    def test_wildcard_bind_untouched(self):
        path = self.write("""
            dns:
              bind_hosts:
                - 0.0.0.0
        """)
        with mock.patch.object(vpnlink, 'syslog_msg'):
            self.assertFalse(vpnlink.sync_adguard_binds(path, ['10.10.0.1']))


class Collector(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        patcher = mock.patch.object(collect_traffic, 'DB_PATH', os.path.join(self.tmp.name, 't.db'))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def run_at(self, now, rx):
        with mock.patch.object(collect_traffic.time, 'time', return_value=now), \
             mock.patch.object(collect_traffic, 'get_peer_stats', return_value={'10.10.0.2': {'rx': rx, 'tx': 0}}):
            collect_traffic.collect()

    def total_rx(self):
        db = sqlite3.connect(collect_traffic.DB_PATH)
        return db.execute('SELECT SUM(delta_rx) FROM traffic_samples').fetchone()[0]

    def test_duplicate_run_same_minute_not_double_counted(self):
        self.run_at(1000, 100)
        self.run_at(1060, 600)
        self.run_at(1065, 700)   # second scheduler firing in the same minute
        self.assertEqual(self.total_rx(), 500)

    def test_counter_reset(self):
        self.run_at(1000, 1000)
        self.run_at(1060, 50)    # wg restarted
        self.assertEqual(self.total_rx(), 50)


if __name__ == '__main__':
    unittest.main()
