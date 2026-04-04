<?php

/*
 * Copyright (c) 2024-2026 DaneBA
 * All rights reserved.
 */

namespace OPNsense\Vpnlink\Api;

use OPNsense\Base\ApiControllerBase;

class MonitorController extends ApiControllerBase
{
    public function summaryAction()
    {
        $backend = new \OPNsense\Core\Backend();
        $response = trim($backend->configdRun('vpnlink traffic_summary'));
        $data = json_decode($response, true);
        return $data ?: ['peers' => [], 'error' => 'Failed to get summary'];
    }

    public function historyAction()
    {
        $range = $this->request->get('range', 'string', '24h');
        $allowed = ['1h', '6h', '24h', '7d', '30d'];
        if (!in_array($range, $allowed)) $range = '24h';

        $backend = new \OPNsense\Core\Backend();
        $response = trim($backend->configdRun('vpnlink traffic_history', [$range]));
        $data = json_decode($response, true);
        return $data ?: ['data' => [], 'error' => 'Failed to get history'];
    }
}
