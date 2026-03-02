# CSChat 서버 인스톨러 스크립트 설명서
`CSChat_Server_Setup.iss`

이 문서는 CSChat 서버 인스톨러(`CSChat_Win_Server_install.exe`)를 생성하는 데 사용되는 Inno Setup 스크립트의 구조와 기능을 설명합니다.

## 1. 메타데이터 및 설치 설정 `[Setup]`
인스톨러의 핵심 속성을 정의합니다.
- **AppName**: `CSChat Server` (애플리케이션 이름)
- **AppVersion**: `1.0.0` (버전)
- **DefaultDirName**: `C:\Choeun\CSChat_Server` (기본 설치 경로)
- **PrivilegesRequired**: `admin` (설치 시 관리자 권한 필요)
- **Compression**: `lzma/solid` (고효율 압축 사용)
- **LicenseFile**: 설치 과정 중 `LICENSE.txt` 내용을 표시합니다.

## 2. 지원 언어 `[Languages]`
- **Korean**: 인스톨러 인터페이스 언어를 한국어로 설정합니다 (`compiler:Languages\Korean.isl`).

## 3. 설치 작업 `[Tasks]`
설치 시 사용자가 선택할 수 있는 추가 작업입니다.
- **autostart**: "윈도우 시작 시 서버 자동 실행". 선택 시 레지스트리에 자동 실행 항목을 등록합니다.

## 4. 설치 파일 구성 `[Files]`
인스톨러에 포함될 파일과 설치될 위치를 지정합니다.
- **서버 파일**: `c:\CSChat\CSChat_Server\*`의 모든 내용을 `{app}`(설치 경로)으로 복사합니다.
  - **제외 목록**: 개발 로그(`*.log`), 소스 맵, 그리고 특히 **`*.db`** 파일은 일반 복사에서 제외하여 기존 데이터를 덮어쓰지 않도록 합니다.
- **Node.js**: 실행에 필요한 `node.exe`를 `{app}\bin` 폴더에 포함합니다.
- **시작 스크립트**: 백그라운드 실행을 위한 `start_server.vbs`를 포함합니다.
- **데이터베이스 보존**:
  - `Source: "...\chat.db"; Flags: onlyifdoesntexist uninsneveruninstall`
  - **핵심**: 대상 컴퓨터에 `chat.db`가 이미 존재하면 **덮어쓰지 않습니다**. 또한 언인스톨 시에도 삭제되지 않고 보존됩니다.

## 5. 아이콘 및 바로가기 `[Icons]`
- **시작 메뉴**: 서버 실행 바로가기를 생성합니다 (`wscript.exe start_server.vbs`).
- **시작 프로그램**: `autostart` 작업 선택 시, 윈도우 시작 폴더에 바로가기를 생성하여 부팅 시 자동 실행되게 합니다.

## 6. 언인스톨 동작 `[UninstallRun]`
- **프로세스 정리**: 파일을 삭제하기 전에 실행 중인 `node.exe` 프로세스를 강제 종료하여 깨끗한 삭제를 보장합니다.

---

## 7. 커스텀 스크립트 로직 `[Code]`
(Pascal Script 섹션)

### A. 하드웨어 식별
- **GetSystemUUID**: WMI를 사용하여 `Win32_ComputerSystemProduct`의 UUID를 추출합니다.
- **GetSystemSerial**: WMI를 사용하여 `Win32_BIOS`의 시리얼 번호를 추출합니다. 찾을 수 없는 경우 기본값 `CS-2026-REG-001`을 사용합니다.

### B. 커스텀 마법사 페이지
1.  **라이선스 인증 페이지 (`LicensePage`)**:
    - 사용자의 **UUID**와 **시리얼 번호**를 표시합니다.
    - **"UUID 복사"**, **"시리얼 복사"** 버튼을 제공하여 쉽게 복사할 수 있습니다.
    - 이 하드웨어 정보를 기반으로 생성된 유효한 인증키를 입력해야만 설치를 진행할 수 있습니다.
2.  **서버 설정 페이지 (`ConfigPage`)**:
    - **서버 호스트 IP** (로컬 IP 자동 감지) 및 **포트** (기본값 `3001`)를 입력받습니다.

### C. 인증키 검증 (`ValidateKey`)
- 숨겨진 PowerShell 명령을 실행하여 입력된 인증키를 검증합니다.
- **알고리즘**: (UUID + 시리얼) 문자열을 비밀키로 서명한 `HMACSHA256` 해시를 Base32로 인코딩하고 `XXXX-XXXX-XXXX-XXXX` 형식으로 변환하여 비교합니다.
- **차단**: 키가 유효하지 않으면 설치 단계를 넘어갈 수 없습니다.

### D. 프로세스 관리 및 설정 생성
- **CurStepChanged(ssInstall)**: 파일 복사 전, "File in Use" 오류를 방지하기 위해 기존에 실행 중인 `node.exe` 프로세스를 종료합니다.
- **CurStepChanged(ssPostInstall)**: 사용자가 입력한 IP/Port 정보를 바탕으로 `config.json` 파일을 동적으로 생성하여 설치 경로에 저장합니다.
