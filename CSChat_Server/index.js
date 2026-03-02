const express = require('express');
const cors = require('cors');
const http = require('http');
const path = require('path');
const fs = require('fs');
const multer = require('multer');
const { ExpressPeerServer } = require('peer');
const { Server } = require('socket.io');
const bcrypt = require('bcryptjs');
const { db, initDatabase, runTransaction, logSystem } = require('./database');
const xlsx = require('xlsx');
const { exec } = require('child_process');

// Windows 서비스 환경에서도 콘솔 색상 강제 활성화
process.env.FORCE_COLOR = '3'; // 24-bit 색상 지원
const chalk = require('chalk');

// 타임존을 한국 시간(Asia/Seoul)으로 설정 (Windows에서는 Date 객체에 영향 없으므로 수동 계산 함수 사용)
process.env.TZ = 'Asia/Seoul';

// 한국 시간 구하는 헬퍼 함수 (특정 Date 객체 전달 가능)
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

// 색상 로그 헬퍼 함수 (긴급 키워드 감지 시 적색 적용)
function colorLog(message, forceRed = false) {
    const isEmergency = forceRed || (typeof message === 'string' && message.includes('긴급'));

    if (isEmergency) {
        console.log(chalk.red.bold(message));
    } else {
        console.log(message);
    }
}

const SALT_ROUNDS = 10;

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    cors: {
        origin: true,
        methods: ["GET", "POST"]
    },
    allowEIO3: true,
    transports: ['polling', 'websocket']
});

// [v2.0.0] 서버 기동 시간 (클라이언트에서 서버 재시작 감지용)
const startTime = Date.now();

// 모든 HTTP 요청 로깅 (소켓 포함 전체 로깅)
app.use((req, res, next) => {
    console.log(chalk.cyan(`[HTTP Req] ${req.method} ${req.url} (IP: ${req.ip}) (Upgrade: ${req.headers.upgrade})`));
    next();
});

const PORT = 3001; // 포트 변경 (충돌 방지)
const HOST = '0.0.0.0';

// WebSocket 업그레이드 요청 로깅
server.on('upgrade', (request, socket, head) => {
    console.log(chalk.yellow(`[Upgrade] URL: ${request.url}`));
});

// Engine.io 연결 로깅
io.engine.on("connection_error", (err) => {
    console.log(chalk.red(`[Engine.io Error] Code: ${err.code}, Message: ${err.message}, Context:`), err.context);
});

// 디렉토리 자동 생성 (public/uploads)
const uploadDir = path.join(__dirname, 'public', 'uploads');
if (!fs.existsSync(uploadDir)) {
    fs.mkdirSync(uploadDir, { recursive: true });
    console.log('디렉토리 생성 완료:', uploadDir);
}

// 미들웨어 설정
app.use(cors());
app.use(express.json());
// [Bug Fix] 가상 배포 경로 - 플랫폼별 자동 리다이렉션 (파일명 고정 문제를 해결하기 위함)
app.get('/api/ota/download', (req, res) => {
    const userAgent = req.headers['user-agent'] || '';

    // version.json에서 최신 버전 정보 가져오기 (파일명을 동적으로 구성하기 위함)
    let versionInfo = { platforms: { android: { version: '2.5.7' }, windows: { version: '2.5.9' } } };
    try {
        const data = fs.readFileSync(path.join(__dirname, 'public', 'version.json'), 'utf8');
        versionInfo = JSON.parse(data);
    } catch (e) {
        console.error('[OTA API] version.json read error:', e);
    }

    if (userAgent.toLowerCase().includes('windows')) {
        const winVer = versionInfo.platforms?.windows?.version || versionInfo.version;
        console.log(`[OTA API] Windows user detected. Redirecting to v${winVer} EXE.`);
        return res.redirect(`/downloads/cschat_win_v${winVer}.exe`);
    } else {
        const andVer = versionInfo.platforms?.android?.version || versionInfo.version;
        console.log(`[OTA API] Android user detected. Redirecting to v${andVer} APK.`);
        return res.redirect(`/downloads/cschat_and_v${andVer}.apk`);
    }
});

// [Debug] 업로드 파일 요청 로깅 (비디오/이미지 로딩 확인용)
app.use('/uploads', (req, res, next) => {
    console.log(chalk.magenta(`[Request] File: ${req.url} (Range: ${req.headers.range || 'None'})`));
    next();
});

// [Hotfix] APK MIME 타입 명시적 지정 (안드로이드 설치 문제 해결)
app.use(express.static('public', {
    setHeaders: (res, path) => {
        if (path.endsWith('.apk')) {
            res.set('Content-Type', 'application/vnd.android.package-archive');
            console.log(chalk.green(`[Static] Serving APK with correct MIME: ${path}`));
        }
    }
}));


// Multer 설정 (타임스탬프 기반 고유 파일명)
const storage = multer.diskStorage({
    destination: (req, file, cb) => {
        cb(null, uploadDir);
    },
    filename: (req, file, cb) => {
        const uniqueSuffix = Date.now() + '_' + Math.round(Math.random() * 1E9);
        // [Fix] 클라이언트가 보낸 별도 파일명 필드가 있으면 우선 사용 (한글 깨짐 방지)
        let utf8Name = req.body.original_filename || file.originalname;
        try {
            // 헤더에서 온 경우에만 latin1 보정 시도
            if (!req.body.original_filename) {
                utf8Name = Buffer.from(file.originalname, 'latin1').toString('utf8');
            }
        } catch (e) { }
        cb(null, uniqueSuffix + '_' + utf8Name);
    }
});
const upload = multer({ storage: storage });

// 데이터베이스 초기화
initDatabase();

// 기본 라우트 (다운로드 페이지)
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// 서버 상태 확인 API
app.get('/api/status', (req, res) => {
    res.json({
        message: 'CSChat 백엔드 서버가 정상적으로 작동 중입니다.',
        status: 'online',
        host: HOST,
        port: PORT,
        endpoints: {
            login: '/api/login',
            users: '/api/users',
            upload: '/api/upload',
            peerjs: '/peerjs'
        }
    });
});

/**
 * [POST] 일반 파일/사진 업로드 API
 */
app.post('/api/upload', upload.single('file'), (req, res) => {
    if (!req.file) {
        return res.status(400).json({ error: '파일이 업로드되지 않았습니다.' });
    }

    try {
        const fileUrl = `/uploads/${req.file.filename}`;
        // [Fix] 필드 우선 사용 및 인코딩 보정
        let originalName = req.body.original_filename || req.file.originalname;
        if (!req.body.original_filename) {
            try {
                originalName = Buffer.from(req.file.originalname, 'latin1').toString('utf8');
            } catch (e) { }
        }

        const ext = path.extname(originalName).toLowerCase();
        const videoExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.webm'];
        const isVideo = req.file.mimetype.startsWith('video/') || videoExtensions.includes(ext);
        let thumbnailUrl = null;

        if (isVideo) {
            const thumbName = req.file.filename.split('.')[0] + '_thumb.jpg';
            const videoPath = path.join(__dirname, 'public', 'uploads', req.file.filename);
            const thumbPath = path.join(__dirname, 'public', 'uploads', thumbName);

            // [Important] public 폴더 경로 포함 (uploads가 public 안에 있음)
            // 1. FFmpeg를 사용하여 첫 프레임 썸네일 생성
            exec(`ffmpeg -i "${videoPath}" -ss 00:00:00.100 -vframes 1 "${thumbPath}"`, (error) => {
                if (error) {
                    console.error('[Upload] 썸네일 생성 실패:', error);
                } else {
                    console.log(chalk.blue(`[Upload] 썸네일 생성 완료: ${thumbName}`));
                }

                // 2. 모바일 스트리밍 무한 버퍼링 방지를 위한 faststart 및 고속 H.264 인코딩 (HEVC 코덱 앱 프리징 방지)
                const faststartTempPath = path.join(__dirname, 'public', 'uploads', 'fast_' + req.file.filename);
                // Windows 무한로딩 / Android 블랙 스크린 해결: 하드웨어 가속 호환성 극대화 (Baseline/Level3.0/짝수해상도), 소리 작아짐 방지 오디오 카피
                exec(`ffmpeg -i "${videoPath}" -c:v libx264 -profile:v baseline -level 3.0 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -preset veryfast -crf 28 -c:a copy -movflags +faststart "${faststartTempPath}"`, (fastError) => {
                    if (!fastError) {
                        try {
                            fs.unlinkSync(videoPath);
                            fs.renameSync(faststartTempPath, videoPath);
                            console.log(chalk.green(`[Upload] 비디오 faststart 스트리밍 최적화 완료: ${req.file.filename}`));
                        } catch (fsErr) {
                            console.error('[Upload] faststart 파일 교체 에러:', fsErr);
                        }
                    } else {
                        console.error('[Upload] 비디오 faststart 최적화 실패:', fastError);
                        // 실패 시 원본(videoPath)이 그대로 유지되므로 스트리밍은 느리지만 다운로드 등은 가능합니다.
                    }

                    // 모든 작업 완료 후 한 번만 응답
                    res.json({
                        success: true,
                        filename: originalName,
                        savedName: req.file.filename,
                        fileUrl: fileUrl,
                        thumbnailUrl: error ? null : `/uploads/${thumbName}`,
                        mimetype: req.file.mimetype,
                        size: req.file.size
                    });
                });
            });
        } else {
            // 이미지 또는 일반 파일인 경우 즉시 응답
            console.log(chalk.green(`[Upload] 파일 업로드 완료: ${originalName} -> ${req.file.filename}`));
            res.json({
                success: true,
                filename: originalName,
                savedName: req.file.filename,
                fileUrl: fileUrl,
                thumbnailUrl: null,
                mimetype: req.file.mimetype,
                size: req.file.size
            });
        }
    } catch (e) {
        console.error('[Upload] 업로드 처리 에러:', e);
        res.status(500).json({ error: '업로드 처리 중 오류가 발생했습니다.' });
    }
});

/**
 * [POST] 관리자 유저 생성 API
 */
app.post('/api/admin/users', async (req, res) => {
    const { username, password } = req.body;
    if (!username || !password) return res.status(400).json({ error: '아이디와 비밀번호 필수' });

    try {
        const existingUser = db.prepare('SELECT id FROM Users WHERE username = ?').get(username);
        if (existingUser) return res.status(400).json({ error: '이미 존재하는 아이디' });

        const hashedPassword = await bcrypt.hash(password, SALT_ROUNDS);
        const info = db.prepare('INSERT INTO Users (username, password) VALUES (?, ?)').run(username, hashedPassword);

        const newUser = { id: info.lastInsertRowid, username };

        // [Fix] 전체 대화방(global)에 자동 참여
        const globalRoom = db.prepare('SELECT id FROM ChatRooms WHERE room_identifier = ? AND room_type = ?').get('global', 'public');
        if (globalRoom) {
            const joinedAt = getKSTDate();
            db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)').run(globalRoom.id, newUser.id, joinedAt);
            console.log(`[Admin] 새 사용자 ${username} (ID: ${newUser.id})를 전체 대화방(Room ${globalRoom.id})에 자동 참여시킴`);
        }

        // [Fix] 사용자 등록 시 모든 클라이언트에게 user_added 이벤트 브로드캐스트
        io.emit('user_added', newUser);
        logSystem('INFO', 'USER', `새 사용자 등록: ${username} (ID: ${newUser.id})`, req);
        console.log(`[Admin] 새 사용자 등록: ${username} (ID: ${newUser.id}) - user_added 이벤트 브로드캐스트`);

        res.status(201).json({ success: true, user: newUser });
    } catch (e) {
        console.error('[Admin] 사용자 등록 오류:', e);
        res.status(500).json({ error: '등록 실패' });
    }
});

/**
 * [DELETE] 관리자 유저 삭제 API
 */
app.delete('/api/admin/users/:id', (req, res) => {
    const { id } = req.params;
    try {
        db.prepare('DELETE FROM Users WHERE id = ?').run(id);
        logSystem('WARN', 'USER', `사용자 삭제 (ID: ${id})`, req);
        res.json({ success: true });
    } catch (e) {
        logSystem('ERROR', 'USER', `사용자 삭제 실패 (ID: ${id})`, req);
        res.status(500).json({ error: '삭제 실패' });
    }
});

/**
 * [DELETE] [v2.5.2] 관리자 대화방 삭제 API
 */
app.delete('/api/admin/rooms/:id', (req, res) => {
    const { id } = req.params;
    try {
        // [v2.6.0] 전체 대화방 삭제 방지
        const room = db.prepare('SELECT room_identifier FROM ChatRooms WHERE id = ?').get(id);
        if (room && room.room_identifier === 'global') {
            return res.status(400).json({ error: '전체 대화방은 삭제할 수 없습니다. 대화 초기화 기능을 사용하세요.' });
        }

        // 관련된 데이터 모두 삭제 (Cascade가 설정되어 있지 않을 수 있으므로 명시적 삭제 권장)
        runTransaction(() => {
            db.prepare('DELETE FROM NoticeReads WHERE message_id IN (SELECT id FROM Messages WHERE room_id = ?)').run(id);
            db.prepare('DELETE FROM Messages WHERE room_id = ?').run(id);
            db.prepare('DELETE FROM Participants WHERE room_id = ?').run(id);
            db.prepare('DELETE FROM ChatRooms WHERE id = ?').run(id);
        });

        // 소켓 알림 (방 폭파)
        io.to(`room_${id}`).emit('force_logout', { message: '관리자에 의해 대화방이 삭제되었습니다.' });
        io.to('admin_room').emit('room_updated', { roomId: -1 }); // 목록 갱신 트리거

        logSystem('WARN', 'ROOM', `대화방 강제 삭제 (ID: ${id})`, req);
        res.json({ success: true });
    } catch (e) {
        console.error(e);
        logSystem('ERROR', 'ROOM', `대화방 삭제 실패 (ID: ${id})`, req);
        res.status(500).json({ error: '삭제 실패' });
    }
});

/**
 * [POST] [v2.6.0] 대화방 대화내용 초기화 API
 */
app.post('/api/admin/rooms/:id/clear', (req, res) => {
    const { id } = req.params;
    try {
        runTransaction(() => {
            db.prepare('DELETE FROM NoticeReads WHERE message_id IN (SELECT id FROM Messages WHERE room_id = ?)').run(id);
            db.prepare('DELETE FROM Messages WHERE room_id = ?').run(id);
        });

        // 소켓 알림 (대화창 갱신 트리거)
        io.to(`room_${id}`).emit('clear_chat', { roomId: id });
        io.to('admin_room').emit('room_updated', { roomId: id });

        logSystem('WARN', 'ROOM', `대화방 대화내용 초기화 (ID: ${id})`, req);
        res.json({ success: true });
    } catch (e) {
        console.error(e);
        logSystem('ERROR', 'ROOM', `대화 내용 초기화 실패 (ID: ${id})`, req);
        res.status(500).json({ error: '초기화 실패' });
    }
});

/**
 * [DELETE] [v2.5.2] 공지사항 삭제 API
 */
app.delete('/api/admin/notices/:id', (req, res) => {
    const { id } = req.params;
    try {
        runTransaction(() => {
            db.prepare('DELETE FROM NoticeReads WHERE message_id = ?').run(id);
            db.prepare('DELETE FROM NoticeSchedules WHERE message_id = ?').run(id);
            db.prepare('DELETE FROM Messages WHERE id = ? AND type = \'notice\'').run(id);
        });

        // [v2.5.19] 실시간 삭제 브로드캐스팅
        io.emit('notice_deleted', { id });

        logSystem('INFO', 'NOTICE', `공지사항 삭제 (ID: ${id})`, req);
        res.json({ success: true });
    } catch (e) {
        res.status(500).json({ error: '공지 삭제 실패' });
    }
});

/**
 * [PATCH] [v2.5.2] 공지사항 수정 API
 */
app.patch('/api/admin/notices/:id', (req, res) => {
    const { id } = req.params;
    const { content } = req.body;
    try {
        db.prepare('UPDATE Messages SET content = ? WHERE id = ? AND type = \'notice\'').run(content, id);

        // [v2.5.19] 실시간 수정 브로드캐스팅
        io.emit('notice_updated', { id, content });

        logSystem('INFO', 'NOTICE', `공지사항 수정 (ID: ${id})`, req);
        res.json({ success: true });
    } catch (e) {
        res.status(500).json({ error: '공지 수정 실패' });
    }
});

/**
 * [POST] 그룹 채팅방 생성 API
 */
app.post('/api/rooms/group', (req, res) => {
    const { groupName, memberIds } = req.body;

    if (!groupName || !memberIds || memberIds.length < 2) {
        return res.status(400).json({ error: '그룹 이름과 최소 2명의 멤버가 필요합니다' });
    }

    try {
        const createdAt = getKSTDate();
        const roomIdentifier = `group_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

        // 그룹 채팅방 생성
        const roomInfo = db.prepare(`
            INSERT INTO ChatRooms (room_type, room_identifier, room_name, created_at)
            VALUES (?, ?, ?, ?)
        `).run('group', roomIdentifier, groupName, createdAt);

        const roomId = roomInfo.lastInsertRowid;

        // 모든 멤버를 Participants에 추가
        const insertParticipant = db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)');
        memberIds.forEach(userId => {
            insertParticipant.run(roomId, userId, createdAt);
        });

        console.log(`[API] 그룹 채팅방 생성: ${groupName} (ID: ${roomId}), 멤버: ${memberIds.length}명`);

        // 모든 멤버에게 group_created 이벤트 브로드캐스트
        io.emit('group_created', { roomId, groupName, memberIds });
        // 어드민 실시간 목록 갱신 알림
        io.to('admin_room').emit('room_updated', { roomId });

        res.status(201).json({
            success: true,
            room: {
                id: roomId,
                roomName: groupName,
                roomType: 'group',
                memberIds
            }
        });
    } catch (e) {
        console.error('[API] 그룹 생성 오류:', e);
        res.status(500).json({ error: '그룹 생성 실패' });
    }
});

/**
 * [POST] 로그인 API (bcrypt 검증)
 */
app.post('/api/login', async (req, res) => {
    const { username, password, macAddress } = req.body;
    console.log(`[Login Attempt] User: ${username}, DeviceID: ${macAddress}`);
    try {
        const user = db.prepare('SELECT * FROM Users WHERE username = ?').get(username);
        if (!user) {
            console.log(`[Login Alert] User ${username} not found in DB`);
            return res.status(401).json({ error: '인증 실패' });
        }

        const isMatch = await bcrypt.compare(password, user.password);
        if (!isMatch) {
            logSystem('WARN', 'AUTH', `로그인 실패 (비빌번호 불일치): ${username}`, req);
            return res.status(401).json({ error: '인증 실패' });
        }

        // MAC 매핑 처리
        if (macAddress && macAddress.trim() !== '') {
            if (user.mac_binding === 1) {
                // 매핑됨: 등록된 MAC과 일치해야 함
                if (user.mac_address && user.mac_address !== macAddress) {
                    logSystem('WARN', 'AUTH', `로그인 거부 (기기 불일치): ${username}, Client: ${macAddress}, DB: ${user.mac_address}`, req);
                    return res.status(403).json({ error: '등록되지 않은 기기입니다.' });
                }
            }

            // 첫 로그인 시 또는 매핑 해제 상태에서 MAC가 비어있으면 자동 저장
            if (!user.mac_address) {
                db.prepare('UPDATE Users SET mac_address = ? WHERE id = ?').run(macAddress, user.id);
                console.log(`[Login] 사용자 ${username}의 기기 식별자 자동 등록: ${macAddress}`);
            }
        }

        // [v2.5.3] User-Agent Analysis
        const userAgent = req.headers['user-agent'] || '';

        // [v2.5.4] Client-Injected Info Priority
        let osInfo = req.body.osInfo;
        let deviceType = req.body.deviceType;

        if (!osInfo) {
            osInfo = 'Unknown';
            deviceType = 'Desktop';

            if (/android/i.test(userAgent)) {
                osInfo = 'Android';
                deviceType = 'Mobile';
                const match = userAgent.match(/Android\s([0-9.]+)/);
                if (match) osInfo += ` ${match[1]}`;
            } else if (/windows/i.test(userAgent)) {
                osInfo = 'Windows';
                if (/Windows NT 10.0/i.test(userAgent)) osInfo += ' 10/11';
                else if (/Windows NT 6.3/i.test(userAgent)) osInfo += ' 8.1';
                else if (/Windows NT 6.2/i.test(userAgent)) osInfo += ' 8';
                else if (/Windows NT 6.1/i.test(userAgent)) osInfo += ' 7';
            } else if (/iphone|ipad|ipod/i.test(userAgent)) {
                osInfo = 'iOS';
                deviceType = 'Mobile';
            } else if (/mac os/i.test(userAgent)) osInfo = 'macOS';
            else if (/linux/i.test(userAgent)) osInfo = 'Linux';
        }

        // Update DB (v2.5.3: OS/Device Info, v2.5.5: Last Login -> Previous Login Logic)
        const loginTime = getKSTDate();

        // 기존 last_login_at을 previous_login_at으로 백업하고, 새로운 시간으로 갱신
        db.prepare(`
            UPDATE Users 
            SET os_info = ?, 
                device_type = ?, 
                previous_login_at = last_login_at, 
                last_login_at = ? 
            WHERE id = ?
        `).run(osInfo || 'Unknown', deviceType, loginTime, user.id);

        if (user.is_admin === 1) {
            logSystem('INFO', 'AUTH', `관리자 로그인 성공: ${username}`, req);
        }
        res.json({ success: true, user: { id: user.id, username: user.username, isAdmin: user.is_admin === 1 } });
    } catch (e) {
        console.error('[Login Error]', e);
        logSystem('ERROR', 'AUTH', `로그인 시스템 오류: ${username}`, req);
        res.status(500).json({ error: '로그인 실패' });
    }
});

/**
 * [GET] 어드민 대시보드 통계 API
 */
app.get('/api/admin/stats', async (req, res) => {
    try {
        const totalUsers = db.prepare('SELECT COUNT(*) as count FROM Users').get().count;
        const onlineCount = onlineUsers.size;
        const today = getKSTDate().split(' ')[0];
        const todayMessages = db.prepare('SELECT COUNT(*) as count FROM Messages WHERE created_at LIKE ?').get(`${today}%`).count;

        // 24시간 타임라인 생성 및 실제 데이터 집계 (빈 시간대 포함)
        const traffic = [];
        const now = new Date();
        const kstGap = 9 * 60 * 60 * 1000;

        for (let i = 23; i >= 0; i--) {
            const targetTimeUTC = new Date(now.getTime() - (i * 60 * 60 * 1000));
            const targetTimeKST = new Date(targetTimeUTC.getTime() + kstGap);

            const hourKey = targetTimeKST.toISOString().substring(11, 13) + ':00';
            const datePrefix = targetTimeKST.toISOString().replace('T', ' ').substring(0, 14); // "YYYY-MM-DD HH:" (KST for DB)

            const count = db.prepare(`
                SELECT COUNT(*) as count FROM Messages 
                WHERE created_at LIKE ?
            `).get(`${datePrefix}%`).count;

            traffic.push({ hour: hourKey, count });
        }

        // DB 용량 (Approx)
        const dbPath = path.join(__dirname, 'chat.db');
        const stats = fs.statSync(dbPath);
        const dbSizeMB = (stats.size / (1024 * 1024)).toFixed(2);

        // [v2.5.5] Admin Last Login (For Header) - Use previous_login_at (직전 접속 시간)
        // If previous_login_at is null (first time after update), use currently active last_login_at fallback or just null
        const adminUser = db.prepare('SELECT previous_login_at, last_login_at FROM Users WHERE is_admin = 1 ORDER BY last_login_at DESC LIMIT 1').get();
        const displayTime = adminUser ? (adminUser.previous_login_at || adminUser.last_login_at) : null;

        res.json({
            totalUsers,
            onlineCount,
            todayMessages,
            dbSize: `${dbSizeMB} MB`,
            traffic,
            adminLastLogin: displayTime,
            systemLogs: [
                { time: getKSTDate(), message: '관리 시스템 통계가 갱신되었습니다.' }
            ]
        });
    } catch (e) {
        console.error('[Admin API] Stats Error:', e);
        res.status(500).json({ error: '통계 조회 실패' });
    }
});

/**
 * [GET] 시스템 로그 조회 API
 */
app.get('/api/admin/logs', (req, res) => {
    try {
        const { limit = 50, offset = 0 } = req.query;
        const logs = db.prepare(`
            SELECT * FROM SystemLogs 
            ORDER BY id DESC 
            LIMIT ? OFFSET ?
        `).all(limit, offset);

        const total = db.prepare('SELECT COUNT(*) as count FROM SystemLogs').get().count;

        res.json({ logs, total });
    } catch (e) {
        res.status(500).json({ error: '로그 조회 실패' });
    }
});

/**
 * [POST] 사용자 비밀번호 초기화 (관리자용)
 */
app.post('/api/admin/users/:id/reset-password', async (req, res) => {
    const { id } = req.params;
    try {
        const newPassword = '1234'; // 기본 초기화 비밀번호
        const hashedPassword = await bcrypt.hash(newPassword, SALT_ROUNDS);
        db.prepare('UPDATE Users SET password = ? WHERE id = ?').run(hashedPassword, id);
        res.json({ success: true, message: '비밀번호가 1234로 초기화되었습니다.' });
    } catch (e) {
        res.status(500).json({ error: '초기화 실패' });
    }
});

/**
 * [PATCH] 사용자 정보 수정 (관리자용 - 권한 변경 등)
 */
app.patch('/api/admin/users/:id', (req, res) => {
    const { id } = req.params;
    const { is_admin, username, mac_binding, mac_address } = req.body;
    try {
        if (is_admin !== undefined) {
            db.prepare('UPDATE Users SET is_admin = ? WHERE id = ?').run(is_admin, id);
        }
        if (username !== undefined && username.trim() !== '') {
            db.prepare('UPDATE Users SET username = ? WHERE id = ?').run(username.trim(), id);
        }
        if (mac_binding !== undefined) {
            db.prepare('UPDATE Users SET mac_binding = ? WHERE id = ?').run(mac_binding, id);
        }
        if (mac_address !== undefined) {
            db.prepare('UPDATE Users SET mac_address = ? WHERE id = ?').run(mac_address, id);
        }
        res.json({ success: true });
    } catch (e) {
        res.status(500).json({ error: '수정 실패' });
    }
});

/**
 * [GET] 공지사항 읽음 확인 명단 API
 */
app.get('/api/admin/notice/:messageId/readers', (req, res) => {
    const { messageId } = req.params;
    try {
        // 1. 공지사항 메시지 정보 확인
        const notice = db.prepare("SELECT room_id FROM Messages WHERE id = ? AND type = 'notice'").get(messageId);
        if (!notice) return res.status(404).json({ error: '공지사항을 찾을 수 없습니다.' });

        // 2. 해당 방의 전체 참여자 목록 (발신자 제외)
        const allParticipants = db.prepare(`
            SELECT u.id, u.username 
            FROM Participants p
            JOIN Users u ON p.user_id = u.id
            WHERE p.room_id = ? AND u.id != 1
        `).all(notice.room_id);

        // 3. 읽은 사람 목록
        const readers = db.prepare(`
            SELECT u.id, u.username, nr.read_at
            FROM NoticeReads nr
            JOIN Users u ON nr.user_id = u.id
            WHERE nr.message_id = ?
        `).all(messageId);

        const readUserIds = new Set(readers.map(r => r.id));
        const unreaders = allParticipants.filter(p => !readUserIds.has(p.id));

        res.json({
            notice_id: messageId,
            total: allParticipants.length,
            readCount: readers.length,
            unreadCount: unreaders.length,
            readers,
            unreaders
        });
    } catch (e) {
        console.error('[Admin] 공지 읽음 조회 오류:', e);
        res.status(500).json({ error: '조회 실패' });
    }
});

/**
 * [GET] 특정 공지의 스케줄 정보 조회
 */
app.get('/api/admin/notice/:messageId/schedule', (req, res) => {
    const { messageId } = req.params;
    try {
        const schedule = db.prepare('SELECT * FROM NoticeSchedules WHERE message_id = ?').get(messageId);
        res.json(schedule || null);
    } catch (e) {
        res.status(500).json({ error: '스케줄 조회 실패' });
    }
});

/**
 * [POST] 특정 공지 미확인자에게 수동 재발송
 */
app.post('/api/admin/notice/:messageId/resend', async (req, res) => {
    const { messageId } = req.params;
    try {
        const notice = db.prepare("SELECT * FROM Messages WHERE id = ? AND type = 'notice'").get(messageId);
        if (!notice) return res.status(404).json({ error: '공지사항을 찾을 수 없습니다.' });

        // 미확인자 목록 조회
        const allParticipants = db.prepare(`
            SELECT u.id FROM Participants p
            JOIN Users u ON p.user_id = u.id
            WHERE p.room_id = ? AND u.id != 1
        `).all(notice.room_id);

        const readers = db.prepare('SELECT user_id FROM NoticeReads WHERE message_id = ?').all(messageId);
        const readUserIds = new Set(readers.map(r => r.user_id));
        const unreaders = allParticipants.filter(p => !readUserIds.has(p.id));

        if (unreaders.length === 0) {
            return res.json({ success: true, message: '모든 사용자가 이미 읽었습니다.', count: 0 });
        }

        const messageData = {
            id: notice.id,
            roomId: notice.room_id,
            senderId: notice.sender_id,
            senderName: '시스템 관리자',
            content: notice.content,
            type: 'notice',
            isResend: true,
            createdAt: notice.created_at
        };

        // 미확인자들에게만 소켓 발송
        unreaders.forEach(u => {
            const socketId = userSockets.get(u.id);
            if (socketId) {
                io.to(socketId).emit('receive_message', messageData);
                io.to(socketId).emit('notice', messageData);
            }
        });

        logSystem('INFO', 'NOTICE', `[공지 재발송] ${unreaders.length}명에게 재발송 완료 (ID: ${messageId})`, req);
        res.json({ success: true, count: unreaders.length });
    } catch (e) {
        console.error('[Admin] 공지 재발송 오류:', e);
        res.status(500).json({ error: '재발송 실패' });
    }
});

/**
 * [POST] 공지 주기적 재발송 스케줄 설정
 */
app.post('/api/admin/notice/:messageId/schedule', (req, res) => {
    const { messageId } = req.params;
    const { interval } = req.body; // minutes

    if (!interval || interval < 1) return res.status(400).json({ error: '올바른 주기를 입력하세요.' });

    try {
        const nextRun = new Date(Date.now() + interval * 60000);
        const nextRunStr = getKSTDate(nextRun);

        db.prepare(`
            INSERT INTO NoticeSchedules (message_id, interval_minutes, next_run_at, is_active)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(message_id) DO UPDATE SET
                interval_minutes = excluded.interval_minutes,
                next_run_at = excluded.next_run_at,
                is_active = 1
        `).run(messageId, interval, nextRunStr);

        res.json({ success: true, next_run_at: nextRunStr });
    } catch (e) {
        console.error('[Admin] 스케줄 설정 오류:', e);
        res.status(500).json({ error: '스케줄 설정 실패' });
    }
});

/**
 * [DELETE] 공지 재발송 스케줄 취소
 */
app.delete('/api/admin/notice/:messageId/schedule', (req, res) => {
    const { messageId } = req.params;
    try {
        db.prepare('DELETE FROM NoticeSchedules WHERE message_id = ?').run(messageId);
        res.json({ success: true });
    } catch (e) {
        res.status(500).json({ error: '스케줄 취소 실패' });
    }
});

/**
 * [POST] 전체 공지 발송 API (관리자용)
 */
app.post('/api/admin/notice', async (req, res) => {
    const { content } = req.body;
    if (!content) return res.status(400).json({ error: '공지 내용을 입력하세요.' });

    try {
        // 1. 전체 대화방(Global Room) 조회
        const globalRoom = db.prepare("SELECT id FROM ChatRooms WHERE room_type = 'public' AND room_identifier = 'global'").get();
        if (!globalRoom) return res.status(404).json({ error: '전체 대화방을 찾을 수 없습니다.' });

        const roomId = globalRoom.id;
        // [Fix] 하드코딩된 ID 1 대신 실제 존재하는 관리자 ID 조회 (FK 제약 조건 오류 해결)
        const adminUser = db.prepare("SELECT id FROM Users WHERE is_admin = 1 LIMIT 1").get();
        const senderId = adminUser ? adminUser.id : 1;
        const createdAt = getKSTDate();

        // 2. 초기 읽음 카운트 계산 (전체 참여자 - 1)
        const pCount = db.prepare('SELECT COUNT(*) as count FROM Participants WHERE room_id = ?').get(roomId).count;
        const initialReadCount = Math.max(0, pCount - 1);

        // [v2.5.26] 공지 내용 앞에 "긴급" 키워드 자동 추가 (클라이언트 적색 테마 트리거)
        const emergencyContent = content.includes('긴급') ? content : `긴급 ${content}`;

        // 3. DB 저장 (전체 공지용 특수 타입 'notice')
        const info = db.prepare(`
            INSERT INTO Messages (room_id, sender_id, content, type, read_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        `).run(roomId, senderId, emergencyContent, 'notice', initialReadCount, createdAt);

        const messageData = {
            id: info.lastInsertRowid,
            roomId: roomId,
            senderId: senderId,
            senderName: '시스템 관리자',
            content: emergencyContent,
            type: 'notice',
            readCount: initialReadCount,
            createdAt: createdAt,
            isGroup: true,
            roomName: '전체 대화방'
        };

        // 4. 실시간 브로드캐스트
        io.to(`room_${roomId}`).emit('receive_message', messageData);
        // 어드민 모니터링 실시간 갱신을 위해 어드민 룸에도 전송
        io.to('admin_room').emit('receive_message', messageData);

        // 추가: 모든 사용자에게 notice 이벤트 전송 및 어드민 룸 업데이트 알림
        io.emit('notice', messageData);
        io.to('admin_room').emit('room_updated', { roomId: roomId });

        logSystem('INFO', 'NOTICE', `[긴급 공지] 발송 완료: ${emergencyContent}`, req);
        console.log(chalk.red.bold(`[Admin] 긴급 공지 발송 및 저장 완료 (ID: ${info.lastInsertRowid})`));

        res.status(201).json({ success: true, message: messageData });
    } catch (e) {
        logSystem('ERROR', 'NOTICE', `긴급 공지 발송 실패: ${e.message}`, req);
        console.error(chalk.red('[Admin] 공지 발송 실패:'), e);
        res.status(500).json({ error: '공지 발송 실패' });
    }
});

/**
 * [GET] 모든 공지 내역 조회 API
 */
app.get('/api/admin/notices', async (req, res) => {
    try {
        const notices = db.prepare(`
            SELECT m.*, u.username as sender_name,
                   (SELECT COUNT(*) FROM NoticeReads nr WHERE nr.message_id = m.id) as read_count,
                   (SELECT COUNT(*) FROM Participants p WHERE p.room_id = m.room_id) as total_participants
            FROM Messages m
            LEFT JOIN Users u ON m.sender_id = u.id
            WHERE m.type = 'notice'
            ORDER BY m.created_at DESC
        `).all();
        res.json(notices);
    } catch (e) {
        console.error('[Admin] 공지 목록 조회 오류:', e);
        res.status(500).json({ error: '조회 실패' });
    }
});

/**
 * [POST] 비밀번호 변경 API
 */
app.post('/api/users/change-password', async (req, res) => {
    const { userId, currentPassword, newPassword } = req.body;

    if (!userId || !currentPassword || !newPassword) {
        return res.status(400).json({ error: '모든 필드를 입력해주세요' });
    }

    try {
        const user = db.prepare('SELECT password FROM Users WHERE id = ?').get(userId);
        if (!user) {
            return res.status(404).json({ error: '사용자를 찾을 수 없습니다' });
        }

        const isMatch = await bcrypt.compare(currentPassword, user.password);
        if (!isMatch) {
            return res.status(401).json({ error: '현재 비밀번호가 일치하지 않습니다' });
        }

        const hashedPassword = await bcrypt.hash(newPassword, SALT_ROUNDS);
        db.prepare('UPDATE Users SET password = ? WHERE id = ?').run(hashedPassword, userId);

        console.log(`[API] 유저 ${userId} 비밀번호 변경 성공`);
        res.json({ success: true });
    } catch (e) {
        console.error('[API] 비밀번호 변경 실패:', e);
        res.status(500).json({ error: '비밀번호 변경 중 오류가 발생했습니다' });
    }
});

// 온라인 사용자 추적
const onlineUsers = new Set();
const userSockets = new Map(); // userId -> socketId

app.get('/api/unread/total', (req, res) => {
    const userId = parseInt(req.query.userId);
    if (isNaN(userId)) {
        return res.status(400).json({ error: 'userId is required' });
    }

    try {
        // [Fix] 1:1은 read_count로, 그룹채팅은 last_read_at으로 안읽은 메시지 정확히 계산
        const result = db.prepare(`
            SELECT COUNT(*) as count
            FROM Messages m
            INNER JOIN Participants p ON m.room_id = p.room_id
            INNER JOIN ChatRooms r ON m.room_id = r.id
            WHERE p.user_id = ? AND p.is_active = 1
            AND m.sender_id != ?
            AND (
                (r.room_type = '1:1' AND m.read_count > 0)
                OR 
                (r.room_type != '1:1' AND m.created_at > IFNULL(p.last_read_at, p.joined_at))
            )
        `).get(userId, userId);

        res.json({ count: result.count || 0 });
    } catch (e) {
        console.error('[API] /api/unread/total error:', e);
        res.status(500).json({ error: 'Internal Server Error' });
    }
});

// --- API Routes ---

/**
 * [GET] 모든 대화방 목록 조회 (관리자용 모니터링)
 */
app.get('/api/admin/rooms', (req, res) => {
    try {
        const rooms = db.prepare(`
            SELECT r.*, 
            (SELECT content FROM Messages WHERE room_id = r.id ORDER BY created_at DESC LIMIT 1) as last_message,
            (SELECT created_at FROM Messages WHERE room_id = r.id ORDER BY created_at DESC LIMIT 1) as last_message_at,
            (SELECT COUNT(*) FROM Participants WHERE room_id = r.id) as participant_count,
            (
                SELECT GROUP_CONCAT(u.username, ', ')
                FROM Participants p
                JOIN Users u ON p.user_id = u.id
                WHERE p.room_id = r.id
            ) as participants
            FROM ChatRooms r
            ORDER BY COALESCE(last_message_at, r.created_at) DESC
        `).all();
        res.json(rooms);
    } catch (e) {
        res.status(500).json({ error: '목록 조회 실패' });
    }
});

/**
 * 백업 실행 공통 로직
 */
function performBackup(customPath, req = null) {
    const timestamp = getKSTDate().replace(/[- :]/g, '').substring(2, 12); // YYMMDDHHMM
    const backupFileName = `chat${timestamp}.db`;
    const backupDir = customPath || path.join(__dirname, 'backups');
    const backupPath = path.join(backupDir, backupFileName);

    if (!fs.existsSync(backupDir)) {
        fs.mkdirSync(backupDir, { recursive: true });
    }

    db.prepare(`VACUUM INTO ?`).run(backupPath);
    logSystem('INFO', 'BACKUP', `시스템 백업 생성: ${backupFileName}`, req);
    return { fileName: backupFileName, fullPath: backupPath };
}

/**
 * 다음 스케줄 일자 계산 루틴
 */
function getNextScheduledDate(type) {
    const now = new Date();
    let next = new Date();
    if (type === 'weekly') {
        next.setDate(now.getDate() + 7);
    } else if (type === 'monthly') {
        next.setMonth(now.getMonth() + 1);
    } else if (type === 'quarterly') {
        const q = Math.floor(now.getMonth() / 3);
        const targetMonth = (q + 1) * 3; // 3, 6, 9, 12
        next = new Date(now.getFullYear(), targetMonth, 0, 23, 59, 59);
        if (next <= now) {
            next = new Date(now.getFullYear(), targetMonth + 3, 0, 23, 59, 59);
        }
    } else if (type === 'yearly') {
        next = new Date(now.getFullYear(), 12, 0, 23, 59, 59); // Dec 31
        if (next <= now) {
            next = new Date(now.getFullYear() + 1, 12, 0, 23, 59, 59);
        }
    }
    return getKSTDate(next);
}

/**
 * [POST] 데이터베이스 즉시 백업
 */
app.post('/api/admin/backup', (req, res) => {
    try {
        const { backupPath } = req.body;
        const result = performBackup(backupPath, req);
        res.json({ success: true, ...result });
    } catch (e) {
        logSystem('ERROR', 'BACKUP', `백업 생성 실패: ${e.message}`, req);
        console.error('[Admin API] Backup Error:', e);
        res.status(500).json({ error: '백업 실패: ' + e.message });
    }
});

/**
 * [GET] 백업 스케줄 목록 조회
 */
app.get('/api/admin/backups/schedules', (req, res) => {
    try {
        const schedules = db.prepare('SELECT * FROM BackupSchedules ORDER BY id DESC').all();
        res.json(schedules);
    } catch (e) {
        res.status(500).json({ error: '스케줄 조회 실패' });
    }
});

/**
 * [POST] 백업 스케줄 등록
 */
app.post('/api/admin/backups/schedules', (req, res) => {
    const { interval_type, backup_path } = req.body;
    if (!['weekly', 'monthly', 'quarterly', 'yearly'].includes(interval_type)) {
        return res.status(400).json({ error: '올바르지 않은 주기 유형입니다.' });
    }

    try {
        const nextRun = getNextScheduledDate(interval_type);
        db.prepare(`
            INSERT INTO BackupSchedules (interval_type, backup_path, next_run_at)
            VALUES (?, ?, ?)
        `).run(interval_type, backup_path || null, nextRun);

        logSystem('INFO', 'BACKUP', `새 백업 스케줄 등록: ${interval_type}`, req);
        res.json({ success: true, nextRun });
    } catch (e) {
        res.status(500).json({ error: '스케줄 등록 실패: ' + e.message });
    }
});

/**
 * [DELETE] 백업 스케줄 삭제
 */
app.delete('/api/admin/backups/schedules/:id', (req, res) => {
    try {
        db.prepare('DELETE FROM BackupSchedules WHERE id = ?').run(req.params.id);
        res.json({ success: true });
    } catch (e) {
        res.status(500).json({ error: '스케줄 삭제 실패' });
    }
});

/**
 * 자동 백업 스케줄러 루프 (1시간마다 체크)
 */
setInterval(() => {
    try {
        const nowStr = getKSTDate();
        const dueSchedules = db.prepare('SELECT * FROM BackupSchedules WHERE is_active = 1 AND next_run_at <= ?').all(nowStr);

        dueSchedules.forEach(sched => {
            try {
                // 1. 백업 실행
                performBackup(sched.backup_path);

                // 2. 다음 실행 시간 업데이트
                const nextRun = getNextScheduledDate(sched.interval_type);
                db.prepare('UPDATE BackupSchedules SET last_run_at = ?, next_run_at = ? WHERE id = ?')
                    .run(nowStr, nextRun, sched.id);

                console.log(`[Scheduler] 자동 백업 완료: ID ${sched.id} (${sched.interval_type})`);
            } catch (err) {
                console.error(`[Scheduler] 자동 백업 오류 (ID: ${sched.id}):`, err);
            }
        });
    } catch (e) {
        console.error('[Scheduler] 백업 스케줄러 메인 루프 오류:', e);
    }
}, 3600000); // 1시간 간격

/**
 * [GET] 백업 파일 목록 조회
 */
app.get('/api/admin/backups', (req, res) => {
    const { backupPath } = req.query;
    const targetDir = backupPath || path.join(__dirname, 'backups');
    try {
        if (!fs.existsSync(targetDir)) return res.json([]);
        const files = fs.readdirSync(targetDir)
            .filter(f => f.startsWith('chat') && f.endsWith('.db'))
            .map(f => ({
                name: f,
                size: (fs.statSync(path.join(targetDir, f)).size / 1024).toFixed(2) + ' KB',
                at: fs.statSync(path.join(targetDir, f)).mtime
            }));
        res.json(files);
    } catch (e) {
        res.status(500).json({ error: '백업 목록 조회 실패' });
    }
});

/**
 * [GET] 백업 파일 데이터 "조회하기" (Read-only Explorer)
 */
app.get('/api/admin/backups/explore', (req, res) => {
    const { fileName, backupPath } = req.query;
    const fullPath = path.join(backupPath || path.join(__dirname, 'backups'), fileName);

    if (!fs.existsSync(fullPath)) return res.status(404).json({ error: '파일을 찾을 수 없습니다.' });

    try {
        const tempDb = new (require('better-sqlite3'))(fullPath, { readonly: true });
        const userCount = tempDb.prepare('SELECT COUNT(*) as count FROM Users').get().count;
        const msgCount = tempDb.prepare('SELECT COUNT(*) as count FROM Messages').get().count;
        const roomCount = tempDb.prepare('SELECT COUNT(*) as count FROM ChatRooms').get().count;

        tempDb.close();

        res.json({
            info: { userCount, msgCount, roomCount, fileName }
        });
    } catch (e) {
        res.status(500).json({ error: '백업 데이터 조회 실패' });
    }
});

/**
 * [GET] 백업 파일 내 대화방 목록 조회
 */
app.get('/api/admin/backups/rooms', (req, res) => {
    const { fileName, backupPath } = req.query;
    const fullPath = path.join(backupPath || path.join(__dirname, 'backups'), fileName);
    if (!fs.existsSync(fullPath)) return res.status(404).json({ error: '파일 없음' });

    try {
        const tempDb = new (require('better-sqlite3'))(fullPath, { readonly: true });
        const rooms = tempDb.prepare(`
            SELECT r.*, 
            (SELECT COUNT(*) FROM Participants WHERE room_id = r.id) as participant_count,
            (SELECT content FROM Messages WHERE room_id = r.id ORDER BY created_at DESC LIMIT 1) as last_message
            FROM ChatRooms r
            ORDER BY r.id ASC
        `).all();
        tempDb.close();
        res.json(rooms);
    } catch (e) {
        res.status(500).json({ error: '백업 방 목록 조회 실패' });
    }
});

/**
 * [GET] 백업 파일 내 특정 방 메시지 조회
 */
app.get('/api/admin/backups/messages', (req, res) => {
    const { fileName, backupPath, roomId } = req.query;
    const fullPath = path.join(backupPath || path.join(__dirname, 'backups'), fileName);
    if (!fs.existsSync(fullPath)) return res.status(404).json({ error: '파일 없음' });

    try {
        const tempDb = new (require('better-sqlite3'))(fullPath, { readonly: true });
        const messages = tempDb.prepare(`
            SELECT m.*, u.username as senderName 
            FROM Messages m
            LEFT JOIN Users u ON m.sender_id = u.id
            WHERE m.room_id = ?
            ORDER BY m.created_at ASC
        `).all(roomId);
        tempDb.close();
        res.json(messages);
    } catch (e) {
        res.status(500).json({ error: '백업 메시지 조회 실패' });
    }
});

/**
 * [GET] 백업 파일 내 시스템 로그 조회
 */
app.get('/api/admin/backups/logs', (req, res) => {
    const { fileName, backupPath } = req.query;
    const fullPath = path.join(backupPath || path.join(__dirname, 'backups'), fileName);
    if (!fs.existsSync(fullPath)) return res.status(404).json({ error: '파일 없음' });

    try {
        const tempDb = new (require('better-sqlite3'))(fullPath, { readonly: true });
        // SystemLogs 테이블 존재 여부 확인
        const tableCheck = tempDb.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='SystemLogs'").get();
        if (!tableCheck) {
            tempDb.close();
            return res.json([]);
        }

        const logs = tempDb.prepare('SELECT * FROM SystemLogs ORDER BY created_at DESC').all();
        tempDb.close();
        res.json(logs);
    } catch (e) {
        res.status(500).json({ error: '백업 로그 조회 실패: ' + e.message });
    }
});

/**
 * [GET] 서버 디렉토리 브라우징 (경로 선택용)
 */
app.get('/api/admin/system/browse', (req, res) => {
    let targetPath = req.query.path || process.cwd();

    // 윈도우 경로 구분자 통일
    targetPath = path.resolve(targetPath);

    try {
        if (!fs.existsSync(targetPath)) {
            return res.status(404).json({ error: '경로가 존재하지 않습니다.' });
        }

        const items = fs.readdirSync(targetPath, { withFileTypes: true });
        const directories = items
            .filter(item => {
                try {
                    return item.isDirectory();
                } catch (e) { return false; }
            })
            .map(item => ({
                name: item.name,
                path: path.join(targetPath, item.name)
            }))
            .sort((a, b) => a.name.localeCompare(b.name));

        res.json({
            currentPath: targetPath,
            parentPath: path.dirname(targetPath),
            directories: directories
        });
    } catch (e) {
        console.error('[Admin API] Directory browse error:', e);
        res.status(500).json({ error: '디렉토리 정보를 가져오는데 실패했습니다: ' + e.message });
    }
});

/**
 * [GET] 서버 드라이브 목록 조회 (Windows 전용)
 */
app.get('/api/admin/system/drives', (req, res) => {
    const { exec } = require('child_process');
    exec('wmic logicaldisk get name', (error, stdout) => {
        if (error) {
            // 실패 시 C드라이브라도 기본 반환
            return res.json(['C:']);
        }
        const drives = stdout.split('\r\r\n')
            .map(value => value.trim())
            .filter(value => /^[A-Z]:$/.test(value));
        res.json(drives);
    });
});

/**
 * [POST] 서버 내 폴더 생성
 */
app.post('/api/admin/system/mkdir', (req, res) => {
    const { path: targetPath, folderName } = req.body;
    if (!targetPath || !folderName) return res.status(400).json({ error: '경로와 폴더명 필수' });

    const fullPath = path.join(targetPath, folderName);
    try {
        if (fs.existsSync(fullPath)) return res.status(400).json({ error: '이미 존재하는 폴더명입니다.' });
        fs.mkdirSync(fullPath);
        logSystem('INFO', 'SYSTEM', `새 폴더 생성: ${fullPath}`, req);
        res.json({ success: true, path: fullPath });
    } catch (e) {
        res.status(500).json({ error: '폴더 생성 실패: ' + e.message });
    }
});

/**
 * [GET] 시스템 로그 조회 API
 */
app.get('/api/admin/logs', (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 50;
        const logs = db.prepare('SELECT * FROM SystemLogs ORDER BY created_at DESC LIMIT ?').all(limit);
        res.json({ logs });
    } catch (e) {
        console.error('[Admin API] Logs Error:', e);
        res.status(500).json({ error: '로그 조회 실패' });
    }
});

/**
 * [POST] 엑셀 사용자 일괄 등록
 * 양식: 1열 사용자명 | 2열 비밀번호
 */
app.post('/api/admin/users/upload', upload.single('file'), async (req, res) => {
    if (!req.file) return res.status(400).json({ error: '파일이 없습니다.' });

    try {
        const workbook = xlsx.readFile(req.file.path);
        const sheetName = workbook.SheetNames[0];
        const sheet = workbook.Sheets[sheetName];
        const rows = xlsx.utils.sheet_to_json(sheet, { header: 1 }); // 2차원 배열로 읽기

        let successCount = 0;
        let failCount = 0;

        const insertUser = db.prepare('INSERT INTO Users (username, password) VALUES (?, ?)');
        const checkUser = db.prepare('SELECT id FROM Users WHERE username = ?');

        // 첫 줄 헤더 체크 (단순히 첫 셀이 'username' 등이면 스킵)
        let startIndex = 0;
        if (rows.length > 0) {
            const firstCell = String(rows[0][0] || '').trim().toLowerCase();
            if (['username', '사용자명', '아이디', 'user'].some(k => firstCell.includes(k))) {
                startIndex = 1;
            }
        }

        for (let i = startIndex; i < rows.length; i++) {
            const row = rows[i];
            if (!row || row.length < 2) continue;

            const username = String(row[0]).trim();
            const password = String(row[1]).trim();

            if (!username || !password) {
                failCount++;
                continue;
            }

            if (checkUser.get(username)) {
                failCount++; // 중복
                continue;
            }

            try {
                const hashedPassword = await bcrypt.hash(password, SALT_ROUNDS);
                const info = insertUser.run(username, hashedPassword);

                // 전체 대화방 자동 참여 (새 사용자 생성 로직과 동일하게)
                const globalRoom = db.prepare('SELECT id FROM ChatRooms WHERE room_identifier = ? AND room_type = ?').get('global', 'public');
                if (globalRoom) {
                    const joinedAt = getKSTDate();
                    db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)').run(globalRoom.id, info.lastInsertRowid, joinedAt);
                }

                successCount++;
            } catch (e) {
                console.error(`[Excel] Row ${i} Insert Error:`, e);
                failCount++;
            }
        }

        try { fs.unlinkSync(req.file.path); } catch (e) { }

        if (successCount > 0) {
            // 클라이언트들에게 갱신 신호 브로드캐스트
            io.emit('user_added', { id: -1, username: 'Batch' });
            logSystem('INFO', 'USER', `엑셀 일괄 등록: 성공 ${successCount}건, 실패 ${failCount}건`, req);
        }

        res.json({ success: true, successCount, failCount });

    } catch (e) {
        console.error('[Admin API] Excel Upload Error:', e);
        try { fs.unlinkSync(req.file.path); } catch (delErr) { }
        res.status(500).json({ error: '엑셀 처리 실패: ' + e.message });
    }
});

// 유저 목록 조회 (온라인 상태 포함 + 검색 지원)
app.get('/api/users', (req, res) => {
    try {
        const { search = '' } = req.query;
        let sql = 'SELECT id, username, is_admin, mac_address, mac_binding, os_info, device_type FROM Users';
        let users;

        if (search) {
            sql += ' WHERE username LIKE ?';
            users = db.prepare(sql).all(`%${search}%`);
        } else {
            users = db.prepare(sql).all();
        }

        // 온라인 상태 추가
        const usersWithStatus = users.map(user => ({
            ...user,
            isOnline: onlineUsers.has(user.id)
        }));
        res.json(usersWithStatus);
    } catch (e) {
        console.error('[Admin API] User list error:', e);
        res.status(500).json({ error: '유저 목록 조회 실패' });
    }
});

// 단일 유저 상세 조회 (편집 모달용)
app.get('/api/admin/users/:id', (req, res) => {
    const { id } = req.params;
    try {
        const user = db.prepare('SELECT id, username, is_admin, mac_address, mac_binding, os_info, device_type FROM Users WHERE id = ?').get(id);
        if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });

        res.json({
            ...user,
            isOnline: onlineUsers.has(user.id)
        });
    } catch (e) {
        res.status(500).json({ error: '정보 조회 실패' });
    }
});

/**
 * [GET] 채팅방 멤버 목록 조회
 */
app.get('/api/rooms/:roomId/members', (req, res) => {
    const { roomId } = req.params;
    console.log(`[API] 멤버 목록 조회 요청: Room ${roomId}`);

    try {
        const id = parseInt(roomId);
        if (isNaN(id)) {
            return res.status(400).json({ error: 'Invalid Room ID' });
        }

        const members = db.prepare(`
            SELECT U.id, U.username, U.profile_img, P.joined_at
            FROM Participants P
            JOIN Users U ON P.user_id = U.id
            WHERE P.room_id = ?
        `).all(id);

        console.log(`[API] 조회된 멤버 수: ${members.length}`);

        // 온라인 상태 매핑
        const membersWithStatus = members.map(m => ({
            ...m,
            isOnline: onlineUsers.has(m.id)
        }));

        res.json(membersWithStatus);
    } catch (e) {
        console.error('[API] 멤버 목록 조회 오류:', e);
        res.status(500).json({ error: '멤버 목록 조회 실패' });
    }
});

/**
 * [POST] 1:1 채팅방 생성 또는 조회
 */
app.post('/api/rooms/private', (req, res) => {
    console.log('[API] 1:1 채팅방 생성 요청 받음');
    console.log('[API] 요청 본문:', req.body);

    const { userId1, userId2 } = req.body;

    console.log('[API] userId1:', userId1, 'userId2:', userId2);

    if (!userId1 || !userId2) {
        console.log('[API] userId1 또는 userId2가 없음');
        return res.status(400).json({ error: 'userId1, userId2 필요' });
    }

    try {
        // 이미 존재하는 1:1 채팅방 찾기
        // room_identifier로 찾기 (user1_user2 형식)
        const ids = [userId1, userId2].sort((a, b) => a - b);
        const roomIdentifier = `${ids[0]}_${ids[1]}`;

        console.log('[API] roomIdentifier:', roomIdentifier);

        const existingRoom = db.prepare(`
            SELECT id, room_type, room_identifier
            FROM ChatRooms
            WHERE room_identifier = ?
        `).get(roomIdentifier);

        if (existingRoom) {
            console.log(`[API] 기존 1:1 채팅방 발견: ${existingRoom.id}`);

            // 재입장 처리: 참여자가 없다면(나간 상태라면) 다시 추가하여 joined_at 갱신
            try {
                runTransaction(() => {
                    const now = getKSTDate();

                    // userId1 재입장 확인
                    const p1 = db.prepare('SELECT user_id FROM Participants WHERE room_id = ? AND user_id = ?').get(existingRoom.id, userId1);
                    if (!p1) {
                        console.log(`[API] 유저 ${userId1} 재입장 처리 (Room: ${existingRoom.id})`);
                        db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)').run(existingRoom.id, userId1, now);
                    }

                    // userId2 재입장 확인 (상대방도 나갔을 수 있으므로)
                    const p2 = db.prepare('SELECT user_id FROM Participants WHERE room_id = ? AND user_id = ?').get(existingRoom.id, userId2);
                    if (!p2) {
                        console.log(`[API] 유저 ${userId2} 재입장 처리 (Room: ${existingRoom.id})`);
                        db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)').run(existingRoom.id, userId2, now);
                    }
                });
            } catch (e) {
                console.error('[API] 재입장 처리 중 오류:', e);
            }

            // 기존 방이 있어도 데이터 변경(재입장 등)이 있을 수 있으므로 알림
            io.to('admin_room').emit('room_updated', { roomId: existingRoom.id });

            return res.json({
                room: {
                    id: existingRoom.id,
                    name: roomIdentifier,
                    is_group: 0
                }
            });
        }

        // 새 채팅방 생성
        const user1 = db.prepare('SELECT username FROM Users WHERE id = ?').get(userId1);
        const user2 = db.prepare('SELECT username FROM Users WHERE id = ?').get(userId2);

        if (!user1 || !user2) {
            return res.status(404).json({ error: '사용자를 찾을 수 없습니다' });
        }

        const roomInfo = db.prepare(`
            INSERT INTO ChatRooms (room_type, room_identifier, created_at)
            VALUES (?, ?, ?)
        `).run('1:1', roomIdentifier, getKSTDate());

        const roomId = roomInfo.lastInsertRowid;

        // 두 사용자를 Participants에 추가
        const joinedAt = getKSTDate();
        db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)').run(roomId, userId1, joinedAt);
        db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)').run(roomId, userId2, joinedAt);

        console.log(`[API] 새 1:1 채팅방 생성: ${roomId} (${roomIdentifier})`);

        // 어드민 실시간 목록 갱신 알림
        io.to('admin_room').emit('room_updated', { roomId });

        res.json({
            room: {
                id: roomId,
                name: roomIdentifier,
                is_group: 0
            }
        });
    } catch (e) {
        console.error('[API] 1:1 채팅방 생성 실패:', e);
        res.status(500).json({ error: '채팅방 생성 실패' });
    }
});

/**
 * [GET] 내가 참여한 채팅방 목록 조회
 */
app.get('/api/rooms/my/:userId', (req, res) => {
    const { userId } = req.params;

    try {
        const rooms = db.prepare(`
            SELECT 
                r.id,
                r.room_type,
                r.room_identifier,
                r.room_name,
                (
                    SELECT content 
                    FROM Messages 
                    WHERE room_id = r.id 
                    ORDER BY created_at DESC 
                    LIMIT 1
                ) as last_message,
                (
                    SELECT created_at 
                    FROM Messages 
                    WHERE room_id = r.id 
                    ORDER BY created_at DESC 
                    LIMIT 1
                ) as last_message_time
            FROM ChatRooms r
            INNER JOIN Participants p ON r.id = p.room_id
            WHERE p.user_id = ? AND p.is_active = 1
            ORDER BY last_message_time DESC
        `).all(userId);

        // 1:1 채팅방의 경우 상대방 정보 추가
        const roomsWithDetails = rooms.map(room => {
            if (room.room_type === '1:1') {
                // 상대방 찾기
                const otherUser = db.prepare(`
                    SELECT u.id, u.username
                    FROM Users u
                    INNER JOIN Participants p ON u.id = p.user_id
                    WHERE p.room_id = ?
                    AND u.id != ?
                    LIMIT 1
                `).get(room.id, userId);

                // 읽지 않은 메시지 개수 계산 (상대방이 보낸 메시지 중 read_count > 0인 것)
                const unreadCount = db.prepare(`
                    SELECT COUNT(*) as count
                    FROM Messages
                    WHERE room_id = ?
                    AND sender_id != ?
                    AND read_count > 0
                `).get(room.id, userId).count;

                return {
                    id: room.id,
                    name: otherUser ? otherUser.username : room.room_identifier,
                    is_group: 0,
                    last_message: room.last_message,
                    last_message_time: room.last_message_time,
                    unreadCount: unreadCount,
                    otherUser: otherUser || null,
                    isOnline: otherUser ? onlineUsers.has(otherUser.id) : false
                };
            }
            return {
                id: room.id,
                name: room.room_name || room.room_identifier, // 그룹 이름 우선, 없으면 identifier
                room_type: room.room_type,
                is_group: 1,
                last_message: room.last_message,
                last_message_time: room.last_message_time,
                // [그룹/전체] 안 읽은 메시지 계산 (본인 메시지 제외)
                unreadCount: db.prepare(`
                    SELECT COUNT(*) as count 
                    FROM Messages 
                    WHERE room_id = ? 
                    AND sender_id != ?
                    AND created_at > (
                        SELECT IFNULL(last_read_at, '1970-01-01') 
                        FROM Participants 
                        WHERE room_id = ? AND user_id = ?
                    )
                `).get(room.id, userId, room.id, userId).count
            };
        });

        console.log(`[API] 사용자 ${userId}의 채팅방 목록 조회: ${roomsWithDetails.length}개`);
        res.json(roomsWithDetails);
    } catch (e) {
        console.error('[API] 채팅방 목록 조회 실패:', e);
        res.status(500).json({ error: '채팅방 목록 조회 실패' });
    }
});

/**
 * [GET] 특정 방의 메시지 히스토리 조회
 */
app.get('/api/rooms/:roomId/messages', (req, res) => {
    const { roomId } = req.params;
    const userId = req.query.userId; // userId 추가 (선택적)

    try {
        const limit = req.query.limit ? parseInt(req.query.limit) : null; // [v1.0.2] limit 지원
        const offset = req.query.offset ? parseInt(req.query.offset) : 0; // [카카오톡 스타일] offset 지원

        let query = 'SELECT * FROM Messages WHERE room_id = ?';
        const params = [roomId];

        if (userId) {
            // 해당 유저의 참여 시간 조회
            const participant = db.prepare('SELECT joined_at FROM Participants WHERE room_id = ? AND user_id = ?').get(roomId, userId);

            if (participant) {
                // 참여 시간 이후의 메시지만 조회
                query += ' AND created_at >= ?';
                params.push(participant.joined_at);
            }
        }

        if (limit) {
            // [카카오톡 스타일] 최근 대화 우선 조회 (역순 정렬 후 Limit + Offset)
            query += ' ORDER BY created_at DESC LIMIT ? OFFSET ?';
            params.push(limit);
            params.push(offset);
        } else {
            // 전체 조회 (기존 로직)
            query += ' ORDER BY created_at ASC';
        }

        let messages = db.prepare(query).all(...params);

        if (limit) {
            // DESC로 가져왔으므로 다시 시간순(ASC) 정렬
            messages.reverse();
        }

        // [Fix] 메시지를 읽음 상태로 변환 (클라이언트 표시용)
        const enrichedMessages = messages.map(msg => {
            let isRead = msg.read_count === 0; // read_count가 0이면 모두 읽음

            // 그룹/전체 방인 경우 last_read_at 기준 판정
            if (userId) {
                const room = db.prepare('SELECT room_type FROM ChatRooms WHERE id = ?').get(roomId);
                if (room && room.room_type !== '1:1') {
                    const participant = db.prepare('SELECT last_read_at, joined_at FROM Participants WHERE room_id = ? AND user_id = ?').get(roomId, userId);
                    const lastReadAt = participant ? (participant.last_read_at || participant.joined_at || '1970-01-01') : '1970-01-01';
                    isRead = msg.created_at <= lastReadAt; // 마지막 읽음 시점 이전이면 읽음
                }
            }

            // 발신자 이름 조회
            const sender = db.prepare('SELECT username FROM Users WHERE id = ?').get(msg.sender_id);

            return {
                ...msg,
                senderName: sender ? sender.username : '알 수 없음', // 발신자 이름 추가
                isRead: isRead
            };
        });

        console.log(`[API] 메시지 조회 (Room: ${roomId}, User: ${userId || 'N/A'}) - ${messages.length}건`);
        res.json(enrichedMessages);
    } catch (e) {
        console.error('[API] 메시지 조회 실패:', e);
        res.status(500).json({ error: '메시지 조회 실패' });
    }
});

/**
 * [POST] 채팅방 나가기
 */
app.post('/api/rooms/leave', (req, res) => {
    console.log('[API] /api/rooms/leave 요청 수신:', req.body);

    // 명시적 형변환 및 유효성 검사
    const roomId = parseInt(req.body.roomId);
    const userId = parseInt(req.body.userId);

    if (isNaN(roomId) || isNaN(userId)) {
        console.error('[API] 잘못된 파라미터:', req.body);
        return res.status(400).json({ error: '데이터 형식 오류 (roomId, userId는 숫자여야 함)' });
    }

    try {
        let deletedParticipant = 0;
        let remaining = 0;

        runTransaction(() => {
            // 1. 참여자 비활성화 처리 (삭제 대신 is_active = 0)
            const result = db.prepare('UPDATE Participants SET is_active = 0 WHERE room_id = ? AND user_id = ?').run(roomId, userId);
            deletedParticipant = result.changes;
            console.log(`[API] 참여자 비활성화 결과: ${result.changes}건 (Room: ${roomId}, User: ${userId})`);

            // 2. 남은 '활성' 참여자 수 확인
            remaining = db.prepare('SELECT COUNT(*) as count FROM Participants WHERE room_id = ? AND is_active = 1').get(roomId).count;
            console.log(`[API] 남은 활성 참여자 수: ${remaining}`);

            if (remaining === 0) {
                // 1:1 방인 경우 상대방도 나갔는지 확인하여 둘 다 나갔으면 삭제 (용량 절약)
                // 그룹 방인 경우 모든 멤버가 is_active=0이면 삭제
                const totalParticipants = db.prepare('SELECT COUNT(*) as count FROM Participants WHERE room_id = ?').get(roomId).count;
                const activeParticipants = remaining;

                if (activeParticipants === 0) {
                    // 참고: 모든 유저가 나갔어도 히스토리 유지를 위해 방을 바로 삭제하지 않을 수 있으나, 
                    // 여기서는 기존 로직에 맞춰 참여자가 0명인 경우(모두 비활성) 삭제 검토 가능.
                    // 하지만 사용자의 '메시지 오면 재참여' 요구사항을 위해 방 자체는 유지함.
                    console.log(`[API] 모든 참여자가 비활성화됨 (Room: ${roomId}) - 자동 재참여를 위해 방 유지`);
                }
            } else {
                console.log(`[API] 유저 ${userId}가 방 ${roomId}에서 나감(비활성). 남은 인원: ${remaining}`);
            }
        });

        // 4. 해당 사용자의 소켓들을 소켓 룸에서 제거 (즉시 알림 중단)
        const userSockets = Array.from(io.sockets.sockets.values()).filter(s => s.userId === userId);
        userSockets.forEach(s => {
            s.leave(`room_${roomId}`);
            console.log(`[API] 소켓 ${s.id}가 room_${roomId}에서 제거됨 (Leave)`);
        });

        // 어드민 실시간 목록 갱신 알림 (참여자 수 변경)
        io.to('admin_room').emit('room_updated', { roomId });

        res.json({ success: true, deleted: deletedParticipant, remaining: remaining });
    } catch (e) {
        console.error('[API] 방 나가기 오류:', e);
        res.status(500).json({ error: '방 나가기 처리 실패' });
    }
});

/**
 * [POST] 파일 업로드 API
 */
app.post('/api/upload', upload.single('file'), (req, res) => {
    if (!req.file) return res.status(400).json({ error: '파일이 없습니다.' });

    const { roomId, currentUserId } = req.body;
    if (!roomId || !currentUserId) return res.status(400).json({ error: '데이터 부족 (roomId, currentUserId)' });

    const fileName = req.file.filename;
    const originalName = req.file.originalname;
    const fileUrl = `/uploads/${fileName}`;
    const createdAt = getKSTDate();

    try {
        // [Fix] 파일 업로드도 전체대화방 로직에 맞게 read_count 계산
        const room = db.prepare('SELECT room_type FROM ChatRooms WHERE id = ?').get(roomId);
        let initialReadCount = 1; // 기본값 (1:1)

        if (room && room.room_type !== '1:1') {
            // 그룹/전체 방의 경우: 총 참여자 수 - 1 (보낸 사람 제외)
            const pCount = db.prepare('SELECT COUNT(*) as count FROM Participants WHERE room_id = ?').get(roomId).count;
            initialReadCount = Math.max(0, pCount - 1);
        }

        // DB 저장
        const info = db.prepare(`
            INSERT INTO Messages (room_id, sender_id, content, file_url, type, read_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        `).run(roomId, currentUserId, originalName, fileUrl, 'file', initialReadCount, createdAt);

        const messageData = {
            id: info.lastInsertRowid,
            roomId: parseInt(roomId),
            senderId: parseInt(currentUserId),
            content: originalName,
            fileUrl: fileUrl,
            type: 'file',
            readCount: initialReadCount,
            createdAt: createdAt
        };

        // 실시간 소켓 브로드캐스트
        io.to(`room_${roomId}`).emit('receive_message', messageData);
        // 어드민 모니터링 실시간 갱신
        io.to('admin_room').emit('receive_message', messageData);
        // 어드민 실시간 목록 갱신
        io.to('admin_room').emit('room_updated', { roomId: parseInt(roomId) });
        console.log(`[File Upload] ${originalName} saved & emitted in room_${roomId}`);

        res.json({ success: true, message: messageData });
    } catch (e) {
        console.error('파일 DB 저장 오류:', e);
        res.status(500).json({ error: '파일 메시지 저장 실패' });
    }
});

// PeerJS 서버 설정 (일시 중지하여 소켓 충돌 가능성 제거)
/*
const peerServer = ExpressPeerServer(server, {
    debug: true,
    path: '/peerjs'
});
app.use('/peerjs', peerServer);

peerServer.on('connection', (client) => {
    console.log('Peer connected:', client.getId());
});
*/

// Socket.io 로직
io.on('connection', (socket) => {
    console.log(`[Socket] 새 연결 발생: ${socket.id} (IP: ${socket.handshake.address})`);

    socket.on('error', (err) => {
        console.error(`[Socket Error] ${socket.id}:`, err);
    });

    socket.on('register_user', (data) => {
        let userId;
        let deviceId;

        if (typeof data === 'object' && data !== null) {
            userId = parseInt(data.userId);
            deviceId = data.deviceId;
        } else {
            userId = parseInt(data);
        }

        console.log(`[Socket] register_user 수신: userId=${userId}, deviceId=${deviceId || 'N/A'}`);

        if (isNaN(userId)) {
            console.error('[Socket] register_user 실패: 유효하지 않은 userId');
            return;
        }

        // [중복 로그인 방지 개선]
        if (userSockets.has(userId)) {
            const oldSocketId = userSockets.get(userId);
            if (oldSocketId !== socket.id) {
                const oldSocket = io.sockets.sockets.get(oldSocketId);
                if (oldSocket) {
                    // [Fix] 같은 기기(deviceId)이면 기존 세션을 조용히 끊고 교체 (중복 알림 방지)
                    if (deviceId && oldSocket.deviceId === deviceId) {
                        console.log(`[Socket] 같은 기기(${deviceId}) 재연결: 이전 소켓(${oldSocketId})을 조용히 교체합니다.`);
                        oldSocket.disconnect(true);
                    } else {
                        console.log(`[Socket] 다른 기기 중복 로그인 감지: 유저 ${userId}의 이전 연결(${oldSocketId})을 종료합니다.`);
                        oldSocket.emit('force_logout', { message: '다른 기기에서 로그인하여 접속이 종료되었습니다.' });
                        oldSocket.disconnect(true);
                    }
                }
            }
        }

        userSockets.set(userId, socket.id);
        socket.userId = userId;
        socket.deviceId = deviceId; // 소켓에 기기 ID 저장

        try {
            const rooms = db.prepare('SELECT room_id FROM Participants WHERE user_id = ?').all(userId);
            console.log(`[Socket] 유저 ${userId}의 참여 방 개수: ${rooms.length}`);
            rooms.forEach(row => {
                const roomName = `room_${row.room_id}`;
                socket.join(roomName);
                console.log(`[Socket] 유저 ${userId}가 ${roomName}에 자동 입장함 (register)`);
            });
        } catch (e) {
            console.error(`[Socket] register_user DB 조회 실패:`, e);
        }

        console.log(`[Socket] 유저 ${userId} 등록 완료 (Socket ID: ${socket.id})`);

        // 온라인 사용자 Set에 추가
        onlineUsers.add(userId);

        // 온라인 상태 브로드캐스트
        io.emit('user_status', { userId, status: 'online' });
        console.log(`[Socket] 유저 ${userId} 온라인 상태 브로드캐스트`);

        // [v2.0.0] 등록 성공 시 서버 정보(startTime 등) 전송
        socket.emit('registration_success', {
            userId,
            startTime,
            serverVer: '2.0.0'
        });
    });

    // 명시적 방 입장 이벤트 추가
    socket.on('join_room', (roomId) => {
        const roomName = `room_${roomId}`;
        socket.join(roomName);
        console.log(`[Socket] Socket ${socket.id}가 ${roomName}에 명시적으로 입장함`);
    });

    socket.on('join_admin_room', () => {
        socket.join('admin_room');
        console.log(`[Socket] Socket ${socket.id}가 admin_room에 입장함`);
    });

    socket.on('send_message', (data) => {
        console.log(`[Socket] send_message 이벤트 수신:`, data);
        const { roomId, content, fileUrl, thumbnailUrl, type } = data;
        const roomNameInPayload = `room_${roomId}`;
        const senderId = socket.userId || data.senderId;
        const createdAt = getKSTDate();

        if (!senderId) {
            console.error('[Socket] 오류: senderId 누락됨');
            return;
        }

        // 방 메타데이터 사전에 조회 (스코프 문제 해결 및 이후 로직 사용)
        const room = db.prepare('SELECT room_type, room_identifier, room_name FROM ChatRooms WHERE id = ?').get(roomId);
        if (!room) {
            console.error(`[Socket] 오류: 존재하지 않는 방 (ID: ${roomId})`);
            return;
        }

        console.log(`[Socket] 메시지 수신 - Room: ${roomId}, Sender: ${senderId}, Content: ${content}`);

        // [1:1 및 그룹 채팅] 상대방이 방을 나갔을(비활성) 경우 자동 재초대/재활성화
        try {
            if (room.room_type === '1:1') {
                const parts = room.room_identifier.split('_');
                if (parts.length === 2) {
                    const u1 = parseInt(parts[0]);
                    const u2 = parseInt(parts[1]);
                    const targetUserId = (senderId === u1) ? u2 : u1;

                    const participant = db.prepare('SELECT is_active FROM Participants WHERE room_id = ? AND user_id = ?').get(roomId, targetUserId);

                    if (!participant) {
                        db.prepare('INSERT INTO Participants (room_id, user_id, joined_at) VALUES (?, ?, ?)').run(roomId, targetUserId, createdAt);
                    } else if (participant.is_active === 0) {
                        db.prepare('UPDATE Participants SET is_active = 1 WHERE room_id = ? AND user_id = ?').run(roomId, targetUserId);
                        console.log(`[Socket] 1:1 상대방(${targetUserId}) 자동 재활성화 (Room: ${roomId})`);
                    }
                }
            } else {
                // [그룹/전체 채팅] 나간 사람(is_active=0)들 모두 자동 재활성화
                const result = db.prepare('UPDATE Participants SET is_active = 1 WHERE room_id = ? AND is_active = 0').run(roomId);
                if (result.changes > 0) {
                    console.log(`[Socket] 그룹 채팅 참여자 ${result.changes}명 자동 재활성화 (Room: ${roomId})`);
                }
            }
        } catch (e) {
            console.error('[Socket] 자동 재활성화 로직 오류:', e);
        }

        try {
            // [Fix] 초기 읽음 카운트 계산: 전체 참여자 수 - 1
            const pCount = db.prepare('SELECT COUNT(*) as count FROM Participants WHERE room_id = ?').get(roomId).count;
            const initialReadCount = Math.max(0, pCount - 1);

            console.log(`[Socket] 메시지 저장 시작 - Room: ${roomId}, Sender: ${senderId}, ReadCount: ${initialReadCount}`);

            const info = db.prepare(`
                INSERT INTO Messages (room_id, sender_id, content, file_url, thumbnail_url, type, read_count, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            `).run(roomId, senderId, content, fileUrl || null, thumbnailUrl || null, type || 'text', initialReadCount, createdAt);

            // DB에서 방금 삽입한 메시지 조회
            const savedMessage = db.prepare('SELECT * FROM Messages WHERE id = ?').get(info.lastInsertRowid);

            // 발신자 이름 조회
            const sender = db.prepare('SELECT username FROM Users WHERE id = ?').get(senderId);

            const messageData = {
                id: savedMessage.id,
                roomId: parseInt(roomId),
                senderId: parseInt(senderId),
                senderName: sender ? sender.username : '알 수 없음', // 발신자 이름 추가
                content: savedMessage.content,
                fileUrl: savedMessage.file_url,
                thumbnailUrl: savedMessage.thumbnail_url,
                type: savedMessage.type,
                readCount: savedMessage.read_count,
                createdAt: savedMessage.created_at,
                // [Fix] 알림 및 라우팅을 위한 추가 정보
                isGroup: room.room_type !== '1:1',
                roomName: room.room_name || room.room_identifier
            };


            const targetRoomName = `room_${roomId}`;
            const clientsInRoom = io.sockets.adapter.rooms.get(targetRoomName);
            console.log(`[Socket] Broadcasting message to ${targetRoomName}. Listeners count: ${clientsInRoom ? clientsInRoom.size : 0}`);

            // [Fix] 새 메시지가 왔을 때 참여자들의 소켓을 다시 룸에 조인 (나갔던 사람 복구)
            try {
                const participants = db.prepare('SELECT user_id FROM Participants WHERE room_id = ? AND is_active = 1').all(roomId);
                participants.forEach(p => {
                    const userSockets = Array.from(io.sockets.sockets.values()).filter(s => s.userId === p.user_id);
                    userSockets.forEach(s => {
                        if (!s.rooms.has(targetRoomName)) {
                            s.join(targetRoomName);
                            console.log(`[Socket] 유저 ${p.user_id}의 소켓 ${s.id}를 ${targetRoomName}에 재입장시킴`);
                        }
                    });
                });
            } catch (e) {
                console.error('[Socket] 참여자 룸 재입장 처리 오류:', e);
            }

            io.to(targetRoomName).emit('receive_message', messageData);
            // [추가] 어드민 모니터링 실시간 대화창 동기화를 위해 어드민 룸에도 전송
            io.to('admin_room').emit('receive_message', messageData);
            console.log(`[Socket] 메시지 저장 및 브로드캐스트 완료 (ID: ${savedMessage.id})`);

            // 채팅방 업데이트 알림 (대화목록 새로고침용)
            try {
                const participants = db.prepare('SELECT user_id FROM Participants WHERE room_id = ?').all(roomId);
                participants.forEach(participant => {
                    const userSockets = Array.from(io.sockets.sockets.values())
                        .filter(s => s.userId === participant.user_id);

                    userSockets.forEach(userSocket => {
                        userSocket.emit('room_updated', { roomId: parseInt(roomId) });

                        // [Fix] 방에 조인되지 않은 유저에게도 메시지 전송 (알림용)
                        const targetRoomName = `room_${roomId}`;
                        const isInRoom = userSocket.rooms.has(targetRoomName);
                        // 수신자 이름 확인 (디버깅용)
                        const recipient = db.prepare('SELECT username FROM Users WHERE id = ?').get(participant.user_id);
                        const recipientName = recipient ? recipient.username : '알 수 없음';

                        console.log(`[Socket Trace] Room:${roomId}, Sender:${messageData.senderName}, Recipient:${recipientName}, Socket:${userSocket.id}, InRoom:${isInRoom}`);

                        if (!isInRoom) {
                            console.log(`[Socket] Sending INDIVIDUAL receive_message to ${recipientName}`);
                            userSocket.emit('receive_message', messageData);
                        } else {
                            console.log(`[Socket] Skip individual emit for ${recipientName} (Already in room)`);
                        }
                    });
                });

                // [추가] 어드민들에게도 방 업데이트 소식 알림 (모니터링 목록 갱신용)
                io.to('admin_room').emit('room_updated', { roomId: parseInt(roomId) });
                console.log(`[Socket] room_updated 이벤트 전송 완료: ${participants.length}명 + 어드민`);
            } catch (e) {
                console.error('[Socket] room_updated 전송 오류:', e);
            }
        } catch (e) {
            console.error('[Socket] DB 저장 오류 상세:', e.message);
        }
    });

    // 읽음 처리 이벤트
    socket.on('mark_as_read', (data) => {
        const { roomId, userId } = data;
        console.log(`[Socket] mark_as_read 수신: roomId=${roomId}, userId=${userId}`);

        try {
            // [Fix] 1:1은 기존 방식, 그룹/전체는 last_read_at 업데이트
            const room = db.prepare('SELECT room_type FROM ChatRooms WHERE id = ?').get(roomId);

            if (room && room.room_type === '1:1') {
                // 해당 방의 내가 받은 메시지들을 모두 읽음 처리
                const result = db.prepare(`
                    UPDATE Messages 
                    SET read_count = CASE WHEN read_count > 0 THEN read_count - 1 ELSE 0 END
                    WHERE room_id = ? AND sender_id != ? AND read_count > 0
                `).run(roomId, userId);
                console.log(`[Socket] 읽음 처리 완료: ${result.changes}건 (Room: ${roomId}, User: ${userId})`);
            } else {
                // 그룹/전체: last_read_at 기준 read_count 차감 및 갱신
                const participant = db.prepare('SELECT last_read_at, joined_at FROM Participants WHERE room_id = ? AND user_id = ?').get(roomId, userId);
                // last_read_at이 없으면 joined_at 이후부터, 그것도 없으면 1970년부터
                const lastReadAt = participant ? (participant.last_read_at || participant.joined_at || '1970-01-01') : '1970-01-01';
                const now = getKSTDate();

                // 안 읽은 메시지(read_count > 0, 내가 보낸거 제외, 내가 마지막으로 읽은 시점 이후) 차감
                const groupReadInfo = db.prepare(`
                    UPDATE Messages 
                    SET read_count = CASE WHEN read_count > 0 THEN read_count - 1 ELSE 0 END
                    WHERE room_id = ? AND sender_id != ? AND read_count > 0 AND created_at > ?
                `).run(roomId, userId, lastReadAt);

                db.prepare(`
                    UPDATE Participants 
                    SET last_read_at = ?
                    WHERE room_id = ? AND user_id = ?
                `).run(now, roomId, userId);

                // [추가] 공지사항 읽음 기록 (NoticeReads)
                try {
                    const notices = db.prepare(`
                        SELECT id FROM Messages 
                        WHERE room_id = ? AND type = 'notice' AND created_at > ?
                    `).all(roomId, lastReadAt);

                    const readAt = getKSTDate();
                    notices.forEach(notice => {
                        db.prepare(`
                            INSERT OR IGNORE INTO NoticeReads (message_id, user_id, read_at)
                            VALUES (?, ?, ?)
                        `).run(notice.id, userId, readAt);

                        // [추가] 어드민에게 실시간 알림 (공지 읽음 현황 갱신용)
                        io.to('admin_room').emit('notice_read_updated', { messageId: notice.id, userId: userId });
                    });
                } catch (ne) {
                    console.error('[Socket] 공지 읽음 기록 중 오류:', ne);
                }

                console.log(`[Socket] 그룹 읽음차감: ${groupReadInfo.changes}건 (User: ${userId}, Range: ${lastReadAt} ~ ${now})`);
            }

            // 같은 방의 다른 사용자에게 읽음 알림 브로드캐스트
            const targetRoom = `room_${roomId}`;
            io.to(targetRoom).emit('messages_read', { roomId, userId });
            console.log(`[Socket] messages_read 브로드캐스트 완료: ${targetRoom}`);
        } catch (e) {
            console.error('[Socket] mark_as_read 오류:', e);
        }
    });

    socket.on('disconnect', () => {
        if (socket.userId) {
            console.log(`[Socket] 연결 종료: ${socket.id} (User: ${socket.userId})`);

            // [중복 로그인 방지] 내가 현재 등록된 소켓일 때만 맵에서 제거
            if (userSockets.get(socket.userId) === socket.id) {
                userSockets.delete(socket.userId);
                onlineUsers.delete(socket.userId);

                // 오프라인 상태 브로드캐스트
                io.emit('user_status', { userId: socket.userId, status: 'offline' });
                console.log(`[Socket] 유저 ${socket.userId} 오프라인 상태 브로드캐스트`);
            } else {
                console.log(`[Socket] 유저 ${socket.userId}의 구세션(${socket.id})이 종료되었습니다. (최신 세션 유지)`);
            }
        } else {
            console.log(`[Socket] 연결 종료: ${socket.id}`);
        }
    });
});

server.listen(PORT, HOST, () => {
    console.log(`서버 기동: http://${HOST}:${PORT}`);
    console.log(`PeerServer running on path /peerjs`);
    console.log(`서버 시간 (타임존: Asia/Seoul): ${getKSTDate()} (KST)`);
});

// --- 주기적 공지 재발송 스케줄러 (1분마다 실행) ---
setInterval(() => {
    const nowStr = getKSTDate();
    try {
        const activeSchedules = db.prepare(`
            SELECT ns.*, m.room_id, m.sender_id, m.content, m.created_at
            FROM NoticeSchedules ns
            JOIN Messages m ON ns.message_id = m.id
            WHERE ns.is_active = 1 AND ns.next_run_at <= ?
        `).all(nowStr);

        activeSchedules.forEach(sched => {
            const messageId = sched.message_id;

            // 미확인자 목록 조회
            const allParticipants = db.prepare(`
                SELECT u.id FROM Participants p
                JOIN Users u ON p.user_id = u.id
                WHERE p.room_id = ? AND u.id != 1
            `).all(sched.room_id);

            const readers = db.prepare('SELECT user_id FROM NoticeReads WHERE message_id = ?').all(messageId);
            const readUserIds = new Set(readers.map(r => r.user_id));
            const unreaders = allParticipants.filter(p => !readUserIds.has(p.id));

            if (unreaders.length > 0) {
                const messageData = {
                    id: messageId,
                    roomId: sched.room_id,
                    senderId: sched.sender_id,
                    senderName: '시스템 관리자',
                    content: sched.content,
                    type: 'notice',
                    isResend: true,
                    isAuto: true,
                    createdAt: sched.created_at
                };

                unreaders.forEach(u => {
                    const socketId = userSockets.get(u.id);
                    if (socketId) {
                        io.to(socketId).emit('receive_message', messageData);
                        io.to(socketId).emit('notice', messageData);
                    }
                });
                console.log(`[Scheduler] 공지(ID: ${messageId}) 미확인자 ${unreaders.length}명에게 자동 재발송 완료`);
            } else {
                // 모두 읽었으면 스케줄 정지
                db.prepare('UPDATE NoticeSchedules SET is_active = 0 WHERE message_id = ?').run(messageId);
                console.log(`[Scheduler] 공지(ID: ${messageId}) 모두 확인 완료. 스케줄 정지.`);
                return;
            }

            // 다음 실행 시간 계산
            const nextRun = new Date(Date.now() + sched.interval_minutes * 60000);
            const nextRunStr = getKSTDate(nextRun);
            db.prepare('UPDATE NoticeSchedules SET last_run_at = ?, next_run_at = ? WHERE message_id = ?')
                .run(nowStr, nextRunStr, messageId);
        });
    } catch (e) {
        console.error('[Scheduler] 공지 재발송 실행 오류:', e);
    }
}, 60000);
