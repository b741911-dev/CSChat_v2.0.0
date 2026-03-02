const sqlite = require('better-sqlite3');
const path = require('path');

const db = new sqlite(path.join(__dirname, 'chat.db'));

function getStats() {
    const now = new Date();
    const kstGap = 9 * 60 * 60 * 1000;
    const traffic = [];

    console.log('Current Time (Local):', now.toString());
    console.log('Current Time (ISO/UTC):', now.toISOString());

    for (let i = 23; i >= 0; i--) {
        const targetTimeUTC = new Date(now.getTime() - (i * 60 * 60 * 1000));
        const targetTimeKST = new Date(targetTimeUTC.getTime() + kstGap);

        const hourKey = targetTimeKST.toISOString().substring(11, 13) + ':00';
        const datePrefix = targetTimeUTC.toISOString().replace('T', ' ').substring(0, 14);

        const countRes = db.prepare(`
            SELECT COUNT(*) as count FROM Messages 
            WHERE created_at LIKE ?
        `).get(`${datePrefix}%`);
        const count = countRes ? countRes.count : 0;

        traffic.push({ hour: hourKey, datePrefix, count });
    }

    console.log('Generated Traffic Data:');
    console.table(traffic);
}

getStats();
