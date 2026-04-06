{# OPNsense VPN Link — Monitor (Traffic-style layout) #}

<script src="/js/vpnlink/chart.umd.min.js"></script>
<script src="/js/vpnlink/chartjs-adapter-date-fns.bundle.min.js"></script>

<style>
    .monitor-controls { display: flex; align-items: center; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
    .monitor-controls .range-btns .btn { padding: 2px 8px; font-size: 11px; }
    .monitor-controls .range-btns .btn.active { background: #337ab7; color: #fff; }
    .sse-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 4px; }
    .sse-dot.on { background: #5cb85c; }
    .sse-dot.off { background: #d9534f; }
    .sse-label { font-size: 11px; color: #888; }

    .chart-grid { display: flex; flex-wrap: wrap; gap: 16px; margin-bottom: 16px; }
    .chart-cell { flex: 1 1 calc(50% - 8px); min-width: 300px; background: #fff; border: 1px solid #ddd; border-radius: 4px; padding: 12px; }
    .chart-cell h5 { margin: 0 0 8px; font-size: 13px; color: #555; font-weight: 600; }

    .monitor-cards { display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
    .monitor-card { flex: 1; min-width: 130px; padding: 12px; background: #fff; border: 1px solid #ddd; border-radius: 4px; text-align: center; }
    .monitor-card .mc-value { font-size: 20px; font-weight: bold; color: #333; }
    .monitor-card .mc-label { font-size: 11px; color: #888; margin-top: 2px; }

    .peer-box { background: #fff; border: 1px solid #ddd; border-radius: 4px; padding: 14px; }
    .peer-box .peer-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
    .peer-box h4 { margin: 0; font-size: 14px; color: #555; }
    .peer-table { font-size: 12px; }
    .peer-table .online { color: #5cb85c; }

    .peer-badge { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 4px; vertical-align: middle; }
    .peer-picker { font-size: 12px; }
</style>

<script>
    // ── Tableau Classic10 palette ──
    var COLORS = ['#4E79A7','#F28E2B','#E15759','#76B7B2','#59A14F','#EDC948','#B07AA1','#FF9DA7','#9C755F','#BAB0AC'];
    function peerColor(idx) { return COLORS[idx % COLORS.length]; }
    function peerColorAlpha(idx, a) {
        var c = COLORS[idx % COLORS.length];
        var r = parseInt(c.slice(1,3),16), g = parseInt(c.slice(3,5),16), b = parseInt(c.slice(5,7),16);
        return 'rgba('+r+','+g+','+b+','+a+')';
    }

    // ── State ──
    var peerNames = {};           // IP → name
    var peerColorMap = {};        // IP → color index
    var peerColorIdx = 0;
    var vpnInterfaces = {};       // OPNsense ifname → {device, name}
    var currentRange = '1h';
    var evtSource = null;
    var charts = {};              // speedIn, speedOut, volIn, volOut

    // Assign a consistent color index to a peer
    function getPeerColorIdx(ip) {
        if (!(ip in peerColorMap)) { peerColorMap[ip] = peerColorIdx++; }
        return peerColorMap[ip];
    }

    $(document).ready(function() {
        // Load peer names
        $.get('/api/vpnlink/link/wgSources', function(r) {
            if (r && r.status === 'ok' && r.peers) {
                $.each(r.peers, function(i, p) { peerNames[p.ip] = p.name; });
            }
        });

        // Load VPN interfaces, then start SSE
        $.get('/api/vpnlink/monitor/interfaces', function(r) {
            if (r && r.interfaces) {
                vpnInterfaces = r.interfaces;
                startSSE();
            }
        });

        // Load data
        loadSummary();
        loadHistory(currentRange);
        setInterval(function() { loadSummary(); }, 30000);
    });

    $(window).on('beforeunload', function() {
        if (evtSource) { evtSource.close(); evtSource = null; }
    });

    // ── Formatting ──
    function peerLabel(ip) {
        return peerNames[ip] ? peerNames[ip] : ip;
    }
    function fmtBytes(b) {
        if (b >= 1073741824) return (b / 1073741824).toFixed(1) + ' GB';
        if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB';
        if (b >= 1024) return (b / 1024).toFixed(1) + ' KB';
        return b + ' B';
    }
    function fmtSpeed(bps) {
        if (bps >= 1048576) return (bps / 1048576).toFixed(1) + ' MB/s';
        if (bps >= 1024) return (bps / 1024).toFixed(1) + ' KB/s';
        return Math.round(bps) + ' B/s';
    }
    function fmtAxisBytes(val) {
        if (val >= 1073741824) return (val / 1073741824).toFixed(1) + ' GB';
        if (val >= 1048576) return (val / 1048576).toFixed(1) + ' MB';
        if (val >= 1024) return (val / 1024).toFixed(1) + ' KB';
        return val + ' B';
    }
    function fmtAxisSpeed(val) {
        if (val >= 1024) return (val / 1024).toFixed(1) + ' MB/s';
        return val.toFixed(0) + ' KB/s';
    }

    // ── SSE for real-time speed cards ──
    function startSSE() {
        if (typeof EventSource === 'undefined') {
            setInterval(pollTraffic, 2000);
            return;
        }
        evtSource = new EventSource('/api/diagnostics/traffic/stream/2');
        evtSource.onmessage = function(e) {
            try {
                var data = JSON.parse(e.data);
                updateSpeedFromSSE(data);
                $('.sse-dot').removeClass('off').addClass('on');
                $('.sse-label').text('live');
            } catch (err) {}
        };
        evtSource.onerror = function() {
            $('.sse-dot').removeClass('on').addClass('off');
            $('.sse-label').text('reconnecting...');
        };
    }

    function pollTraffic() {
        $.get('/api/diagnostics/traffic/interface', function(data) {
            if (data) updateSpeedFromSSE(data);
        });
    }

    var lastPollCounters = {};
    var lastPollTime = 0;

    // Rolling buffer for real-time chart data (last 5 min = 150 points at 2s interval)
    var MAX_REALTIME_POINTS = 150;
    var realtimeData = { labels: [], rx: [], tx: [] };
    var sseTickCount = 0;

    function updateSpeedFromSSE(data) {
        var interfaces = data.interfaces || data;
        var now = data.time || (Date.now() / 1000);
        var totalRx = 0, totalTx = 0;
        var isStream = false;

        $.each(interfaces, function(ifname, stats) {
            if (!vpnInterfaces[ifname]) return;

            if ('inbytes' in stats) {
                isStream = true;
                totalRx += stats.inbytes;
                totalTx += stats.outbytes;
            } else if ('bytes received' in stats) {
                var prev = lastPollCounters[ifname];
                if (prev && lastPollTime > 0) {
                    var elapsed = now - lastPollTime;
                    if (elapsed > 0 && elapsed < 10) {
                        totalRx += Math.max(0, stats['bytes received'] - prev.rx);
                        totalTx += Math.max(0, stats['bytes transmitted'] - prev.tx);
                    }
                }
                lastPollCounters[ifname] = { rx: stats['bytes received'], tx: stats['bytes transmitted'] };
            }
        });

        var elapsed = isStream ? 2 : Math.max(now - lastPollTime, 2);
        lastPollTime = now;
        var speedRx = totalRx / elapsed;
        var speedTx = totalTx / elapsed;

        // Update speed cards
        $('#card-speed-in').text(fmtSpeed(speedRx));
        $('#card-speed-out').text(fmtSpeed(speedTx));

        // Feed real-time chart (only when range is 1h or less, to show live data)
        if (currentRange === '1h') {
            realtimeData.labels.push(new Date(now * 1000));
            realtimeData.rx.push(speedRx / 1024); // KB/s
            realtimeData.tx.push(speedTx / 1024);

            if (realtimeData.labels.length > MAX_REALTIME_POINTS) {
                realtimeData.labels.shift();
                realtimeData.rx.shift();
                realtimeData.tx.shift();
            }

            // Update speed charts every 4 ticks (~8 seconds) to avoid excessive redraws
            sseTickCount++;
            if (sseTickCount % 4 === 0) {
                updateRealtimeCharts();
            }
        }
    }

    function updateRealtimeCharts() {
        if (!charts.speedIn || realtimeData.labels.length < 2) return;

        // Update speed-in chart
        charts.speedIn.data.labels = realtimeData.labels.slice();
        if (charts.speedIn.data.datasets.length === 0) {
            charts.speedIn.data.datasets.push({
                label: 'All VPN', data: realtimeData.rx.slice(),
                borderColor: '#5cb85c', backgroundColor: 'rgba(92,184,92,0.2)',
                fill: true, tension: 0.4, pointRadius: 0, borderWidth: 1.5
            });
        } else {
            charts.speedIn.data.datasets[0].data = realtimeData.rx.slice();
        }
        charts.speedIn.update('none');

        // Update speed-out chart
        charts.speedOut.data.labels = realtimeData.labels.slice();
        if (charts.speedOut.data.datasets.length === 0) {
            charts.speedOut.data.datasets.push({
                label: 'All VPN', data: realtimeData.tx.slice(),
                borderColor: '#337ab7', backgroundColor: 'rgba(51,122,183,0.2)',
                fill: true, tension: 0.4, pointRadius: 0, borderWidth: 1.5
            });
        } else {
            charts.speedOut.data.datasets[0].data = realtimeData.tx.slice();
        }
        charts.speedOut.update('none');
    }

    // ── Build peer picker ──
    function buildPeerPicker(peers) {
        var container = $('#peer-picker').empty();
        var allPeers = Object.keys(peers);
        // "All" checkbox
        container.append(
            '<label class="peer-picker" style="margin-right:10px;">' +
            '<input type="checkbox" id="peer-pick-all" checked onchange="toggleAllPeers(this)"> ' +
            '<strong>{{ lang._("All") }}</strong></label>'
        );
        $.each(allPeers, function(i, ip) {
            var ci = getPeerColorIdx(ip);
            container.append(
                '<label class="peer-picker" style="margin-right:10px;">' +
                '<input type="checkbox" class="peer-cb" data-ip="' + ip + '" checked onchange="onPeerToggle()"> ' +
                '<span class="peer-badge" style="background:' + peerColor(ci) + '"></span>' +
                peerLabel(ip) + '</label>'
            );
        });
    }

    function toggleAllPeers(el) {
        var checked = $(el).is(':checked');
        $('.peer-cb').prop('checked', checked);
        onPeerToggle();
    }

    function getSelectedPeers() {
        var selected = [];
        $('.peer-cb:checked').each(function() { selected.push($(this).data('ip')); });
        return selected;
    }

    function onPeerToggle() {
        // Re-render charts with selected peers
        renderCharts(window._lastHistoryData, getSelectedPeers());
    }

    // ── History data loading ──
    function loadHistory(range) {
        currentRange = range;
        $('.range-btns .btn').removeClass('active');
        $('.range-btns .btn[data-range="' + range + '"]').addClass('active');

        $.get('/api/vpnlink/monitor/history?range=' + range, function(r) {
            if (!r || !r.data || r.data.length === 0) {
                // No history data — create empty charts (SSE will fill speed charts)
                destroyCharts();
                window._lastHistoryData = null;
                charts.speedIn = makeChart('speedInCanvas', [], [], { yTitle: 'KB/s', yCallback: fmtAxisSpeed, timeFmt: 'HH:mm:ss' });
                charts.speedOut = makeChart('speedOutCanvas', [], [], { yTitle: 'KB/s', yCallback: fmtAxisSpeed, timeFmt: 'HH:mm:ss' });
                charts.volIn = makeChart('volInCanvas', [], [], { yTitle: '{{ lang._("Volume") }}', yCallback: fmtAxisBytes, timeFmt: 'HH:mm:ss' });
                charts.volOut = makeChart('volOutCanvas', [], [], { yTitle: '{{ lang._("Volume") }}', yCallback: fmtAxisBytes, timeFmt: 'HH:mm:ss' });
                return;
            }
            window._lastHistoryData = r;

            // Discover all peers in data
            var peersInData = {};
            $.each(r.data, function(i, d) { peersInData[d.peer_ip] = true; });
            buildPeerPicker(peersInData);

            renderCharts(r, Object.keys(peersInData));
        });
    }

    function destroyCharts() {
        $.each(charts, function(k, c) { if (c) c.destroy(); });
        charts = {};
    }

    // ── Render 4 charts ──
    function renderCharts(r, selectedPeers) {
        if (!r || !r.data) return;
        destroyCharts();

        // Group data: { peer_ip: { timestamp: {rx_speed, tx_speed, rx, tx} } }
        var peerBuckets = {};
        var allTimestamps = {};
        $.each(r.data, function(i, d) {
            if (selectedPeers.indexOf(d.peer_ip) === -1) return;
            if (!peerBuckets[d.peer_ip]) peerBuckets[d.peer_ip] = {};
            peerBuckets[d.peer_ip][d.timestamp] = {
                rx_speed: d.rx_speed || 0,
                tx_speed: d.tx_speed || 0,
                rx: d.rx || 0,
                tx: d.tx || 0
            };
            allTimestamps[d.timestamp] = true;
        });

        var sortedTs = Object.keys(allTimestamps).sort(function(a,b){ return a-b; });
        var labels = sortedTs.map(function(ts) { return new Date(parseInt(ts) * 1000); });

        // Build per-peer datasets
        var speedInDS = [], speedOutDS = [], volInDS = [], volOutDS = [];
        $.each(peerBuckets, function(ip, buckets) {
            var ci = getPeerColorIdx(ip);
            var rxSpeed = [], txSpeed = [], rxVol = [], txVol = [];
            var cumRx = 0, cumTx = 0;
            $.each(sortedTs, function(i, ts) {
                var d = buckets[ts] || { rx_speed: 0, tx_speed: 0, rx: 0, tx: 0 };
                rxSpeed.push(d.rx_speed / 1024);  // KB/s
                txSpeed.push(d.tx_speed / 1024);
                cumRx += d.rx;
                cumTx += d.tx;
                rxVol.push(cumRx);
                txVol.push(cumTx);
            });

            var label = peerLabel(ip);
            speedInDS.push({
                label: label, data: rxSpeed,
                borderColor: peerColor(ci), backgroundColor: peerColorAlpha(ci, 0.3),
                fill: true, tension: 0.4, pointRadius: 0, borderWidth: 1.5
            });
            speedOutDS.push({
                label: label, data: txSpeed,
                borderColor: peerColor(ci), backgroundColor: peerColorAlpha(ci, 0.3),
                fill: true, tension: 0.4, pointRadius: 0, borderWidth: 1.5
            });
            volInDS.push({
                label: label, data: rxVol,
                borderColor: peerColor(ci), backgroundColor: peerColorAlpha(ci, 0.3),
                fill: true, tension: 0.4, pointRadius: 0, borderWidth: 1.5
            });
            volOutDS.push({
                label: label, data: txVol,
                borderColor: peerColor(ci), backgroundColor: peerColorAlpha(ci, 0.3),
                fill: true, tension: 0.4, pointRadius: 0, borderWidth: 1.5
            });
        });

        // Time format depends on range
        var timeFmt = 'HH:mm:ss';
        if (currentRange === '7d' || currentRange === '30d') timeFmt = 'MM/dd HH:mm';

        // Create the 4 charts
        charts.speedIn = makeChart('speedInCanvas', labels, speedInDS, {
            yTitle: 'KB/s', yCallback: fmtAxisSpeed, timeFmt: timeFmt
        });
        charts.speedOut = makeChart('speedOutCanvas', labels, speedOutDS, {
            yTitle: 'KB/s', yCallback: fmtAxisSpeed, timeFmt: timeFmt
        });
        charts.volIn = makeChart('volInCanvas', labels, volInDS, {
            yTitle: '{{ lang._("Volume") }}', yCallback: fmtAxisBytes, timeFmt: timeFmt
        });
        charts.volOut = makeChart('volOutCanvas', labels, volOutDS, {
            yTitle: '{{ lang._("Volume") }}', yCallback: fmtAxisBytes, timeFmt: timeFmt
        });
    }

    function makeChart(canvasId, labels, datasets, opts) {
        var ctx = document.getElementById(canvasId).getContext('2d');
        return new Chart(ctx, {
            type: 'line',
            data: { labels: labels, datasets: datasets },
            options: {
                responsive: true, maintainAspectRatio: false,
                animation: false,
                interaction: { mode: 'index', intersect: false },
                scales: {
                    x: {
                        type: 'time',
                        time: { tooltipFormat: opts.timeFmt, displayFormats: { second: 'HH:mm:ss', minute: 'HH:mm', hour: 'MM/dd HH:mm' } },
                        grid: { display: false },
                        ticks: { maxTicksLimit: 6, font: { size: 10 } }
                    },
                    y: {
                        beginAtZero: true,
                        ticks: {
                            callback: opts.yCallback,
                            font: { size: 10 },
                            maxTicksLimit: 5
                        }
                    }
                },
                plugins: {
                    legend: { display: false },
                    tooltip: {
                        callbacks: {
                            label: function(ctx) {
                                return ctx.dataset.label + ': ' + opts.yCallback(ctx.parsed.y);
                            }
                        }
                    }
                }
            }
        });
    }

    // ── Peer table / summary ──
    function loadSummary() {
        $.get('/api/vpnlink/monitor/summary', function(r) {
            if (!r || !r.peers) return;
            var totalToday = 0, online = 0;
            var tbody = $('#peer-tbody').empty();
            $.each(r.peers, function(i, p) {
                var ci = getPeerColorIdx(p.peer_ip);
                totalToday += p.today_rx + p.today_tx; online++;
                tbody.append(
                    '<tr><td><span class="peer-badge" style="background:' + peerColor(ci) + '"></span> ' + peerLabel(p.peer_ip) +
                    ' <span style="color:#aaa;font-size:11px">(' + p.peer_ip + ')</span></td>' +
                    '<td>' + fmtSpeed(p.speed_rx) + ' / ' + fmtSpeed(p.speed_tx) + '</td>' +
                    '<td>' + fmtBytes(p.today_rx + p.today_tx) + '</td>' +
                    '<td>' + fmtBytes(p.rx_bytes) + ' / ' + fmtBytes(p.tx_bytes) + '</td></tr>'
                );
            });
            $('#card-today').text(fmtBytes(totalToday));
            $('#card-peers').text(online + ' online');
        });
    }
</script>

<div class="content-box" style="padding: 1.5em;">
    <h2 style="margin:0 0 12px;"><span class="fa fa-area-chart"></span> {{ lang._('Monitor') }}</h2>

    <!-- Controls bar -->
    <div class="monitor-controls">
        <div id="peer-picker" style="flex:1;">
            <span class="text-muted" style="font-size:12px;">{{ lang._('Loading peers...') }}</span>
        </div>
        <div class="range-btns">
            <button class="btn btn-xs btn-default active" data-range="1h" onclick="loadHistory('1h')">1h</button>
            <button class="btn btn-xs btn-default" data-range="6h" onclick="loadHistory('6h')">6h</button>
            <button class="btn btn-xs btn-default" data-range="24h" onclick="loadHistory('24h')">24h</button>
            <button class="btn btn-xs btn-default" data-range="7d" onclick="loadHistory('7d')">7d</button>
            <button class="btn btn-xs btn-default" data-range="30d" onclick="loadHistory('30d')">30d</button>
        </div>
        <div>
            <span class="sse-dot off"></span>
            <span class="sse-label">{{ lang._('connecting...') }}</span>
        </div>
    </div>

    <!-- 2x2 Chart Grid -->
    <div class="chart-grid">
        <div class="chart-cell">
            <h5><span class="fa fa-arrow-down" style="color:#5cb85c"></span> {{ lang._('In (speed)') }}</h5>
            <div style="position:relative; height:220px;"><canvas id="speedInCanvas"></canvas></div>
        </div>
        <div class="chart-cell">
            <h5><span class="fa fa-arrow-up" style="color:#337ab7"></span> {{ lang._('Out (speed)') }}</h5>
            <div style="position:relative; height:220px;"><canvas id="speedOutCanvas"></canvas></div>
        </div>
        <div class="chart-cell">
            <h5><span class="fa fa-arrow-down" style="color:#5cb85c"></span> {{ lang._('In (volume)') }}</h5>
            <div style="position:relative; height:220px;"><canvas id="volInCanvas"></canvas></div>
        </div>
        <div class="chart-cell">
            <h5><span class="fa fa-arrow-up" style="color:#337ab7"></span> {{ lang._('Out (volume)') }}</h5>
            <div style="position:relative; height:220px;"><canvas id="volOutCanvas"></canvas></div>
        </div>
    </div>

    <!-- Summary cards -->
    <div class="monitor-cards">
        <div class="monitor-card"><div class="mc-value" id="card-speed-in">&mdash;</div><div class="mc-label"><span class="fa fa-arrow-down"></span> {{ lang._('Download') }}</div></div>
        <div class="monitor-card"><div class="mc-value" id="card-speed-out">&mdash;</div><div class="mc-label"><span class="fa fa-arrow-up"></span> {{ lang._('Upload') }}</div></div>
        <div class="monitor-card"><div class="mc-value" id="card-today">&mdash;</div><div class="mc-label">{{ lang._('Today') }}</div></div>
        <div class="monitor-card"><div class="mc-value" id="card-peers">&mdash;</div><div class="mc-label">{{ lang._('Peers') }}</div></div>
    </div>

    <!-- Peer table -->
    <div class="peer-box">
        <div class="peer-header">
            <h4><span class="fa fa-users"></span> {{ lang._('Peers') }}</h4>
            <button class="btn btn-xs btn-default" onclick="loadSummary()"><span class="fa fa-refresh"></span></button>
        </div>
        <table class="table table-condensed table-striped peer-table">
            <thead><tr>
                <th>{{ lang._('Peer') }}</th>
                <th>{{ lang._('Speed (rx/tx)') }}</th>
                <th>{{ lang._('Today') }}</th>
                <th>{{ lang._('Total (rx/tx)') }}</th>
            </tr></thead>
            <tbody id="peer-tbody"><tr><td colspan="4" class="text-center text-muted">{{ lang._('Loading...') }}</td></tr></tbody>
        </table>
    </div>
</div>
