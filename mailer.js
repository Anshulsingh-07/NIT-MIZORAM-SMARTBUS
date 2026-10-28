'use strict';

function mailProvider(env = process.env) {
    if (env.BREVO_API_KEY && env.MAIL_FROM) return 'brevo';
    if (env.RESEND_API_KEY && env.MAIL_FROM) return 'resend';
    return null;
}

function parseSender(value) {
    const sender = String(value || '').trim();
    const match = sender.match(/^(.*?)\s*<([^<>]+)>$/);
    const email = (match ? match[2] : sender).trim();
    const name = match ? match[1].trim().replace(/^"|"$/g, '') : '';
    if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(email)) {
        throw new Error('MAIL_FROM must be an email address or a name plus email address');
    }
    return { name: name || email.split('@')[0], email };
}

async function sendMail({ to, subject, text, html }, {
    env = process.env,
    fetchImpl = globalThis.fetch,
    timeoutMs = 8000,
} = {}) {
    const provider = mailProvider(env);
    if (!provider) throw new Error('Configure MAIL_FROM and a mail provider API key');
    if (typeof fetchImpl !== 'function') throw new Error('A fetch implementation is required');
    if (!to || !subject || (!text && !html)) throw new Error('Recipient, subject, and message content are required');

    const sender = parseSender(env.MAIL_FROM);
    let url;
    let headers;
    let body;
    if (provider === 'brevo') {
        url = 'https://api.brevo.com/v3/smtp/email';
        headers = {
            'api-key': env.BREVO_API_KEY,
            'content-type': 'application/json',
        };
        body = {
            sender,
            to: [{ email: to }],
            subject,
            ...(text ? { textContent: text } : {}),
            ...(html ? { htmlContent: html } : {}),
        };
    } else {
        url = 'https://api.resend.com/emails';
        headers = {
            authorization: `Bearer ${env.RESEND_API_KEY}`,
            'content-type': 'application/json',
        };
        body = {
            from: `${sender.name} <${sender.email}>`,
            to: [to],
            subject,
            ...(text ? { text } : {}),
            ...(html ? { html } : {}),
        };
    }

    const controller = new AbortController();
    let timeout;
    const deadline = new Promise((_, reject) => {
        timeout = setTimeout(() => {
            controller.abort();
            const error = new Error(`${provider} mail request timed out`);
            error.name = 'TimeoutError';
            reject(error);
        }, timeoutMs);
    });
    let response;
    try {
        response = await Promise.race([
            fetchImpl(url, {
                method: 'POST',
                headers,
                body: JSON.stringify(body),
                signal: controller.signal,
            }),
            deadline,
        ]);
    } catch (error) {
        if (error.name === 'TimeoutError' || error.name === 'AbortError') {
            throw new Error(`${provider} mail request timed out`);
        }
        throw new Error(`${provider} mail request failed`);
    } finally {
        clearTimeout(timeout);
    }
    if (!response.ok) {
        const details = typeof response.text === 'function' ? await response.text() : '';
        throw new Error(`${provider} mail request failed (${response.status})${details ? `: ${details}` : ''}`);
    }
    return response;
}

module.exports = { sendMail, mailProvider, parseSender };
