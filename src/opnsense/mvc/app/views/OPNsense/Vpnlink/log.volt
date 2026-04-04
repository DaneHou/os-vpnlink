{# OPNsense VPN Link — Log #}

<style>
    /* Log */
    .log-table { font-size: 12px; font-family: monospace; }
    .log-table td.ts { width: 7em; color: #888; white-space: nowrap; }
    .log-filter { margin-bottom: 8px; }
    .log-filter input { width: 250px; display: inline-block; }
</style>

<script>
    var _logData = [];

    function loadLog() {
        var box = $('#log-body');
        box.html('<div class="text-center text-muted" style="padding:20px">Loading...</div>');
        $.get('/api/vpnlink/service/log', function(r) {
            _logData = (r && r.entries) ? r.entries : [];
            renderLog();
        });
    }

    function renderLog() {
        var box = $('#log-body').empty();
        var filter = $('#log-filter-input').val() || '';
        var filtered = filter ? _logData.filter(function(e) { return e.message.toLowerCase().indexOf(filter.toLowerCase()) >= 0; }) : _logData;

        if (filtered.length === 0) {
            box.html('<div class="text-muted" style="padding:20px;text-align:center">{{ lang._("No log entries found.") }}</div>');
            return;
        }
        var html = '<table class="table table-condensed log-table">';
        $.each(filtered, function(i, e) {
            var ts = e.timestamp ? e.timestamp.replace(/T/,' ').split('.')[0].split('-').slice(0,3).join('-') : '';
            if (ts.length > 19) ts = ts.substring(0, 19);
            // Extract just time portion
            var timePart = ts.indexOf(' ') > 0 ? ts.split(' ')[1] : ts;
            html += '<tr><td class="ts">' + timePart + '</td><td>' + $('<span>').text(e.message).html() + '</td></tr>';
        });
        html += '</table>';
        box.html(html);
    }

    $(document).ready(function() {
        $('#log-filter-input').on('input', function() { renderLog(); });
        loadLog();
    });
</script>

<div class="content-box" style="padding: 1.5em;">
    <div class="log-filter">
        <input type="text" id="log-filter-input" class="form-control input-sm" placeholder="{{ lang._('Filter log...') }}"/>
        <button class="btn btn-default btn-sm" onclick="loadLog()" style="margin-left:5px;"><span class="fa fa-refresh"></span></button>
    </div>
    <div id="log-body" style="max-height:400px; overflow-y:auto;">
        <div class="text-center text-muted" style="padding:20px">{{ lang._('Loading...') }}</div>
    </div>
</div>
