'use strict';

const { captureLocalMessage, localMockDeliveryEnabled } = require('./local_delivery');

function mailProvider(env = process.env) {
    if (localMockDeliveryEnabled(env)) return 'local-mock';
    const configuredProvider = String(env.MAIL_PROVIDER || '').trim().toLowerCase();
    if (configuredProvider) {
        if (configuredProvider === 'apps_script' && env.APPS_SCRIPT_URL && env.MAIL_SECRET) return 'apps_script';
        if (configuredProvider === 'brevo' && env.BREVO_API_KEY && env.MAIL_FROM) return 'brevo';
        if (configuredProvider === 'resend' && env.RESEND_API_KEY && env.MAIL_FROM) return 'resend';
        return null;
    }
    if (env.BREVO_API_KEY && env.MAIL_FROM) return 'brevo';
    if (env.RESEND_API_KEY && env.MAIL_FROM) return 'resend';
    return null;
}

function mailConfigurationIssue(env = process.env) {
    if (localMockDeliveryEnabled(env)) return null;
    const configuredProvider = String(env.MAIL_PROVIDER || '').trim().toLowerCase();
    if (configuredProvider === 'apps_script') {
        if (!env.APPS_SCRIPT_URL || !env.MAIL_SECRET) return 'EMAIL_PROVIDER_CREDENTIALS_UNAVAILABLE';
        try {
            parseAppsScriptUrl(env.APPS_SCRIPT_URL);
        } catch (_) {
            return 'EMAIL_PROVIDER_CONFIGURATION_INVALID';
        }
        return null;
    }
    if (configuredProvider && !mailProvider(env)) return 'EMAIL_PROVIDER_CREDENTIALS_UNAVAILABLE';
    if (!env.MAIL_FROM) return 'MAIL_FROM_UNAVAILABLE';
    try {
        parseSender(env.MAIL_FROM);
    } catch (_) {
        return 'MAIL_FROM_INVALID';
    }
    if (!env.BREVO_API_KEY && !env.RESEND_API_KEY) return 'EMAIL_PROVIDER_CREDENTIALS_UNAVAILABLE';
    return null;
}

function parseAppsScriptUrl(value) {
    let url;
    try {
        url = new URL(String(value || ''));
    } catch (_) {
        throw new Error('Invalid Apps Script deployment URL');
    }
    if (url.protocol !== 'https:' || url.hostname !== 'script.google.com' ||
        url.username || url.password || url.search || url.hash ||
        !/^\/macros\/s\/[A-Za-z0-9_-]+\/exec\/?$/.test(url.pathname)) {
        throw new Error('Invalid Apps Script deployment URL');
    }
    return url;
}

function isTrustedAppsScriptRedirect(value, baseUrl) {
    let url;
    try {
        url = new URL(value, baseUrl);
    } catch (_) {
        return false;
    }
    return url.protocol === 'https:' && url.hostname === 'script.googleusercontent.com' &&
        !url.username && !url.password;
}

async function sendAppsScriptMail({ to, subject, text, html }, { env, fetchImpl, timeoutMs }) {
    let deploymentUrl;
    try {
        deploymentUrl = parseAppsScriptUrl(env.APPS_SCRIPT_URL);
    } catch (_) {
        throw new Error('apps_script mail configuration is invalid');
    }
    if (!env.MAIL_SECRET) throw new Error('apps_script mail configuration is incomplete');
    if (typeof fetchImpl !== 'function') throw new Error('A fetch implementation is required');

    const controller = new AbortController();
    let timeout;
    const operation = (async () => {
        let response = await fetchImpl(deploymentUrl.toString(), {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ secret: env.MAIL_SECRET, to, subject, text, ...(html ? { html } : {}) }),
            signal: controller.signal,
            redirect: 'manual',
        });

        // Apps Script commonly redirects the POST result to script.googleusercontent.com.
        // The handler has already received the secret; fetch only the result URL with GET.
        for (let redirects = 0; response.status >= 300 && response.status < 400; redirects += 1) {
            if (redirects >= 3) throw new Error('apps_script mail delivery failed');
            const location = response.headers?.get?.('location');
            if (!location || !isTrustedAppsScriptRedirect(location, deploymentUrl)) {
                throw new Error('apps_script mail delivery failed');
            }
            const redirectUrl = new URL(location, deploymentUrl);
            response = await fetchImpl(redirectUrl.toString(), {
                method: 'GET',
                signal: controller.signal,
                redirect: 'manual',
            });
        }
        if (!response.ok) throw new Error('apps_script mail delivery failed');
        const responseText = typeof response.text === 'function' ? await response.text() : '';
        if (responseText.trim() !== 'OK') throw new Error('apps_script mail delivery failed');
        return response;
    })();
    const deadline = new Promise((_, reject) => {
        timeout = setTimeout(() => {
            controller.abort();
            const error = new Error('apps_script mail request timed out');
            error.name = 'TimeoutError';
            reject(error);
        }, timeoutMs);
    });
    try {
        return await Promise.race([operation, deadline]);
    } catch (error) {
        if (error.name === 'TimeoutError' || error.name === 'AbortError') {
            throw new Error('apps_script mail request timed out');
        }
        if (error.message === 'apps_script mail delivery failed') throw error;
        throw new Error('apps_script mail delivery failed');
    } finally {
        clearTimeout(timeout);
    }
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
    if (provider === 'local-mock') {
        captureLocalMessage({ type: 'email', to, subject, text, html }, env);
        return { ok: true, localMock: true };
    }
    if (!to || !subject || (!text && !html)) throw new Error('Recipient, subject, and message content are required');

    if (provider === 'apps_script') {
        return sendAppsScriptMail({ to, subject, text, html }, { env, fetchImpl, timeoutMs });
    }
    if (typeof fetchImpl !== 'function') throw new Error('A fetch implementation is required');

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
        throw new Error(`${provider} mail request failed (${response.status})`);
    }
    return response;
}

module.exports = { sendMail, mailProvider, mailConfigurationIssue, parseSender, parseAppsScriptUrl };
