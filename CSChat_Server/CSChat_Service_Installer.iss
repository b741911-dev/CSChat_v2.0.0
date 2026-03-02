; CSChat_Server Windows Service Installer Script
; NSSM을 사용하여 Node.js 서버를 서비스로 등록합니다.

[Setup]
AppName=CSChat_Server
AppVersion=1.0.7
DefaultDirName={autopf}\CSChat_Server
DefaultGroupName=CSChat_Server
OutputBaseFilename=CSChat_Server_Installer_v1.0.7
Compression=lzma
SolidCompression=yes
; 관리자 권한 필요
PrivilegesRequired=admin

[Files]
; 서버 파일들 (이미 빌드된 파일들이 있는 경로로 수정 필요)
Source: "C:\CSChat\CSChat_Server\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NSSM 실행 파일 (bin 폴더에 위치해야 함)
Source: "C:\CSChat\CSChat_Server\bin\nssm.exe"; DestDir: "{app}\bin"; Flags: ignoreversion

[Run]
; 1. 서비스 설치
; AppDirectory를 설정하여 작업 디렉토리를 소스 코드가 있는 곳으로 지정
Filename: "{app}\bin\nssm.exe"; Parameters: "install CSChat_Server ""node.exe"" ""{app}\index.js"""; Flags: runhidden
Filename: "{app}\bin\nssm.exe"; Parameters: "set CSChat_Server AppDirectory ""{app}"""; Flags: runhidden

; 2. 와치독(Watchdog) 및 자동 재시작 설정
; 서비스 종료 시 자동 재시작 (기본값이기도 하지만 명시적으로 설정)
Filename: "{app}\bin\nssm.exe"; Parameters: "set CSChat_Server AppExit Default Restart"; Flags: runhidden

; 3. 서비스 시작
Filename: "{app}\bin\nssm.exe"; Parameters: "start CSChat_Server"; Flags: runhidden

; 4. 서비스 관리 배치 파일 실행 (설치 완료 페이지에 체크박스 표시)
Filename: "{app}\service_manage.bat"; Description: "{cm:LaunchProgram,CSChat Server 서비스 관리 도구}"; Flags: postinstall shellexec skipifsilent

[UninstallRun]
; 삭제 시 서비스 중지 및 제거
Filename: "{app}\bin\nssm.exe"; Parameters: "stop CSChat_Server"; Flags: runhidden
Filename: "{app}\bin\nssm.exe"; Parameters: "remove CSChat_Server confirm"; Flags: runhidden

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Messages]
korean.FinishedHeadingLabel=CSChat_Server 서비스 설치 완료
korean.FinishedLabel=서비스가 성공적으로 등록되고 시작되었습니다. 이제 백그라운드에서 상시 작동합니다.
