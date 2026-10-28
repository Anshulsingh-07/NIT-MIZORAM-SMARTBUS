'use strict';

function getCaretakerBootstrapAction(account, validInitialPassword) {
    if (!account) return validInitialPassword ? 'create' : 'skip';
    if (account.role !== 'caretaker') return 'conflict';
    return /^\$2[aby]\$/.test(account.password || '') ? 'preserve' : 'legacy';
}

module.exports = { getCaretakerBootstrapAction };
