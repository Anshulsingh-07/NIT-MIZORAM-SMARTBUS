'use strict';

const messages = [];

function localMockDeliveryEnabled(env = process.env) {
    return env.NODE_ENV === 'development' && env.LOCAL_MOCK_DELIVERY === 'true';
}

function captureLocalMessage(message, env = process.env) {
    if (!localMockDeliveryEnabled(env)) {
        throw new Error('Local delivery mock is disabled.');
    }
    messages.push({ ...message, capturedAt: new Date().toISOString() });
}

function takeLocalMessages(env = process.env) {
    if (!localMockDeliveryEnabled(env)) return [];
    return messages.splice(0, messages.length);
}

module.exports = {
    captureLocalMessage,
    localMockDeliveryEnabled,
    takeLocalMessages,
};
