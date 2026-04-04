{#
  OPNsense VPN Link
  VPN > VPN Link
#}

<script>
    var _wgData = null;
    var _lanData = null;

    $( document ).ready(function() {
        // Load enable toggle
        mapDataToFormUI({'frm_GeneralSettings': "/api/vpnlink/settings/get"}).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        // Pre-fetch WG and LAN data
        function refreshPickerData() {
            $.get('/api/vpnlink/link/wgSources', function(r) { if (r && r.status === 'ok') _wgData = r; });
            $.get('/api/vpnlink/link/lanInterfaces', function(r) { if (r && r.status === 'ok') _lanData = r; });
        }
        refreshPickerData();

        // Populate source dropdown
        function populateSourceSelect(selectEl, currentVal) {
            selectEl.empty();
            selectEl.append('<option value="any">Any (all WireGuard clients)</option>');

            if (_wgData) {
                if (_wgData.servers && _wgData.servers.length > 0) {
                    var grp = $('<optgroup label="── WG Server (all clients) ──"></optgroup>');
                    $.each(_wgData.servers, function(i, srv) {
                        grp.append($('<option></option>').val(srv.subnet).text(srv.name + '  (' + srv.subnet + ')'));
                    });
                    selectEl.append(grp);
                }
                if (_wgData.peers && _wgData.peers.length > 0) {
                    var groups = {};
                    $.each(_wgData.peers, function(i, p) {
                        var g = p.server || 'Other';
                        if (!groups[g]) groups[g] = [];
                        groups[g].push(p);
                    });
                    $.each(groups, function(gName, peers) {
                        var grp = $('<optgroup label="── ' + gName + ' (devices) ──"></optgroup>');
                        $.each(peers, function(i, p) {
                            grp.append($('<option></option>').val(p.ip).text(p.name + '  (' + p.ip + ')'));
                        });
                        selectEl.append(grp);
                    });
                }
            }
            if (currentVal) selectEl.val(currentVal);
            if (!selectEl.val()) selectEl.val('any');
        }

        // Populate LAN dropdown
        function populateLanSelect(selectEl, currentVal) {
            selectEl.empty();
            selectEl.append('<option value="">— Select LAN —</option>');
            if (_lanData && _lanData.interfaces) {
                $.each(_lanData.interfaces, function(i, iface) {
                    var label = iface.descr + ' (' + iface.name + ')';
                    if (iface.cidr) label += '  —  ' + iface.cidr;
                    selectEl.append($('<option></option>').val(iface.name).text(label));
                });
            }
            if (currentVal) selectEl.val(currentVal);
        }

        // Open dialog for add/edit
        var _editUuid = null;

        function openLinkDialog(uuid) {
            _editUuid = uuid || null;

            populateSourceSelect($('#dlg-source'), '');
            populateLanSelect($('#dlg-lan'), '');
            $('#dlg-enabled').prop('checked', true);

            if (_editUuid) {
                // Load existing link
                $.get('/api/vpnlink/link/getLink/' + _editUuid, function(r) {
                    if (r && r.link) {
                        $('#dlg-enabled').prop('checked', r.link.enabled === '1');
                        populateSourceSelect($('#dlg-source'), r.link.source);
                        populateLanSelect($('#dlg-lan'), r.link.lanInterface);
                    }
                    $('#DialogLink').modal('show');
                });
            } else {
                $('#DialogLink').modal('show');
            }
        }

        // Save link
        $('#dlg-save').on('click', function() {
            var source = $('#dlg-source').val();
            var lanIf = $('#dlg-lan').val();
            if (!lanIf) { alert('Please select a destination LAN.'); return; }

            // Derive name from selected option text
            var name = $('#dlg-source option:selected').text().split('(')[0].trim() || source;

            var data = {
                link: {
                    enabled: $('#dlg-enabled').is(':checked') ? '1' : '0',
                    name: name,
                    source: source,
                    lanInterface: lanIf
                }
            };

            var url = _editUuid
                ? '/api/vpnlink/link/setLink/' + _editUuid
                : '/api/vpnlink/link/addLink/';

            $.post(url, data, function(r) {
                if (r && (r.result === 'saved' || r.uuid)) {
                    $('#DialogLink').modal('hide');
                    $('#grid-links').bootgrid('reload');
                    $('#LinkChangeMessage').show();
                } else {
                    var msg = 'Save failed.';
                    if (r && r.validations) {
                        msg = Object.values(r.validations).join('\n');
                    }
                    alert(msg);
                }
            });
        });

        // Links grid
        $("#grid-links").UIBootgrid({
            search: '/api/vpnlink/link/searchLink',
            get: '/api/vpnlink/link/getLink/',
            set: '/api/vpnlink/link/setLink/',
            add: '/api/vpnlink/link/addLink/',
            del: '/api/vpnlink/link/delLink/',
            options: {
                useRequestHandlerOnGet: false,
                formatters: {
                    "commands": function(col, row) {
                        return '<button type="button" class="btn btn-xs btn-default command-edit" data-row-id="' + row.uuid + '"><span class="fa fa-fw fa-pencil"></span></button> ' +
                            '<button type="button" class="btn btn-xs btn-default command-delete" data-row-id="' + row.uuid + '"><span class="fa fa-fw fa-trash-o"></span></button>';
                    },
                    "status": function(col, row) {
                        return row.enabled == "1" ? '<span class="fa fa-fw fa-check-circle text-success"></span>' : '<span class="fa fa-fw fa-times-circle text-danger"></span>';
                    },
                    "sourceFmt": function(col, row) {
                        if (row.source === 'any') return '<span class="fa fa-fw fa-globe"></span> <b>Any</b> <small class="text-muted">(all WireGuard)</small>';
                        var icon = (row.source && row.source.indexOf('/') > 0) ? 'fa-server' : 'fa-mobile';
                        return '<span class="fa fa-fw ' + icon + '"></span> ' + (row.name || '') + ' <small class="text-muted">(' + (row.source || '') + ')</small>';
                    },
                    "lanFmt": function(col, row) {
                        return '<span class="fa fa-fw fa-arrow-right"></span> <b>' + (row.lanInterface || '') + '</b>';
                    }
                }
            }
        });

        // Intercept grid add/edit to use our custom dialog
        $(document).on('click', '#grid-links .command-edit', function() {
            openLinkDialog($(this).data('row-id'));
            return false;
        });
        $(document).on('click', '#grid-links [data-action="add"]', function() {
            openLinkDialog(null);
            return false;
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
                $('#grid-links').bootgrid('reload');
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

<div class="content-box" style="margin-top:1em;">
    <table id="grid-links" class="table table-condensed table-hover table-striped"
           data-editAlert="LinkChangeMessage">
        <thead>
            <tr>
                <th data-column-id="uuid" data-type="string" data-identifier="true" data-visible="false">ID</th>
                <th data-column-id="enabled" data-width="4em" data-type="string" data-formatter="status">{{ lang._('On') }}</th>
                <th data-column-id="source" data-type="string" data-formatter="sourceFmt">{{ lang._('Source (WireGuard)') }}</th>
                <th data-column-id="lanInterface" data-type="string" data-width="16em" data-formatter="lanFmt">{{ lang._('Destination (LAN)') }}</th>
                <th data-column-id="commands" data-width="7em" data-formatter="commands" data-sortable="false">{{ lang._('') }}</th>
            </tr>
        </thead>
        <tbody></tbody>
        <tfoot>
            <tr>
                <td></td>
                <td>
                    <button data-action="add" type="button" class="btn btn-xs btn-primary"><span class="fa fa-fw fa-plus"></span></button>
                    <button data-action="deleteSelected" type="button" class="btn btn-xs btn-default"><span class="fa fa-fw fa-trash-o"></span></button>
                </td>
            </tr>
        </tfoot>
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

{# Custom dialog with native dropdowns — no base_dialog #}
<div class="modal fade" id="DialogLink" tabindex="-1" role="dialog">
    <div class="modal-dialog">
        <div class="modal-content">
            <div class="modal-header">
                <button type="button" class="close" data-dismiss="modal"><span>&times;</span></button>
                <h4 class="modal-title">{{ lang._('Edit Link') }}</h4>
            </div>
            <div class="modal-body">
                <div class="form-group">
                    <label>{{ lang._('Enabled') }}</label>
                    <div>
                        <input type="checkbox" id="dlg-enabled" checked/>
                    </div>
                </div>
                <div class="form-group">
                    <label>{{ lang._('Source (WireGuard)') }}</label>
                    <select id="dlg-source" class="form-control">
                        <option value="any">Loading...</option>
                    </select>
                    <small class="text-muted">{{ lang._('Which WireGuard server or device to link.') }}</small>
                </div>
                <div class="form-group">
                    <label>{{ lang._('Destination (LAN)') }}</label>
                    <select id="dlg-lan" class="form-control">
                        <option value="">Loading...</option>
                    </select>
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
