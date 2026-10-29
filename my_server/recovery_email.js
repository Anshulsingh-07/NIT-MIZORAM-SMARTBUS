'use strict';

const APPS_SCRIPT_HOST = 'script.google.com';
const APPS_SCRIPT_REDIRECT_HOST = 'script.googleusercontent.com';
const ALLOWED_ERRORS = new Set(['unauthorized', 'bad_to', 'bad_otp', 'send_failed', 'timeout']);

class RecoveryEmailError extends Error {
    constructor({ provider, status = 0, providerError = 'send_failed' }) {
        super('Recovery email delivery failed');
        this.name = 'RecoveryEmailError';
        this.provider = provider;
        this.status = Number.isInteger(status) ? status : 0;
        this.providerError = ALLOWED_ERRORS.has(providerError) ? providerError : 'send_failed';
    }
}

function recoveryEmailProvider(env = process.env) {
    if (env.APPS_SCRIPT_URL && env.APPS_SCRIPT_SECRET) return 'apps_script';
    if (env.RESEND_API_KEY) return 'resend';
    return null;
}

function safeProviderError(value) {
    return ALLOWED_ERRORS.has(String(value || '').toLowerCase())
        ? String(value).toLowerCase()
        : 'send_failed';
}

function trustedAppsScriptRedirect(location, baseUrl) {
    try {
        const url = new URL(location, baseUrl);
        return url.protocol === 'https:' && url.hostname === APPS_SCRIPT_REDIRECT_HOST &&
            !url.username && !url.password;
    } catch (_) {
        return false;
    }
}

async function readJson(response) {
    const contentType = String(response.headers?.get?.('content-type') || '').toLowerCase();
    if (!contentType.includes('application/json') && !contentType.includes('+json')) return null;
    try {
        return await response.json();
    } catch (_) {
        return null;
    }
}

async function sendRecoveryEmail({ to, otp }, {
    env = process.env,
    fetchImpl = globalThis.fetch,
    timeoutMs = 15000,
} = {}) {
    const provider = recoveryEmailProvider(env);
    if (!provider) throw new RecoveryEmailError({ provider: 'none' });
    if (typeof fetchImpl !== 'function') throw new RecoveryEmailError({ provider });

    const controller = new AbortController();
    let timeout;
    const deadline = new Promise((_, reject) => {
        timeout = setTimeout(() => {
            controller.abort();
            const error = new Error('timeout');
            error.name = 'RecoveryTimeoutError';
            reject(error);
        }, timeoutMs);
    });

    const operation = provider === 'apps_script'
        ? sendViaAppsScript({ to, otp }, { env, fetchImpl, signal: controller.signal })
        : sendViaResend({ to, otp }, { env, fetchImpl, signal: controller.signal });

    try {
        return await Promise.race([operation, deadline]);
    } catch (error) {
        if (error?.name === 'RecoveryEmailError') throw error;
        const providerError = error?.name === 'RecoveryTimeoutError' || error?.name === 'AbortError'
            ? 'timeout'
            : 'send_failed';
        throw new RecoveryEmailError({ provider, status: error?.status || 0, providerError });
    } finally {
        clearTimeout(timeout);
    }
}

async function sendViaAppsScript({ to, otp }, { env, fetchImpl, signal }) {
    let deploymentUrl;
    try {
        deploymentUrl = new URL(env.APPS_SCRIPT_URL);
    } catch (_) {
        throw new RecoveryEmailError({ provider: 'apps_script' });
    }
    if (deploymentUrl.protocol !== 'https:' || deploymentUrl.hostname !== APPS_SCRIPT_HOST ||
        !/^\/macros\/s\/[A-Za-z0-9_-]+\/exec\/?$/.test(deploymentUrl.pathname) ||
        deploymentUrl.username || deploymentUrl.password || deploymentUrl.search || deploymentUrl.hash) {
        throw new RecoveryEmailError({ provider: 'apps_script' });
    }

    let response = await fetchImpl(deploymentUrl.toString(), {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ secret: env.APPS_SCRIPT_SECRET, to, otp }),
        signal,
        redirect: 'manual',
    });
    for (let redirects = 0; response.status >= 300 && response.status < 400; redirects += 1) {
        const location = response.headers?.get?.('location');
        if (redirects >= 3 || !location || !trustedAppsScriptRedirect(location, deploymentUrl)) {
            throw new RecoveryEmailError({ provider: 'apps_script', status: response.status });
        }
        response = await fetchImpl(new URL(location, deploymentUrl).toString(), {
            method: 'GET', signal, redirect: 'manual',
        });
    }

    const result = await readJson(response);
    if (response.ok && result?.ok === true) return { provider: 'apps_script', status: response.status };
    throw new RecoveryEmailError({
        provider: 'apps_script',
        status: response.status,
        providerError: safeProviderError(result?.error),
    });
}

async function sendViaResend({ to, otp }, { env, fetchImpl, signal }) {
    if (!env.MAIL_FROM) throw new RecoveryEmailError({ provider: 'resend' });
    const response = await fetchImpl('https://api.resend.com/emails', {
        method: 'POST',
        headers: { authorization: `Bearer ${env.RESEND_API_KEY}`, 'content-type': 'application/json' },
        body: JSON.stringify({
            from: env.MAIL_FROM,
            to: [to],
            subject: 'SmartBus password recovery code',
            text: `Your SmartBus password recovery code is ${otp}. It expires in 10 minutes.`,
        }),
        signal,
    });
    if (response.ok) return { provider: 'resend', status: response.status };
    const result = await readJson(response);
    const candidate = result?.error?.name || result?.error?.code || result?.error;
    const error = ['unauthorized', 'bad_to', 'bad_otp'].includes(String(candidate || '').toLowerCase())
        ? String(candidate).toLowerCase()
        : response.status === 401 || response.status === 403 ? 'unauthorized'
            : response.status === 400 ? 'bad_to' : 'send_failed';
    throw new RecoveryEmailError({ provider: 'resend', status: response.status, providerError: error });
}

module.exports = { RecoveryEmailError, recoveryEmailProvider, sendRecoveryEmail };
