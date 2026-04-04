#!/usr/local/bin/python3

"""
VPN Link — Traffic collector (runs via cron every minute).

Reads WireGuard peer rx/tx counters and stores deltas in SQLite.
Data is used by the Monitor page for charts.
"""

import json
import os
import sqlite3
import subprocess
import sys
import time

DB_PATH = '/var/db/vpnlink/traffic.db'
WG_SHOW_CMD = '/usr/bin/wg'


def init_db():
    """Create database and tables if needed."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    db = sqlite3.connect(DB_PATH)
    db.execute('''CREATE TABLE IF NOT EXISTS traffic_samples (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        peer_ip TEXT NOT NULL,
        rx_bytes INTEGER NOT NULL,
        tx_bytes INTEGER NOT NULL,
        delta_rx INTEGER DEFAULT 0,
        delta_tx INTEGER DEFAULT 0
    )''')
    db.execute('''CREATE TABLE IF NOT EXISTS traffic_hourly (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        hour INTEGER NOT NULL,
        peer_ip TEXT NOT NULL,
        total_rx INTEGER NOT NULL,
        total_tx INTEGER NOT NULL,
        UNIQUE(hour, peer_ip)
    )''')
    db.execute('CREATE INDEX IF NOT EXISTS idx_samples_ts ON traffic_samples(timestamp)')
    db.execute('CREATE INDEX IF NOT EXISTS idx_samples_peer ON traffic_samples(peer_ip)')
    db.execute('CREATE INDEX IF NOT EXISTS idx_hourly_hour ON traffic_hourly(hour)')
    db.commit()
    return db


def get_peer_stats():
    """Read current WireGuard peer stats from wg show."""
    peers = {}
    try:
        result = subprocess.run(
            [WG_SHOW_CMD, 'show', 'all', 'dump'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return peers

        for line in result.stdout.strip().splitlines():
            parts = line.split('\t')
            if len(parts) < 9:
                continue
            # Skip the interface header line
            if parts[0] == parts[1]:
                continue

            allowed_ips = parts[4]
            rx_bytes = int(parts[6])
            tx_bytes = int(parts[7])
            handshake = int(parts[5]) if parts[5] != '0' else 0

            # Extract peer IP from allowed_ips (e.g. "10.10.0.3/32")
            peer_ip = allowed_ips.split('/')[0] if allowed_ips else None
            if peer_ip and handshake > 0:
                peers[peer_ip] = {'rx': rx_bytes, 'tx': tx_bytes}

    except (FileNotFoundError, subprocess.TimeoutExpired, ValueError):
        pass
    return peers


def collect():
    """Main collection routine."""
    db = init_db()
    now = int(time.time())
    peers = get_peer_stats()

    if not peers:
        db.close()
        return

    for peer_ip, stats in peers.items():
        rx = stats['rx']
        tx = stats['tx']

        # Get previous sample to calculate delta
        prev = db.execute(
            'SELECT rx_bytes, tx_bytes FROM traffic_samples WHERE peer_ip = ? ORDER BY timestamp DESC LIMIT 1',
            (peer_ip,)
        ).fetchone()

        delta_rx = 0
        delta_tx = 0
        if prev:
            # Handle counter reset (reboot, interface restart)
            delta_rx = max(0, rx - prev[0]) if rx >= prev[0] else rx
            delta_tx = max(0, tx - prev[1]) if tx >= prev[1] else tx

        db.execute(
            'INSERT INTO traffic_samples (timestamp, peer_ip, rx_bytes, tx_bytes, delta_rx, delta_tx) VALUES (?, ?, ?, ?, ?, ?)',
            (now, peer_ip, rx, tx, delta_rx, delta_tx)
        )

        # Update hourly aggregate
        hour = (now // 3600) * 3600
        db.execute('''INSERT INTO traffic_hourly (hour, peer_ip, total_rx, total_tx)
                      VALUES (?, ?, ?, ?)
                      ON CONFLICT(hour, peer_ip)
                      DO UPDATE SET total_rx = total_rx + ?, total_tx = total_tx + ?''',
                   (hour, peer_ip, delta_rx, delta_tx, delta_rx, delta_tx))

    db.commit()

    # Cleanup: remove raw samples older than 48h
    cutoff = now - 48 * 3600
    db.execute('DELETE FROM traffic_samples WHERE timestamp < ?', (cutoff,))
    db.commit()
    db.close()


def cmd_summary():
    """Current traffic summary for all peers. Uses live wg data + SQLite for history."""
    db = init_db()
    now = int(time.time())
    peers = get_peer_stats()

    results = []
    for peer_ip, stats in peers.items():
        # Calculate speed from last sample delta (most recent)
        last = db.execute(
            'SELECT delta_rx, delta_tx, timestamp FROM traffic_samples WHERE peer_ip = ? AND delta_rx > 0 ORDER BY timestamp DESC LIMIT 1',
            (peer_ip,)
        ).fetchone()

        if last and (now - last[2]) < 180:  # within 3 minutes
            elapsed = max(now - last[2], 60)
            speed_rx = last[0] / elapsed
            speed_tx = last[1] / elapsed
        else:
            speed_rx = 0
            speed_tx = 0

        # Today's total
        today_start = (now // 86400) * 86400
        today = db.execute(
            'SELECT SUM(delta_rx), SUM(delta_tx) FROM traffic_samples WHERE peer_ip = ? AND timestamp > ?',
            (peer_ip, today_start)
        ).fetchone()

        results.append({
            'peer_ip': peer_ip,
            'rx_bytes': stats['rx'],
            'tx_bytes': stats['tx'],
            'speed_rx': round(speed_rx),
            'speed_tx': round(speed_tx),
            'today_rx': today[0] or 0,
            'today_tx': today[1] or 0,
        })

    db.close()
    print(json.dumps({'peers': results, 'timestamp': now}, indent=2))


def cmd_history(range_str='24h'):
    """Historical traffic data for charting."""
    db = init_db()
    now = int(time.time())

    # Clean range_str (configd may pass extra whitespace)
    range_str = range_str.strip()
    ranges = {'1h': 3600, '6h': 21600, '24h': 86400, '7d': 604800, '30d': 2592000}
    seconds = ranges.get(range_str, 86400)
    since = now - seconds

    # Use raw samples for short ranges, hourly for longer
    if seconds <= 86400:
        rows = db.execute(
            'SELECT timestamp, peer_ip, delta_rx, delta_tx FROM traffic_samples WHERE timestamp > ? ORDER BY timestamp',
            (since,)
        ).fetchall()
    else:
        rows = db.execute(
            'SELECT hour as timestamp, peer_ip, total_rx as delta_rx, total_tx as delta_tx FROM traffic_hourly WHERE hour > ? ORDER BY hour',
            (since,)
        ).fetchall()

    # Aggregate into time buckets — use 60s for short ranges, scale up for longer
    if seconds <= 3600:
        bucket_size = 60
    else:
        bucket_size = max(seconds // 200, 60)
    buckets = {}
    for ts, peer_ip, drx, dtx in rows:
        bucket = (ts // bucket_size) * bucket_size
        key = (bucket, peer_ip)
        if key not in buckets:
            buckets[key] = {'rx': 0, 'tx': 0}
        buckets[key]['rx'] += drx
        buckets[key]['tx'] += dtx

    # Format for chart
    data = []
    for (ts, peer_ip), vals in sorted(buckets.items()):
        data.append({
            'timestamp': ts,
            'peer_ip': peer_ip,
            'rx': vals['rx'],
            'tx': vals['tx'],
            'rx_speed': round(vals['rx'] / bucket_size),
            'tx_speed': round(vals['tx'] / bucket_size),
        })

    db.close()
    print(json.dumps({'data': data, 'range': range_str, 'bucket_size': bucket_size}, indent=2))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        collect()
    elif sys.argv[1] == 'summary':
        cmd_summary()
    elif sys.argv[1] == 'history':
        cmd_history(sys.argv[2] if len(sys.argv) > 2 else '24h')
    else:
        collect()
