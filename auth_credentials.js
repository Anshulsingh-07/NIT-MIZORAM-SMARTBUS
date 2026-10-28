'use strict';

const bcrypt = require('bcryptjs');

async function canAuthenticateUser(user, password, hostels) {
    if (!user) return false;
    const storedPassword = user.password || '';
    if (!/^\$2[aby]\$/.test(storedPassword)) return false;
    if (!await bcrypt.compare(password, storedPassword)) return false;
    if (user.role === 'caretaker' && !hostels.some((hostel) => hostel.id === user.hostel_id)) {
        return false;
    }
    return true;
}

module.exports = { canAuthenticateUser };