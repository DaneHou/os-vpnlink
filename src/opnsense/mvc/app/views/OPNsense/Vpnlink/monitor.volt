{# OPNsense VPN Link — Monitor #}

<script src="/js/vpnlink/chart.umd.min.js"></script>
<script src="/js/vpnlink/chartjs-adapter-date-fns.bundle.min.js"></script>

<style>
    .monitor-cards { display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
    .monitor-card { flex: 1; min-width: 140px; padding: 14px; background: #fff; border: 1px solid #ddd; border-radius: 4px; text-align: center; }
    .monitor-card .mc-value { font-size: 22px; font-weight: bold; color: #333; }
    .monitor-card .mc-label { font-size: 11px; color: #888; margin-top: 2px; }
    .chart-box { background: #fff; border: 1px solid #ddd; border-radius: 4px; padding: 14px; margin-bottom: 16px; }
    .chart-box .chart-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
    .chart-box .chart-header h4 { margin: 0; font-size: 14px; color: #555; }
    .range-btns .btn { padding: 2px 8px; font-size: 11px; }
    .range-btns .btn.active { background: #337ab7; color: #fff; }
    .peer-table { font-size: 12px; }
    .peer-table .online { color: #5cb85c; }
</style>

<script>
    var historyChart = null, currentRange = '1h';
    var peerNames = {};  // IP → name lookup

    $(document).ready(function() {
        // Load peer names from WireGuard config
        $.get('/api/vpnlink/link/wgSources', function(r) {
            if (r && r.status === 'ok' && r.peers) {
                $.each(r.peers, function(i, p) { peerNames[p.ip] = p.name; });
            }
            loadSummary();
            loadHistory(currentRange);
        });
        setInterval(function() { loadSummary(); loadHistory(currentRange); }, 30000);
    });

    function peerLabel(ip) {
        return peerNames[ip] ? peerNames[ip] + ' (' + ip + ')' : ip;
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
        return bps + ' B/s';
    }

    function loadSummary() {
        $.get('/api/vpnlink/monitor/summary', function(r) {
            if (!r || !r.peers) return;
            var totalRx = 0, totalTx = 0, totalToday = 0, online = 0;
            var tbody = $('#peer-tbody').empty();
            $.each(r.peers, function(i, p) {
                totalRx += p.speed_rx; totalTx += p.speed_tx;
                totalToday += p.today_rx + p.today_tx; online++;
                tbody.append('<tr><td><span class="fa fa-fw fa-circle online"></span> ' + peerLabel(p.peer_ip) + '</td>' +
                    '<td>' + fmtSpeed(p.speed_rx) + ' / ' + fmtSpeed(p.speed_tx) + '</td>' +
                    '<td>' + fmtBytes(p.today_rx + p.today_tx) + '</td>' +
                    '<td>' + fmtBytes(p.rx_bytes) + ' / ' + fmtBytes(p.tx_bytes) + '</td></tr>');
            });
            $('#card-speed-in').text(fmtSpeed(totalRx));
            $('#card-speed-out').text(fmtSpeed(totalTx));
            $('#card-today').text(fmtBytes(totalToday));
            $('#card-peers').text(online + ' online');
        });
    }

    function loadHistory(range) {
        currentRange = range;
        $('.range-btns .btn').removeClass('active');
        $('.range-btns .btn[data-range="' + range + '"]').addClass('active');

        $.get('/api/vpnlink/monitor/history?range=' + range, function(r) {
            if (!r || !r.data || r.data.length === 0) {
                if (historyChart) historyChart.destroy();
                historyChart = null;
                return;
            }
            var buckets = {};
            $.each(r.data, function(i, d) {
                if (!buckets[d.timestamp]) buckets[d.timestamp] = {rx: 0, tx: 0};
                buckets[d.timestamp].rx += d.rx_speed;
                buckets[d.timestamp].tx += d.tx_speed;
            });
            var labels = [], rxData = [], txData = [];
            $.each(Object.keys(buckets).sort(), function(i, ts) {
                labels.push(new Date(parseInt(ts) * 1000));
                rxData.push(buckets[ts].rx / 1024);
                txData.push(buckets[ts].tx / 1024);
            });

            var ctx = document.getElementById('historyCanvas').getContext('2d');
            if (historyChart) historyChart.destroy();
            historyChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels: labels,
                    datasets: [
                        { label: 'Download (KB/s)', data: rxData, borderColor: '#5cb85c', backgroundColor: 'rgba(92,184,92,0.1)', fill: true, tension: 0.3, pointRadius: 0 },
                        { label: 'Upload (KB/s)', data: txData, borderColor: '#337ab7', backgroundColor: 'rgba(51,122,183,0.1)', fill: true, tension: 0.3, pointRadius: 0 }
                    ]
                },
                options: {
                    responsive: true, maintainAspectRatio: false,
                    interaction: { mode: 'index', intersect: false },
                    scales: {
                        x: { type: 'time', time: { tooltipFormat: 'HH:mm:ss' }, grid: { display: false } },
                        y: { beginAtZero: true, title: { display: true, text: 'KB/s' } }
                    },
                    plugins: { legend: { position: 'bottom' } }
                }
            });
        });
    }
</script>

<div class="content-box" style="padding: 1.5em;">
    <h2 style="margin:0 0 15px;"><span class="fa fa-area-chart"></span> {{ lang._('Monitor') }}</h2>

    <div class="monitor-cards">
        <div class="monitor-card"><div class="mc-value" id="card-speed-in">&mdash;</div><div class="mc-label">{{ lang._('Download') }}</div></div>
        <div class="monitor-card"><div class="mc-value" id="card-speed-out">&mdash;</div><div class="mc-label">{{ lang._('Upload') }}</div></div>
        <div class="monitor-card"><div class="mc-value" id="card-today">&mdash;</div><div class="mc-label">{{ lang._('Today') }}</div></div>
        <div class="monitor-card"><div class="mc-value" id="card-peers">&mdash;</div><div class="mc-label">{{ lang._('Peers') }}</div></div>
    </div>

    <div class="chart-box">
        <div class="chart-header">
            <h4><span class="fa fa-line-chart"></span> {{ lang._('Traffic') }}</h4>
            <div class="range-btns">
                <button class="btn btn-xs btn-default active" data-range="1h" onclick="loadHistory('1h')">1h</button>
                <button class="btn btn-xs btn-default" data-range="6h" onclick="loadHistory('6h')">6h</button>
                <button class="btn btn-xs btn-default" data-range="24h" onclick="loadHistory('24h')">24h</button>
                <button class="btn btn-xs btn-default" data-range="7d" onclick="loadHistory('7d')">7d</button>
                <button class="btn btn-xs btn-default" data-range="30d" onclick="loadHistory('30d')">30d</button>
            </div>
        </div>
        <div style="position:relative; height:250px;"><canvas id="historyCanvas"></canvas></div>
    </div>

    <div class="chart-box">
        <div class="chart-header">
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
