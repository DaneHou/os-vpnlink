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
        with open(path, 'w', encoding='utf-8') as f:
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

    FULL = (
        "http:\n"
        "  pprof:\n"
        "    port: 6060\n"
        "  address: 0.0.0.0:3000\n"
        "# 注释 kept as is\n"
        "dns:\n"
        "  bind_hosts:\n"
        "    - 192.168.1.1\n"
        "  port: 53\n"
        "  upstream_dns:\n"
        "    - '# --- App Router: DNS via gateway (managed) ---'\n"
        "    - '[/example.cn/]127.0.0.1:53530'\n"
        "    - '# --- App Router end ---'\n"
        "    - https://dns10.quad9.net/dns-query\n"
        "  bootstrap_dns:   [9.9.9.10, 149.112.112.10]\n"
        "filtering:\n"
        "  rewrites: []\n"
        "schema_version: 29\n"
    )

    def test_only_bind_hosts_lines_change(self):
        path = self.write(self.FULL)
        with mock.patch.object(vpnlink, 'syslog_msg'):
            self.assertTrue(vpnlink.sync_adguard_binds(path, ['10.10.0.1', '10.20.0.1']))
        with open(path, encoding='utf-8') as f:
            got = f.read()
        want = self.FULL.replace("    - 192.168.1.1\n",
                                 "    - 192.168.1.1\n    - 10.10.0.1\n    - 10.20.0.1\n")
        self.assertEqual(got, want)            # every other byte kept, incl. comments and flow lists
        with open(path + '.vpnlink.bak', encoding='utf-8') as f:
            self.assertEqual(f.read(), self.FULL)

    def test_inline_and_same_indent_lists(self):
        for body, after in (
            ("dns:\n  bind_hosts: []\n  port: 53\n", "dns:\n  bind_hosts:\n    - 10.10.0.1\n  port: 53\n"),
            ("dns:\n  bind_hosts: [192.168.1.1]\n  port: 53\n",
             "dns:\n  bind_hosts:\n    - 192.168.1.1\n    - 10.10.0.1\n  port: 53\n"),
            ("dns:\n  bind_hosts:\n  - 192.168.1.1\n  port: 53\n",
             "dns:\n  bind_hosts:\n  - 192.168.1.1\n  - 10.10.0.1\n  port: 53\n"),
        ):
            self.assertEqual(vpnlink.add_bind_hosts_text(body, ['10.10.0.1']), after)
            ok, reason = vpnlink.validate_bind_hosts_edit(
                body, after, [ip for ip in ('192.168.1.1', '10.10.0.1') if ip in after])
            self.assertTrue(ok, reason)

    def test_bind_hosts_outside_dns_is_not_used(self):
        self.assertIsNone(vpnlink.add_bind_hosts_text("http:\n  bind_hosts:\n    - 1.1.1.1\n", ['10.10.0.1']))

    def test_refuses_edit_that_changes_anything_else(self):
        path = self.write(self.FULL)
        broken = self.FULL.replace("  port: 53\n", "  port: 5353\n").replace(
            "    - 192.168.1.1\n", "    - 192.168.1.1\n    - 10.10.0.1\n")
        with mock.patch.object(vpnlink, 'add_bind_hosts_text', return_value=broken), \
                mock.patch.object(vpnlink, 'syslog_msg') as logm:
            self.assertFalse(vpnlink.sync_adguard_binds(path, ['10.10.0.1']))
        self.assertIn('other settings', logm.call_args[0][0])
        with open(path, encoding='utf-8') as f:
            self.assertEqual(f.read(), self.FULL)
        unparsable = self.FULL.replace("    - 192.168.1.1\n", "    - 192.168.1.1\n   - [bad\n")
        ok, _reason = vpnlink.validate_bind_hosts_edit(self.FULL, unparsable, ['192.168.1.1', '10.10.0.1'])
        self.assertFalse(ok)

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


class UnboundControl(unittest.TestCase):
    def run_with(self, results):
        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            r = results.pop(0)
            if isinstance(r, Exception):
                raise r
            return mock.Mock(returncode=r[0], stdout=r[1], stderr=r[2])

        with mock.patch.object(vpnlink.subprocess, 'run', side_effect=fake_run), \
                mock.patch.object(vpnlink, 'syslog_msg') as log:
            ok = vpnlink.apply_unbound_acl_runtime(['10.10.0.0/24', '10.20.0.0/24'])
        return ok, calls, [c.args[0] for c in log.call_args_list if not c.kwargs.get('debug')]

    def test_uses_opnsense_config(self):
        ok, calls, errors = self.run_with([(0, 'ok\n', ''), (0, 'ok\n', '')])
        self.assertTrue(ok)
        self.assertEqual(errors, [])
        for cmd in calls:
            self.assertEqual(cmd[1:3], ['-c', '/var/unbound/unbound.conf'])
        self.assertEqual([c[3:] for c in calls],
                         [['access_control', '10.10.0.0/24', 'allow'], ['access_control', '10.20.0.0/24', 'allow']])

    def test_failures_are_logged_and_reported(self):
        ok, calls, errors = self.run_with([
            (1, '', 'error: connect: Connection refused for 127.0.0.1 port 8953'),
            FileNotFoundError('unbound-control'),
        ])
        self.assertFalse(ok)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(errors), 2)
        self.assertIn('Connection refused', errors[0])
        self.assertIn('10.20.0.0/24', errors[1])

    def test_sync_dns_restarts_unbound_when_runtime_add_fails(self):
        with mock.patch.object(vpnlink, 'dns_sync_targets', return_value=(True, ['10.10.0.0/24'], [])), \
                mock.patch.object(vpnlink, 'UNBOUND_ACL_FILE', '/nonexistent/vpnlink_acl.conf'), \
                mock.patch.object(vpnlink, 'generate_unbound_acl'), \
                mock.patch.object(vpnlink, 'apply_unbound_acl_runtime', return_value=False), \
                mock.patch.object(vpnlink, 'resolve_dns_topology', return_value=('unbound', None)), \
                mock.patch.object(vpnlink, 'reload_unbound') as reload, \
                mock.patch.object(vpnlink, 'syslog_msg'):
            vpnlink.cmd_sync_dns()
        reload.assert_called_once()


class DnsAclStatusTest(unittest.TestCase):
    def test_missing_acl_fails_with_unbound_only(self):
        ok, detail = vpnlink.dns_acl_status(['10.10.0.0/24'], set(), 'unbound', None)
        self.assertFalse(ok)
        self.assertIn('run Apply', detail)

    def test_missing_acl_is_fine_behind_adguard(self):
        ok, detail = vpnlink.dns_acl_status(['10.10.0.0/24'], set(), 'adguard_unbound', '/x/AdGuardHome.yaml')
        self.assertTrue(ok)
        self.assertIn('Not needed', detail)

    def test_adguard_topology_without_adguard_still_fails(self):
        ok, _ = vpnlink.dns_acl_status(['10.10.0.0/24'], set(), 'adguard_unbound', None)
        self.assertFalse(ok)

    def test_present_and_empty(self):
        self.assertTrue(vpnlink.dns_acl_status(['10.10.0.0/24'], {'10.10.0.0/24'}, 'unbound', None)[0])
        self.assertEqual(vpnlink.dns_acl_status([], set(), 'unbound', None), (True, 'No links with DNS sync'))


class HealthcheckContract(unittest.TestCase):
    """`configctl vpnlink healthcheck` follows the os-netbaseline plugin health contract."""

    def run_healthcheck(self, adguard=None, enabled=True, peers=0):
        import io
        import json
        from contextlib import redirect_stdout
        dump = 'wg0\tpriv\tpub\t51820\toff\n' + ''.join(
            'wg0\tpk{0}\t(none)\t198.51.100.{0}:1234\t10.10.0.{0}/32\t1795000000\t10\t20\toff\n'.format(i + 2)
            for i in range(peers))

        def fake_run(argv, **kw):
            out = dump if argv[1:3] == ['show', 'all'] else ''
            return mock.Mock(returncode=0, stdout=out)
        buf = io.StringIO()
        with mock.patch.object(vpnlink, 'discover_wg_subnets', return_value=['10.10.0.0/24']), \
                mock.patch.object(vpnlink, 'resolve_dns_topology',
                                  return_value=('adguard_unbound' if adguard else 'unbound', adguard)), \
                mock.patch.object(vpnlink, 'dns_sync_targets', return_value=(enabled, [], [])), \
                mock.patch.object(vpnlink, 'list_wg_interfaces', return_value=['wg0']), \
                mock.patch.object(vpnlink, 'plugin_enabled', return_value=enabled), \
                mock.patch.object(vpnlink, 'CONFIG_XML', '/nonexistent/config.xml'), \
                mock.patch.object(vpnlink.subprocess, 'run', side_effect=fake_run), \
                redirect_stdout(buf):
            vpnlink.cmd_healthcheck()
        return {c['name']: c for c in json.loads(buf.getvalue())['checks']}

    def test_every_check_has_contract_keys(self):
        for c in self.run_healthcheck().values():
            self.assertIn(c['ok'], (True, False, None))
            self.assertIn(c['severity'], ('medium', 'low', 'info'))
            self.assertIsInstance(c['detail'], str)

    def test_adguard_absent_is_not_applicable(self):
        c = self.run_healthcheck()['AdGuard Home']
        self.assertIsNone(c['ok'])
        self.assertEqual(c['severity'], 'info')
        c = self.run_healthcheck(adguard='/usr/local/AdGuardHome/AdGuardHome.yaml')['AdGuard Home']
        self.assertIs(c['ok'], True)

    def test_connected_peers_is_info(self):
        c = self.run_healthcheck()['Connected Peers']
        self.assertEqual((c['ok'], c['severity']), (False, 'info'))
        c = self.run_healthcheck(peers=2)['Connected Peers']
        self.assertEqual((c['ok'], c['detail']), (True, '2 peer(s) connected'))
        self.assertNotIn('priv', str(c))

    def test_real_problems_stay_medium(self):
        checks = self.run_healthcheck()
        self.assertEqual((checks['NAT Rules']['ok'], checks['NAT Rules']['severity']), (False, 'medium'))

    def test_disabled_plugin_reports_not_applicable(self):
        checks = self.run_healthcheck(enabled=False)
        self.assertFalse([c for c in checks.values() if c['ok'] is False])
        self.assertTrue(checks['NAT Rules']['detail'].endswith('(plugin disabled)'))

    def test_finalize_checks(self):
        out = vpnlink.finalize_checks([{'name': 'a', 'ok': False, 'detail': 'x'},
                                       {'name': 'b', 'ok': True, 'severity': 'low', 'detail': ''}], True)
        self.assertEqual([c['severity'] for c in out], ['medium', 'low'])
        self.assertIs(out[0]['ok'], False)


class AdguardRestartTest(unittest.TestCase):
    """AdGuardHome.yaml writes: correct restart command, rollback when it does not come back."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.conf = os.path.join(self.tmp, 'AdGuardHome.yaml')
        self.bak = self.conf + '.vpnlink.bak'
        with open(self.conf, 'w') as f:
            f.write('dns:\n  bind_hosts: [bad\n')
        with open(self.bak, 'w') as f:
            f.write('dns:\n  bind_hosts:\n    - 192.168.68.1\n')

    def test_restart_uses_the_rc_name_and_keeps_a_good_file(self):
        with mock.patch.object(vpnlink.subprocess, 'run') as run, \
                mock.patch.object(vpnlink, 'adguard_running', return_value=True), \
                mock.patch.object(vpnlink.time, 'sleep'):
            self.assertTrue(vpnlink.restart_adguard(self.conf, self.bak))
        run.assert_called_once()
        self.assertEqual(run.call_args[0][0], ['/usr/local/sbin/configctl', 'adguardhome', 'restart'])
        self.assertIn('bad', open(self.conf).read())

    def test_rollback_when_adguard_does_not_stay_up(self):
        with mock.patch.object(vpnlink.subprocess, 'run') as run, \
                mock.patch.object(vpnlink, 'adguard_running', return_value=False), \
                mock.patch.object(vpnlink.time, 'sleep'), \
                mock.patch.object(vpnlink, 'syslog_msg'):
            self.assertFalse(vpnlink.restart_adguard(self.conf, self.bak))
        self.assertEqual(run.call_count, 2)
        self.assertEqual(open(self.conf).read(), open(self.bak).read())

    def test_lock_is_exclusive(self):
        import fcntl
        lock = os.path.join(self.tmp, 'agh.lock')
        with mock.patch.object(vpnlink, 'AGH_LOCK', lock), mock.patch.object(vpnlink.time, 'sleep'):
            fd = os.open(lock, os.O_RDWR | os.O_CREAT)
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                with self.assertRaises(TimeoutError):
                    with vpnlink.adguard_lock(timeout=0):
                        pass
            finally:
                os.close(fd)
            with vpnlink.adguard_lock(timeout=0):
                pass
