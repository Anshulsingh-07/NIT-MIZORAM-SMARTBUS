'use strict';

const crypto = require('crypto');

function fingerprintDatabaseIdentity(identity = {}) {
    const values = [
        identity.database,
        identity.schema,
        identity.address,
        identity.port,
    ].map((value) => String(value ?? ''));
    return crypto.createHash('sha256').update(values.join('\0')).digest('hex').slice(0, 16);
}

module.exports = { fingerprintDatabaseIdentity };
