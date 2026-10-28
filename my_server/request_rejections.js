'use strict';

function rejectRequest(res, req, status, code, error, logger = console) {
    // Log only the method and fixed reason code; never log path, headers, or body.
    logger.warn(`Request rejected: ${req.method} ${code}`);
    return res.status(status).json({ error, code });
}

module.exports = { rejectRequest };
