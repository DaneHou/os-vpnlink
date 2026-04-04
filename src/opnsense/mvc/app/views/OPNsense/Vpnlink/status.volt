{# OPNsense VPN Link — Status #}

<style>
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
</style>

<script>
    function loadStatus() {
        var box = $('#status-cards').html('<div class="text-center text-muted" style="padding:30px">Loading...</div>');
        $('#svc-status-text').html('<span class="fa fa-circle-o-notch fa-spin"></span> Checking...');
        $.get('/api/vpnlink/service/healthcheck', function(r) {
            box.empty();
            if (!r || !r.checks) { box.html('<div class="text-muted">Error loading status</div>'); return; }

            // Update service bar
            var allOk = r.checks.every(function(c) { return c.ok; });
            var failCount = r.checks.filter(function(c) { return !c.ok; }).length;
            if (allOk) {
                $('#svc-status-text').html('<span class="fa fa-check-circle text-success"></span> All checks passed');
            } else {
                $('#svc-status-text').html('<span class="fa fa-exclamation-triangle text-warning"></span> ' + failCount + ' issue(s) detected');
            }

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

    $(document).ready(function() {
        loadStatus();
    });
</script>

<div class="content-box" style="padding: 1.5em;">
    <div class="svc-bar">
        <span class="svc-status" id="svc-status-text"><span class="fa fa-circle-o-notch fa-spin"></span> {{ lang._('Checking...') }}</span>
        <span class="svc-controls">
            <button class="btn btn-default btn-sm" onclick="loadStatus()"><span class="fa fa-refresh"></span> {{ lang._('Refresh') }}</button>
        </span>
    </div>
    <div id="status-cards">
        <div class="text-center text-muted" style="padding:30px">{{ lang._('Loading...') }}</div>
    </div>
</div>
