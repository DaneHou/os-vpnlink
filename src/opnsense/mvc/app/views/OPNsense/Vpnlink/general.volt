{# OPNsense VPN Link — Links #}

<style>
    /* Dialog form */
    .dlg-form-table { width: 100%; }
    .dlg-form-table td.dlg-label { width: 120px; vertical-align: middle; padding: 10px 12px 10px 0; text-align: right; font-weight: bold; color: #555; }
    .dlg-form-table td.dlg-field { padding: 8px 0; }
    .dlg-form-table td.dlg-field small { display: block; margin-top: 3px; color: #999; }
    #DialogLink .modal-body { overflow: visible; }
</style>

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
                    tbody.append('<tr><td colspan="5" class="text-center text-muted" style="padding:20px">{{ lang._("No links configured. Click Add Link to create one.") }}</td></tr>');
                    return;
                }
                $.each(rows, function(i, row) {
                    var on = row.enabled == '1' ? '<span class="fa fa-check-circle text-success"></span>' : '<span class="fa fa-times-circle text-danger"></span>';
                    tbody.append(
                        '<tr><td class="text-center" style="width:3em">' + on + '</td>' +
                        '<td>' + fmtSource(row.source, row.name) + '</td>' +
                        '<td style="width:18em"><span class="fa fa-fw fa-arrow-right text-muted"></span> <b>' + fmtLan(row.lanInterface) + '</b></td>' +
                        '<td style="width:14em">' + fmtEgress(row) + '</td>' +
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

            var firstName = sources[0] === 'any' ? 'Any' : wgName(sources[0]);
            if (sources.length > 1) firstName += ' +' + (sources.length - 1);
            $.post(_editUuid ? '/api/vpnlink/link/setLink/' + _editUuid : '/api/vpnlink/link/addLink/',
                { link: { enabled:$('#dlg-enabled').is(':checked')?'1':'0', name:firstName, source:sources.join(','), lanInterface:lanIf,
                    cloneRules:$('#dlg-clone-rules').is(':checked')?'1':'0', autoNat:$('#dlg-auto-nat').is(':checked')?'1':'0', dnsSync:$('#dlg-dns-sync').is(':checked')?'1':'0',
                    natOnLan:$('#dlg-nat-lan').is(':checked')?'1':'0', killSwitch:$('#dlg-kill-switch').is(':checked')?'1':'0',
                    gateway:$('#dlg-gateway').val() || '' } },
                function(r) {
                    if (r && (r.result === 'saved' || r.uuid)) { $('#DialogLink').modal('hide'); loadLinksTable(); $('#LinkChangeMessage').show(); }
                    else { alert(r && r.validations ? Object.values(r.validations).join('\n') : 'Save failed.'); }
                }
            );
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
    </div>
    <table class="table table-condensed table-hover table-striped">
        <thead><tr>
            <th style="width:3em" class="text-center">{{ lang._('On') }}</th>
            <th>{{ lang._('Source (WireGuard)') }}</th>
            <th style="width:18em">{{ lang._('Destination (LAN)') }}</th>
            <th style="width:14em">{{ lang._('Egress') }}</th>
            <th style="width:6em"></th>
        </tr></thead>
        <tbody id="links-tbody"><tr><td colspan="5" class="text-center text-muted" style="padding:20px">{{ lang._('Loading...') }}</td></tr></tbody>
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
