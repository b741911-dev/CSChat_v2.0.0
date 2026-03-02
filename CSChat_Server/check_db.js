const Database = require('better-sqlite3');
const db = new Database('chat.db');
console.log('--- Participants ---');
console.log(db.prepare("PRAGMA table_info(Participants)").all());
console.log('--- Messages ---');
console.log(db.prepare("PRAGMA table_info(Messages)").all());
console.log('--- ChatRooms ---');
console.log(db.prepare("PRAGMA table_info(ChatRooms)").all());
db.close();
