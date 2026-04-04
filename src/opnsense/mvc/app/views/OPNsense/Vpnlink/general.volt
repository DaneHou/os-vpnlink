{#
  OPNsense VPN Link — Settings
  VPN > VPN Link
#}

<script>
    $( document ).ready(function() {
        // ── Load settings ──
        mapDataToFormUI({'frm_GeneralSettings': "/api/vpnlink/settings/get"}).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        // ── Peer & Gateway pickers in Device Link dialog ──
        $(document).on('opendialog.DialogDeviceLink', function(e) {
            loadPeerPicker();
            loadGatewayPicker();
        });

        function loadPeerPicker() {
            $('#peer-picker-container').remove();
            var nameInput = $('#devicelink\\.name');
            var ipInput = $('#devicelink\\.tunnelIp');
            var container = $('<div id="peer-picker-container" style="margin-top:5px"></div>');

            $.get('/api/vpnlink/devicelink/wgPeers', function(response) {
                if (!response || response.status !== 'ok') {
                    container.append('<small class="text-muted">Cannot read WireGuard config.</small>');
                    nameInput.closest('td').append(container);
                    return;
                }

                var peers = response.peers || [];
                var servers = response.servers || [];

                if (servers.length > 0) {
                    container.append('<small class="text-muted"><b>WG Server (all clients):</b> </small>');
                    $.each(servers, function(idx, srv) {
                        var btn = $('<button type="button" class="btn btn-xs btn-warning" style="margin:2px"></button>');
                        btn.html('<span class="fa fa-fw fa-server"></span> ' + srv.name + ' (' + srv.subnet + ')');
                        btn.on('click', function() {
                            nameInput.val('All_' + srv.name).trigger('change');
                            ipInput.val(srv.subnet).trigger('change');
                            container.find('.btn').removeClass('active').css('font-weight', '');
                            $(this).addClass('active').css('font-weight', 'bold');
                        });
                        if (ipInput.val() === srv.subnet) btn.addClass('active').css('font-weight', 'bold');
                        container.append(btn);
                    });
                    container.append('<br/>');
                }

                if (peers.length > 0) {
                    container.append('<small class="text-muted"><b>Individual Peer:</b> </small>');
                    $.each(peers, function(idx, peer) {
                        var label = peer.name + ' (' + peer.tunnelIp + ')';
                        if (peer.server) label += ' [' + peer.server + ']';
                        var btn = $('<button type="button" class="btn btn-xs btn-default" style="margin:2px"></button>');
                        btn.html('<span class="fa fa-fw fa-mobile"></span> ' + label);
                        btn.on('click', function() {
                            nameInput.val(peer.name).trigger('change');
                            ipInput.val(peer.tunnelIp).trigger('change');
                            container.find('.btn').removeClass('active').css('font-weight', '');
                            $(this).addClass('active').css('font-weight', 'bold');
                        });
                        if (ipInput.val() === peer.tunnelIp) btn.addClass('active').css('font-weight', 'bold');
                        container.append(btn);
                    });
                }

                if (peers.length === 0 && servers.length === 0) {
                    container.append('<small class="text-muted">No WireGuard peers found.</small>');
                }
                nameInput.closest('td').append(container);
            });
        }

        function loadGatewayPicker() {
            $('#gw-picker-container').remove();
            var gwInput = $('#devicelink\\.gateway');
            var container = $('<div id="gw-picker-container" style="margin-top:5px"></div>');
            container.append('<small class="text-muted">Gateways: </small>');

            var wanBtn = $('<button type="button" class="btn btn-xs btn-default" style="margin:2px">WAN (default)</button>');
            wanBtn.on('click', function() {
                gwInput.val('').trigger('change');
                container.find('.btn').removeClass('active btn-primary').addClass('btn-default');
                $(this).removeClass('btn-default').addClass('active btn-primary');
            });
            if (!gwInput.val()) wanBtn.removeClass('btn-default').addClass('active btn-primary');
            container.append(wanBtn);

            $.get('/api/vpnlink/devicelink/gateways', function(response) {
                if (response && response.gateways) {
                    $.each(response.gateways, function(idx, gw) {
                        var label = gw.name;
                        if (gw.descr) label += ' (' + gw.descr + ')';
                        var btn = $('<button type="button" class="btn btn-xs btn-default" style="margin:2px"></button>');
                        btn.text(label);
                        btn.on('click', function() {
                            gwInput.val(gw.name).trigger('change');
                            container.find('.btn').removeClass('active btn-primary').addClass('btn-default');
                            $(this).removeClass('btn-default').addClass('active btn-primary');
                        });
                        if (gwInput.val() === gw.name) btn.removeClass('btn-default').addClass('active btn-primary');
                        container.append(btn);
                    });
                }
                gwInput.closest('td').append(container);
            });
        }

        // ── Device Links grid ──
        $("#grid-devicelinks").UIBootgrid({
            search: '/api/vpnlink/devicelink/searchDeviceLink',
            get: '/api/vpnlink/devicelink/getDeviceLink/',
            set: '/api/vpnlink/devicelink/setDeviceLink/',
            add: '/api/vpnlink/devicelink/addDeviceLink/',
            del: '/api/vpnlink/devicelink/delDeviceLink/',
            options: {
                formatters: {
                    "commands": function(column, row) {
                        return '<button type="button" class="btn btn-xs btn-default command-edit bootgrid-tooltip" data-row-id="' + row.uuid + '"><span class="fa fa-fw fa-pencil"></span></button> ' +
                            '<button type="button" class="btn btn-xs btn-default command-delete bootgrid-tooltip" data-row-id="' + row.uuid + '"><span class="fa fa-fw fa-trash-o"></span></button>';
                    },
                    "status": function(column, row) {
                        return row.enabled == "1" ? '<span class="fa fa-fw fa-check-circle text-success"></span>' : '<span class="fa fa-fw fa-times-circle text-danger"></span>';
                    },
                    "gatewayBadge": function(column, row) {
                        return row.gateway ? '<span class="label label-primary">' + row.gateway + '</span>' : '<span class="label label-default">WAN</span>';
                    },
                    "aliasBadge": function(column, row) {
                        return row.targetAlias ? '<span class="label label-info">' + row.targetAlias + '</span>' : '<span class="text-muted">all</span>';
                    }
                }
            }
        });

        // ── Apply button ──
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
                $('#grid-devicelinks').bootgrid('reload');
            }
        });

        updateServiceControlUI('vpnlink');
    });
</script>

<!-- ── Main Settings ── -->
<div class="content-box" style="padding-bottom: 1.5em;">
    <div class="alert alert-info" role="alert" style="margin: 15px;">
        <b>{{ lang._('VPN Link') }}</b> —
        {{ lang._('WireGuard VPN clients will behave exactly like devices on the selected LAN.') }}
        <br/>
        <small>
            {{ lang._('Same DNS, same routing rules, same gateway policies. NAT and DNS are configured automatically.') }}<br/>
            {{ lang._('Make sure WireGuard peers use OPNsense as their DNS server.') }}
        </small>
    </div>
    {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_GeneralSettings'])}}
</div>

<!-- ── Advanced: Device Links ── -->
<div class="content-box" style="margin-top: 1em;">
    <div class="panel panel-default">
        <div class="panel-heading" style="cursor:pointer" data-toggle="collapse" data-target="#devicelinks-panel">
            <h3 class="panel-title">
                <span class="fa fa-fw fa-caret-right"></span>
                {{ lang._('Advanced: Device Links (optional)') }}
            </h3>
        </div>
        <div id="devicelinks-panel" class="panel-collapse collapse">
            <div class="panel-body">
                <small class="text-muted">
                    {{ lang._('Route specific VPN clients through different gateways. Not needed for basic LAN mirroring.') }}
                </small>
                <table id="grid-devicelinks" class="table table-condensed table-hover table-striped"
                       data-editDialog="DialogDeviceLink" data-editAlert="DeviceLinkChangeMessage">
                    <thead>
                        <tr>
                            <th data-column-id="uuid" data-type="string" data-identifier="true" data-visible="false">ID</th>
                            <th data-column-id="enabled" data-width="4em" data-type="string" data-formatter="status">{{ lang._('On') }}</th>
                            <th data-column-id="name" data-type="string" data-width="10em">{{ lang._('Device') }}</th>
                            <th data-column-id="tunnelIp" data-type="string" data-width="11em">{{ lang._('Tunnel IP') }}</th>
                            <th data-column-id="gateway" data-type="string" data-width="10em" data-formatter="gatewayBadge">{{ lang._('Gateway') }}</th>
                            <th data-column-id="targetAlias" data-type="string" data-width="8em" data-formatter="aliasBadge">{{ lang._('Alias') }}</th>
                            <th data-column-id="description" data-type="string">{{ lang._('Description') }}</th>
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
        </div>
    </div>
</div>

<!-- ── Apply ── -->
<div class="col-md-12">
    <div id="DeviceLinkChangeMessage" class="alert alert-info" style="display: none" role="alert">
        {{ lang._('Click Apply to activate changes.') }}
    </div>
    <hr/>
    <button class="btn btn-primary" id="reconfigureAct"
            data-endpoint='/api/vpnlink/service/reconfigure'
            data-label="{{ lang._('Apply') }}"
            data-error-title="{{ lang._('Error reconfiguring VPN Link') }}"
            type="button"></button>
</div>

{{ partial("layout_partials/base_dialog",['fields':devicelinkForm,'id':'DialogDeviceLink','label':lang._('Edit Device Link')]) }}
