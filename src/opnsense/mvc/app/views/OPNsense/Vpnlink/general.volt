{#
  OPNsense VPN Link
  VPN > VPN Link

  Each row: WireGuard source → LAN destination (dropdown style like firewall rules)
#}

<script>
    // Cache API data so we don't re-fetch on every dialog open
    var _wgData = null;
    var _lanData = null;

    $( document ).ready(function() {
        // ── Load enable toggle ──
        mapDataToFormUI({'frm_GeneralSettings': "/api/vpnlink/settings/get"}).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        // Pre-fetch WG and LAN data
        $.get('/api/vpnlink/link/wgSources', function(r) { if (r && r.status === 'ok') _wgData = r; });
        $.get('/api/vpnlink/link/lanInterfaces', function(r) { if (r && r.status === 'ok') _lanData = r; });

        // ── Replace text inputs with dropdowns when dialog opens ──
        $(document).on('opendialog.DialogLink', function(e) {
            setTimeout(function() { buildDropdowns(); }, 50);
        });

        function buildDropdowns() {
            // === SOURCE dropdown (WireGuard server / device) ===
            var srcInput = $('#link\\.source');
            var nameInput = $('#link\\.name');
            var currentSrc = srcInput.val() || '';
            var currentName = nameInput.val() || '';

            // Hide original inputs, show dropdown instead
            srcInput.hide();
            nameInput.closest('tr').hide(); // hide name row entirely

            $('#vpnlink-src-select').remove();
            var srcSelect = $('<select id="vpnlink-src-select" class="form-control"></select>');

            // "Any" option
            srcSelect.append('<option value="any">Any (all WireGuard clients)</option>');

            if (_wgData) {
                // WG Servers as optgroup
                if (_wgData.servers && _wgData.servers.length > 0) {
                    var grp = $('<optgroup label="WireGuard Servers (all clients)"></optgroup>');
                    $.each(_wgData.servers, function(i, srv) {
                        grp.append($('<option></option>')
                            .val(srv.subnet)
                            .text(srv.name + ' — ' + srv.subnet)
                            .data('linkname', srv.name));
                    });
                    srcSelect.append(grp);
                }

                // Individual peers grouped by server
                var serverGroups = {};
                $.each(_wgData.peers || [], function(i, p) {
                    var grpName = p.server || 'Other';
                    if (!serverGroups[grpName]) serverGroups[grpName] = [];
                    serverGroups[grpName].push(p);
                });

                $.each(serverGroups, function(grpName, peers) {
                    var grp = $('<optgroup label="' + grpName + ' — Individual Devices"></optgroup>');
                    $.each(peers, function(i, p) {
                        grp.append($('<option></option>')
                            .val(p.ip)
                            .text(p.name + ' — ' + p.ip)
                            .data('linkname', p.name));
                    });
                    srcSelect.append(grp);
                });
            }

            // Set current value
            if (currentSrc) {
                srcSelect.val(currentSrc);
            }
            if (!srcSelect.val()) {
                srcSelect.val('any');
            }

            srcInput.after(srcSelect);

            // Sync dropdown → hidden inputs
            srcSelect.on('change', function() {
                var val = $(this).val();
                var opt = $(this).find('option:selected');
                srcInput.val(val === 'any' ? 'any' : val).trigger('change');
                nameInput.val(opt.data('linkname') || val).trigger('change');
            });
            // Trigger initial sync if adding new
            if (!currentSrc) srcSelect.trigger('change');

            // === DESTINATION dropdown (LAN interface) ===
            var lanInput = $('#link\\.lanInterface');
            var currentLan = lanInput.val() || '';
            lanInput.hide();

            $('#vpnlink-lan-select').remove();
            var lanSelect = $('<select id="vpnlink-lan-select" class="form-control"></select>');
            lanSelect.append('<option value="">— Select LAN —</option>');

            if (_lanData && _lanData.interfaces) {
                $.each(_lanData.interfaces, function(i, iface) {
                    var label = iface.descr + ' (' + iface.name + ')';
                    if (iface.cidr) label += ' — ' + iface.cidr;
                    lanSelect.append($('<option></option>').val(iface.name).text(label));
                });
            }

            if (currentLan) lanSelect.val(currentLan);
            lanInput.after(lanSelect);

            lanSelect.on('change', function() {
                lanInput.val($(this).val()).trigger('change');
            });
        }

        // ── Links grid ──
        $("#grid-links").UIBootgrid({
            search: '/api/vpnlink/link/searchLink',
            get: '/api/vpnlink/link/getLink/',
            set: '/api/vpnlink/link/setLink/',
            add: '/api/vpnlink/link/addLink/',
            del: '/api/vpnlink/link/delLink/',
            options: {
                formatters: {
                    "commands": function(col, row) {
                        return '<button type="button" class="btn btn-xs btn-default command-edit" data-row-id="' + row.uuid + '"><span class="fa fa-fw fa-pencil"></span></button> ' +
                            '<button type="button" class="btn btn-xs btn-default command-delete" data-row-id="' + row.uuid + '"><span class="fa fa-fw fa-trash-o"></span></button>';
                    },
                    "status": function(col, row) {
                        return row.enabled == "1" ? '<span class="fa fa-fw fa-check-circle text-success"></span>' : '<span class="fa fa-fw fa-times-circle text-danger"></span>';
                    },
                    "sourceFmt": function(col, row) {
                        if (row.source === 'any') {
                            return '<span class="fa fa-fw fa-globe"></span> <b>Any</b> <small class="text-muted">(all WireGuard)</small>';
                        }
                        var icon = (row.source && row.source.indexOf('/') > 0) ? 'fa-server' : 'fa-mobile';
                        return '<span class="fa fa-fw ' + icon + '"></span> ' + (row.name || '') + ' <small class="text-muted">(' + (row.source || '') + ')</small>';
                    },
                    "lanFmt": function(col, row) {
                        return '<span class="fa fa-fw fa-arrow-right"></span> <b>' + (row.lanInterface || '') + '</b>';
                    }
                }
            }
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
           data-editDialog="DialogLink" data-editAlert="LinkChangeMessage">
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

{{ partial("layout_partials/base_dialog",['fields':linkForm,'id':'DialogLink','label':lang._('Edit Link')]) }}
