'use strict';

const express = require('express');

function createRegistrationMobileRouter() {
    const router = express.Router();
    const gone = (_req, res) => res.status(410).json({
        success: false,
        code: 'REGISTRATION_MOBILE_OTP_REMOVED',
        message: 'Mobile verification is no longer required for registration.',
    });
    router.post('/request', gone);
    router.post('/verify', gone);
    return router;
}

module.exports = { createRegistrationMobileRouter };
