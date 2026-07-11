@ECHO OFF
SETLOCAL
SET "_CCSWITCH_CODEX_LAUNCHER=%USERPROFILE%\.prodex\bin\invoke-ccswitch-codex.ps1"
WHERE pwsh.exe >NUL 2>NUL
IF %ERRORLEVEL% EQU 0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%_CCSWITCH_CODEX_LAUNCHER%" %*
) ELSE (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%_CCSWITCH_CODEX_LAUNCHER%" %*
)
SET "_CCSWITCH_CODEX_EXIT=%ERRORLEVEL%"
ENDLOCAL & EXIT /B %_CCSWITCH_CODEX_EXIT%
