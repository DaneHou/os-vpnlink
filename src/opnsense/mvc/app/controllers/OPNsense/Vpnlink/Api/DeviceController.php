<?php

/*
 * Copyright (c) 2024-2026 The os-vpnlink contributors
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 */

namespace OPNsense\Vpnlink\Api;

use OPNsense\Base\ApiControllerBase;
use OPNsense\Vpnlink\DeviceWizard;
use OPNsense\Vpnlink\DeviceWizardBackend;

/**
 * "Add device" wizard: /api/vpnlink/device/*
 * (CSRF is checked by ApiControllerBase for every POST)
 */
class DeviceController extends ApiControllerBase
{
    /**
     * GET /api/vpnlink/device/defaults
     * Enabled WireGuard instances with form defaults (next address, endpoint, DNS, MTU, ...).
     */
    public function defaultsAction()
    {
        try {
            $backend = new DeviceWizardBackend();
            $ctx = $backend->context();
            $wan = $backend->wanAddress();
            return DeviceWizard::defaults($ctx, $backend->ddnsHostname(), $wan);
        } catch (\Throwable $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
    }

    /**
     * POST /api/vpnlink/device/add  {device: {...}}
     * Creates peer (+ link), applies, returns the client config.
     * The response contains the client's PRIVATE KEY. It is generated for this
     * response only and is not stored or logged anywhere on the firewall.
     */
    public function addAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $req = $this->request->getPost('device');
        if (!is_array($req)) {
            return ['status' => 'failed', 'message' => 'missing device data'];
        }
        session_write_close();   // apply can take a while, don't block other GUI requests
        try {
            $backend = new DeviceWizardBackend();
            return DeviceWizard::run($backend, $backend->context(), $req);
        } catch (\Throwable $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
    }
}
