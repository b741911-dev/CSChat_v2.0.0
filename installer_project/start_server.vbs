' CSChat Server Startup Script
' 스크립트 파일이 위치한 디렉토리를 작업 디렉토리로 설정

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' 스크립트 파일의 디렉토리 경로 가져오기
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

' 작업 디렉토리를 스크립트 위치로 변경
WshShell.CurrentDirectory = scriptDir

' Node.js 서버 실행 (창 보이기: 1, 숨기기: 0)
' 1 = 일반 창으로 표시, 0 = 숨김
WshShell.Run """" & scriptDir & "\bin\node.exe"" """ & scriptDir & "\index.js""", 1, False
