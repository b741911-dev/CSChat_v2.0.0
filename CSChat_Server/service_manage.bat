@echo off
cd /d "%~dp0"
:: 관리자 권한 체크 및 승격
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 관리자 권한으로 재실행 중...
    powershell -Command "Start-Process -FilePath '%0' -Verb RunAs" 
    exit /b
)

set SERVICE_NAME=CSChat_Server
set NSSM_PATH=bin\nssm.exe

:MENU
cls
echo ============================================
echo      CSChat Server 서비스 관리 도구
echo ============================================
echo  1. 서비스 상태 확인 (Status)
echo  2. 서비스 시작 (Start)
echo  3. 서비스 중지 (Stop)
echo  4. 서비스 재시작 (Restart)
echo  5. 종료 (Exit)
echo ============================================
set /p choice="원하는 작업 번호를 입력하세요: "

if "%choice%"=="1" goto STATUS
if "%choice%"=="2" goto START
if "%choice%"=="3" goto STOP
if "%choice%"=="4" goto RESTART
if "%choice%"=="5" goto EXIT
goto MENU

:STATUS
echo.
echo [상태 확인 중...]
"%NSSM_PATH%" status %SERVICE_NAME%
pause
goto MENU

:START
echo.
echo [서비스 시작 중...]
"%NSSM_PATH%" start %SERVICE_NAME%
pause
goto MENU

:STOP
echo.
echo [서비스 중지 중...]
"%NSSM_PATH%" stop %SERVICE_NAME%
pause
goto MENU

:RESTART
echo.
echo [서비스 재시작 중...]
"%NSSM_PATH%" restart %SERVICE_NAME%
pause
goto MENU

:EXIT
exit
