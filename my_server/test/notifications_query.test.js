'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('notifications endpoint types its nullable hostel filter as the column type', () => {
    const source = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
    const routeStart = source.indexOf("app.get('/api/notifications'");
    const routeEnd = source.indexOf("app.post('/api/reports'", routeStart);
    assert.notEqual(routeStart, -1, 'notifications endpoint exists');
    assert.notEqual(routeEnd, -1, 'notifications endpoint has a following route');
    const route = source.slice(routeStart, routeEnd);

    assert.match(route, /\$1::varchar\(10\) IS NULL OR target_hostel = \$1::varchar\(10\)/);
    assert.match(route, /expires_at > CURRENT_TIMESTAMP/);
    assert.match(route, /target_hostel IS NULL/);
    assert.match(route, /ORDER BY sent_at DESC/);
    assert.match(route, /return res\.json\(rows\.map\(\(n\) => \(\{ \.\.\.n, isRead: !!n\.isRead \}\)\)\)/);
});
