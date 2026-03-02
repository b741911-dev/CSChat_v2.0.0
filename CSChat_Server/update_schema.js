const db = require('better-sqlite3')('./chat.db');

try {
    // room_name 컬럼이 이미 있는지 확인
    const columns = db.prepare('PRAGMA table_info(ChatRooms)').all();
    const hasRoomName = columns.some(col => col.name === 'room_name');

    if (hasRoomName) {
        console.log('✅ room_name 컬럼이 이미 존재합니다.');
    } else {
        db.prepare('ALTER TABLE ChatRooms ADD COLUMN room_name TEXT').run();
        console.log('✅ room_name 컬럼 추가 완료!');
    }

    // 확인
    const updatedColumns = db.prepare('PRAGMA table_info(ChatRooms)').all();
    console.log('\n현재 ChatRooms 테이블 구조:');
    console.table(updatedColumns);

} catch (e) {
    console.error('❌ 오류:', e.message);
} finally {
    db.close();
}
