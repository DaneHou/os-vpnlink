{# OPNsense VPN Link — Links #}

<style>
    /* Dialog form */
    .dlg-form-table { width: 100%; }
    .dlg-form-table td.dlg-label { width: 120px; vertical-align: middle; padding: 10px 12px 10px 0; text-align: right; font-weight: bold; color: #555; }
    .dlg-form-table td.dlg-field { padding: 8px 0; }
    .dlg-form-table td.dlg-field small { display: block; margin-top: 3px; color: #999; }
    #DialogLink .modal-body, #DialogDevice .modal-body { overflow: visible; }
    #dev-qr svg { width: 100%; max-width: 300px; height: auto; background: #fff; }
    #dev-config { font-family: monospace; font-size: 12px; }
</style>

<script src="/js/vpnlink/qrcode.js"></script>

<script>
    // Escape text before building HTML strings (names/descriptions come from config)
    function vlEsc(s) {
        return String(s === undefined || s === null ? '' : s).replace(/[&<>"']/g, function(c) {
            return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
        });
    }

    var _wgData = null, _lanData = null, _gwData = [];

    $(document).ready(function() {
        mapDataToFormUI({'frm_GeneralSettings': "/api/vpnlink/settings/get"}).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        $.when(
            $.get('/api/vpnlink/link/wgSources'),
            $.get('/api/vpnlink/link/lanInterfaces'),
            $.get('/api/vpnlink/link/gateways')
        ).done(function(wgR, lanR, gwR) {
            if (wgR[0] && wgR[0].status === 'ok') _wgData = wgR[0];
            if (lanR[0] && lanR[0].status === 'ok') _lanData = lanR[0];
            if (gwR[0] && gwR[0].status === 'ok') _gwData = gwR[0].gateways || [];
            loadLinksTable();
        });

        // ══════════════════════════════════════
        // Links Table + Conflict Detection
        // ══════════════════════════════════════
        var _existingLinks = [];  // for conflict checking

        function loadLinksTable() {
            $.post('/api/vpnlink/link/searchLink', {current:1, rowCount:-1}, function(r) {
                var tbody = $('#links-tbody').empty();
                var rows = (r && r.rows) ? r.rows : [];
                _existingLinks = rows;  // cache for conflict checks
                if (rows.length === 0) {
                    tbody.append('<tr><td colspan="6" class="text-center text-muted" style="padding:20px">{{ lang._("No links configured. Click Add Link to create one.") }}</td></tr>');
                    return;
                }
                $.each(rows, function(i, row) {
                    var on = row.enabled == '1' ? '<span class="fa fa-check-circle text-success"></span>' : '<span class="fa fa-times-circle text-danger"></span>';
                    tbody.append(
                        '<tr><td class="text-center" style="width:3em">' + on + '</td>' +
                        '<td>' + fmtSource(row.source, row.name) + '</td>' +
                        '<td style="width:18em"><span class="fa fa-fw fa-arrow-right text-muted"></span> <b>' + fmtLan(row.lanInterface) + '</b></td>' +
                        '<td style="width:14em">' + fmtEgress(row) + '</td>' +
                        '<td style="width:14em">' + fmtAccess(row) + '</td>' +
                        '<td style="width:6em">' +
                            '<button class="btn btn-xs btn-default btn-edit" data-uuid="' + vlEsc(row.uuid) + '" title="Edit"><span class="fa fa-pencil"></span></button> ' +
                            '<button class="btn btn-xs btn-danger btn-del" data-uuid="' + vlEsc(row.uuid) + '" title="Delete"><span class="fa fa-trash-o"></span></button>' +
                        '</td></tr>'
                    );
                });
            });
        }

        function fmtSource(src, name) {
            if (!src) return '';
            var parts = src.split(','), labels = [];
            $.each(parts, function(i, s) {
                s = $.trim(s);
                if (s === 'any') { labels.push('<span class="fa fa-fw fa-globe"></span> <b>Any</b>'); return; }
                var n = wgName(s), icon = s.indexOf('/') > 0 ? 'fa-server' : 'fa-mobile';
                labels.push('<span class="fa fa-fw ' + icon + '"></span> ' + vlEsc(n) + ' <small class="text-muted">(' + vlEsc(s) + ')</small>');
            });
            return labels.join(', ');
        }

        function wgName(val) {
            if (!_wgData) return val;
            for (var i = 0; i < (_wgData.servers||[]).length; i++) if (_wgData.servers[i].subnet === val) return _wgData.servers[i].name;
            for (var i = 0; i < (_wgData.peers||[]).length; i++) if (_wgData.peers[i].ip === val) return _wgData.peers[i].name;
            return val;
        }

        function fmtEgress(row) {
            var html = row.gateway ? '<span class="fa fa-fw fa-road"></span> ' + vlEsc(row.gateway)
                                   : '<span class="text-muted">{{ lang._("as LAN") }}</span>';
            if (row.killSwitch === '1') html += ' <span class="label label-danger" title="{{ lang._("Kill switch: never exits via WAN directly") }}">KS</span>';
            return html;
        }

        function fmtAccess(row) {
            if (row.access === 'internet') return '<span class="fa fa-fw fa-lock"></span> {{ lang._("Internet only") }}';
            if (row.access === 'custom') {
                var nets = (row.allowedNets || '').split(',').map(function(s) { return $.trim(s); }).filter(Boolean);
                return '<span class="fa fa-fw fa-lock"></span> {{ lang._("Internet") }}' +
                    (nets.length ? ' + ' + nets.map(function(n) { return vlEsc(lanLabel(n)); }).join(', ') : '');
            }
            return '<span class="text-muted">{{ lang._("Full") }}</span>';
        }

        function lanLabel(ifname) {
            if (_lanData && _lanData.interfaces) {
                for (var i = 0; i < _lanData.interfaces.length; i++)
                    if (_lanData.interfaces[i].name === ifname) return _lanData.interfaces[i].descr;
            }
            return ifname;
        }

        // Access: "full" | "internet" | "custom" (+ interfaces from the picker and free-form networks/aliases)
        function buildAccess(access, allowedCsv) {
            var nets = (allowedCsv || '').split(',').map(function(s) { return $.trim(s); }).filter(Boolean);
            var ifNames = (_lanData && _lanData.interfaces) ? _lanData.interfaces.map(function(f) { return f.name; }) : [];
            var picked = nets.filter(function(n) { return ifNames.indexOf(n) >= 0; });
            var extra = nets.filter(function(n) { return ifNames.indexOf(n) < 0; });
            var el = $('#dlg-allowed-ifs').empty();
            if (_lanData && _lanData.interfaces) {
                $.each(_lanData.interfaces, function(i, f) {
                    el.append($('<option>').val(f.name).text(f.descr + ' (' + f.name + ')' + (f.cidr ? ' — ' + f.cidr : '')));
                });
            }
            el.selectpicker('destroy').selectpicker({ noneSelectedText:'{{ lang._("No interface networks") }}' }).selectpicker('val', picked);
            $('#dlg-allowed-extra').val(extra.join(', '));
            $('#dlg-access').val(access || 'full');
            toggleAccess();
        }

        // getLink returns OptionFields as {key: {value, selected}}; plain strings pass through
        function selectedOption(field) {
            if (!field || typeof field !== 'object') return field;
            var sel = '';
            $.each(field, function(k, o) { if (o && (o.selected === 1 || o.selected === '1' || o.selected === true)) sel = k; });
            return sel;
        }

        function toggleAccess() {
            var a = $('#dlg-access').val();
            $('#dlg-allowed-panel').toggle(a === 'custom');
            $('#dlg-access-help').toggle(a !== 'full');
        }
        $('#dlg-access').on('change', toggleAccess);

        function allowedNetsValue() {
            if ($('#dlg-access').val() !== 'custom') return '';
            var nets = ($('#dlg-allowed-ifs').val() || []).slice();
            $.each(($('#dlg-allowed-extra').val() || '').split(','), function(i, s) {
                s = $.trim(s);
                if (s && nets.indexOf(s) < 0) nets.push(s);
            });
            return nets.join(',');
        }

        function buildGatewaySelect(val) {
            var el = $('#dlg-gateway').empty();
            el.append($('<option>').val('').text('{{ lang._("Same as LAN (no override)") }}'));
            $.each(_gwData, function(i, g) {
                el.append($('<option>').val(g.name).text(g.name + (g.group ? ' (group)' : ' (' + g.interface + ')')));
            });
            if (val && !_gwData.some(function(g) { return g.name === val; })) {
                el.append($('<option>').val(val).text(val + ' ({{ lang._("missing") }})'));
            }
            el.val(val || '');
            el.selectpicker('destroy').selectpicker({ liveSearch:true }).selectpicker('val', val || '');
        }

        function fmtLan(ifname) {
            if (_lanData && _lanData.interfaces) {
                for (var i = 0; i < _lanData.interfaces.length; i++)
                    if (_lanData.interfaces[i].name === ifname) return vlEsc(_lanData.interfaces[i].descr + ' (' + ifname + ')');
            }
            return vlEsc(ifname || '');
        }

        // ── Dialog ──
        var typeIcons = {wireguard:'WG', openvpn:'OVPN', ipsec:'IPsec', tailscale:'TS', zerotier:'ZT', openconnect:'OC', other:'VPN'};

        function buildSourceSelect(selectedCsv) {
            var sel = (selectedCsv || '').split(',').map(function(s){ return $.trim(s); });
            var el = $('#dlg-source').empty();
            el.append('<option value="any">Any (all VPN clients)</option>');
            if (_wgData) {
                // Group servers by type
                var serversByType = {};
                $.each(_wgData.servers || [], function(i, s) {
                    var t = s.type || 'wireguard';
                    if (!serversByType[t]) serversByType[t] = [];
                    serversByType[t].push(s);
                });
                $.each(serversByType, function(type, svrs) {
                    var label = (typeIcons[type] || type.toUpperCase()) + ' Servers (all clients)';
                    var g = $('<optgroup>').attr('label', label);
                    $.each(svrs, function(i, s) { g.append($('<option>').val(s.subnet).text(s.name + ' (' + s.subnet + ')')); });
                    el.append(g);
                });

                // WG peers grouped by server
                var groups = {};
                $.each(_wgData.peers || [], function(i, p) { var gn = p.server || 'Other'; if (!groups[gn]) groups[gn] = []; groups[gn].push(p); });
                $.each(groups, function(gn, peers) {
                    var g = $('<optgroup>').attr('label', gn + ' — Devices');
                    $.each(peers, function(i, p) { g.append($('<option>').val(p.ip).text(p.name + ' (' + p.ip + ')')); });
                    el.append(g);
                });
            }
            el.val(sel);
            el.selectpicker('destroy').selectpicker({ actionsBox:true, liveSearch:true, selectedTextFormat:'count > 2', countSelectedText:'{0} selected', noneSelectedText:'— Select source —' }).selectpicker('val', sel);
        }

        function buildDestSelect(val) {
            var el = $('#dlg-dest').empty();
            el.append('<option value="">— Select LAN —</option>');
            if (_lanData && _lanData.interfaces) {
                $.each(_lanData.interfaces, function(i, f) {
                    var label = f.descr + ' (' + f.name + ')';
                    if (f.cidr) label += ' — ' + f.cidr;
                    el.append($('<option>').val(f.name).text(label));
                });
            }
            if (val) el.val(val);
            el.selectpicker('destroy').selectpicker({ liveSearch:false, noneSelectedText:'— Select LAN —' }).selectpicker('val', val || '');
        }

        var _editUuid = null;
        $('#btn-add-link').on('click', function() {
            _editUuid = null;
            $('#dlg-title').text('{{ lang._("Add Link") }}');
            $('#dlg-enabled').prop('checked', true);
            $('#dlg-clone-rules,#dlg-auto-nat,#dlg-dns-sync,#dlg-nat-lan').prop('checked', true);
            $('#dlg-kill-switch').prop('checked', false);
            buildGatewaySelect('');
            buildAccess('full', '');
            $('#dlg-advanced-panel').collapse('hide');
            buildSourceSelect('');
            buildDestSelect('');
            $('#DialogLink').modal('show');
        });

        $(document).on('click', '.btn-edit', function() {
            _editUuid = $(this).data('uuid');
            $('#dlg-title').text('{{ lang._("Edit Link") }}');
            $.get('/api/vpnlink/link/getLink/' + _editUuid, function(r) {
                if (r && r.link) {
                    $('#dlg-enabled').prop('checked', r.link.enabled === '1');
                    $('#dlg-clone-rules').prop('checked', r.link.cloneRules !== '0');
                    $('#dlg-auto-nat').prop('checked', r.link.autoNat !== '0');
                    $('#dlg-dns-sync').prop('checked', r.link.dnsSync !== '0');
                    $('#dlg-nat-lan').prop('checked', r.link.natOnLan !== '0');
                    $('#dlg-kill-switch').prop('checked', r.link.killSwitch === '1');
                    buildGatewaySelect(r.link.gateway || "");
                    buildAccess(selectedOption(r.link.access) || 'full', r.link.allowedNets || '');
                    buildSourceSelect(r.link.source || '');
                    buildDestSelect(r.link.lanInterface || '');
                    (r.link.cloneRules==='0'||r.link.autoNat==='0'||r.link.dnsSync==='0'||r.link.natOnLan==='0') ? $('#dlg-advanced-panel').collapse('show') : $('#dlg-advanced-panel').collapse('hide');
                }
                $('#DialogLink').modal('show');
            });
        });

        $(document).on('click', '.btn-del', function() {
            if (confirm('{{ lang._("Delete this link?") }}')) {
                $.post('/api/vpnlink/link/delLink/' + $(this).data('uuid'), function() { loadLinksTable(); $('#LinkChangeMessage').show(); });
            }
        });

        // Check for source conflicts before saving (mirrors vpnlink_ranges_overlap() in vpnlink.inc)
        function ip2int(ip) {
            var p = ip.split('.');
            if (p.length !== 4) return null;
            return ((+p[0] << 24) >>> 0) + (+p[1] << 16) + (+p[2] << 8) + (+p[3]);
        }
        function overlaps(a, b) {
            if (a === 'any' || b === 'any') return true;
            var pa = a.split('/'), pb = b.split('/');
            var ia = ip2int(pa[0]), ib = ip2int(pb[0]);
            if (ia === null || ib === null) return a === b;
            var prefix = Math.min(pa[1] !== undefined ? +pa[1] : 32, pb[1] !== undefined ? +pb[1] : 32);
            var mask = prefix === 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) >>> 0;
            return ((ia & mask) >>> 0) === ((ib & mask) >>> 0);
        }
        function checkConflicts(sources, lanIf) {
            var conflicts = [];
            $.each(_existingLinks, function(i, link) {
                if (_editUuid && link.uuid === _editUuid) return; // skip self when editing
                if (link.enabled !== '1' || link.lanInterface === lanIf) return;
                var existingSources = (link.source || '').split(',').map(function(s) { return $.trim(s); });
                $.each(sources, function(j, src) {
                    $.each(existingSources, function(k, existSrc) {
                        if (existSrc && overlaps(src, existSrc)) {
                            conflicts.push('"' + (wgName(src) || src) + '" overlaps "' + wgName(existSrc) + '" → ' + link.lanInterface + ' (in "' + link.name + '")');
                        }
                    });
                });
            });
            return conflicts;
        }

        $('#dlg-save').on('click', function() {
            var sources = $('#dlg-source').val() || [];
            if (!sources.length) { alert('{{ lang._("Select at least one source.") }}'); return; }
            var lanIf = $('#dlg-dest').val();
            if (!lanIf) { alert('{{ lang._("Select a destination LAN.") }}'); return; }

            // Conflict check
            var conflicts = checkConflicts(sources, lanIf);
            if (conflicts.length > 0) {
                // Overlapping sources on different LANs would clone competing rules — server rejects these too
                alert('{{ lang._("Conflict detected:") }}\n\n' + conflicts.join('\n') + '\n\n{{ lang._("Disable or edit the other link first.") }}');
                return;
            }

            var allowedNets = allowedNetsValue();
            if (!/^$|^[a-zA-Z0-9_.\/]{1,64}(,[a-zA-Z0-9_.\/]{1,64})*$/.test(allowedNets)) {
                alert('{{ lang._("Allowed networks: use interface names, IPv4 networks (e.g. 192.168.50.0/24) or alias names, separated by commas.") }}');
                return;
            }
            if ($('#dlg-access').val() === 'custom' && !allowedNets) {
                alert('{{ lang._("Select at least one network, or choose Internet only.") }}');
                return;
            }

            var firstName = sources[0] === 'any' ? 'Any' : wgName(sources[0]);
            if (sources.length > 1) firstName += ' +' + (sources.length - 1);
            $.post(_editUuid ? '/api/vpnlink/link/setLink/' + _editUuid : '/api/vpnlink/link/addLink/',
                { link: { enabled:$('#dlg-enabled').is(':checked')?'1':'0', name:firstName, source:sources.join(','), lanInterface:lanIf,
                    cloneRules:$('#dlg-clone-rules').is(':checked')?'1':'0', autoNat:$('#dlg-auto-nat').is(':checked')?'1':'0', dnsSync:$('#dlg-dns-sync').is(':checked')?'1':'0',
                    natOnLan:$('#dlg-nat-lan').is(':checked')?'1':'0', killSwitch:$('#dlg-kill-switch').is(':checked')?'1':'0',
                    gateway:$('#dlg-gateway').val() || '', access:$('#dlg-access').val() || 'full', allowedNets:allowedNets } },
                function(r) {
                    if (r && (r.result === 'saved' || r.uuid)) { $('#DialogLink').modal('hide'); loadLinksTable(); $('#LinkChangeMessage').show(); }
                    else { alert(r && r.validations ? Object.values(r.validations).join('\n') : 'Save failed.'); }
                }
            );
        });

        // ══════════════════════════════════════
        // Add device wizard
        // ══════════════════════════════════════
        var _devDefaults = null, _devDone = false;

        function devInstance() {
            var uuid = $('#dev-instance').val();
            var list = (_devDefaults && _devDefaults.instances) || [];
            for (var i = 0; i < list.length; i++) if (list[i].uuid === uuid) return list[i];
            return null;
        }

        function devFillInstance() {
            var inst = devInstance();
            if (!inst) return;
            $('#dev-endpoint').val(inst.endpoint);
            $('#dev-port').val(inst.port);
            $('#dev-dns').val(inst.dns);
            $('#dev-mtu').val(inst.mtu);
            $('#dev-next-ip').text(inst.nextIp || '{{ lang._("none free") }}');
            var src = {ddns:'{{ lang._("Dynamic DNS hostname") }}', 'peer generator':'{{ lang._("WireGuard instance default") }}', wan:'{{ lang._("current WAN address") }}'}[inst.endpointSource] || '';
            $('#dev-endpoint-src').text(src ? '{{ lang._("Default:") }} ' + src : '{{ lang._("No default found: enter the public hostname or IP of this firewall.") }}');
            if (inst.covered) {
                $('#dev-lan-row').hide();
                $('#dev-covered').html('{{ lang._("Covered by link") }} <b>' + vlEsc(inst.covered.name) + '</b> (' + vlEsc(inst.covered.source) + ' &rarr; ' + fmtLan(inst.covered.lanInterface) + ')').show();
            } else {
                $('#dev-covered').hide();
                var el = $('#dev-lan').empty();
                $.each((_lanData && _lanData.interfaces) || [], function(i, f) {
                    el.append($('<option>').val(f.name).text(f.descr + ' (' + f.name + ')' + (f.cidr ? ' — ' + f.cidr : '')));
                });
                el.val(inst.defaultLan || el.find('option:first').val());
                $('#dev-lan-row').show();
            }
            devToggle();
        }

        function devToggle() {
            var a = $('#dev-access').val();
            $('#dev-allowed-panel').toggle(a === 'custom');
            $('#dev-split-internet').toggle(a === 'internet' && $('input[name=dev-routing]:checked').val() === 'split');
            $('#dev-plugin-off').toggle(!!_devDefaults && !_devDefaults.pluginEnabled && a !== 'full');
        }
        $('#dev-access').on('change', devToggle);
        $('input[name=dev-routing]').on('change', devToggle);
        $('#dev-instance').on('change', devFillInstance);

        function devAllowedNets() {
            if ($('#dev-access').val() !== 'custom') return '';
            var nets = ($('#dev-allowed-ifs').val() || []).slice();
            $.each(($('#dev-allowed-extra').val() || '').split(','), function(i, s) {
                s = $.trim(s);
                if (s && nets.indexOf(s) < 0) nets.push(s);
            });
            return nets.join(',');
        }

        function devShowError(msg) {
            $('#dev-error').text(msg).toggle(!!msg);
        }

        function devClearResult() {
            // drop the private key from the page
            $('#dev-config').val('');
            $('#dev-qr').empty();
            $('#dev-summary').empty();
        }

        $('#btn-add-device').on('click', function() {
            _devDone = false;
            devClearResult();
            devShowError('');
            $('#dev-form').show();
            $('#dev-result').hide();
            $('#dev-create').show().prop('disabled', true);
            $('#dev-name').val('');
            $('#dev-access').val('full');
            $('input[name=dev-routing][value=full]').prop('checked', true);
            $('#dev-psk').prop('checked', false);
            $('#dev-allowed-extra').val('');
            var el = $('#dev-allowed-ifs').empty();
            $.each((_lanData && _lanData.interfaces) || [], function(i, f) {
                el.append($('<option>').val(f.name).text(f.descr + ' (' + f.name + ')' + (f.cidr ? ' — ' + f.cidr : '')));
            });
            el.selectpicker('destroy').selectpicker({ noneSelectedText:'{{ lang._("No interface networks") }}' }).selectpicker('val', []);
            $('#dev-instance').empty();
            $('#DialogDevice').modal('show');

            $.get('/api/vpnlink/device/defaults', function(r) {
                if (!r || r.status !== 'ok') { devShowError((r && r.message) || '{{ lang._("Could not read the WireGuard configuration.") }}'); return; }
                _devDefaults = r;
                if (!r.instances.length) { devShowError('{{ lang._("No enabled WireGuard instance found. Create one under VPN > WireGuard > Instances first.") }}'); return; }
                $.each(r.instances, function(i, inst) {
                    $('#dev-instance').append($('<option>').val(inst.uuid).text(inst.name + ' (' + inst.interface + ', ' + inst.subnet + ', ' + inst.peers + ' {{ lang._("peers") }})'));
                });
                $('#dev-instance').val(r['default']);
                $('#dev-keepalive').val(r.keepalive);
                devFillInstance();
                $('#dev-create').prop('disabled', false);
            });
        });

        $('#dev-create').on('click', function() {
            devShowError('');
            if ($('#dev-access').val() === 'custom' && !devAllowedNets()) {
                devShowError('{{ lang._("Select at least one network, or choose Internet only.") }}');
                return;
            }
            var inst = devInstance();
            var payload = { device: {
                name: $.trim($('#dev-name').val()), instance: $('#dev-instance').val(),
                access: $('#dev-access').val(), allowedNets: devAllowedNets(),
                routing: $('input[name=dev-routing]:checked').val(),
                endpoint: $.trim($('#dev-endpoint').val()), port: $.trim($('#dev-port').val()),
                dns: $.trim($('#dev-dns').val()), keepalive: $.trim($('#dev-keepalive').val()), mtu: $.trim($('#dev-mtu').val()),
                psk: $('#dev-psk').is(':checked') ? '1' : '0',
                lanInterface: (inst && !inst.covered) ? ($('#dev-lan').val() || '') : ''
            }};
            var btn = $(this).prop('disabled', true);
            btn.find('.fa').attr('class', 'fa fa-spinner fa-pulse');
            $.post('/api/vpnlink/device/add', payload, function(r) {
                if (r && r.status === 'ok') {
                    devShowResult(r);
                } else if (r && r.validations) {
                    devShowError(Object.values(r.validations).join('\n'));
                } else {
                    devShowError((r && r.message) || '{{ lang._("Adding the device failed.") }}');
                }
            }).fail(function() {
                devShowError('{{ lang._("Request failed. Check VPN > WireGuard before retrying: the device may have been created.") }}');
            }).always(function() {
                btn.prop('disabled', false).find('.fa').attr('class', 'fa fa-check');
            });
        });

        function devShowResult(r) {
            _devDone = true;
            var s = r.summary || {};
            var access = {full:'{{ lang._("Full") }}', internet:'{{ lang._("Internet only") }}', custom:'{{ lang._("Internet + selected networks") }}'}[s.access] || s.access;
            if (s.access === 'custom' && s.allowedNets) access += ': ' + s.allowedNets.split(',').map(lanLabel).join(', ');
            var rows = [
                ['{{ lang._("Device") }}', vlEsc(s.name)],
                ['{{ lang._("Tunnel address") }}', vlEsc(s.ip) + ' <small class="text-muted">(' + vlEsc(s.instance) + ', ' + vlEsc(s.interface) + ')</small>'],
                ['{{ lang._("Access") }}', vlEsc(access)],
                ['{{ lang._("Routing") }}', s.routing === 'split' ? '{{ lang._("Split tunnel (home networks only)") }}' : '{{ lang._("Full tunnel (all traffic)") }}'],
                ['{{ lang._("VPN Link link") }}', vlEsc(s.link)],
                ['{{ lang._("Peer loaded") }}', s.peerLoaded ? '<span class="fa fa-check-circle text-success"></span> {{ lang._("yes") }}'
                                                             : '<span class="fa fa-times-circle text-danger"></span> {{ lang._("no") }}']
            ];
            var tb = $('#dev-summary').empty();
            $.each(rows, function(i, row) { tb.append('<tr><th style="width:11em">' + row[0] + '</th><td>' + row[1] + '</td></tr>'); });
            var w = $('#dev-warnings').empty();
            $.each(r.warnings || [], function(i, msg) { w.append($('<div class="alert alert-warning" style="margin:6px 0">').text(msg)); });

            $('#dev-config').val(r.config);
            $('#dev-filename').val(r.filename || 'wireguard.conf');
            try {
                var qr = qrcode(0, 'L');
                qr.addData(r.config);
                qr.make();
                $('#dev-qr').html(qr.createSvgTag({cellSize: 3, margin: 12, scalable: true}));
            } catch (e) {
                $('#dev-qr').text('{{ lang._("QR code could not be generated.") }}');
            }
            $('#dev-form').hide();
            $('#dev-create').hide();
            $('#dev-result').show();
        }

        $('#dev-copy').on('click', function() {
            var text = $('#dev-config').val();
            var done = function() { $('#dev-copy-ok').show().delay(1500).fadeOut(); };
            if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(text).then(done);
            } else {
                $('#dev-config').trigger('select');
                document.execCommand('copy');
                done();
            }
        });

        $('#dev-download').on('click', function() {
            var blob = new Blob([$('#dev-config').val()], {type: 'text/plain'});
            var a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = $('#dev-filename').val();
            document.body.appendChild(a);
            a.click();
            setTimeout(function() { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
        });

        $('#DialogDevice').on('hide.bs.modal', function(ev) {
            if (_devDone && !confirm('{{ lang._("The private key is shown only once. Close anyway?") }}')) {
                ev.preventDefault();
                return;
            }
        }).on('hidden.bs.modal', function() {
            devClearResult();
            if (_devDone) {
                _devDone = false;
                $.get('/api/vpnlink/link/wgSources', function(r) { if (r && r.status === 'ok') _wgData = r; loadLinksTable(); });
                updateStatusBar();
            }
        });

        // ══════════════════════════════════════
        // Status Bar + Apply
        // ══════════════════════════════════════
        function updateStatusBar() {
            $.get('/api/vpnlink/service/healthcheck', function(r) {
                if (!r || !r.checks) {
                    $('#svc-bar-icon').attr('class', 'fa fa-question-circle text-muted');
                    $('#svc-bar-text').text('Unknown');
                    return;
                }
                var allOk = r.checks.every(function(c) { return c.ok; });
                var failCount = r.checks.filter(function(c) { return !c.ok; }).length;
                if (allOk) {
                    $('#svc-bar-icon').attr('class', 'fa fa-check-circle text-success');
                    $('#svc-bar-text').text('Active — all checks passed');
                    $('#svc-bar').css('border-left-color', '#5cb85c');
                } else {
                    $('#svc-bar-icon').attr('class', 'fa fa-exclamation-triangle text-warning');
                    $('#svc-bar-text').text(failCount + ' issue(s)');
                    $('#svc-bar').css('border-left-color', '#f0ad4e');
                }
            });
        }

        $("#reconfigureAct").SimpleActionButton({
            onPreAction: function() {
                var dfObj = new $.Deferred();
                saveFormToEndpoint("/api/vpnlink/settings/set", 'frm_GeneralSettings',
                    function() { dfObj.resolve(); }, true, function() { dfObj.reject(); });
                return dfObj;
            },
            onAction: function() { loadLinksTable(); $('#LinkChangeMessage').hide(); updateStatusBar(); }
        });

        updateStatusBar();
    });
</script>

{# ══════ Status Bar ══════ #}
<div id="svc-bar" style="padding:10px 15px; background:#f8f8f8; border:1px solid #ddd; border-left:4px solid #ccc; border-radius:4px; margin-bottom:12px; display:flex; justify-content:space-between; align-items:center;">
    <span>
        <span id="svc-bar-icon" class="fa fa-circle-o-notch fa-spin text-muted"></span>
        <strong>{{ lang._('VPN Link') }}</strong>
        <span id="svc-bar-text" class="text-muted" style="margin-left:8px;">{{ lang._('Checking...') }}</span>
    </span>
    <span>
        <button class="btn btn-primary btn-sm" id="reconfigureAct"
                data-endpoint='/api/vpnlink/service/reconfigure'
                data-label="{{ lang._('Apply') }}"
                data-error-title="{{ lang._('Error reconfiguring VPN Link') }}"
                type="button"></button>
    </span>
</div>

{# ══════ Header ══════ #}
<div class="content-box" style="padding-bottom:0;">
    {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_GeneralSettings'])}}
</div>

{# ══════ Links ══════ #}
<div class="content-box" style="padding: 1.5em; margin-top: 1em;">
    <div style="margin-bottom:10px;">
        <button id="btn-add-link" class="btn btn-primary btn-sm"><span class="fa fa-plus"></span> {{ lang._('Add Link') }}</button>
        <button id="btn-add-device" class="btn btn-default btn-sm" title="{{ lang._('Create a WireGuard peer, its access link and the client config in one step') }}"><span class="fa fa-laptop"></span> {{ lang._('Add device') }}</button>
    </div>
    <table class="table table-condensed table-hover table-striped">
        <thead><tr>
            <th style="width:3em" class="text-center">{{ lang._('On') }}</th>
            <th>{{ lang._('Source (WireGuard)') }}</th>
            <th style="width:18em">{{ lang._('Destination (LAN)') }}</th>
            <th style="width:14em">{{ lang._('Egress') }}</th>
            <th style="width:14em">{{ lang._('Access') }}</th>
            <th style="width:6em"></th>
        </tr></thead>
        <tbody id="links-tbody"><tr><td colspan="6" class="text-center text-muted" style="padding:20px">{{ lang._('Loading...') }}</td></tr></tbody>
    </table>
</div>

{# ══════ Change Message ══════ #}
<div class="col-md-12" style="margin-top:1em;">
    <div id="LinkChangeMessage" class="alert alert-info" style="display:none" role="alert">{{ lang._('Click Apply in the status bar above to activate changes.') }}</div>
</div>

{# ══════ Edit Link Dialog ══════ #}
<div class="modal fade" id="DialogLink" tabindex="-1" role="dialog">
    <div class="modal-dialog">
        <div class="modal-content">
            <div class="modal-header">
                <button type="button" class="close" data-dismiss="modal"><span>&times;</span></button>
                <h4 class="modal-title" id="dlg-title">{{ lang._('Edit Link') }}</h4>
            </div>
            <div class="modal-body">
                <table class="dlg-form-table">
                    <tr>
                        <td class="dlg-label">{{ lang._('Enabled') }}</td>
                        <td class="dlg-field"><input type="checkbox" id="dlg-enabled" checked/></td>
                    </tr>
                    <tr>
                        <td class="dlg-label">{{ lang._('Source') }}</td>
                        <td class="dlg-field">
                            <select id="dlg-source" class="selectpicker" multiple data-live-search="true" data-actions-box="true" data-selected-text-format="count > 2" data-count-selected-text="{0} selected" data-none-selected-text="— Select source —" data-width="100%" data-container="body"></select>
                            <small>{{ lang._('WireGuard server(s) or device(s).') }}</small>
                        </td>
                    </tr>
                    <tr>
                        <td class="dlg-label">{{ lang._('Destination') }}</td>
                        <td class="dlg-field">
                            <select id="dlg-dest" class="selectpicker" data-width="100%" data-none-selected-text="— Select LAN —" data-container="body"></select>
                            <small>{{ lang._('VPN clients will mirror this LAN.') }}</small>
                        </td>
                    </tr>
                    <tr>
                        <td class="dlg-label">{{ lang._('Egress gateway') }}</td>
                        <td class="dlg-field">
                            <select id="dlg-gateway" class="selectpicker" data-width="100%" data-container="body"></select>
                            <small>{{ lang._('Optional. Internet traffic of these clients leaves via this gateway; local/private destinations are not affected.') }}</small>
                            <label style="display:block; margin:6px 0 0; font-weight:normal;">
                                <input type="checkbox" id="dlg-kill-switch"/> {{ lang._('Kill switch') }}
                                <small class="text-muted" style="display:inline"> — {{ lang._('never exit via WAN directly, even if the gateway is down') }}</small>
                            </label>
                        </td>
                    </tr>
                    <tr>
                        <td class="dlg-label">{{ lang._('Access') }}</td>
                        <td class="dlg-field">
                            <select id="dlg-access" class="form-control">
                                <option value="full">{{ lang._('Full (mirror LAN rules)') }}</option>
                                <option value="internet">{{ lang._('Internet only') }}</option>
                                <option value="custom">{{ lang._('Internet + selected networks') }}</option>
                            </select>
                            <div id="dlg-allowed-panel" style="display:none; margin-top:6px;">
                                <select id="dlg-allowed-ifs" class="selectpicker" multiple data-width="100%" data-container="body"></select>
                                <input type="text" id="dlg-allowed-extra" class="form-control" style="margin-top:6px;" placeholder="{{ lang._('More networks or aliases, e.g. 192.168.50.0/24, MyAlias') }}"/>
                            </div>
                            <small id="dlg-access-help" style="display:none">{{ lang._('Blocks the firewall itself (GUI, SSH, ...) and all private networks for these clients, except DNS on the firewall and the selected networks. Internet traffic follows the mirrored LAN rules.') }}</small>
                        </td>
                    </tr>
                    <tr>
                        <td></td>
                        <td class="dlg-field" style="padding-top:12px;">
                            <a data-toggle="collapse" href="#dlg-advanced-panel" style="font-size:12px; color:#888;">
                                <span class="fa fa-cog"></span> {{ lang._('Advanced') }} <span class="fa fa-caret-down"></span>
                            </a>
                            <div class="collapse" id="dlg-advanced-panel" style="margin-top:8px; padding:10px; background:#f9f9f9; border:1px solid #eee; border-radius:3px;">
                                <label style="display:block; margin:4px 0; font-weight:normal;">
                                    <input type="checkbox" id="dlg-clone-rules" checked/> {{ lang._('Clone firewall rules') }}
                                    <small class="text-muted"> — {{ lang._('replicate LAN routing rules') }}</small>
                                </label>
                                <label style="display:block; margin:4px 0; font-weight:normal;">
                                    <input type="checkbox" id="dlg-auto-nat" checked/> {{ lang._('Auto NAT') }}
                                    <small class="text-muted"> — {{ lang._('outbound NAT on all interfaces') }}</small>
                                </label>
                                <label style="display:block; margin:4px 0; font-weight:normal;">
                                    <input type="checkbox" id="dlg-dns-sync" checked/> {{ lang._('DNS sync') }}
                                    <small class="text-muted"> — {{ lang._('Unbound/AdGuard ACL') }}</small>
                                </label>
                                <label style="display:block; margin:4px 0; font-weight:normal;">
                                    <input type="checkbox" id="dlg-nat-lan" checked/> {{ lang._('NAT towards LAN') }}
                                    <small class="text-muted"> — {{ lang._('off: LAN hosts see real VPN client IPs') }}</small>
                                </label>
                            </div>
                        </td>
                    </tr>
                </table>
            </div>
            <div class="modal-footer">
                <button type="button" class="btn btn-default" data-dismiss="modal">{{ lang._('Cancel') }}</button>
                <button type="button" class="btn btn-primary" id="dlg-save"><span class="fa fa-check"></span> {{ lang._('Save') }}</button>
            </div>
        </div>
    </div>
</div>

{# ══════ Add Device Wizard ══════ #}
<div class="modal fade" id="DialogDevice" tabindex="-1" role="dialog" data-backdrop="static">
    <div class="modal-dialog modal-lg">
        <div class="modal-content">
            <div class="modal-header">
                <button type="button" class="close" data-dismiss="modal"><span>&times;</span></button>
                <h4 class="modal-title">{{ lang._('Add device') }}</h4>
            </div>
            <div class="modal-body">
                <div id="dev-error" class="alert alert-danger" style="display:none; white-space:pre-line"></div>
                <div id="dev-form">
                    <p class="text-muted">{{ lang._('Creates the WireGuard peer on the selected instance, the VPN Link access rules it needs, applies both and shows the client configuration.') }}</p>
                    <table class="dlg-form-table">
                        <tr>
                            <td class="dlg-label">{{ lang._('Device name') }}</td>
                            <td class="dlg-field">
                                <input type="text" id="dev-name" class="form-control" maxlength="64" placeholder="{{ lang._('e.g. work-laptop') }}"/>
                                <small>{{ lang._('Letters, digits, dot, dash, underscore. Must be unique among WireGuard peers.') }}</small>
                            </td>
                        </tr>
                        <tr>
                            <td class="dlg-label">{{ lang._('Instance') }}</td>
                            <td class="dlg-field">
                                <select id="dev-instance" class="form-control"></select>
                                <small>{{ lang._('Next free tunnel address:') }} <b id="dev-next-ip"></b></small>
                            </td>
                        </tr>
                        <tr>
                            <td class="dlg-label">{{ lang._('Access') }}</td>
                            <td class="dlg-field">
                                <select id="dev-access" class="form-control">
                                    <option value="full">{{ lang._('Full (mirror LAN rules)') }}</option>
                                    <option value="internet">{{ lang._('Internet only') }}</option>
                                    <option value="custom">{{ lang._('Internet + selected networks') }}</option>
                                </select>
                                <div id="dev-allowed-panel" style="display:none; margin-top:6px;">
                                    <select id="dev-allowed-ifs" class="selectpicker" multiple data-width="100%" data-container="body"></select>
                                    <input type="text" id="dev-allowed-extra" class="form-control" style="margin-top:6px;" placeholder="{{ lang._('More networks or aliases, e.g. 192.168.50.0/24, MyAlias') }}"/>
                                </div>
                                <small id="dev-covered" style="display:none"></small>
                                <div id="dev-plugin-off" class="text-warning" style="display:none; margin-top:4px;"><span class="fa fa-exclamation-triangle"></span> {{ lang._('VPN Link is disabled: the restriction takes effect only after enabling it and clicking Apply.') }}</div>
                            </td>
                        </tr>
                        <tr id="dev-lan-row" style="display:none">
                            <td class="dlg-label">{{ lang._('Mirror LAN') }}</td>
                            <td class="dlg-field">
                                <select id="dev-lan" class="form-control"></select>
                                <small>{{ lang._('No link covers this instance yet: the device gets its own link mirroring this LAN (rules, NAT, DNS).') }}</small>
                            </td>
                        </tr>
                        <tr>
                            <td class="dlg-label">{{ lang._('Client routing') }}</td>
                            <td class="dlg-field">
                                <label style="font-weight:normal; margin-right:16px;"><input type="radio" name="dev-routing" value="full" checked/> {{ lang._('Full tunnel (all traffic, 0.0.0.0/0)') }}</label>
                                <label style="font-weight:normal;"><input type="radio" name="dev-routing" value="split"/> {{ lang._('Split tunnel (home networks only)') }}</label>
                                <small id="dev-split-internet" style="display:none">{{ lang._('With Internet only access, a split tunnel only carries DNS through the tunnel.') }}</small>
                            </td>
                        </tr>
                        <tr>
                            <td class="dlg-label">{{ lang._('Endpoint') }}</td>
                            <td class="dlg-field">
                                <div style="display:flex; gap:6px;">
                                    <input type="text" id="dev-endpoint" class="form-control" style="flex:1" placeholder="{{ lang._('vpn.example.com') }}"/>
                                    <input type="text" id="dev-port" class="form-control" style="width:7em" placeholder="51820"/>
                                </div>
                                <small id="dev-endpoint-src"></small>
                            </td>
                        </tr>
                        <tr>
                            <td class="dlg-label">{{ lang._('Client DNS') }}</td>
                            <td class="dlg-field">
                                <input type="text" id="dev-dns" class="form-control"/>
                                <small>{{ lang._('Default: the tunnel address of the instance (required for iOS).') }}</small>
                            </td>
                        </tr>
                        <tr>
                            <td class="dlg-label">{{ lang._('Keepalive / MTU') }}</td>
                            <td class="dlg-field">
                                <div style="display:flex; gap:6px;">
                                    <input type="text" id="dev-keepalive" class="form-control" style="width:7em" title="{{ lang._('Persistent keepalive in seconds, 0 = off') }}"/>
                                    <input type="text" id="dev-mtu" class="form-control" style="width:7em" title="MTU"/>
                                </div>
                                <small>{{ lang._('Keepalive in seconds (0 = off), set on the client only.') }}</small>
                            </td>
                        </tr>
                        <tr>
                            <td class="dlg-label">{{ lang._('Pre-shared key') }}</td>
                            <td class="dlg-field"><label style="font-weight:normal;"><input type="checkbox" id="dev-psk"/> {{ lang._('Generate a pre-shared key') }}</label></td>
                        </tr>
                    </table>
                </div>
                <div id="dev-result" style="display:none">
                    <div class="alert alert-warning"><span class="fa fa-key"></span> <b>{{ lang._('Shown once: save it now.') }}</b>
                        {{ lang._('This configuration contains the private key of the device. It is not stored on the firewall and cannot be shown again.') }}</div>
                    <div id="dev-warnings"></div>
                    <div class="row">
                        <div class="col-sm-7">
                            <table class="table table-condensed" id="dev-summary"></table>
                            <textarea id="dev-config" class="form-control" rows="13" readonly spellcheck="false"></textarea>
                            <input type="hidden" id="dev-filename"/>
                            <div style="margin-top:8px;">
                                <button type="button" class="btn btn-default btn-sm" id="dev-copy"><span class="fa fa-clipboard"></span> {{ lang._('Copy') }}</button>
                                <button type="button" class="btn btn-default btn-sm" id="dev-download"><span class="fa fa-download"></span> {{ lang._('Download .conf') }}</button>
                                <span id="dev-copy-ok" class="text-success" style="display:none; margin-left:8px;"><span class="fa fa-check"></span> {{ lang._('Copied') }}</span>
                            </div>
                        </div>
                        <div class="col-sm-5 text-center">
                            <div id="dev-qr"></div>
                            <small class="text-muted">{{ lang._('Scan with the WireGuard app') }}</small>
                        </div>
                    </div>
                </div>
            </div>
            <div class="modal-footer">
                <button type="button" class="btn btn-default" data-dismiss="modal">{{ lang._('Close') }}</button>
                <button type="button" class="btn btn-primary" id="dev-create"><span class="fa fa-check"></span> {{ lang._('Create device') }}</button>
            </div>
        </div>
    </div>
</div>
