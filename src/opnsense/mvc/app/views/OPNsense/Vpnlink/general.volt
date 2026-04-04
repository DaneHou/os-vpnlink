{# OPNsense VPN Link — VPN > VPN Link #}

<style>
    /* Dialog form */
    .dlg-form-table { width: 100%; }
    .dlg-form-table td.dlg-label { width: 120px; vertical-align: middle; padding: 10px 12px 10px 0; text-align: right; font-weight: bold; color: #555; }
    .dlg-form-table td.dlg-field { padding: 8px 0; }
    .dlg-form-table td.dlg-field small { display: block; margin-top: 3px; color: #999; }
    #DialogLink .modal-body { overflow: visible; }

    /* Status cards */
    .vpnlink-card { border: 1px solid #ddd; border-radius: 4px; margin-bottom: 12px; background: #fff; }
    .vpnlink-card.card-ok { border-left: 4px solid #5cb85c; }
    .vpnlink-card.card-err { border-left: 4px solid #d9534f; }
    .vpnlink-card .card-head { padding: 10px 14px; display: flex; justify-content: space-between; align-items: center; }
    .vpnlink-card .card-head .card-title { font-weight: bold; font-size: 13px; }
    .vpnlink-card .card-head .card-badge { font-size: 11px; }
    .vpnlink-card .card-body { padding: 0 14px 10px; font-size: 12px; color: #555; }
    .vpnlink-card .card-body .metric { display: inline-block; margin-right: 18px; }
    .vpnlink-card .card-body .metric .label-text { color: #888; }
    .vpnlink-card .card-body .metric .value { font-weight: bold; }
    .vpnlink-card .peer-row { padding: 2px 0 2px 8px; border-left: 2px solid #eee; margin: 3px 0; }
    .vpnlink-card .rules-toggle { font-size: 11px; color: #888; cursor: pointer; margin-top: 4px; display: inline-block; }
    .vpnlink-card .rules-list { font-family: monospace; font-size: 11px; color: #666; margin-top: 4px; max-height: 150px; overflow-y: auto; }
    .vpnlink-card .rules-list div { padding: 1px 0; white-space: nowrap; }

    /* Service bar */
    .svc-bar { padding: 8px 15px; background: #f5f5f5; border: 1px solid #ddd; border-radius: 4px; display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
    .svc-bar .svc-status { font-size: 13px; }
    .svc-bar .svc-controls .btn { margin-left: 5px; }

    /* Log */
    .log-table { font-size: 12px; font-family: monospace; }
    .log-table td.ts { width: 7em; color: #888; white-space: nowrap; }
    .log-filter { margin-bottom: 8px; }
    .log-filter input { width: 250px; display: inline-block; }
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

        // ══════════════════════════════════════
        // Links Tab
        // ══════════════════════════════════════
        function loadLinksTable() {
            $.post('/api/vpnlink/link/searchLink', {current:1, rowCount:-1}, function(r) {
                var tbody = $('#links-tbody').empty();
                var rows = (r && r.rows) ? r.rows : [];
                if (rows.length === 0) {
                    tbody.append('<tr><td colspan="4" class="text-center text-muted" style="padding:20px">{{ lang._("No links configured. Click Add Link to create one.") }}</td></tr>');
                    return;
                }
                $.each(rows, function(i, row) {
                    var on = row.enabled == '1' ? '<span class="fa fa-check-circle text-success"></span>' : '<span class="fa fa-times-circle text-danger"></span>';
                    tbody.append(
                        '<tr><td class="text-center" style="width:3em">' + on + '</td>' +
                        '<td>' + fmtSource(row.source, row.name) + '</td>' +
                        '<td style="width:18em"><span class="fa fa-fw fa-arrow-right text-muted"></span> <b>' + fmtLan(row.lanInterface) + '</b></td>' +
                        '<td style="width:6em">' +
                            '<button class="btn btn-xs btn-default btn-edit" data-uuid="' + row.uuid + '" title="Edit"><span class="fa fa-pencil"></span></button> ' +
                            '<button class="btn btn-xs btn-danger btn-del" data-uuid="' + row.uuid + '" title="Delete"><span class="fa fa-trash-o"></span></button>' +
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

        // ── Dialog ──
        function buildSourceSelect(selectedCsv) {
            var sel = (selectedCsv || '').split(',').map(function(s){ return $.trim(s); });
            var el = $('#dlg-source').empty();
            el.append('<option value="any">Any (all WireGuard)</option>');
            if (_wgData) {
                if (_wgData.servers && _wgData.servers.length > 0) {
                    var g = $('<optgroup label="WG Servers (all clients)"></optgroup>');
                    $.each(_wgData.servers, function(i, s) { g.append($('<option>').val(s.subnet).text(s.name + ' (' + s.subnet + ')')); });
                    el.append(g);
                }
                var groups = {};
                $.each(_wgData.peers || [], function(i, p) { var gn = p.server || 'Other'; if (!groups[gn]) groups[gn] = []; groups[gn].push(p); });
                $.each(groups, function(gn, peers) {
                    var g = $('<optgroup label="' + gn + ' — Devices"></optgroup>');
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
            $('#dlg-clone-rules,#dlg-auto-nat,#dlg-dns-sync').prop('checked', true);
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
                    buildSourceSelect(r.link.source || '');
                    buildDestSelect(r.link.lanInterface || '');
                    (r.link.cloneRules==='0'||r.link.autoNat==='0'||r.link.dnsSync==='0') ? $('#dlg-advanced-panel').collapse('show') : $('#dlg-advanced-panel').collapse('hide');
                }
                $('#DialogLink').modal('show');
            });
        });

        $(document).on('click', '.btn-del', function() {
            if (confirm('{{ lang._("Delete this link?") }}')) {
                $.post('/api/vpnlink/link/delLink/' + $(this).data('uuid'), function() { loadLinksTable(); $('#LinkChangeMessage').show(); });
            }
        });

        $('#dlg-save').on('click', function() {
            var sources = $('#dlg-source').val() || [];
            if (!sources.length) { alert('{{ lang._("Select at least one source.") }}'); return; }
            var lanIf = $('#dlg-dest').val();
            if (!lanIf) { alert('{{ lang._("Select a destination LAN.") }}'); return; }
            var firstName = sources[0] === 'any' ? 'Any' : wgName(sources[0]);
            if (sources.length > 1) firstName += ' +' + (sources.length - 1);
            $.post(_editUuid ? '/api/vpnlink/link/setLink/' + _editUuid : '/api/vpnlink/link/addLink/',
                { link: { enabled:$('#dlg-enabled').is(':checked')?'1':'0', name:firstName, source:sources.join(','), lanInterface:lanIf,
                    cloneRules:$('#dlg-clone-rules').is(':checked')?'1':'0', autoNat:$('#dlg-auto-nat').is(':checked')?'1':'0', dnsSync:$('#dlg-dns-sync').is(':checked')?'1':'0' } },
                function(r) {
                    if (r && (r.result === 'saved' || r.uuid)) { $('#DialogLink').modal('hide'); loadLinksTable(); $('#LinkChangeMessage').show(); }
                    else { alert(r && r.validations ? Object.values(r.validations).join('\n') : 'Save failed.'); }
                }
            );
        });

        // ══════════════════════════════════════
        // Status Tab — Card Layout
        // ══════════════════════════════════════
        function loadStatus() {
            var box = $('#status-cards').html('<div class="text-center text-muted" style="padding:30px">Loading...</div>');
            $.get('/api/vpnlink/service/healthcheck', function(r) {
                box.empty();
                if (!r || !r.checks) { box.html('<div class="text-muted">Error loading status</div>'); return; }

                $.each(r.checks, function(i, c) {
                    var cls = c.ok ? 'card-ok' : 'card-err';
                    var icon = c.ok ? '<span class="fa fa-check-circle text-success"></span>' : '<span class="fa fa-times-circle text-danger"></span>';
                    var card = $('<div class="vpnlink-card ' + cls + '"></div>');

                    // Header
                    card.append('<div class="card-head"><span class="card-title">' + icon + ' ' + c.name + '</span><span class="card-badge text-muted">' + c.detail + '</span></div>');

                    // Body (peers, rules)
                    var body = $('<div class="card-body"></div>');
                    var hasBody = false;

                    if (c.peers && c.peers.length > 0) {
                        hasBody = true;
                        $.each(c.peers, function(j, p) {
                            var ago = p.handshake_ago;
                            var agoStr = ago < 60 ? ago + 's' : ago < 3600 ? Math.floor(ago/60) + 'm' : Math.floor(ago/3600) + 'h';
                            var rx = (p.rx_bytes / 1048576).toFixed(1);
                            var tx = (p.tx_bytes / 1048576).toFixed(1);
                            body.append('<div class="peer-row"><span class="fa fa-fw fa-mobile"></span> ' + p.allowed_ips +
                                ' <span class="text-muted">— ' + agoStr + ' ago</span>' +
                                ' <span class="metric"><span class="label-text">rx:</span> <span class="value">' + rx + ' MB</span></span>' +
                                ' <span class="metric"><span class="label-text">tx:</span> <span class="value">' + tx + ' MB</span></span></div>');
                        });
                    }

                    if (c.rules && c.rules.length > 0) {
                        hasBody = true;
                        var rid = 'rules-' + i;
                        body.append('<a class="rules-toggle" data-toggle="collapse" href="#' + rid + '"><span class="fa fa-caret-right"></span> Show ' + c.rules.length + ' rule(s)</a>' +
                            '<div class="collapse rules-list" id="' + rid + '"></div>');
                        var rlist = body.find('#' + rid);
                        $.each(c.rules, function(j, rule) {
                            rlist.append('<div>' + $('<span>').text(rule).html() + '</div>');
                        });
                    }

                    if (hasBody) card.append(body);
                    box.append(card);
                });
            });
        }

        // ══════════════════════════════════════
        // Log Tab
        // ══════════════════════════════════════
        var _logData = [];
        function loadLog() {
            var box = $('#log-body');
            box.html('<div class="text-center text-muted" style="padding:20px">Loading...</div>');
            $.get('/api/vpnlink/service/log', function(r) {
                _logData = (r && r.entries) ? r.entries : [];
                renderLog();
            });
        }

        function renderLog() {
            var box = $('#log-body').empty();
            var filter = $('#log-filter-input').val() || '';
            var filtered = filter ? _logData.filter(function(e) { return e.message.toLowerCase().indexOf(filter.toLowerCase()) >= 0; }) : _logData;

            if (filtered.length === 0) {
                box.html('<div class="text-muted" style="padding:20px;text-align:center">{{ lang._("No log entries found.") }}</div>');
                return;
            }
            var html = '<table class="table table-condensed log-table">';
            $.each(filtered, function(i, e) {
                var ts = e.timestamp ? e.timestamp.replace(/T/,' ').split('.')[0].split('-').slice(0,3).join('-') : '';
                if (ts.length > 19) ts = ts.substring(0, 19);
                // Extract just time portion
                var timePart = ts.indexOf(' ') > 0 ? ts.split(' ')[1] : ts;
                html += '<tr><td class="ts">' + timePart + '</td><td>' + $('<span>').text(e.message).html() + '</td></tr>';
            });
            html += '</table>';
            box.html(html);
        }

        $('#log-filter-input').on('input', function() { renderLog(); });

        // Tab loading
        $('a[href="#tab-status"]').on('shown.bs.tab', function() { loadStatus(); });
        $('a[href="#tab-log"]').on('shown.bs.tab', function() { loadLog(); });

        // ══════════════════════════════════════
        // Service Control
        // ══════════════════════════════════════
        $("#reconfigureAct").SimpleActionButton({
            onPreAction: function() {
                var dfObj = new $.Deferred();
                saveFormToEndpoint("/api/vpnlink/settings/set", 'frm_GeneralSettings',
                    function() { dfObj.resolve(); }, true, function() { dfObj.reject(); });
                return dfObj;
            },
            onAction: function() { updateServiceControlUI('vpnlink'); loadLinksTable(); $('#LinkChangeMessage').hide(); }
        });

        updateServiceControlUI('vpnlink');
    });
</script>

{# ══════ Header ══════ #}
<div class="content-box" style="padding-bottom:0;">
    <div style="padding: 15px 15px 5px;">
        <h2 style="margin:0 0 5px;"><span class="fa fa-link"></span> {{ lang._('VPN Link') }}</h2>
        <p class="text-muted" style="margin:0;">
            {{ lang._('Map WireGuard sources to LAN destinations. VPN clients mirror the selected LAN.') }}
        </p>
    </div>
    {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_GeneralSettings'])}}
</div>

{# ══════ Tabs ══════ #}
<ul class="nav nav-tabs" style="margin-top:1em; padding-left:15px;">
    <li class="active"><a data-toggle="tab" href="#tab-links"><span class="fa fa-fw fa-link"></span> {{ lang._('Links') }}</a></li>
    <li><a data-toggle="tab" href="#tab-status"><span class="fa fa-fw fa-heartbeat"></span> {{ lang._('Status') }}</a></li>
    <li><a data-toggle="tab" href="#tab-log"><span class="fa fa-fw fa-file-text-o"></span> {{ lang._('Log') }}</a></li>
</ul>

<div class="tab-content content-box">
    {# ── Links Tab ── #}
    <div id="tab-links" class="tab-pane fade in active" style="padding: 1.5em;">
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

    {# ── Status Tab ── #}
    <div id="tab-status" class="tab-pane fade" style="padding: 1.5em;">
        <div class="svc-bar">
            <span class="svc-status" id="svc-status-text"><span class="fa fa-circle-o-notch fa-spin"></span> {{ lang._('Checking...') }}</span>
            <span class="svc-controls">
                <button class="btn btn-default btn-sm" onclick="loadStatus()"><span class="fa fa-refresh"></span> {{ lang._('Refresh') }}</button>
            </span>
        </div>
        <div id="status-cards">
            <div class="text-center text-muted" style="padding:30px">{{ lang._('Click Status tab to load...') }}</div>
        </div>
    </div>

    {# ── Log Tab ── #}
    <div id="tab-log" class="tab-pane fade" style="padding: 1.5em;">
        <div class="log-filter">
            <input type="text" id="log-filter-input" class="form-control input-sm" placeholder="{{ lang._('Filter log...') }}"/>
            <button class="btn btn-default btn-sm" onclick="loadLog()" style="margin-left:5px;"><span class="fa fa-refresh"></span></button>
        </div>
        <div id="log-body" style="max-height:400px; overflow-y:auto;">
            <div class="text-center text-muted" style="padding:20px">{{ lang._('Click Log tab to load...') }}</div>
        </div>
    </div>
</div>

{# ══════ Apply ══════ #}
<div class="col-md-12" style="margin-top:1em;">
    <div id="LinkChangeMessage" class="alert alert-info" style="display:none" role="alert">{{ lang._('Click Apply to activate changes.') }}</div>
    <button class="btn btn-primary" id="reconfigureAct"
            data-endpoint='/api/vpnlink/service/reconfigure'
            data-label="{{ lang._('Apply') }}"
            data-error-title="{{ lang._('Error reconfiguring VPN Link') }}"
            type="button"></button>
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
