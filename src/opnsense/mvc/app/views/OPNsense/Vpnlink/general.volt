{#
  OPNsense VPN Link
  VPN > VPN Link
#}

<style>
    .vpnlink-chk-list { max-height: 250px; overflow-y: auto; border: 1px solid #ddd; border-radius: 3px; padding: 6px 10px; background: #fff; }
    .vpnlink-chk-list label { display: block; margin: 0; padding: 4px 0; font-weight: normal; cursor: pointer; }
    .vpnlink-chk-list label:hover { background: #f5f5f5; }
    .vpnlink-chk-list .group-header { font-weight: bold; color: #555; padding: 6px 0 2px; border-bottom: 1px solid #eee; margin-bottom: 2px; font-size: 11px; text-transform: uppercase; }
    .vpnlink-radio-list label { display: block; margin: 0; padding: 5px 0; font-weight: normal; cursor: pointer; }
    .vpnlink-radio-list label:hover { background: #f5f5f5; }
    #DialogLink .dlg-form-table { width: 100%; }
    #DialogLink .dlg-form-table td.dlg-label { width: 130px; vertical-align: top; padding: 10px 15px 10px 0; text-align: right; font-weight: bold; color: #555; }
    #DialogLink .dlg-form-table td.dlg-field { padding: 8px 0; }
    #DialogLink .dlg-form-table td.dlg-field small { display: block; margin-top: 4px; color: #999; }
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

        // ── Table ──
        function loadLinksTable() {
            $.post('/api/vpnlink/link/searchLink', {current:1, rowCount:-1}, function(r) {
                var tbody = $('#links-tbody').empty();
                var rows = (r && r.rows) ? r.rows : [];
                if (rows.length === 0) {
                    tbody.append('<tr><td colspan="4" class="text-center text-muted" style="padding:20px">{{ lang._("No links configured yet. Click Add Link to create one.") }}</td></tr>');
                    return;
                }
                $.each(rows, function(i, row) {
                    var on = row.enabled == '1' ? '<span class="fa fa-check-circle text-success"></span>' : '<span class="fa fa-times-circle text-danger"></span>';
                    var src = formatSource(row.source, row.name);
                    var dst = resolveLanLabel(row.lanInterface);
                    tbody.append(
                        '<tr>' +
                        '<td class="text-center" style="width:3em">' + on + '</td>' +
                        '<td>' + src + '</td>' +
                        '<td style="width:18em"><span class="fa fa-fw fa-arrow-right text-muted"></span> <b>' + dst + '</b></td>' +
                        '<td style="width:6em">' +
                            '<button class="btn btn-xs btn-default btn-edit" data-uuid="' + row.uuid + '" title="Edit"><span class="fa fa-pencil"></span></button> ' +
                            '<button class="btn btn-xs btn-danger btn-del" data-uuid="' + row.uuid + '" title="Delete"><span class="fa fa-trash-o"></span></button>' +
                        '</td></tr>'
                    );
                });
            });
        }

        function formatSource(source, name) {
            if (!source) return '';
            // source can be comma-separated (multi-select)
            var parts = source.split(',');
            var labels = [];
            $.each(parts, function(i, s) {
                s = $.trim(s);
                if (s === 'any') { labels.push('<span class="fa fa-fw fa-globe"></span> <b>Any</b>'); return; }
                var peerName = resolveWgName(s);
                var icon = s.indexOf('/') > 0 ? 'fa-server' : 'fa-mobile';
                labels.push('<span class="fa fa-fw ' + icon + '"></span> ' + peerName + ' <small class="text-muted">(' + s + ')</small>');
            });
            return labels.join('<br/>');
        }

        function resolveWgName(val) {
            if (!_wgData) return val;
            for (var i = 0; i < (_wgData.servers || []).length; i++) {
                if (_wgData.servers[i].subnet === val) return _wgData.servers[i].name;
            }
            for (var i = 0; i < (_wgData.peers || []).length; i++) {
                if (_wgData.peers[i].ip === val) return _wgData.peers[i].name;
            }
            return val;
        }

        function resolveLanLabel(ifname) {
            if (_lanData && _lanData.interfaces) {
                for (var i = 0; i < _lanData.interfaces.length; i++) {
                    if (_lanData.interfaces[i].name === ifname) return _lanData.interfaces[i].descr + ' (' + ifname + ')';
                }
            }
            return ifname || '';
        }

        // ── Dialog: build source checkboxes ──
        function buildSourceCheckboxes(selectedValues) {
            var sel = (selectedValues || '').split(',').map(function(s){ return $.trim(s); });
            var box = $('#dlg-source-list').empty();

            // "Any" checkbox
            var anyChk = $('<label><input type="checkbox" class="src-chk" value="any"/> <span class="fa fa-fw fa-globe"></span> <b>Any</b> (all WireGuard clients)</label>');
            box.append(anyChk);

            if (_wgData) {
                // Servers
                if (_wgData.servers && _wgData.servers.length > 0) {
                    box.append('<div class="group-header"><span class="fa fa-fw fa-server"></span> WG Servers (all clients)</div>');
                    $.each(_wgData.servers, function(i, srv) {
                        box.append('<label><input type="checkbox" class="src-chk" value="' + srv.subnet + '"/> ' + srv.name + ' <small class="text-muted">(' + srv.subnet + ')</small></label>');
                    });
                }
                // Peers grouped by server
                var groups = {};
                $.each(_wgData.peers || [], function(i, p) {
                    var g = p.server || 'Other';
                    if (!groups[g]) groups[g] = [];
                    groups[g].push(p);
                });
                $.each(groups, function(gName, peers) {
                    box.append('<div class="group-header"><span class="fa fa-fw fa-mobile"></span> ' + gName + ' Devices</div>');
                    $.each(peers, function(i, p) {
                        box.append('<label><input type="checkbox" class="src-chk" value="' + p.ip + '"/> ' + p.name + ' <small class="text-muted">(' + p.ip + ')</small></label>');
                    });
                });
            }

            // Set checked state
            box.find('.src-chk').each(function() {
                if (sel.indexOf($(this).val()) >= 0) $(this).prop('checked', true);
            });

            // "Any" logic: if any is checked, disable others
            box.on('change', '.src-chk[value="any"]', function() {
                if ($(this).is(':checked')) {
                    box.find('.src-chk').not('[value="any"]').prop('checked', false).prop('disabled', true);
                } else {
                    box.find('.src-chk').prop('disabled', false);
                }
            });
            if (sel.indexOf('any') >= 0) {
                box.find('.src-chk[value="any"]').trigger('change');
            }
        }

        // ── Dialog: build destination radios ──
        function buildDestRadios(selectedVal) {
            var box = $('#dlg-dest-list').empty();
            if (_lanData && _lanData.interfaces) {
                $.each(_lanData.interfaces, function(i, iface) {
                    var label = iface.descr + ' (' + iface.name + ')';
                    if (iface.cidr) label += ' &mdash; <small class="text-muted">' + iface.cidr + '</small>';
                    var checked = (iface.name === selectedVal) ? ' checked' : '';
                    box.append('<label><input type="radio" name="dlg-dest" value="' + iface.name + '"' + checked + '/> ' + label + '</label>');
                });
            }
        }

        // ── Dialog open ──
        var _editUuid = null;

        $('#btn-add-link').on('click', function() {
            _editUuid = null;
            $('#dlg-title').text('{{ lang._("Add Link") }}');
            $('#dlg-enabled').prop('checked', true);
            buildSourceCheckboxes('');
            buildDestRadios('');
            $('#DialogLink').modal('show');
        });

        $(document).on('click', '.btn-edit', function() {
            _editUuid = $(this).data('uuid');
            $('#dlg-title').text('{{ lang._("Edit Link") }}');
            $.get('/api/vpnlink/link/getLink/' + _editUuid, function(r) {
                if (r && r.link) {
                    $('#dlg-enabled').prop('checked', r.link.enabled === '1');
                    buildSourceCheckboxes(r.link.source || '');
                    buildDestRadios(r.link.lanInterface || '');
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
            // Collect checked sources
            var sources = [];
            $('#dlg-source-list .src-chk:checked').each(function() { sources.push($(this).val()); });
            if (sources.length === 0) { alert('{{ lang._("Please select at least one source.") }}'); return; }
            var sourceStr = sources.join(',');

            var lanIf = $('input[name="dlg-dest"]:checked').val();
            if (!lanIf) { alert('{{ lang._("Please select a destination LAN.") }}'); return; }

            // Build name from first source
            var firstName = sources[0];
            if (firstName === 'any') { firstName = 'Any'; }
            else { firstName = resolveWgName(firstName); }
            if (sources.length > 1) firstName += ' +' + (sources.length - 1);

            var data = { link: {
                enabled: $('#dlg-enabled').is(':checked') ? '1' : '0',
                name: firstName,
                source: sourceStr,
                lanInterface: lanIf
            }};

            var url = _editUuid ? '/api/vpnlink/link/setLink/' + _editUuid : '/api/vpnlink/link/addLink/';
            $.post(url, data, function(r) {
                if (r && (r.result === 'saved' || r.uuid)) {
                    $('#DialogLink').modal('hide');
                    loadLinksTable();
                    $('#LinkChangeMessage').show();
                } else {
                    alert(r && r.validations ? Object.values(r.validations).join('\n') : 'Save failed.');
                }
            });
        });

        // ── Apply ──
        $("#reconfigureAct").SimpleActionButton({
            onPreAction: function() {
                const dfObj = new $.Deferred();
                saveFormToEndpoint("/api/vpnlink/settings/set", 'frm_GeneralSettings',
                    function() { dfObj.resolve(); }, true, function() { dfObj.reject(); }
                );
                return dfObj;
            },
            onAction: function(data, status) {
                updateServiceControlUI('vpnlink');
                loadLinksTable();
                $('#LinkChangeMessage').hide();
            }
        });

        updateServiceControlUI('vpnlink');
    });
</script>

<!-- ── Header + Enable toggle ── -->
<div class="content-box" style="padding-bottom:0;">
    <div class="alert alert-info" role="alert" style="margin:15px;">
        <b>{{ lang._('VPN Link') }}</b> &mdash;
        {{ lang._('Map WireGuard sources to LAN destinations. VPN clients behave exactly like devices on that LAN.') }}
        <br/><small>{{ lang._('NAT, DNS, and routing are configured automatically. Ensure WireGuard peers use OPNsense as DNS.') }}</small>
    </div>
    {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_GeneralSettings'])}}
</div>

<!-- ── Links Table ── -->
<div class="content-box" style="margin-top:1em; padding:15px;">
    <div style="margin-bottom:10px;">
        <button id="btn-add-link" class="btn btn-primary btn-sm"><span class="fa fa-plus"></span> {{ lang._('Add Link') }}</button>
    </div>
    <table class="table table-condensed table-hover table-striped">
        <thead>
            <tr>
                <th style="width:3em" class="text-center">{{ lang._('On') }}</th>
                <th>{{ lang._('Source (WireGuard)') }}</th>
                <th style="width:18em">{{ lang._('Destination (LAN)') }}</th>
                <th style="width:6em"></th>
            </tr>
        </thead>
        <tbody id="links-tbody">
            <tr><td colspan="4" class="text-center text-muted" style="padding:20px">{{ lang._('Loading...') }}</td></tr>
        </tbody>
    </table>
</div>

<!-- ── Apply ── -->
<div class="col-md-12">
    <div id="LinkChangeMessage" class="alert alert-info" style="display:none" role="alert">
        {{ lang._('Click Apply to activate changes.') }}
    </div>
    <hr/>
    <button class="btn btn-primary" id="reconfigureAct"
            data-endpoint='/api/vpnlink/service/reconfigure'
            data-label="{{ lang._('Apply') }}"
            data-error-title="{{ lang._('Error reconfiguring VPN Link') }}"
            type="button"></button>
</div>

<!-- ── Edit Dialog (OPNsense native style) ── -->
<div class="modal fade" id="DialogLink" tabindex="-1" role="dialog">
    <div class="modal-dialog modal-lg">
        <div class="modal-content">
            <div class="modal-header">
                <button type="button" class="close" data-dismiss="modal"><span>&times;</span></button>
                <h4 class="modal-title" id="dlg-title">{{ lang._('Edit Link') }}</h4>
            </div>
            <div class="modal-body">
                <table class="dlg-form-table">
                    <tr>
                        <td class="dlg-label">{{ lang._('Enabled') }}</td>
                        <td class="dlg-field">
                            <input type="checkbox" id="dlg-enabled" checked/>
                        </td>
                    </tr>
                    <tr>
                        <td class="dlg-label">{{ lang._('Source') }}</td>
                        <td class="dlg-field">
                            <div id="dlg-source-list" class="vpnlink-chk-list"></div>
                            <small>{{ lang._('Select WireGuard server(s) or individual device(s). Check "Any" for all.') }}</small>
                        </td>
                    </tr>
                    <tr>
                        <td class="dlg-label">{{ lang._('Destination') }}</td>
                        <td class="dlg-field">
                            <div id="dlg-dest-list" class="vpnlink-radio-list"></div>
                            <small>{{ lang._('VPN clients will mirror this LAN — same DNS, routing, gateway policies.') }}</small>
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
