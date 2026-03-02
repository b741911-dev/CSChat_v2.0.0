const Database = require('better-sqlite3');
const path = require('path');
const bcrypt = require('bcryptjs');

// 데이터베이스 파일 경로 설정
const dbPath = path.join(__dirname, 'chat.db');
const db = new Database(dbPath);

// 성능 향상을 위한 WAL 모드 설정
db.pragma('journal_mode = WAL');

// 한국 시간 구하는 헬퍼 함수
function getKSTDate(date = new Date()) {
    try {
        return new Intl.DateTimeFormat('sv-SE', {
            timeZone: 'Asia/Seoul',
            year: 'numeric', month: '2-digit', day: '2-digit',
            hour: '2-digit', minute: '2-digit', second: '2-digit'
        }).format(date);
    } catch (e) {
        const kstGap = 9 * 60 * 60 * 1000;
        const kstDate = new Date(date.getTime() + kstGap);
        return kstDate.toISOString().replace('T', ' ').substring(0, 19);
    }
}

/**
 * 데이터베이스 초기화 및 테이블 생성
 */
function initDatabase() {
    // Users 테이블
    db.prepare(`
        CREATE TABLE IF NOT EXISTS Users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL,
            profile_img TEXT,
            is_admin INTEGER DEFAULT 0, -- 0: 일반, 1: 관리자
            mac_address TEXT, -- 접속기기 MAC 주소
            mac_binding INTEGER DEFAULT 0, -- 0: 미매핑, 1: 매핑됨
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    `).run();

    // ChatRooms 테이블
    db.prepare(`
        CREATE TABLE IF NOT EXISTS ChatRooms (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            room_type TEXT NOT NULL, -- '1:1' 또는 'group'
            room_identifier TEXT UNIQUE, -- 1:1의 경우 'user1_user2' 형태
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    `).run();

    // Participants 테이블
    db.prepare(`
        CREATE TABLE IF NOT EXISTS Participants (
            room_id INTEGER,
            user_id INTEGER,
            joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (room_id, user_id),
            FOREIGN KEY (room_id) REFERENCES ChatRooms(id) ON DELETE CASCADE,
            FOREIGN KEY (user_id) REFERENCES Users(id) ON DELETE CASCADE
        )
    `).run();

    // Messages 테이블
    db.prepare(`
        CREATE TABLE IF NOT EXISTS Messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            room_id INTEGER,
            sender_id INTEGER,
            content TEXT,
            file_url TEXT,
            thumbnail_url TEXT,
            type TEXT DEFAULT 'text', -- 'text', 'file', 'notice'
            read_count INTEGER DEFAULT 1, -- 안 읽은 사람 수 (1:1의 경우 기본 1)
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (room_id) REFERENCES ChatRooms(id) ON DELETE CASCADE,
            FOREIGN KEY (sender_id) REFERENCES Users(id) ON DELETE CASCADE
        )
    `).run();

    // NoticeReads 테이블 (공지사항 전용 읽음 추적)
    db.prepare(`
        CREATE TABLE IF NOT EXISTS NoticeReads (
            message_id INTEGER,
            user_id INTEGER,
            read_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (message_id, user_id),
            FOREIGN KEY (message_id) REFERENCES Messages(id) ON DELETE CASCADE,
            FOREIGN KEY (user_id) REFERENCES Users(id) ON DELETE CASCADE
        )
    `).run();

    // NoticeSchedules 테이블 (주기적 재발송 스케줄)
    db.prepare(`
        CREATE TABLE IF NOT EXISTS NoticeSchedules (
            message_id INTEGER PRIMARY KEY,
            interval_minutes INTEGER NOT NULL,
            last_run_at DATETIME,
            next_run_at DATETIME,
            is_active INTEGER DEFAULT 1,
            FOREIGN KEY (message_id) REFERENCES Messages(id) ON DELETE CASCADE
        )
    `).run();

    // BackupSchedules 테이블 (자동 백업 스케줄)
    db.prepare(`
        CREATE TABLE IF NOT EXISTS BackupSchedules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            interval_type TEXT NOT NULL, -- 'weekly', 'monthly', 'quarterly', 'yearly'
            backup_path TEXT,
            last_run_at DATETIME,
            next_run_at DATETIME,
            is_active INTEGER DEFAULT 1,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    `).run();

    console.log('데이터베이스 초기화 완료: chat.db');

    // SystemLogs 테이블 (시스템 로그 기록)
    db.prepare(`
        CREATE TABLE IF NOT EXISTS SystemLogs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            level TEXT, -- 'INFO', 'WARN', 'ERROR'
            category TEXT, -- 'AUTH', 'USER', 'SYSTEM', 'NOTICE', 'BACKUP'
            message TEXT,
            ip_address TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    `).run();

    // [마이그레이션] Users 테이블에 MAC 관련 컬럼 추가
    try {
        const userTableInfo = db.prepare("PRAGMA table_info(Users)").all();
        if (!userTableInfo.some(col => col.name === 'mac_address')) {
            db.prepare("ALTER TABLE Users ADD COLUMN mac_address TEXT").run();
            console.log('📢 Users 테이블에 mac_address 컬럼 추가됨');
        }
        if (!userTableInfo.some(col => col.name === 'mac_binding')) {
            db.prepare("ALTER TABLE Users ADD COLUMN mac_binding INTEGER DEFAULT 0").run();
            console.log('📢 Users 테이블에 mac_binding 컬럼 추가됨');
        }
        // [v2.5.3] OS/Device Info
        if (!userTableInfo.some(col => col.name === 'os_info')) {
            db.prepare("ALTER TABLE Users ADD COLUMN os_info TEXT").run();
            console.log('📢 Users 테이블에 os_info 컬럼 추가됨');
        }
        if (!userTableInfo.some(col => col.name === 'device_type')) {
            db.prepare("ALTER TABLE Users ADD COLUMN device_type TEXT").run();
            console.log('📢 Users 테이블에 device_type 컬럼 추가됨');
        }
        if (!userTableInfo.some(col => col.name === 'last_login_at')) {
            db.prepare("ALTER TABLE Users ADD COLUMN last_login_at DATETIME").run();
            console.log('📢 Users 테이블에 last_login_at 컬럼 추가됨');
        }
        if (!userTableInfo.some(col => col.name === 'previous_login_at')) {
            db.prepare("ALTER TABLE Users ADD COLUMN previous_login_at DATETIME").run();
            console.log('📢 Users 테이블에 previous_login_at 컬럼 추가됨');
        }
    } catch (e) {
        console.error('❌ Users 스키마 마이그레이션 오류:', e);
    }

    // [마이그레이션] Participants 테이블에 last_read_at, is_active 컬럼 추가
    try {
        const tableInfo = db.prepare("PRAGMA table_info(Participants)").all();

        // last_read_at 추가
        if (!tableInfo.some(col => col.name === 'last_read_at')) {
            db.prepare("ALTER TABLE Participants ADD COLUMN last_read_at DATETIME").run();
            console.log('📢 Participants 테이블에 last_read_at 컬럼 추가됨');
        }

        // is_active 추가
        if (!tableInfo.some(col => col.name === 'is_active')) {
            db.prepare("ALTER TABLE Participants ADD COLUMN is_active INTEGER DEFAULT 1").run();
            console.log('📢 Participants 테이블에 is_active 컬럼 추가됨');
        }
    } catch (e) {
        console.error('❌ Participants 스키마 마이그레이션 오류:', e);
    }

    // [마이그레이션] Messages 테이블에 thumbnail_url 컬럼 추가
    try {
        const tableInfo = db.prepare("PRAGMA table_info(Messages)").all();

        if (!tableInfo.some(col => col.name === 'thumbnail_url')) {
            db.prepare("ALTER TABLE Messages ADD COLUMN thumbnail_url TEXT").run();
            console.log('📢 Messages 테이블에 thumbnail_url 컬럼 추가됨');
        }
    } catch (e) {
        console.error('❌ Messages 스키마 마이그레이션 오류:', e);
    }

    // [전체 대화방 구현]
    try {
        const globalRoom = db.prepare("SELECT id FROM ChatRooms WHERE room_type = 'public'").get();
        let globalRoomId;

        if (!globalRoom) {
            const info = db.prepare("INSERT INTO ChatRooms (room_type, room_identifier) VALUES ('public', 'global')").run();
            globalRoomId = info.lastInsertRowid;
            console.log('📢 전체 대화방 자동 생성 완료 (ID: ' + globalRoomId + ')');
        } else {
            globalRoomId = globalRoom.id;
        }

        // 모든 유저를 전체 대화방에 초대
        const users = db.prepare("SELECT id FROM Users").all();
        let addedCount = 0;
        const joinedAt = getKSTDate();
        const insertStmt = db.prepare("INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)");
        const checkStmt = db.prepare("SELECT 1 FROM Participants WHERE room_id = ? AND user_id = ?");

        const runTransaction = db.transaction(() => {
            users.forEach(user => {
                if (!checkStmt.get(globalRoomId, user.id)) {
                    insertStmt.run(globalRoomId, user.id, joinedAt);
                    addedCount++;
                }
            });
        });
        runTransaction();

        if (addedCount > 0) console.log(`📢 전체 대화방에 ${addedCount}명의 유저 추가됨`);

    } catch (e) {
        console.error('❌ 전체 대화방 초기화 오류:', e);
    }

    // [v2.7.0] 초기 관리자 계정(admin) 자동 생성
    try {
        const adminUser = db.prepare('SELECT id FROM Users WHERE username = ?').get('admin');
        if (!adminUser) {
            console.log('📢 초기 관리자 계정(admin)이 없어 생성합니다. (PW: 1234)');
            // 비밀번호 해싱 (Salt Rounds 10)
            const hashedPassword = bcrypt.hashSync('1234', 10);

            // is_admin = 1로 생성
            const createdAt = getKSTDate();
            const info = db.prepare('INSERT INTO Users (username, password, is_admin, created_at) VALUES (?, ?, 1, ?)').run('admin', hashedPassword, createdAt);
            const adminId = info.lastInsertRowid;
            console.log(`✅ 관리자 계정 생성 완료 (ID: ${adminId})`);

            // 전체 대화방 초대
            const globalRoom = db.prepare("SELECT id FROM ChatRooms WHERE room_type = 'public'").get();
            if (globalRoom) {
                db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)').run(globalRoom.id, adminId, createdAt);
            }
        }
    } catch (e) {
        console.error('❌ 초기 관리자 계정 생성 실패:', e);
    }
}

/**
 * 트랜잭션 래퍼 함수
 */
const runTransaction = (fn) => db.transaction(fn)();

/**
 * 시스템 로그 기록 헬퍼
 */
function logSystem(level, category, message, req = null) {
    try {
        let ip = 'SYSTEM';
        if (req) {
            ip = req.headers['x-forwarded-for'] || req.connection.remoteAddress || 'UNKNOWN';
        }

        db.prepare(`
            INSERT INTO SystemLogs(level, category, message, ip_address, created_at)
            VALUES(?, ?, ?, ?, ?)
        `).run(level, category, message, ip, getKSTDate());

        // 콘솔에도 출력
        const color = level === 'ERROR' ? '\x1b[31m' : (level === 'WARN' ? '\x1b[33m' : '\x1b[36m');
        console.log(`${color} [${level}][${category}] ${message} \x1b[0m`);
    } catch (e) {
        console.error('로그 기록 실패:', e);
    }
}

module.exports = {
    db,
    initDatabase,
    runTransaction,
    logSystem
};
