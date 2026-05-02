@echo off
REM ============================================================
REM  Farshid AI WebClip - Windows launcher
REM
REM  ONLY TWO COMMANDS YOU NEED:
REM
REM    farshid.bat install   One-time setup:
REM                            - packs the extension
REM                            - stages a self-contained copy of the
REM                              bridge + extension + .crx into
REM                              %%USERPROFILE%%\.farshid\runtime\
REM                              (so it works even if this project
REM                               lives in OneDrive / Dropbox / a path
REM                               with spaces)
REM                            - force-installs into your normal Chrome
REM                              (HKLM policy, asks for UAC once)
REM                            - registers the bridge to auto-start at login
REM                          After this, just open Chrome and clip.
REM
REM    farshid.bat start     Start Ollama (if needed) + the local bridge.
REM                          The auto-start shortcut from `install` runs
REM                          this same command at every login, so you
REM                          rarely need to type it manually.
REM
REM  (Internal commands `pack`, `stage`, `forceinstall`, `forceuninstall`,
REM   `uninstall`, `chrome`, `all` still exist for advanced use.)
REM
REM  Optional override file: scripts\local.env.bat (gitignored)
REM    set PYTHON=C:\path\to\python.exe
REM    set OLLAMA=C:\path\to\ollama.exe
REM    set MODEL=qwen3:0.6b
REM    set CHROME=C:\path\to\chrome.exe
REM    set STAGE_DIR=C:\path\to\custom\runtime
REM ============================================================
setlocal EnableDelayedExpansion

REM ============================================================
REM When this script self-elevates via UAC, Windows replaces
REM USERPROFILE / APPDATA with the elevating admin account.
REM Our self-elevation code passes the real user's profile path
REM as a /home:... flag so we can put STAGE_DIR and the Startup
REM shortcut in the actual user's home, not the admin's.
REM ============================================================
set "_REAL_HOME="
for %%A in (%*) do (
    set "_A=%%~A"
    if /I "!_A:~0,6!"=="/home:" set "_REAL_HOME=!_A:~6!"
)
if not "%_REAL_HOME%"=="" (
    if exist "%_REAL_HOME%" (
        set "USERPROFILE=%_REAL_HOME%"
        set "APPDATA=%_REAL_HOME%\AppData\Roaming"
        set "LOCALAPPDATA=%_REAL_HOME%\AppData\Local"
    )
)

set "SCRIPT_DIR=%~dp0"
set "PROJECT_DIR=%SCRIPT_DIR%.."
set "BRIDGE_DIR=%PROJECT_DIR%\bridge"
set "EXT_DIR=%PROJECT_DIR%\extension"
set "LOG_DIR=%PROJECT_DIR%\logs"
set "DIST_DIR=%PROJECT_DIR%\dist"
for %%I in ("%EXT_DIR%")     do set "EXT_DIR=%%~fI"
for %%I in ("%PROJECT_DIR%") do set "PROJECT_DIR=%%~fI"
for %%I in ("%DIST_DIR%")    do set "DIST_DIR=%%~fI"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "CRX_FILE=%DIST_DIR%\farshid-ai-webclip.crx"
set "PEM_FILE=%DIST_DIR%\farshid-ai-webclip.pem"
set "UPDATES_XML=%DIST_DIR%\updates.xml"

if exist "%SCRIPT_DIR%local.env.bat" call "%SCRIPT_DIR%local.env.bat"

if "%PYTHON%"=="" set "PYTHON=python"
if "%OLLAMA%"=="" set "OLLAMA=ollama"
if "%MODEL%"==""  set "MODEL=granite4-fast:latest"

REM Staging dir under %USERPROFILE%\.farshid\runtime so the project
REM folder is never required at runtime. Mirrors the macOS / Linux
REM script. Override with STAGE_DIR in local.env.bat if you want.
if "%STAGE_DIR%"=="" set "STAGE_DIR=%USERPROFILE%\.farshid\runtime"
set "STAGE_BRIDGE=%STAGE_DIR%\bridge"
set "STAGE_DIST=%STAGE_DIR%\dist"
set "STAGE_EXT=%STAGE_DIR%\extension"
set "STAGE_LOG_DIR=%STAGE_DIR%\logs"
set "STAGE_LAUNCHER=%STAGE_DIR%\farshid.bat"
set "STAGE_CRX=%STAGE_DIST%\farshid-ai-webclip.crx"
set "STAGE_PEM=%STAGE_DIST%\farshid-ai-webclip.pem"
set "STAGE_UPDATES_XML=%STAGE_DIST%\updates.xml"

set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "BRIDGE_LINK=%STARTUP%\Farshid AI WebClip.lnk"
set "CHROME_LINK=%STARTUP%\Farshid AI WebClip - Chrome.lnk"

set "CMD=%~1"
if "%CMD%"=="" set "CMD=setup"
REM Strip a leading /home:... arg so it isn't treated as a command.
if /I "%CMD:~0,6%"=="/home:" set "CMD=%~2"
if "%CMD%"=="" set "CMD=setup"

if /I "%CMD%"=="setup"          goto :cmd_setup
if /I "%CMD%"=="start"     goto :cmd_start
if /I "%CMD%"=="chrome"    goto :cmd_chrome
if /I "%CMD%"=="all"       goto :cmd_all
if /I "%CMD%"=="install"        goto :cmd_install
if /I "%CMD%"=="uninstall"      goto :cmd_uninstall
if /I "%CMD%"=="pack"           goto :cmd_pack
if /I "%CMD%"=="stage"          goto :cmd_stage
if /I "%CMD%"=="forceinstall"   goto :cmd_forceinstall
if /I "%CMD%"=="forceuninstall" goto :cmd_forceuninstall
if /I "%CMD%"=="doctor"         goto :cmd_doctor
if /I "%CMD%"=="moc"            goto :cmd_moc
if /I "%CMD%"=="help"           goto :cmd_help
if /I "%CMD%"=="-h"        goto :cmd_help
if /I "%CMD%"=="/?"        goto :cmd_help

echo [farshid] Unknown command: %CMD%
goto :cmd_help

REM ------------------------------------------------------------
:cmd_help
echo.
echo Farshid AI WebClip
echo.
echo   Just double-click farshid.bat ^(no arguments^).
echo   It does everything for you:
echo     - packs the extension into a stable .crx
echo     - copies the runtime into %%USERPROFILE%%\.farshid\runtime
echo     - registers the extension with Chrome ^(asks for UAC once^)
echo     - installs an auto-start shortcut so the bridge runs at login
echo     - starts the bridge in this window
echo   Re-run any time you change the extension or bridge - it just
echo   re-syncs everything safely.
echo.
echo   farshid.bat start     Just start the bridge ^(no setup^).
echo   farshid.bat doctor    Diagnose: is everything healthy?
echo.
echo Advanced:  install ^| pack ^| stage ^| forceinstall ^| forceuninstall ^| uninstall ^| chrome ^| all ^| moc
echo.
endlocal
exit /b 0

REM ------------------------------------------------------------
REM Default action when the user just double-clicks farshid.bat.
REM No knowledge required: it does the full one-time setup
REM (UAC prompt the first time), then starts the bridge in this
REM same window. Closing the window stops the bridge.
REM Re-running it later is safe: it just re-syncs everything
REM (re-packs the .crx, re-stages, fixes the policy + shortcut)
REM so any changes to the extension or bridge take effect.
:cmd_setup
echo.
echo === Farshid AI WebClip - one-click setup ===
echo.
net session >nul 2>&1
if errorlevel 1 (
    echo [farshid] One-time admin step needed to register the extension
    echo           with Chrome. A UAC prompt will appear next.
    powershell -NoProfile -Command "Start-Process -Wait -Verb RunAs -FilePath '%~f0' -ArgumentList @('/home:%USERPROFILE%','install')"
    if errorlevel 1 (
        echo [farshid] Elevated setup was cancelled or failed.
        pause
        endlocal
        exit /b 1
    )
) else (
    REM Already running elevated - just do the install steps inline.
    call :do_pack
    if errorlevel 1 ( pause & endlocal & exit /b 1 )
    call :do_stage
    if errorlevel 1 ( pause & endlocal & exit /b 1 )
    call :do_forceinstall
    if errorlevel 1 ( pause & endlocal & exit /b 1 )
    if exist "%CHROME_LINK%" del "%CHROME_LINK%"
    set "FAIL=0"
    call :install_shortcut "%STAGE_LAUNCHER%" "start" "%BRIDGE_LINK%" "Farshid AI WebClip bridge + Ollama"
    if not "%FAIL%"=="0" ( pause & endlocal & exit /b 1 )
)
echo.
echo === Setup complete. ===
echo.
echo NEXT STEPS:
echo   1) Fully quit Chrome ^(close ALL windows AND any tray icon^).
echo   2) Reopen Chrome - 'Farshid AI WebClip' will be loaded automatically.
echo.
echo The bridge will now start in this window. Closing this window stops it.
echo It will auto-start at every Windows login from now on.
echo.
set "LAUNCH_CHROME="
goto :cmd_start

REM ------------------------------------------------------------
:cmd_moc
REM Rebuild %USERPROFILE%\.farshid\MOC.md from existing clips.
curl -fsS --max-time 2 "http://127.0.0.1:8765/moc" >nul 2>nul
if %ERRORLEVEL%==0 (
    curl -fsS "http://127.0.0.1:8765/moc"
    echo.
) else (
    if exist "%STAGE_BRIDGE%\server.py" (
        "%PYTHON%" "%STAGE_BRIDGE%\server.py" --moc
    ) else (
        "%PYTHON%" "%PROJECT_DIR%\bridge\server.py" --moc
    )
)
endlocal
exit /b 0

REM ------------------------------------------------------------
:cmd_doctor
echo.
echo === Farshid AI WebClip - doctor ===
echo.
echo [1] OS:                Windows (%PROCESSOR_ARCHITECTURE%)
echo [2] Project dir:       %PROJECT_DIR%
echo [3] Stage dir:         %STAGE_DIR%
if exist "%STAGE_CRX%" (echo     OK   %STAGE_CRX%) else (echo     MISS %STAGE_CRX%   ^(run: farshid.bat install^))
if exist "%STAGE_UPDATES_XML%" (echo     OK   %STAGE_UPDATES_XML%) else (echo     MISS %STAGE_UPDATES_XML%)
if exist "%STAGE_EXT%\manifest.json" (
    echo [4] Staged extension:  OK   %STAGE_EXT%
    findstr /C:"\"tabs\"" "%STAGE_EXT%\manifest.json" >nul 2>nul && (echo         snapshot perm:    OK ^('tabs' present^)) || (echo         snapshot perm:    MISS ^('tabs' missing - re-stage^))
) else (
    echo [4] Staged extension:  MISS %STAGE_EXT%   ^(run: farshid.bat stage^)
)
if exist "%USERPROFILE%\.farshid\template-webclip-ai.md" (echo [5] PKM template:      OK   %USERPROFILE%\.farshid\template-webclip-ai.md) else (echo [5] PKM template:      MISS  ^(auto-created on first clip^))
echo [6] Bridge /health:
curl -fsS --max-time 2 "http://127.0.0.1:8765/health" 2>nul && echo. || echo     DOWN  ^(run: farshid.bat start^)
echo [7] Startup shortcut:
set "_LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Farshid AI WebClip.lnk"
if exist "%_LNK%" (echo     OK   %_LNK%) else (echo     MISS %_LNK%   ^(run: farshid.bat install^))
echo.
endlocal
exit /b 0

REM ------------------------------------------------------------
:cmd_all
set "LAUNCH_CHROME=1"
goto :cmd_start

:cmd_start
echo [farshid] Checking Ollama on http://127.0.0.1:11434 ...
powershell -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2) | Out-Null; exit 0 } catch { exit 1 }"
if errorlevel 1 (
    echo [farshid] Starting Ollama in background...
    start "" /B "%OLLAMA%" serve > "%LOG_DIR%\ollama.log" 2>&1
    powershell -NoProfile -Command "for ($i=0; $i -lt 20; $i++) { try { (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 1) | Out-Null; exit 0 } catch { Start-Sleep -Milliseconds 500 } }; exit 1"
) else (
    echo [farshid] Ollama already running.
)

echo [farshid] Ensuring model "%MODEL%" is pulled...
"%OLLAMA%" pull "%MODEL%" >> "%LOG_DIR%\ollama.log" 2>&1

if /I "%LAUNCH_CHROME%"=="1" (
    echo [farshid] Launching Chrome with extension...
    call :launch_chrome
)

echo [farshid] Starting bridge from "%BRIDGE_DIR%"
REM Prefer the staged copy under %USERPROFILE%\.farshid\runtime\bridge
REM if present. That path is stable even when the project lives in
REM OneDrive / Dropbox or moves around.
set "_BRIDGE_DIR=%BRIDGE_DIR%"
if exist "%STAGE_BRIDGE%\server.py" (
    set "_BRIDGE_DIR=%STAGE_BRIDGE%"
    echo [farshid] Using staged bridge: %STAGE_BRIDGE%
)
cd /d "%_BRIDGE_DIR%"
"%PYTHON%" server.py
endlocal
exit /b %errorlevel%

REM ------------------------------------------------------------
:cmd_chrome
call :launch_chrome
endlocal
exit /b %errorlevel%

:launch_chrome
if "%CHROME%"=="" (
    if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
)
if "%CHROME%"=="" (
    if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
)
if "%CHROME%"=="" (
    if exist "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" set "CHROME=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
)
if "%CHROME%"=="" (
    echo [farshid] Cannot find chrome.exe. Set CHROME in scripts\local.env.bat
    exit /b 1
)
if "%CHROME_PROFILE%"=="" set "CHROME_PROFILE=%LOCALAPPDATA%\farshid-ai-webclip\chrome-profile"
if not exist "%CHROME_PROFILE%" mkdir "%CHROME_PROFILE%"

REM Prefer the staged unpacked extension folder so this works even
REM if the project itself is on OneDrive / Dropbox.
set "_EXT_DIR=%EXT_DIR%"
if exist "%STAGE_EXT%\manifest.json" set "_EXT_DIR=%STAGE_EXT%"

echo [farshid] Chrome:        %CHROME%
echo [farshid] Extension:     %_EXT_DIR%
echo [farshid] User profile:  %CHROME_PROFILE%
start "" "%CHROME%" --user-data-dir="%CHROME_PROFILE%" --load-extension="%_EXT_DIR%" --no-first-run --no-default-browser-check
goto :eof

REM ------------------------------------------------------------
:cmd_install
REM 1) Pack + force-install the extension into the user's normal
REM    Chrome profile via HKLM policy (UAC). After this, the
REM    extension survives every reboot inside the Chrome they
REM    actually use day-to-day.
REM 2) Drop a Startup-folder shortcut for the bridge + Ollama so
REM    the localhost helper is up at every login.
REM
REM We deliberately do NOT autostart a separate Chrome window.
REM The extension lives in the normal Chrome profile now.

REM Self-elevate up front so the whole install runs as admin.
REM (APPDATA still points at the real user under UAC, so the
REM Startup-folder shortcut goes in the right place.)
net session >nul 2>&1
if errorlevel 1 (
    echo [farshid] Elevation required. Re-launching as administrator ^(UAC^)...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList @('/home:%USERPROFILE%','install') -Verb RunAs"
    endlocal
    exit /b 0
)

echo [farshid] Step 1/4 - packing extension...
call :do_pack
if errorlevel 1 ( pause & endlocal & exit /b 1 )

echo.
echo [farshid] Step 2/4 - staging runtime into %STAGE_DIR% ...
call :do_stage
if errorlevel 1 ( pause & endlocal & exit /b 1 )

echo.
echo [farshid] Step 3/4 - force-installing into your normal Chrome...
call :do_forceinstall
if errorlevel 1 ( pause & endlocal & exit /b 1 )

echo.
echo [farshid] Step 4/4 - installing bridge auto-start shortcut...
REM Remove any previous Chrome-dedicated-profile autostart from older versions.
if exist "%CHROME_LINK%" del "%CHROME_LINK%"
set "FAIL=0"
REM Point the Startup-folder shortcut at the STAGED launcher copy so
REM the autostart never depends on the project folder existing.
call :install_shortcut "%STAGE_LAUNCHER%" "start" "%BRIDGE_LINK%" "Farshid AI WebClip bridge + Ollama"
if not "%FAIL%"=="0" (
    echo [farshid] Failed to create bridge shortcut.
    pause & endlocal & exit /b 1
)

echo.
echo [farshid] Done. After your next Windows restart:
echo           - The bridge + Ollama start automatically at login.
echo           - Open Chrome normally; the extension is locked-on
echo             with an "Installed by your administrator" badge.
echo [farshid] Tip: fully quit Chrome now ^(incl. system-tray icon^)
echo               then reopen, to load the extension immediately.
pause
endlocal
exit /b 0

:install_shortcut
REM %~1 = farshid.bat path   %~2 = subcommand   %~3 = .lnk path   %~4 = description
set "_T=%~1"
set "_A=%~2"
set "_L=%~3"
set "_D=%~4"
echo [farshid] Creating Startup shortcut: "%_L%"
powershell -NoProfile -Command ^
  "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut('%_L%'); $sc.TargetPath = '%_T%'; $sc.Arguments = '%_A%'; $sc.WorkingDirectory = '%SCRIPT_DIR%'; $sc.WindowStyle = 7; $sc.IconLocation = '%PROJECT_DIR%\farshid.png,0'; $sc.Description = '%_D%'; $sc.Save()"
if not exist "%_L%" (
    echo [farshid] Failed to create "%_L%"
    set "FAIL=1"
)
goto :eof

REM ------------------------------------------------------------
:cmd_uninstall
call :remove_link "%BRIDGE_LINK%"
call :remove_link "%CHROME_LINK%"
echo.
echo [farshid] To also remove the Chrome force-install policy:
echo               farshid.bat forceuninstall
echo [farshid] To wipe the staged runtime:
echo               rmdir /S /Q "%STAGE_DIR%"
endlocal
exit /b 0

:remove_link
if exist "%~1" (
    del "%~1"
    echo [farshid] Removed "%~1"
) else (
    echo [farshid] Not present:  "%~1"
)
goto :eof

REM ------------------------------------------------------------
:cmd_pack
call :do_pack
endlocal
exit /b %errorlevel%

REM ------------------------------------------------------------
:cmd_stage
call :do_stage
endlocal
exit /b %errorlevel%

:do_stage
REM Build a self-contained runtime tree under %STAGE_DIR%:
REM   bridge\        - bridge code
REM   extension\     - unpacked MV3 extension
REM   dist\          - .crx, .pem, updates.xml (codebase rewritten)
REM   logs\          - bridge logs
REM   farshid.bat    - copy of this launcher
REM
REM After staging, the Startup-folder shortcut and the HKLM Chrome
REM policy both point at this tree, so the project folder is no
REM longer needed at runtime (and OneDrive / Dropbox sandboxing
REM cannot break startup).
if not exist "%CRX_FILE%" call :do_pack
if errorlevel 1 exit /b 1
echo [farshid] Staging runtime into %STAGE_DIR%
if not exist "%STAGE_DIR%"     mkdir "%STAGE_DIR%"
if not exist "%STAGE_BRIDGE%"  mkdir "%STAGE_BRIDGE%"
if not exist "%STAGE_DIST%"    mkdir "%STAGE_DIST%"
if not exist "%STAGE_LOG_DIR%" mkdir "%STAGE_LOG_DIR%"
if exist "%STAGE_EXT%" rmdir /S /Q "%STAGE_EXT%"
mkdir "%STAGE_EXT%"

xcopy "%BRIDGE_DIR%\*.py" "%STAGE_BRIDGE%\" /Y /Q >nul
xcopy "%EXT_DIR%"        "%STAGE_EXT%\"   /E /Y /Q >nul
copy /Y "%CRX_FILE%" "%STAGE_CRX%" >nul
copy /Y "%PEM_FILE%" "%STAGE_PEM%" >nul
copy /Y "%~f0"       "%STAGE_LAUNCHER%" >nul

REM Re-write updates.xml so codebase= points at the STAGED .crx
REM (the one inside the project folder may move).
call :write_idscript
set "EXT_ID="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%IDSCRIPT%" "%STAGE_CRX%"`) do set "EXT_ID=%%I"
if "%EXT_ID%"=="" (
    echo [farshid] Could not derive extension ID from staged .crx
    exit /b 1
)
set "EXT_VERSION=0.0.0"
for /f "tokens=2 delims=:," %%V in ('findstr /R /C:"\"version\"" "%EXT_DIR%\manifest.json"') do (
    set "EXT_VERSION=%%~V"
    goto :stage_got_version
)
:stage_got_version
set "EXT_VERSION=%EXT_VERSION: =%"
set "EXT_VERSION=%EXT_VERSION:"=%"
set "STAGE_CRX_URL=%STAGE_CRX:\=/%"
set "STAGE_CRX_URL=file:///%STAGE_CRX_URL%"
>  "%STAGE_UPDATES_XML%" echo ^<?xml version='1.0' encoding='UTF-8'?^>
>> "%STAGE_UPDATES_XML%" echo ^<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'^>
>> "%STAGE_UPDATES_XML%" echo   ^<app appid='%EXT_ID%'^>
>> "%STAGE_UPDATES_XML%" echo     ^<updatecheck codebase='%STAGE_CRX_URL%' version='%EXT_VERSION%' /^>
>> "%STAGE_UPDATES_XML%" echo   ^</app^>
>> "%STAGE_UPDATES_XML%" echo ^</gupdate^>

echo [farshid] Staged:
echo     bridge      %STAGE_BRIDGE%
echo     extension   %STAGE_EXT%
echo     .crx        %STAGE_CRX%
echo     updates.xml %STAGE_UPDATES_XML%
echo     launcher    %STAGE_LAUNCHER%
exit /b 0

:do_pack
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
call :resolve_chrome_only
if errorlevel 1 exit /b 1

REM Chrome --pack-extension writes <ext>.crx and <ext>.pem next to <ext>\.
REM Reuse the .pem if it already exists so the extension ID stays stable.
set "TMP_CRX=%EXT_DIR%.crx"
set "TMP_PEM=%EXT_DIR%.pem"
if exist "%TMP_CRX%" del "%TMP_CRX%"
if exist "%TMP_PEM%" del "%TMP_PEM%"

if exist "%PEM_FILE%" (
    echo [farshid] Reusing existing key: "%PEM_FILE%"
    "%CHROME%" --pack-extension="%EXT_DIR%" --pack-extension-key="%PEM_FILE%" >nul 2>&1
) else (
    echo [farshid] Generating new signing key ^(will be saved to %PEM_FILE%^)
    "%CHROME%" --pack-extension="%EXT_DIR%" >nul 2>&1
)

if not exist "%TMP_CRX%" (
    echo [farshid] Pack failed - chrome did not produce "%TMP_CRX%"
    exit /b 1
)
move /Y "%TMP_CRX%" "%CRX_FILE%" >nul
if exist "%TMP_PEM%" move /Y "%TMP_PEM%" "%PEM_FILE%" >nul

REM Read manifest version (simple grep) for updates.xml.
set "EXT_VERSION=0.0.0"
for /f "tokens=2 delims=:," %%V in ('findstr /R /C:"\"version\"" "%EXT_DIR%\manifest.json"') do (
    set "EXT_VERSION=%%~V"
    goto :got_version
)
:got_version
set "EXT_VERSION=%EXT_VERSION: =%"
set "EXT_VERSION=%EXT_VERSION:"=%"

call :write_idscript
set "EXT_ID="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%IDSCRIPT%" "%CRX_FILE%"`) do set "EXT_ID=%%I"

if "%EXT_ID%"=="" (
    echo [farshid] Could not derive extension ID from "%CRX_FILE%"
    exit /b 1
)

REM Build update_url path: file:///C:/... with forward slashes.
set "CRX_URL=%CRX_FILE:\=/%"
set "CRX_URL=file:///%CRX_URL%"

>  "%UPDATES_XML%" echo ^<?xml version='1.0' encoding='UTF-8'?^>
>> "%UPDATES_XML%" echo ^<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'^>
>> "%UPDATES_XML%" echo   ^<app appid='%EXT_ID%'^>
>> "%UPDATES_XML%" echo     ^<updatecheck codebase='%CRX_URL%' version='%EXT_VERSION%' /^>
>> "%UPDATES_XML%" echo   ^</app^>
>> "%UPDATES_XML%" echo ^</gupdate^>

echo.
echo [farshid] Packed:
echo   .crx        %CRX_FILE%
echo   .pem        %PEM_FILE%   ^(KEEP SECRET, do not commit^)
echo   updates.xml %UPDATES_XML%
echo   ID          %EXT_ID%
echo   version     %EXT_VERSION%
exit /b 0

:resolve_chrome_only
if not "%CHROME%"=="" goto :eof
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe" & goto :eof
if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" & goto :eof
if exist "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" set "CHROME=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" & goto :eof
echo [farshid] Cannot find chrome.exe. Set CHROME in scripts\local.env.bat
exit /b 1

REM ------------------------------------------------------------
:cmd_forceinstall
REM Self-elevate if needed.
net session >nul 2>&1
if errorlevel 1 (
    echo [farshid] Elevation required to write Chrome policy under HKLM.
    echo [farshid] Re-launching as administrator ^(UAC prompt^)...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList @('/home:%USERPROFILE%','forceinstall') -Verb RunAs"
    endlocal
    exit /b 0
)
call :do_forceinstall
set "_RC=%errorlevel%"
if "%_RC%"=="0" (
    echo.
    echo [farshid] Done. Restart Chrome ^(close ALL windows including background tray^).
    echo           Verify at:   chrome://policy   and   chrome://extensions
)
pause
endlocal
exit /b %_RC%

:do_forceinstall
if not exist "%CRX_FILE%" (
    echo [farshid] No packed .crx found. Run "farshid.bat pack" first.
    exit /b 1
)
if not exist "%UPDATES_XML%" (
    echo [farshid] No updates.xml found. Run "farshid.bat pack" first.
    exit /b 1
)

REM Prefer the staged .crx + updates.xml so the policy points at
REM the stable %USERPROFILE%\.farshid\runtime path even after the
REM project folder moves.
set "_CRX_FILE=%CRX_FILE%"
set "_UPDATES_XML=%UPDATES_XML%"
if exist "%STAGE_CRX%"          set "_CRX_FILE=%STAGE_CRX%"
if exist "%STAGE_UPDATES_XML%"  set "_UPDATES_XML=%STAGE_UPDATES_XML%"

call :write_idscript
set "EXT_ID="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%IDSCRIPT%" "%_CRX_FILE%"`) do set "EXT_ID=%%I"
if "%EXT_ID%"=="" (
    echo [farshid] Could not derive extension ID from "%_CRX_FILE%"
    exit /b 1
)

set "UPDATES_URL=%_UPDATES_XML:\=/%"
set "UPDATES_URL=file:///%UPDATES_URL%"
set "FORCELIST_KEY=HKLM\Software\Policies\Google\Chrome\ExtensionInstallForcelist"
set "SOURCES_KEY=HKLM\Software\Policies\Google\Chrome\ExtensionInstallSources"

echo [farshid] Extension ID: %EXT_ID%
echo [farshid] Update URL:   %UPDATES_URL%
echo [farshid] Writing HKLM policy keys...
reg add "%FORCELIST_KEY%" /v 1 /t REG_SZ /d "%EXT_ID%;%UPDATES_URL%" /f
if errorlevel 1 ( echo [farshid] Failed to write %FORCELIST_KEY% & exit /b 1 )
reg add "%SOURCES_KEY%"   /v 1 /t REG_SZ /d "file:///*" /f
if errorlevel 1 ( echo [farshid] Failed to write %SOURCES_KEY% & exit /b 1 )
exit /b 0

REM ------------------------------------------------------------
:cmd_forceuninstall
set "FORCELIST_KEY=HKLM\Software\Policies\Google\Chrome\ExtensionInstallForcelist"
set "SOURCES_KEY=HKLM\Software\Policies\Google\Chrome\ExtensionInstallSources"

net session >nul 2>&1
if errorlevel 1 (
    echo [farshid] Elevation required to remove Chrome policy under HKLM.
    echo [farshid] Re-launching as administrator ^(UAC prompt^)...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList @('/home:%USERPROFILE%','forceuninstall') -Verb RunAs"
    endlocal
    exit /b 0
)

reg delete "%FORCELIST_KEY%" /v 1 /f >nul 2>&1
reg delete "%SOURCES_KEY%"   /v 1 /f >nul 2>&1
echo [farshid] Removed force-install policy. Restart Chrome to apply.
pause
endlocal
exit /b 0

REM ------------------------------------------------------------
REM  Write a small PowerShell script to %TEMP% that prints the
REM  CRX3 extension ID for a given .crx path. Inlining this as
REM  -Command exceeds the Windows command-line length limit.
:write_idscript
set "IDSCRIPT=%TEMP%\farshid_crxid.ps1"
>  "%IDSCRIPT%" echo param([string]$crx)
>> "%IDSCRIPT%" echo $b = [IO.File]::ReadAllBytes($crx)
>> "%IDSCRIPT%" echo if ([Text.Encoding]::ASCII.GetString($b,0,4) -ne 'Cr24') { throw 'not a CRX3 file' }
>> "%IDSCRIPT%" echo $hs = [BitConverter]::ToUInt32($b,8)
>> "%IDSCRIPT%" echo $h  = $b[12..(11+$hs)]
>> "%IDSCRIPT%" echo function ReadVarint($buf,$o) {
>> "%IDSCRIPT%" echo     $v=0; $s=0; $n=0
>> "%IDSCRIPT%" echo     while ($true) {
>> "%IDSCRIPT%" echo         $x = $buf[$o+$n]; $n++
>> "%IDSCRIPT%" echo         $v = $v -bor (([int]($x -band 0x7f)) -shl $s)
>> "%IDSCRIPT%" echo         if (($x -band 0x80) -eq 0) { break }
>> "%IDSCRIPT%" echo         $s += 7
>> "%IDSCRIPT%" echo     }
>> "%IDSCRIPT%" echo     ,@($v,$n)
>> "%IDSCRIPT%" echo }
>> "%IDSCRIPT%" echo $i = 0; $pk = $null
>> "%IDSCRIPT%" echo while ($i -lt $h.Length) {
>> "%IDSCRIPT%" echo     $tag = $h[$i]; $i++
>> "%IDSCRIPT%" echo     $w = $tag -band 7
>> "%IDSCRIPT%" echo     $f = $tag -shr 3
>> "%IDSCRIPT%" echo     if ($w -eq 2) {
>> "%IDSCRIPT%" echo         $r = ReadVarint $h $i; $L = $r[0]; $i += $r[1]
>> "%IDSCRIPT%" echo         if ($f -eq 2 -and $pk -eq $null) {
>> "%IDSCRIPT%" echo             $pr = $h[$i..($i+$L-1)]
>> "%IDSCRIPT%" echo             if ($pr[0] -eq 0x0a) {
>> "%IDSCRIPT%" echo                 $r2 = ReadVarint $pr 1; $pl = $r2[0]; $po = 1 + $r2[1]
>> "%IDSCRIPT%" echo                 $pk = $pr[$po..($po+$pl-1)]
>> "%IDSCRIPT%" echo                 break
>> "%IDSCRIPT%" echo             }
>> "%IDSCRIPT%" echo         }
>> "%IDSCRIPT%" echo         $i += $L
>> "%IDSCRIPT%" echo     } elseif ($w -eq 0) {
>> "%IDSCRIPT%" echo         $r = ReadVarint $h $i; $i += $r[1]
>> "%IDSCRIPT%" echo     } else { break }
>> "%IDSCRIPT%" echo }
>> "%IDSCRIPT%" echo if ($pk -eq $null) { throw 'public key not found in CRX header' }
>> "%IDSCRIPT%" echo $sha = [Security.Cryptography.SHA256]::Create().ComputeHash($pk)
>> "%IDSCRIPT%" echo -join ($sha[0..15] ^| ForEach-Object {
>> "%IDSCRIPT%" echo     [string][char]([int][char]'a' + ($_ -shr 4)) + [string][char]([int][char]'a' + ($_ -band 0x0f))
>> "%IDSCRIPT%" echo })
goto :eof
