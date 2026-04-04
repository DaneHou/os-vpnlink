{#
  OPNsense VPN Link
  VPN > VPN Link
#}

<script>
    var _wgData = null, _lanData = null;

    $(document).ready(function() {
        mapDataToFormUI({'frm_GeneralSettings': "/api/vpnlink/settings/get"}).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        // Fetch WG + LAN data, then load table
        $.when(
            $.get('/api/vpnlink/link/wgSources'),
            $.get('/api/vpnlink/link/lanInterfaces')
        ).done(function(wgR, lanR) {
            if (wgR[0] && wgR[0].status === 'ok') _wgData = wgR[0];
            if (lanR[0] && lanR[0].status === 'ok') _lanData = lanR[0];
            loadLinksTable();
        });

        function loadLinksTable() {
            $.post('/api/vpnlink/link/searchLink', {current: 1, rowCount: -1}, function(r) {
                var tbody = $('#links-tbody');
                tbody.empty();

                var rows = (r && r.rows) ? r.rows : [];
                if (rows.length === 0) {
                    tbody.append('<tr><td colspan="4" class="text-center text-muted">{{ lang._("No links configured. Click + to add one.") }}</td></tr>');
                    return;
                }

                $.each(rows, function(i, row) {
                    var statusIcon = row.enabled == '1'
                        ? '<span class="fa fa-check-circle text-success"></span>'
                        : '<span class="fa fa-times-circle text-danger"></span>';

                    var srcIcon, srcLabel;
                    if (row.source === 'any') {
                        srcIcon = 'fa-globe'; srcLabel = '<b>Any</b> <small class="text-muted">(all WireGuard)</small>';
                    } else if (row.source && row.source.indexOf('/') > 0) {
                        srcIcon = 'fa-server'; srcLabel = (row.name || '') + ' <small class="text-muted">(' + row.source + ')</small>';
                    } else {
                        srcIcon = 'fa-mobile'; srcLabel = (row.name || '') + ' <small class="text-muted">(' + row.source + ')</small>';
                    }

                    var lanLabel = resolveLanName(row.lanInterface);

                    var tr = $('<tr></tr>');
                    tr.append('<td class="text-center" style="width:3em">' + statusIcon + '</td>');
                    tr.append('<td><span class="fa fa-fw ' + srcIcon + '"></span> ' + srcLabel + '</td>');
                    tr.append('<td style="width:16em"><span class="fa fa-fw fa-arrow-right"></span> <b>' + lanLabel + '</b></td>');
                    tr.append(
                        '<td style="width:6em">' +
                        '<button class="btn btn-xs btn-default btn-edit" data-uuid="' + row.uuid + '"><span class="fa fa-pencil"></span></button> ' +
                        '<button class="btn btn-xs btn-danger btn-del" data-uuid="' + row.uuid + '"><span class="fa fa-trash-o"></span></button>' +
                        '</td>'
                    );
                    tbody.append(tr);
                });
            });
        }

        function resolveLanName(ifname) {
            if (_lanData && _lanData.interfaces) {
                for (var i = 0; i < _lanData.interfaces.length; i++) {
                    if (_lanData.interfaces[i].name === ifname) {
                        return _lanData.interfaces[i].descr + ' (' + ifname + ')';
                    }
                }
            }
            return ifname || '';
        }

        // Populate dropdowns
        function populateSourceSelect(el, val) {
            el.empty();
            el.append('<option value="any">Any (all WireGuard clients)</option>');
            if (_wgData) {
                if (_wgData.servers && _wgData.servers.length > 0) {
                    var g = $('<optgroup label="── WG Server (all clients) ──"></optgroup>');
                    $.each(_wgData.servers, function(i, s) {
                        g.append($('<option></option>').val(s.subnet).text(s.name + '  (' + s.subnet + ')'));
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
                    var g = $('<optgroup label="── ' + gn + ' (devices) ──"></optgroup>');
                    $.each(peers, function(i, p) {
                        g.append($('<option></option>').val(p.ip).text(p.name + '  (' + p.ip + ')'));
                    });
                    el.append(g);
                });
            }
            if (val) el.val(val);
            if (!el.val()) el.val('any');
        }

        function populateLanSelect(el, val) {
            el.empty();
            el.append('<option value="">— {{ lang._("Select LAN") }} —</option>');
            if (_lanData && _lanData.interfaces) {
                $.each(_lanData.interfaces, function(i, f) {
                    var label = f.descr + ' (' + f.name + ')';
                    if (f.cidr) label += '  —  ' + f.cidr;
                    el.append($('<option></option>').val(f.name).text(label));
                });
            }
            if (val) el.val(val);
        }

        // Add button
        var _editUuid = null;
        $('#btn-add-link').on('click', function() {
            _editUuid = null;
            $('#dlg-enabled').prop('checked', true);
            populateSourceSelect($('#dlg-source'), '');
            populateLanSelect($('#dlg-lan'), '');
            $('#DialogLink').modal('show');
        });

        // Edit button (delegated)
        $(document).on('click', '.btn-edit', function() {
            _editUuid = $(this).data('uuid');
            $.get('/api/vpnlink/link/getLink/' + _editUuid, function(r) {
                if (r && r.link) {
                    $('#dlg-enabled').prop('checked', r.link.enabled === '1');
                    populateSourceSelect($('#dlg-source'), r.link.source);
                    populateLanSelect($('#dlg-lan'), r.link.lanInterface);
                }
                $('#DialogLink').modal('show');
            });
        });

        // Delete button
        $(document).on('click', '.btn-del', function() {
            var uuid = $(this).data('uuid');
            if (confirm('{{ lang._("Delete this link?") }}')) {
                $.post('/api/vpnlink/link/delLink/' + uuid, function() {
                    loadLinksTable();
                    $('#LinkChangeMessage').show();
                });
            }
        });

        // Save
        $('#dlg-save').on('click', function() {
            var source = $('#dlg-source').val();
            var lanIf = $('#dlg-lan').val();
            if (!lanIf) { alert('{{ lang._("Please select a destination LAN.") }}'); return; }

            var name = $('#dlg-source option:selected').text().split('(')[0].trim() || source;
            var data = { link: { enabled: $('#dlg-enabled').is(':checked') ? '1' : '0', name: name, source: source, lanInterface: lanIf } };
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

        // Apply
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

<div class="content-box" style="padding-bottom:0;">
    <div class="alert alert-info" role="alert" style="margin:15px;">
        <b>{{ lang._('VPN Link') }}</b> —
        {{ lang._('Map WireGuard sources to LAN destinations. VPN clients behave exactly like devices on that LAN.') }}
        <br/><small>{{ lang._('NAT, DNS, and routing are configured automatically. Ensure WireGuard peers use OPNsense as DNS.') }}</small>
    </div>
    {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_GeneralSettings'])}}
</div>

<div class="content-box" style="margin-top:1em; padding:15px;">
    <div style="margin-bottom:10px;">
        <button id="btn-add-link" class="btn btn-primary btn-sm"><span class="fa fa-plus"></span> {{ lang._('Add Link') }}</button>
    </div>
    <table class="table table-condensed table-hover table-striped">
        <thead>
            <tr>
                <th style="width:3em" class="text-center">{{ lang._('On') }}</th>
                <th>{{ lang._('Source (WireGuard)') }}</th>
                <th style="width:16em">{{ lang._('Destination (LAN)') }}</th>
                <th style="width:6em"></th>
            </tr>
        </thead>
        <tbody id="links-tbody">
            <tr><td colspan="4" class="text-center text-muted">{{ lang._('Loading...') }}</td></tr>
        </tbody>
    </table>
</div>

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

{# Custom modal with native dropdowns #}
<div class="modal fade" id="DialogLink" tabindex="-1" role="dialog">
    <div class="modal-dialog">
        <div class="modal-content">
            <div class="modal-header">
                <button type="button" class="close" data-dismiss="modal"><span>&times;</span></button>
                <h4 class="modal-title">{{ lang._('Edit Link') }}</h4>
            </div>
            <div class="modal-body">
                <div class="form-group">
                    <label><input type="checkbox" id="dlg-enabled" checked/> {{ lang._('Enabled') }}</label>
                </div>
                <div class="form-group">
                    <label>{{ lang._('Source (WireGuard)') }}</label>
                    <select id="dlg-source" class="form-control"></select>
                    <small class="text-muted">{{ lang._('WireGuard server (all clients) or a specific device.') }}</small>
                </div>
                <div class="form-group">
                    <label>{{ lang._('Destination (LAN)') }}</label>
                    <select id="dlg-lan" class="form-control"></select>
                    <small class="text-muted">{{ lang._('VPN clients will mirror this LAN — same DNS, routing, gateway policies.') }}</small>
                </div>
            </div>
            <div class="modal-footer">
                <button type="button" class="btn btn-default" data-dismiss="modal">{{ lang._('Cancel') }}</button>
                <button type="button" class="btn btn-primary" id="dlg-save">{{ lang._('Save') }}</button>
            </div>
        </div>
    </div>
</div>
