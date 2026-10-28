'use strict';

const { boundedString, positiveSafeInteger } = require('./input_validation');
const { rejectRequest } = require('./request_rejections');

function createReportSubmissionHandler({ requireAuth, query, uid, internalError, logger = console }) {
    return async (req, res) => {
        const auth = requireAuth(req, res, ['student']);
        if (!auth) return;

        const category = boundedString(req.body?.category, 40, { fallback: 'other' });
        const message = boundedString(req.body?.message, 2000, { required: true });
        const busNumber = req.body?.busNumber == null ? null : positiveSafeInteger(req.body.busNumber);
        if (category === null || !message || (req.body?.busNumber != null && !busNumber)) {
            return res.status(400).json({ error: 'A report message up to 2000 characters is required' });
        }
        if (!auth.hostelId) {
            return rejectRequest(res, req, 403, 'STUDENT_HOSTEL_UNASSIGNED', 'Student account has no assigned hostel', logger);
        }

        try {
            if (busNumber != null) {
                const buses = await query('SELECT bus_number, assigned_hostel FROM buses WHERE bus_number = ? LIMIT 1', [busNumber]);
                if (!buses.length) return res.status(404).json({ error: 'Bus not found' });
                if (buses[0].assigned_hostel !== auth.hostelId) {
                    return rejectRequest(res, req, 403, 'BUS_HOSTEL_MISMATCH', 'You can only report buses assigned to your hostel', logger);
                }
            }
            const rows = await query(`INSERT INTO reports (id, reporter_id, hostel_id, bus_number, category, message)
                VALUES (?, ?, ?, ?, ?, ?) RETURNING id, reporter_id AS "reporterId", hostel_id AS "hostelId",
                bus_number AS "busNumber", category, message, status, created_at AS "createdAt"`,
            [uid('r_'), auth.userId, auth.hostelId, busNumber, category || 'other', message]);
            return res.status(201).json({ status: 'success', data: rows[0] });
        } catch (error) {
            return internalError(res, error, 'submit report');
        }
    };
}

module.exports = { createReportSubmissionHandler };
