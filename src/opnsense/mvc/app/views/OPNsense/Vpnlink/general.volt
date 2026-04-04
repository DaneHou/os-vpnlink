{#
  OPNsense VPN Link — VPN > VPN Link
#}

<style>
    #DialogLink .dlg-form-table { width: 100%; }
    #DialogLink .dlg-form-table td.dlg-label { width: 120px; vertical-align: middle; padding: 10px 12px 10px 0; text-align: right; font-weight: bold; color: #555; }
    #DialogLink .dlg-form-table td.dlg-field { padding: 8px 0; }
    #DialogLink .dlg-form-table td.dlg-field small { display: block; margin-top: 3px; color: #999; }
    #DialogLink .modal-body { overflow: visible; }
</style>

<script>
    var _wgData = null, _lanData = null;

    $(document).ready(function() {
        mapDataToFormUI({'frm_GeneralSettings': "/api/vpnlink/settings/get"}).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        $.when(
            $.get('/api/vpnlink/link/wgSources'),
            $.get('/api/vpnlink/link/lanInterfaces')
        ).done(function(wgR, lanR) {
            if (wgR[0] && wgR[0].status === 'ok') _wgData = wgR[0];
            if (lanR[0] && lanR[0].status === 'ok') _lanData = lanR[0];
            loadLinksTable();
        });

        // ── Links Table ──
        function loadLinksTable() {
            $.post('/api/vpnlink/link/searchLink', {current:1, rowCount:-1}, function(r) {
                var tbody = $('#links-tbody').empty();
                var rows = (r && r.rows) ? r.rows : [];
                if (rows.length === 0) {
                    tbody.append('<tr><td colspan="4" class="text-center text-muted" style="padding:20px">{{ lang._("No links yet. Click Add Link.") }}</td></tr>');
                    return;
                }
                $.each(rows, function(i, row) {
                    var on = row.enabled == '1' ? '<span class="fa fa-check-circle text-success"></span>' : '<span class="fa fa-times-circle text-danger"></span>';
                    tbody.append(
                        '<tr><td class="text-center" style="width:3em">' + on + '</td>' +
                        '<td>' + fmtSource(row.source, row.name) + '</td>' +
                        '<td style="width:18em"><span class="fa fa-fw fa-arrow-right text-muted"></span> <b>' + fmtLan(row.lanInterface) + '</b></td>' +
                        '<td style="width:6em">' +
                            '<button class="btn btn-xs btn-default btn-edit" data-uuid="' + row.uuid + '"><span class="fa fa-pencil"></span></button> ' +
                            '<button class="btn btn-xs btn-danger btn-del" data-uuid="' + row.uuid + '"><span class="fa fa-trash-o"></span></button>' +
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
                labels.push('<span class="fa fa-fw ' + icon + '"></span> ' + n + ' <small class="text-muted">(' + s + ')</small>');
            });
            return labels.join(', ');
        }

        function wgName(val) {
            if (!_wgData) return val;
            for (var i = 0; i < (_wgData.servers||[]).length; i++) if (_wgData.servers[i].subnet === val) return _wgData.servers[i].name;
            for (var i = 0; i < (_wgData.peers||[]).length; i++) if (_wgData.peers[i].ip === val) return _wgData.peers[i].name;
            return val;
        }

        function fmtLan(ifname) {
            if (_lanData && _lanData.interfaces) {
                for (var i = 0; i < _lanData.interfaces.length; i++)
                    if (_lanData.interfaces[i].name === ifname) return _lanData.interfaces[i].descr + ' (' + ifname + ')';
            }
            return ifname || '';
        }

        // ── Dialog: populate source multi-select ──
        function buildSourceSelect(selectedCsv) {
            var sel = (selectedCsv || '').split(',').map(function(s){ return $.trim(s); });
            var el = $('#dlg-source');
            el.empty();

            el.append('<option value="any">Any (all WireGuard)</option>');

            if (_wgData) {
                if (_wgData.servers && _wgData.servers.length > 0) {
                    var g = $('<optgroup label="WG Servers (all clients)"></optgroup>');
                    $.each(_wgData.servers, function(i, s) {
                        g.append($('<option></option>').val(s.subnet).text(s.name + ' (' + s.subnet + ')'));
                    });
                    el.append(g);
                }
                var groups = {};
                $.each(_wgData.peers || [], function(i, p) {
                    var gn = p.server || 'Other';
                    if (!groups[gn]) groups[gn] = [];
                    groups[gn].push(p);
                });
                $.each(groups, function(gn, peers) {
                    var g = $('<optgroup label="' + gn + ' — Devices"></optgroup>');
                    $.each(peers, function(i, p) {
                        g.append($('<option></option>').val(p.ip).text(p.name + ' (' + p.ip + ')'));
                    });
                    el.append(g);
                });
            }

            el.val(sel);
            el.selectpicker('destroy').selectpicker({
                actionsBox: true,
                liveSearch: true,
                selectedTextFormat: 'count > 2',
                countSelectedText: '{0} selected',
                noneSelectedText: '— Select source —'
            }).selectpicker('val', sel);
        }

        // ── Dialog: populate destination single-select ──
        function buildDestSelect(selectedVal) {
            var el = $('#dlg-dest');
            el.empty();
            el.append('<option value="">— Select LAN —</option>');
            if (_lanData && _lanData.interfaces) {
                $.each(_lanData.interfaces, function(i, f) {
                    var label = f.descr + ' (' + f.name + ')';
                    if (f.cidr) label += ' — ' + f.cidr;
                    el.append($('<option></option>').val(f.name).text(label));
                });
            }
            if (selectedVal) el.val(selectedVal);
            el.selectpicker('destroy').selectpicker({ liveSearch: false, noneSelectedText: '— Select LAN —' }).selectpicker('val', selectedVal || '');
        }

        // ── Open dialog ──
        var _editUuid = null;

        function resetAdvanced() {
            $('#dlg-clone-rules').prop('checked', true);
            $('#dlg-auto-nat').prop('checked', true);
            $('#dlg-dns-sync').prop('checked', true);
            $('#dlg-advanced-panel').collapse('hide');
        }

        $('#btn-add-link').on('click', function() {
            _editUuid = null;
            $('#dlg-title').text('{{ lang._("Add Link") }}');
            $('#dlg-enabled').prop('checked', true);
            resetAdvanced();
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
                    buildSourceSelect(r.link.source || '');
                    buildDestSelect(r.link.lanInterface || '');
                    // Show advanced if any option is off
                    if (r.link.cloneRules === '0' || r.link.autoNat === '0' || r.link.dnsSync === '0') {
                        $('#dlg-advanced-panel').collapse('show');
                    } else {
                        $('#dlg-advanced-panel').collapse('hide');
                    }
                }
                $('#DialogLink').modal('show');
            });
        });

        $(document).on('click', '.btn-del', function() {
            var uuid = $(this).data('uuid');
            if (confirm('{{ lang._("Delete this link?") }}')) {
                $.post('/api/vpnlink/link/delLink/' + uuid, function() { loadLinksTable(); $('#LinkChangeMessage').show(); });
            }
        });

        // ── Save ──
        $('#dlg-save').on('click', function() {
            var sources = $('#dlg-source').val() || [];
            if (sources.length === 0) { alert('{{ lang._("Select at least one source.") }}'); return; }
            var sourceStr = sources.join(',');

            var lanIf = $('#dlg-dest').val();
            if (!lanIf) { alert('{{ lang._("Select a destination LAN.") }}'); return; }

            var firstName = sources[0] === 'any' ? 'Any' : wgName(sources[0]);
            if (sources.length > 1) firstName += ' +' + (sources.length - 1);

            $.post(
                _editUuid ? '/api/vpnlink/link/setLink/' + _editUuid : '/api/vpnlink/link/addLink/',
                { link: {
                    enabled: $('#dlg-enabled').is(':checked') ? '1' : '0',
                    name: firstName, source: sourceStr, lanInterface: lanIf,
                    cloneRules: $('#dlg-clone-rules').is(':checked') ? '1' : '0',
                    autoNat: $('#dlg-auto-nat').is(':checked') ? '1' : '0',
                    dnsSync: $('#dlg-dns-sync').is(':checked') ? '1' : '0'
                } },
                function(r) {
                    if (r && (r.result === 'saved' || r.uuid)) {
                        $('#DialogLink').modal('hide');
                        loadLinksTable();
                        $('#LinkChangeMessage').show();
                    } else {
                        alert(r && r.validations ? Object.values(r.validations).join('\n') : 'Save failed.');
                    }
                }
            );
        });

        // ── Status Tab ──
        function loadStatus() {
            var box = $('#status-body').html('<tr><td colspan="2" class="text-center text-muted">Loading...</td></tr>');
            $.get('/api/vpnlink/service/healthcheck', function(r) {
                box.empty();
                if (!r || !r.checks) { box.html('<tr><td colspan="2">Error loading status</td></tr>'); return; }
                $.each(r.checks, function(i, c) {
                    var icon = c.ok ? '<span class="fa fa-check-circle text-success"></span>' : '<span class="fa fa-times-circle text-danger"></span>';
                    var row = '<tr><td style="width:2em">' + icon + '</td><td><b>' + c.name + '</b><br/><small class="text-muted">' + c.detail + '</small>';
                    // Show peers if available
                    if (c.peers && c.peers.length > 0) {
                        row += '<div style="margin-top:4px">';
                        $.each(c.peers, function(j, p) {
                            var ago = p.handshake_ago;
                            var agoStr = ago < 60 ? ago + 's ago' : ago < 3600 ? Math.floor(ago/60) + 'm ago' : Math.floor(ago/3600) + 'h ago';
                            var rx = (p.rx_bytes / 1048576).toFixed(1) + ' MB';
                            var tx = (p.tx_bytes / 1048576).toFixed(1) + ' MB';
                            row += '<div style="margin-left:1em"><small><span class="fa fa-fw fa-mobile"></span> ' + p.allowed_ips + ' — ' + agoStr + ' (rx:' + rx + ' tx:' + tx + ')</small></div>';
                        });
                        row += '</div>';
                    }
                    // Show rules if available (expandable)
                    if (c.rules && c.rules.length > 0) {
                        var rid = 'rules-' + i;
                        row += '<div style="margin-top:4px"><a data-toggle="collapse" href="#' + rid + '" style="font-size:11px;color:#888;"><span class="fa fa-caret-right"></span> Show rules</a>';
                        row += '<div class="collapse" id="' + rid + '" style="margin-top:4px;">';
                        $.each(c.rules, function(j, r) {
                            row += '<div style="font-family:monospace;font-size:11px;color:#666;padding:1px 0;white-space:nowrap;overflow-x:auto;">' + $('<span>').text(r).html() + '</div>';
                        });
                        row += '</div></div>';
                    }
                    row += '</td></tr>';
                    box.append(row);
                });
            });
        }

        // ── Log Tab ──
        function loadLog() {
            var box = $('#log-body').html('<div class="text-center text-muted">Loading...</div>');
            $.get('/api/vpnlink/service/log', function(r) {
                box.empty();
                if (!r || !r.entries || r.entries.length === 0) {
                    box.html('<div class="text-muted" style="padding:20px;text-align:center">No VPNLink log entries found.</div>');
                    return;
                }
                var html = '<table class="table table-condensed table-striped" style="font-size:12px;">';
                $.each(r.entries, function(i, e) {
                    var ts = e.timestamp ? e.timestamp.split('T').pop().split('-')[0] : '';
                    html += '<tr><td style="width:8em;white-space:nowrap;color:#888;">' + ts + '</td><td>' + $('<span>').text(e.message).html() + '</td></tr>';
                });
                html += '</table>';
                box.html(html);
            });
        }

        // Load tabs on click
        $('a[href="#tab-status"]').on('shown.bs.tab', function() { loadStatus(); });
        $('a[href="#tab-log"]').on('shown.bs.tab', function() { loadLog(); });

        // ── Apply ──
        $("#reconfigureAct").SimpleActionButton({
            onPreAction: function() {
                const dfObj = new $.Deferred();
                saveFormToEndpoint("/api/vpnlink/settings/set", 'frm_GeneralSettings',
                    function() { dfObj.resolve(); }, true, function() { dfObj.reject(); }
                );
                return dfObj;
            },
            onAction: function(data, status) { updateServiceControlUI('vpnlink'); loadLinksTable(); $('#LinkChangeMessage').hide(); }
        });

        updateServiceControlUI('vpnlink');
    });
</script>

<!-- Header + Enable -->
<div class="content-box" style="padding-bottom:0;">
    <div class="alert alert-info" role="alert" style="margin:15px;">
        <b>{{ lang._('VPN Link') }}</b> &mdash;
        {{ lang._('Map WireGuard sources to LAN destinations. VPN clients behave like devices on that LAN.') }}
        <br/><small>{{ lang._('NAT, DNS, and routing are automatic. WireGuard peers DNS should point to the WG interface IP.') }}</small>
    </div>
    {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_GeneralSettings'])}}
</div>

<!-- Tabs -->
<ul class="nav nav-tabs" style="margin-top:1em;">
    <li class="active"><a data-toggle="tab" href="#tab-links">{{ lang._('Links') }}</a></li>
    <li><a data-toggle="tab" href="#tab-status">{{ lang._('Status') }}</a></li>
    <li><a data-toggle="tab" href="#tab-log">{{ lang._('Log') }}</a></li>
</ul>

<div class="tab-content">
    <!-- Links Tab -->
    <div id="tab-links" class="tab-pane fade in active" style="padding:15px;">
        <div style="margin-bottom:10px;">
            <button id="btn-add-link" class="btn btn-primary btn-sm"><span class="fa fa-plus"></span> {{ lang._('Add Link') }}</button>
        </div>
        <table class="table table-condensed table-hover table-striped">
            <thead><tr>
                <th style="width:3em" class="text-center">{{ lang._('On') }}</th>
                <th>{{ lang._('Source (WireGuard)') }}</th>
                <th style="width:18em">{{ lang._('Destination (LAN)') }}</th>
                <th style="width:6em"></th>
            </tr></thead>
            <tbody id="links-tbody"><tr><td colspan="4" class="text-center text-muted" style="padding:20px">{{ lang._('Loading...') }}</td></tr></tbody>
        </table>
    </div>

    <!-- Status Tab -->
    <div id="tab-status" class="tab-pane fade" style="padding:15px;">
        <div style="margin-bottom:10px;">
            <button class="btn btn-default btn-sm" onclick="loadStatus()"><span class="fa fa-refresh"></span> {{ lang._('Refresh') }}</button>
        </div>
        <table class="table table-condensed">
            <tbody id="status-body">
                <tr><td class="text-center text-muted" style="padding:20px">{{ lang._('Click tab to load status...') }}</td></tr>
            </tbody>
        </table>
    </div>

    <!-- Log Tab -->
    <div id="tab-log" class="tab-pane fade" style="padding:15px;">
        <div style="margin-bottom:10px;">
            <button class="btn btn-default btn-sm" onclick="loadLog()"><span class="fa fa-refresh"></span> {{ lang._('Refresh') }}</button>
        </div>
        <div id="log-body" style="max-height:400px; overflow-y:auto;">
            <div class="text-center text-muted" style="padding:20px">{{ lang._('Click tab to load log...') }}</div>
        </div>
    </div>
</div>

<!-- Apply -->
<div class="col-md-12">
    <div id="LinkChangeMessage" class="alert alert-info" style="display:none" role="alert">{{ lang._('Click Apply to activate changes.') }}</div>
    <hr/>
    <button class="btn btn-primary" id="reconfigureAct"
            data-endpoint='/api/vpnlink/service/reconfigure'
            data-label="{{ lang._('Apply') }}"
            data-error-title="{{ lang._('Error reconfiguring VPN Link') }}"
            type="button"></button>
</div>

<!-- Edit Dialog -->
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
                            <small>{{ lang._('WireGuard server(s) or device(s). Multi-select supported.') }}</small>
                        </td>
                    </tr>
                    <tr>
                        <td class="dlg-label">{{ lang._('Destination') }}</td>
                        <td class="dlg-field">
                            <select id="dlg-dest" class="selectpicker" data-width="100%" data-none-selected-text="— Select LAN —" data-container="body"></select>
                            <small>{{ lang._('VPN clients will mirror this LAN — same DNS, routing, gateway policies.') }}</small>
                        </td>
                    </tr>
                    <tr>
                        <td></td>
                        <td class="dlg-field" style="padding-top:12px;">
                            <a data-toggle="collapse" href="#dlg-advanced-panel" style="font-size:12px; color:#888;">
                                <span class="fa fa-cog"></span> {{ lang._('Advanced Options') }} <span class="fa fa-caret-down"></span>
                            </a>
                            <div class="collapse" id="dlg-advanced-panel" style="margin-top:8px; padding:10px; background:#f9f9f9; border:1px solid #eee; border-radius:3px;">
                                <label style="display:block; margin:4px 0; font-weight:normal;">
                                    <input type="checkbox" id="dlg-clone-rules" checked/>
                                    {{ lang._('Clone firewall rules') }}
                                    <small class="text-muted"> — {{ lang._('replicate LAN policy routing, gateway rules onto WG interface') }}</small>
                                </label>
                                <label style="display:block; margin:4px 0; font-weight:normal;">
                                    <input type="checkbox" id="dlg-auto-nat" checked/>
                                    {{ lang._('Auto NAT') }}
                                    <small class="text-muted"> — {{ lang._('outbound NAT on WAN, LAN, and all gateway interfaces') }}</small>
                                </label>
                                <label style="display:block; margin:4px 0; font-weight:normal;">
                                    <input type="checkbox" id="dlg-dns-sync" checked/>
                                    {{ lang._('DNS sync') }}
                                    <small class="text-muted"> — {{ lang._('add WG subnet to Unbound/AdGuard ACL') }}</small>
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
