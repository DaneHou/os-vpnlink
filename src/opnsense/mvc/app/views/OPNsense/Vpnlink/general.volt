{#
  OPNsense VPN Link — Settings & Device Links
  VPN > VPN Link
#}

<script>
    $( document ).ready(function() {
        // ── Load general settings ──
        mapDataToFormUI({'frm_GeneralSettings': "/api/vpnlink/settings/get"}).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
            toggleModeFields();
        });

        // ── Toggle fields based on mode and DNS settings ──
        function toggleModeFields() {
            var mode = $('#general\\.mode').val();
            if (mode === 'lan_equal') {
                $('[id="row_general.lanSubnets"]').hide();
                $('[id="row_general.natInterfaces"]').show();
            } else {
                $('[id="row_general.lanSubnets"]').show();
                $('[id="row_general.natInterfaces"]').hide();
            }

            var dnsSync = $('#general\\.dnsSync').is(':checked');
            if (dnsSync) {
                $('[id="row_general.dnsTopology"]').show();
            } else {
                $('[id="row_general.dnsTopology"]').hide();
            }
        }
        $(document).on('change', '#general\\.mode', toggleModeFields);
        $(document).on('change', '#general\\.dnsSync', toggleModeFields);

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

                // ── Server buttons (whole subnet) ──
                if (servers.length > 0) {
                    container.append('<small class="text-muted"><b>WG Server (all clients):</b> </small>');
                    $.each(servers, function(idx, srv) {
                        var label = srv.name + ' (' + srv.subnet + ')';
                        var btn = $('<button type="button" class="btn btn-xs btn-warning" style="margin:2px"></button>');
                        btn.html('<span class="fa fa-fw fa-server"></span> ' + label);
                        btn.on('click', function() {
                            nameInput.val('All_' + srv.name).trigger('change');
                            ipInput.val(srv.subnet).trigger('change');
                            container.find('.btn').removeClass('active').css('font-weight', '');
                            $(this).addClass('active').css('font-weight', 'bold');
                        });
                        if (ipInput.val() === srv.subnet) {
                            btn.addClass('active').css('font-weight', 'bold');
                        }
                        container.append(btn);
                    });
                    container.append('<br/>');
                }

                // ── Individual peer buttons ──
                if (peers.length > 0) {
                    container.append('<small class="text-muted"><b>Individual Peer:</b> </small>');
                    $.each(peers, function(idx, peer) {
                        var label = peer.name + ' (' + peer.tunnelIp + ')';
                        if (peer.server) {
                            label += ' [' + peer.server + ']';
                        }
                        var btn = $('<button type="button" class="btn btn-xs btn-default" style="margin:2px"></button>');
                        btn.html('<span class="fa fa-fw fa-mobile"></span> ' + label);
                        btn.on('click', function() {
                            nameInput.val(peer.name).trigger('change');
                            ipInput.val(peer.tunnelIp).trigger('change');
                            container.find('.btn').removeClass('active').css('font-weight', '');
                            $(this).addClass('active').css('font-weight', 'bold');
                        });
                        if (ipInput.val() === peer.tunnelIp) {
                            btn.addClass('active').css('font-weight', 'bold');
                        }
                        container.append(btn);
                    });
                }

                if (peers.length === 0 && servers.length === 0) {
                    container.append('<small class="text-muted">No WireGuard peers or servers found.</small>');
                }

                nameInput.closest('td').append(container);
            });
        }

        function loadGatewayPicker() {
            $('#gw-picker-container').remove();
            var gwInput = $('#devicelink\\.gateway');
            var container = $('<div id="gw-picker-container" style="margin-top:5px"></div>');
            container.append('<small class="text-muted">Gateways: </small>');

            // Add WAN default button
            var wanBtn = $('<button type="button" class="btn btn-xs btn-default" style="margin:2px">WAN (default)</button>');
            wanBtn.on('click', function() {
                gwInput.val('').trigger('change');
                container.find('.btn').removeClass('active btn-primary').addClass('btn-default');
                $(this).removeClass('btn-default').addClass('active btn-primary');
            });
            if (!gwInput.val()) {
                wanBtn.removeClass('btn-default').addClass('active btn-primary');
            }
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
                        if (gwInput.val() === gw.name) {
                            btn.removeClass('btn-default').addClass('active btn-primary');
                        }
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
                        return '<button type="button" class="btn btn-xs btn-default command-edit bootgrid-tooltip" ' +
                            'data-row-id="' + row.uuid + '"><span class="fa fa-fw fa-pencil"></span></button> ' +
                            '<button type="button" class="btn btn-xs btn-default command-delete bootgrid-tooltip" ' +
                            'data-row-id="' + row.uuid + '"><span class="fa fa-fw fa-trash-o"></span></button>';
                    },
                    "status": function(column, row) {
                        if (row.enabled == "1") {
                            return '<span class="fa fa-fw fa-check-circle text-success"></span>';
                        } else {
                            return '<span class="fa fa-fw fa-times-circle text-danger"></span>';
                        }
                    },
                    "gatewayBadge": function(column, row) {
                        if (row.gateway) {
                            return '<span class="label label-primary">' + row.gateway + '</span>';
                        }
                        return '<span class="label label-default">WAN (default)</span>';
                    },
                    "aliasBadge": function(column, row) {
                        if (row.targetAlias) {
                            return '<span class="label label-info">' + row.targetAlias + '</span>';
                        }
                        return '<span class="text-muted">all traffic</span>';
                    }
                }
            }
        });

        // ── Apply button ──
        $("#reconfigureAct").SimpleActionButton({
            onPreAction: function() {
                const dfObj = new $.Deferred();
                saveFormToEndpoint("/api/vpnlink/settings/set", 'frm_GeneralSettings',
                    function() { dfObj.resolve(); },
                    true,
                    function() { dfObj.reject(); }
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

<div class="alert alert-info" role="alert" style="margin-bottom: 1em;">
    <b>{{ lang._('VPN Link') }}</b> —
    {{ lang._('Automatically configures NAT, DNS, and routing for WireGuard VPN clients.') }}
    <br/>
    <small>
        {{ lang._('In LAN Equivalent mode, VPN clients inherit all existing firewall rules including domain-based gateway routing.') }}
        {{ lang._('Ensure WireGuard peers use OPNsense as DNS server.') }}
    </small>
</div>

<!-- ── Tab Navigation ── -->
<ul class="nav nav-tabs" data-tabs="tabs" id="maintabs">
    <li class="active"><a data-toggle="tab" href="#tab-general">{{ lang._('Global Settings') }}</a></li>
    <li><a data-toggle="tab" href="#tab-devicelinks">{{ lang._('Device Links') }}</a></li>
</ul>

<div class="tab-content content-box">
    <!-- ── Global Settings Tab ── -->
    <div id="tab-general" class="tab-pane fade in active">
        <div class="content-box" style="padding-bottom: 1.5em;">
            {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_GeneralSettings'])}}
        </div>
    </div>

    <!-- ── Device Links Tab ── -->
    <div id="tab-devicelinks" class="tab-pane fade">
        <div class="content-box" style="padding-top: 1em;">
            <div class="alert alert-info" role="alert">
                {{ lang._('Device Links let you route specific VPN clients through specific gateways.') }}
                <br/>
                <small>
                    {{ lang._('Example: route your phone (10.10.10.2) through OpenVPN gateway "BA_VPNV4", matching alias "BA_HOSTS".') }}
                </small>
            </div>

            <table id="grid-devicelinks" class="table table-condensed table-hover table-striped"
                   data-editDialog="DialogDeviceLink"
                   data-editAlert="DeviceLinkChangeMessage">
                <thead>
                    <tr>
                        <th data-column-id="uuid" data-type="string" data-identifier="true" data-visible="false">ID</th>
                        <th data-column-id="enabled" data-width="5em" data-type="string" data-formatter="status">{{ lang._('On') }}</th>
                        <th data-column-id="name" data-type="string" data-width="12em">{{ lang._('Device') }}</th>
                        <th data-column-id="tunnelIp" data-type="string" data-width="12em">{{ lang._('Tunnel IP') }}</th>
                        <th data-column-id="gateway" data-type="string" data-width="12em" data-formatter="gatewayBadge">{{ lang._('Gateway') }}</th>
                        <th data-column-id="targetAlias" data-type="string" data-width="10em" data-formatter="aliasBadge">{{ lang._('Alias') }}</th>
                        <th data-column-id="description" data-type="string">{{ lang._('Description') }}</th>
                        <th data-column-id="commands" data-width="7em" data-formatter="commands"
                            data-sortable="false">{{ lang._('Commands') }}</th>
                    </tr>
                </thead>
                <tbody>
                </tbody>
                <tfoot>
                    <tr>
                        <td></td>
                        <td>
                            <button data-action="add" type="button" class="btn btn-xs btn-primary">
                                <span class="fa fa-fw fa-plus"></span>
                            </button>
                            <button data-action="deleteSelected" type="button" class="btn btn-xs btn-default">
                                <span class="fa fa-fw fa-trash-o"></span>
                            </button>
                        </td>
                    </tr>
                </tfoot>
            </table>
        </div>
    </div>
</div>

<!-- ── Apply Bar ── -->
<div class="col-md-12">
    <div id="DeviceLinkChangeMessage" class="alert alert-info" style="display: none" role="alert">
        {{ lang._('After changing settings, please remember to apply them.') }}
    </div>
    <hr/>
    <button class="btn btn-primary" id="reconfigureAct"
            data-endpoint='/api/vpnlink/service/reconfigure'
            data-label="{{ lang._('Apply') }}"
            data-error-title="{{ lang._('Error reconfiguring VPN Link') }}"
            type="button">
    </button>
</div>

{# Device Link Edit Dialog #}
{{ partial("layout_partials/base_dialog",['fields':devicelinkForm,'id':'DialogDeviceLink','label':lang._('Edit Device Link')]) }}
