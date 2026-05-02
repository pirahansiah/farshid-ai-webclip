@echo off
REM ============================================================
REM  start.bat - Boot all background services for Farshid AI
REM
REM  Run this once after a Windows reboot (or pin it to Startup).
REM  It starts everything HIDDEN (no console windows):
REM
REM    1. Ollama         (http://127.0.0.1:11434)
REM    2. SearXNG        (http://127.0.0.1:8888, via Docker)
REM    3. Farshid bridge (http://127.0.0.1:8765)
REM
REM  Safe to run multiple times: each service is only started
REM  if it isn't already listening on its port.
REM
REM  Logs:
REM    %USERPROFILE%\.farshid\ollama.log
REM    %USERPROFILE%\.farshid\searxng.log
REM    %USERPROFILE%\.farshid\bridge.log
REM ============================================================
setlocal EnableDelayedExpansion

set "HOME_DIR=%USERPROFILE%\.farshid"
if not exist "%HOME_DIR%" mkdir "%HOME_DIR%"

REM ---- Resolve ollama.exe ------------------------------------
set "OLLAMA=ollama"
where %OLLAMA% >nul 2>&1
if errorlevel 1 (
    if exist "%LOCALAPPDATA%\Programs\Ollama\ollama.exe" (
        set "OLLAMA=%LOCALAPPDATA%\Programs\Ollama\ollama.exe"
    ) else if exist "%ProgramFiles%\Ollama\ollama.exe" (
        set "OLLAMA=%ProgramFiles%\Ollama\ollama.exe"
    )
)

REM ---- Resolve farshid hidden launcher -----------------------
set "FARSHID_VBS=%USERPROFILE%\.farshid\runtime\bridge-hidden.vbs"

REM ---- SearXNG container name (override here if different) ---
if "%SEARXNG_CONTAINER%"=="" set "SEARXNG_CONTAINER=searxng"
if "%SEARXNG_PORT%"=="" set "SEARXNG_PORT=8888"

echo.
echo === start.bat - launching background services ===
echo.

REM ---- 1) Ollama ---------------------------------------------
call :is_listening 11434
if "%LISTENING%"=="1" (
    echo [ollama]   already running on 11434
) else (
    echo [ollama]   starting hidden...
    call :run_hidden "%OLLAMA%" "serve" "%HOME_DIR%\ollama.log"
)

REM ---- 2) SearXNG (Docker container) -------------------------
call :is_listening %SEARXNG_PORT%
if "%LISTENING%"=="1" (
    echo [searxng]  already running on %SEARXNG_PORT%
) else (
    where docker >nul 2>&1
    if errorlevel 1 (
        echo [searxng]  SKIP - docker not on PATH
    ) else (
        docker inspect "%SEARXNG_CONTAINER%" >nul 2>&1
        if errorlevel 1 (
            echo [searxng]  SKIP - no docker container named "%SEARXNG_CONTAINER%"
            echo            create one with e.g.:
            echo            docker run -d --name searxng -p %SEARXNG_PORT%:8080 --restart unless-stopped searxng/searxng
        ) else (
            echo [searxng]  starting container "%SEARXNG_CONTAINER%"...
            docker start "%SEARXNG_CONTAINER%" >> "%HOME_DIR%\searxng.log" 2>&1
        )
    )
)

REM ---- 3) Farshid bridge -------------------------------------
call :is_listening 8765
if "%LISTENING%"=="1" (
    echo [bridge]   already running on 8765
) else (
    if exist "%FARSHID_VBS%" (
        echo [bridge]   starting hidden via %FARSHID_VBS%
        wscript //nologo "%FARSHID_VBS%"
    ) else (
        echo [bridge]   SKIP - %FARSHID_VBS% not staged
        echo            run once: scripts\farshid.bat install
    )
)

echo.
echo Done. Tail logs in: %HOME_DIR%
endlocal
exit /b 0

REM ============================================================
:is_listening
REM Sets LISTENING=1 if the given TCP port is in LISTEN state.
set "LISTENING=0"
for /f "tokens=*" %%L in ('powershell -NoProfile -Command "if (Get-NetTCPConnection -LocalPort %~1 -State Listen -ErrorAction SilentlyContinue) { 'Y' }"') do set "LISTENING=1"
goto :eof

:run_hidden
REM %~1 = exe   %~2 = args   %~3 = log file
REM Launches an EXE fully hidden (no console window) via a tiny
REM ad-hoc VBScript, so it survives this script exiting.
set "_EXE=%~1"
set "_ARGS=%~2"
set "_LOG=%~3"
set "_VBS=%TEMP%\farshid_run_hidden_%RANDOM%.vbs"
> "%_VBS%" echo Set sh = CreateObject("WScript.Shell")
>>"%_VBS%" echo sh.Run "cmd /c """"%_EXE:\=\\%"" %_ARGS% >> """"%_LOG%"""" 2>&1""", 0, False
wscript //nologo "%_VBS%"
del "%_VBS%" >nul 2>&1
goto :eof
