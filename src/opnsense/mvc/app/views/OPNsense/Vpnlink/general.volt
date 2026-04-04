{#
  OPNsense VPN Link
  VPN > VPN Link

  Simple concept: each row maps a WireGuard source → a LAN to mirror.
#}

<script>
    $( document ).ready(function() {
        // ── Load enable toggle ──
        mapDataToFormUI({'frm_GeneralSettings': "/api/vpnlink/settings/get"}).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        // ── Source & LAN pickers in the link edit dialog ──
        $(document).on('opendialog.DialogLink', function(e) {
            loadSourcePicker();
            loadLanPicker();
        });

        function loadSourcePicker() {
            $('#src-picker').remove();
            var nameInput = $('#link\\.name');
            var srcInput = $('#link\\.source');
            var container = $('<div id="src-picker" style="margin-top:5px"></div>');

            $.get('/api/vpnlink/link/wgSources', function(r) {
                if (!r || r.status !== 'ok') {
                    container.append('<small class="text-muted">Cannot read WireGuard config.</small>');
                    nameInput.closest('td').append(container);
                    return;
                }

                // WG Servers (whole subnet)
                if (r.servers && r.servers.length > 0) {
                    container.append('<div style="margin-bottom:3px"><small class="text-muted"><b>WG Server (all clients):</b></small></div>');
                    $.each(r.servers, function(i, srv) {
                        var btn = $('<button type="button" class="btn btn-sm btn-warning" style="margin:2px"></button>');
                        btn.html('<span class="fa fa-fw fa-server"></span> ' + srv.name + ' <small>(' + srv.subnet + ')</small>');
                        btn.on('click', function() {
                            nameInput.val(srv.name).trigger('change');
                            srcInput.val(srv.subnet).trigger('change');
                            container.find('.btn').removeClass('active').css('font-weight','');
                            $(this).addClass('active').css('font-weight','bold');
                        });
                        if (srcInput.val() === srv.subnet) btn.addClass('active').css('font-weight','bold');
                        container.append(btn);
                    });
                }

                // Individual peers
                if (r.peers && r.peers.length > 0) {
                    container.append('<div style="margin-top:5px;margin-bottom:3px"><small class="text-muted"><b>Individual Peer:</b></small></div>');
                    $.each(r.peers, function(i, p) {
                        var label = p.name + ' (' + p.ip + ')';
                        if (p.server) label += ' [' + p.server + ']';
                        var btn = $('<button type="button" class="btn btn-xs btn-default" style="margin:2px"></button>');
                        btn.html('<span class="fa fa-fw fa-mobile"></span> ' + label);
                        btn.on('click', function() {
                            nameInput.val(p.name).trigger('change');
                            srcInput.val(p.ip).trigger('change');
                            container.find('.btn').removeClass('active').css('font-weight','');
                            $(this).addClass('active').css('font-weight','bold');
                        });
                        if (srcInput.val() === p.ip) btn.addClass('active').css('font-weight','bold');
                        container.append(btn);
                    });
                }

                nameInput.closest('td').append(container);
            });
        }

        function loadLanPicker() {
            $('#lan-picker').remove();
            var lanInput = $('#link\\.lanInterface');
            var container = $('<div id="lan-picker" style="margin-top:5px"></div>');

            $.get('/api/vpnlink/link/lanInterfaces', function(r) {
                if (!r || r.status !== 'ok' || !r.interfaces) return;

                $.each(r.interfaces, function(i, iface) {
                    var label = iface.descr + ' (' + iface.name + ')';
                    if (iface.cidr) label += ' — ' + iface.cidr;
                    var btn = $('<button type="button" class="btn btn-sm btn-default" style="margin:2px"></button>');
                    btn.html('<span class="fa fa-fw fa-sitemap"></span> ' + label);
                    btn.on('click', function() {
                        lanInput.val(iface.name).trigger('change');
                        container.find('.btn').removeClass('active btn-success').addClass('btn-default');
                        $(this).removeClass('btn-default').addClass('active btn-success');
                    });
                    if (lanInput.val() === iface.name) btn.removeClass('btn-default').addClass('active btn-success');
                    container.append(btn);
                });

                lanInput.closest('td').append(container);
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
                        var icon = (row.source && row.source.indexOf('/') > 0) ? 'fa-server' : 'fa-mobile';
                        return '<span class="fa fa-fw ' + icon + '"></span> ' + (row.name || '') + ' <small class="text-muted">(' + (row.source || '') + ')</small>';
                    },
                    "lanFmt": function(col, row) {
                        return '<span class="fa fa-fw fa-sitemap text-success"></span> <b>' + (row.lanInterface || '') + '</b>';
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
        {{ lang._('Map each WireGuard server or device to a LAN. VPN clients will behave exactly like devices on that LAN.') }}
        <br/><small>{{ lang._('NAT, DNS, and routing are configured automatically. Make sure WireGuard peers use OPNsense as DNS.') }}</small>
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
                <th data-column-id="source" data-type="string" data-formatter="sourceFmt">{{ lang._('WireGuard Source') }}</th>
                <th data-column-id="lanInterface" data-type="string" data-width="14em" data-formatter="lanFmt">{{ lang._('Mirror LAN') }}</th>
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
