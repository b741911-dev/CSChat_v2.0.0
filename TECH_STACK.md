# CSChat 기술 스택 (Technology Stack)

본 문서는 **CSChat** 프로젝트에 사용된 주요 기술 및 라이브러리 구성을 정리한 문서입니다.

## 1. 서버 (Backend)

| 구분 | 기술 스택 | 비고 |
| :--- | :--- | :--- |
| **Runtime** | Node.js | 서버 실행 환경 |
| **Web Framework** | Express.js (v5.x) | REST API 및 정적 파일 서빙 |
| **Real-time** | Socket.io (v4.x) | 실시간 메시징 및 상태 동기화 |
| **P2P/Signaling** | PeerJS Server | WebRTC 기반 시그널링 |
| **Database** | SQLite (better-sqlite3) | 고성능 로컬 DB (WAL 모드 적용) |
| **Authentication** | Bcrypt | 비밀번호 암호화 저장 |
| **File Handling** | Multer | 프로필 및 채팅 파일 업로드 처리 |

## 2. 클라이언트 (Frontend - App/Windows)

| 구분 | 기술 스택 | 비고 |
| :--- | :--- | :--- |
| **Framework** | Flutter (v3.10.x 이상) | 크로스 플랫폼 개발 프레임워크 |
| **Language** | Dart | 클라이언트 개발 언어 |
| **State Management** | Provider | 전역 상태 관리 및 의존성 주입 |
| **Communication** | Socket.io Client / HTTP | 서버 실시간 연동 및 API 통신 |
| **Desktop Integration** | window_manager, tray_manager | 윈도우 창 제어 및 시스템 트레이 구현 |
| **Notification** | flutter_local_notifications | 안드로이드/윈도우 알림 처리 |
| **Background** | flutter_background_service | 안드로이드 백그라운드 메시지 수신 |
| **Storage** | shared_preferences | 사용자 개인 설정 및 토큰 저장 |

## 3. 보안 및 인증 (Security)

*   **기기 결합 인증 (MAC Binding)**: 관리자가 승인한 기기(MAC Address / Machine UUID)에서만 로그인이 가능하도록 제한.
*   **세션 관리**: 중복 로그인 방지(Kick-out) 로직 구현.
*   **암호화**: 모든 비밀번호는 솔트(Salt)를 포함한 단방향 해시로 저장.

## 4. 인프라 및 배포 (Infrastructure)

*   **Installer**: **Inno Setup**을 사용한 Windows용 통합 설치 패키지 제작.
*   **Tray Agent**: **Python (Tkinter/pystray)** 기반의 서버 관리 도구 구현.
*   **Distribution**: Express 서버를 통한 OTA(Over-The-Air) 업데이트 및 다운로드 페이지 제공.
*   **Backup**: 주간/월간/분기/연간 자동 데이터베이스 백업 스케줄러 탑재.

## 5. 디자인 원칙 (Design)

*   **Aesthetics**: Creative Dark Mode, Vibrant Colors, Glassmorphism 스타일 적용.
*   **UX**: 실시간 메시지 수신 시 자동 창 활성화(Windows) 및 인앱 배너 알림 시스템.
