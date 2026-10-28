'use strict';

const { captureLocalMessage, localMockDeliveryEnabled } = require('./local_delivery');

function smsProvider(env = process.env) {
    if (localMockDeliveryEnabled(env)) return 'local-mock';
    return env.TWILIO_ACCOUNT_SID && env.TWILIO_AUTH_TOKEN && env.TWILIO_FROM_NUMBER
        ? 'twilio'
        : null;
}

async function sendSms(to, message, {
    env = process.env,
    fetchImpl = globalThis.fetch,
    timeoutMs = 8000,
} = {}) {
    const provider = smsProvider(env);
    if (!provider) throw new Error('Configure Twilio SMS environment variables');
    if (provider === 'local-mock') {
        captureLocalMessage({ type: 'sms', to, message }, env);
        return { ok: true, localMock: true };
    }
    if (typeof fetchImpl !== 'function') throw new Error('A fetch implementation is required');
    if (!/^\+[1-9]\d{7,14}$/.test(String(to || '')) || !String(message || '').trim()) {
        throw new Error('A valid E.164 recipient and message are required');
    }

    const credentials = Buffer.from(
        `${env.TWILIO_ACCOUNT_SID}:${env.TWILIO_AUTH_TOKEN}`,
    ).toString('base64');
    const body = new URLSearchParams({
        To: to,
        From: env.TWILIO_FROM_NUMBER,
        Body: message,
    });
    const controller = new AbortController();
    let timeout;
    const deadline = new Promise((_, reject) => {
        timeout = setTimeout(() => {
            controller.abort();
            const error = new Error('Twilio SMS request timed out');
            error.name = 'TimeoutError';
            reject(error);
        }, timeoutMs);
    });
    let response;
    try {
        response = await Promise.race([fetchImpl(
            `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(env.TWILIO_ACCOUNT_SID)}/Messages.json`,
            {
                method: 'POST',
                headers: {
                    authorization: `Basic ${credentials}`,
                    'content-type': 'application/x-www-form-urlencoded',
                },
                body: body.toString(),
                signal: controller.signal,
            },
        ), deadline]);
    } catch (error) {
        if (error.name === 'TimeoutError' || error.name === 'AbortError') {
            throw new Error('Twilio SMS request timed out');
        }
        throw new Error('Twilio SMS request failed');
    } finally {
        clearTimeout(timeout);
    }
    if (!response.ok) {
        throw new Error(`Twilio SMS request failed (${response.status})`);
    }
    return response;
}

module.exports = { sendSms, smsProvider };