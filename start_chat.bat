@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
title AlphaInference - Chat Server

set "BASE_DIR=%~dp0"
set "VENDOR_DIR=%BASE_DIR%vendor"
set "PYTHON_DIR=%VENDOR_DIR%\python"
set "OLLAMA_DIR=%VENDOR_DIR%\ollama"
set "SD_DIR=%VENDOR_DIR%\stable-diffusion"
set "SERVER_PORT=5000"

set "PS_EXE="
where powershell.exe >nul 2>&1 && set "PS_EXE=powershell.exe"
if not defined PS_EXE where pwsh.exe >nul 2>&1 && set "PS_EXE=pwsh.exe"

if not defined ALPHA_RESTART_OLLAMA set "ALPHA_RESTART_OLLAMA=0"

:: If ALPHA_EXPOSE_LAN was not set by a parent process, ask the user.
if not defined ALPHA_EXPOSE_LAN (
    cls
    echo.
    echo  +----------------------------------------------------------+
    echo  ^|         AlphaInference - Chat Server                     ^|
    echo  +----------------------------------------------------------+
    echo.
    echo   Make this application discoverable over the network?
    echo   Other devices on your LAN will be able to open the Chat UI.
    echo.
    set "_SC_LAN="
    set /p "_SC_LAN=  Allow network access? [y/n]: "
    if /I "!_SC_LAN!"=="y" (
        set "ALPHA_EXPOSE_LAN=1"
    ) else (
        set "ALPHA_EXPOSE_LAN=0"
    )
)
call :APPLY_LAN_SETTING
set "SERVER_BIND_HOST=127.0.0.1"
set "SERVER_UI_HOST=127.0.0.1"
if /I "!ALPHA_EXPOSE_LAN!"=="1" (
    set "SERVER_BIND_HOST=0.0.0.0"
    if defined PS_EXE (
        for /f "usebackq delims=" %%I in (`"!PS_EXE!" -NoProfile -Command "$ip=Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*'} | Select-Object -First 1 -ExpandProperty IPAddress; if($ip){$ip}" 2^>nul`) do set "SERVER_UI_HOST=%%I"
    ) else (
        for /f "tokens=2 delims=:" %%I in ('ipconfig ^| findstr /R /C:"IPv4" ^| findstr /V "127.0.0.1 169.254."') do (
            set "_IP_CAND=%%I"
            set "_IP_CAND=!_IP_CAND: =!"
            if not "!_IP_CAND!"=="" if "!SERVER_UI_HOST!"=="127.0.0.1" set "SERVER_UI_HOST=!_IP_CAND!"
        )
    )
)

set "LOCAL_URL=http://127.0.0.1:%SERVER_PORT%"
set "LAN_URL=http://%SERVER_UI_HOST%:%SERVER_PORT%"
set "HEALTH_URL=%LOCAL_URL%/api/health"

:: ============================================================
:: Portability isolation
:: ============================================================
set "OLLAMA_MODELS=%BASE_DIR%models\ollama"
set "OLLAMA_HOME=%VENDOR_DIR%\ollama_home"
set "OLLAMA_HOST=127.0.0.1:11434"
set "OLLAMA_KV_CACHE_TYPE=q8_0"
set "SD_WEIGHT_TYPE=f16"

if not exist "%OLLAMA_MODELS%" mkdir "%OLLAMA_MODELS%"
if not exist "%OLLAMA_HOME%"   mkdir "%OLLAMA_HOME%"

:: ============================================================
:: Use VENDOR_DIR\temp for helper scripts
:: ============================================================
set "TEMP_DIR=%VENDOR_DIR%\temp"
if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%"

:: ============================================================
:: Detect tools
:: ============================================================
set "CHECK_TOOL=none"
where curl.exe >nul 2>&1 && set "CHECK_TOOL=curl"

:: ============================================================
:: Detect SD executable
:: ============================================================
set "SD_EXE_NAME=none"
if exist "%SD_DIR%\sd-cli.exe" (
    set "SD_EXE_NAME=sd-cli.exe"
) else if exist "%SD_DIR%\sd.exe" (
    set "SD_EXE_NAME=sd.exe"
)

:: ============================================================
:: Pre-flight Checks
:: ============================================================
cls
echo.
echo  +----------------------------------------------------------+
echo  ^|         AlphaInference - Starting Chat Server            ^|
echo  +----------------------------------------------------------+
echo.

if not exist "%PYTHON_DIR%\python.exe" (
    echo  [ERROR] Python not found. Run install.bat first.
    pause
    exit /b 1
)
if not exist "%BASE_DIR%chat_server.py" (
    echo  [ERROR] chat_server.py not found.
    pause
    exit /b 1
)
if not exist "%BASE_DIR%chatUI.html" (
    echo  [WARN] chatUI.html not found.
)

echo  [OK] Python found.
echo  [OK] chat_server.py found.
echo  [OK] Model store: %OLLAMA_MODELS%

if "!SD_EXE_NAME!"=="none" (
    echo  [--] SD.cpp not installed
) else (
    echo  [OK] SD.cpp found: !SD_EXE_NAME!
    if "!SD_EXE_NAME!"=="sd-cli.exe" (
        if not exist "%SD_DIR%\stable-diffusion.dll" (
            echo  [WARN] sd-cli.exe found but stable-diffusion.dll is missing.
        )
    )
)

:: ============================================================
:: Check server port
:: ============================================================
echo.
echo  [*] Checking port %SERVER_PORT% ...
netstat -ano 2>nul | findstr ":%SERVER_PORT% " | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
    echo  [ERROR] Port %SERVER_PORT% is already in use.
    pause
    exit /b 1
)
echo  [OK] Port %SERVER_PORT% is free.

:: ============================================================
:: Start Ollama
:: ============================================================
echo.
echo  [*] Checking Ollama ...

if not exist "%OLLAMA_DIR%\ollama.exe" (
    echo  [WARN] Ollama not found. Chat will not work.
    goto SHOW_MODELS
)

set "_OL_LOCK=%TEMP_DIR%\ollama_busy.lock"
if exist "!_OL_LOCK!" (
    echo  [WARN] Ollama model operation in progress.
    echo         Lock file: !_OL_LOCK!
    echo         Finish the current pull/import before starting Chat UI.
    pause
    exit /b 1
)

set "_OL_ALREADY_RUNNING=0"
set "OLLAMA_STARTED_BY_BAT=0"
tasklist /fi "imagename eq ollama.exe" 2>nul | findstr /i "ollama.exe" >nul 2>&1
if not errorlevel 1 (
    set "_OL_ALREADY_RUNNING=1"
    if /I "%ALPHA_RESTART_OLLAMA%"=="1" (
        echo  [*] Existing Ollama detected. Restarting with portable model store ...
        taskkill /f /im ollama.exe >nul 2>&1
        ping -n 2 127.0.0.1 >nul
        tasklist /fi "imagename eq ollama.exe" 2>nul | findstr /i "ollama.exe" >nul 2>&1
        if not errorlevel 1 (
            echo  [WARN] Could not stop existing Ollama process. Reusing it.
        ) else (
            set "_OL_ALREADY_RUNNING=0"
        )
    ) else (
        echo  [*] Existing Ollama detected. Reusing it.
        echo      Set ALPHA_RESTART_OLLAMA=1 to force a restart.
    )
)

if "!_OL_ALREADY_RUNNING!"=="0" (
    echo  [*] Starting Ollama server ...
    start /b "" "%OLLAMA_DIR%\ollama.exe" serve >nul 2>&1
    set "OLLAMA_STARTED_BY_BAT=1"
)

<nul set /p "=  Waiting: "
set "_OL_UP=0"
for /l %%I in (1,1,25) do (
    if "!_OL_UP!"=="0" (
        ping -n 2 127.0.0.1 >nul
        <nul set /p "=."
        if "%CHECK_TOOL%"=="curl" (
            curl.exe -s -o nul -w "" --connect-timeout 2 "http://127.0.0.1:11434/api/tags" >nul 2>&1
            if !errorlevel! EQU 0 (
                echo  Ready!
                set "_OL_UP=1"
            )
        ) else (
            if %%I==10 (
                echo  OK
                set "_OL_UP=1"
            )
        )
    )
)

if "!_OL_UP!"=="0" (
    echo.
    echo  [WARN] Ollama may not have started.
)

:SHOW_MODELS
echo.

:: ============================================================
:: List Models
:: ============================================================
echo  Models available in UI:
echo  ----------------------------------------------------------
echo.
echo  Chat dropdown:
if exist "%OLLAMA_DIR%\ollama.exe" (
    "%OLLAMA_DIR%\ollama.exe" list 2>nul
) else (
    echo   none
)
echo.
echo  Image dropdown:
set "_IM_FOUND=0"
if exist "%BASE_DIR%models\image" (
    for %%F in ("%BASE_DIR%models\image\*.*") do (
        echo "%%~nxF" | findstr /i "partial" >nul
        if errorlevel 1 (
            set "_IM_FOUND=1"
            echo   %%~nxF
        )
    )
)
if "!_IM_FOUND!"=="0" echo   none
echo.
echo  ----------------------------------------------------------

:: ============================================================
:: Start Chat Server
:: ============================================================
echo.
echo  +----------------------------------------------------------+
echo  ^|   Chat UI (local): %LOCAL_URL%                          ^|
if /I "%ALPHA_EXPOSE_LAN%"=="1" echo  ^|   Chat UI (LAN):   %LAN_URL%                           ^|
echo  ^|   API:             %LOCAL_URL%/api                      ^|
echo  ^|   Press Ctrl+C to stop.                                 ^|
echo  +----------------------------------------------------------+
echo.

set "OLLAMA_MANAGED_BY_BAT=1"
set "ALPHA_MODELS_DIR=%BASE_DIR%models"
set "ALPHA_SERVER_HOST=%SERVER_BIND_HOST%"
set "ALPHA_SERVER_PORT=%SERVER_PORT%"

:: ============================================================
:: Write browser helper using a subroutine (no escape hell)
:: ============================================================
set "_BROWSER_HELPER=%TEMP_DIR%\_open_browser.bat"
call :WRITE_BROWSER_HELPER "%_BROWSER_HELPER%"

if exist "%_BROWSER_HELPER%" (
    if "%CHECK_TOOL%"=="curl" (
        start "" cmd /c ""%_BROWSER_HELPER%""
    ) else (
        start "" cmd /c "ping -n 6 127.0.0.1 >nul & start %LOCAL_URL%"
    )
) else (
    echo  [WARN] Could not write browser helper.
    echo         Open manually: %LOCAL_URL%
)

:: Run server - blocks until Ctrl+C
"%PYTHON_DIR%\python.exe" "%BASE_DIR%chat_server.py"

:: ============================================================
:: Cleanup
:: ============================================================
echo.
echo  [*] Server stopped. Cleaning up ...

if "!OLLAMA_STARTED_BY_BAT!"=="1" (
    tasklist /fi "imagename eq ollama.exe" 2>nul | findstr /i "ollama.exe" >nul 2>&1
    if not errorlevel 1 (
        echo  [*] Stopping Ollama ...
        taskkill /f /im ollama.exe >nul 2>&1
        echo  [OK] Ollama stopped.
    )
) else (
    echo  [*] Ollama was pre-existing, leaving it alone.
)

del "%_BROWSER_HELPER%" 2>nul
echo  [OK] Cleanup complete.
echo.
pause
exit /b 0


:: ============================================================
:: SUBROUTINE: Write the browser polling helper script
:: This subroutine uses line-by-line echo to avoid the
:: escaping problems that arise from heredocs containing
:: parentheses, ampersands, and redirects.
:: ============================================================
:WRITE_BROWSER_HELPER
set "_OUT=%~1"
if exist "%_OUT%" del "%_OUT%" 2>nul

> "%_OUT%" echo @echo off
>>"%_OUT%" echo setlocal enabledelayedexpansion
>>"%_OUT%" echo set "_OPENED=0"
>>"%_OUT%" echo for /l %%%%I in (1^,1^,30) do (
>>"%_OUT%" echo   if "!_OPENED!"=="0" (
>>"%_OUT%" echo     ping -n 2 127.0.0.1 ^>nul
>>"%_OUT%" echo     curl.exe -s -o nul --connect-timeout 1 %HEALTH_URL% ^>nul 2^>^&1
>>"%_OUT%" echo     if !errorlevel! EQU 0 (
>>"%_OUT%" echo       start %LOCAL_URL%
>>"%_OUT%" echo       set "_OPENED=1"
>>"%_OUT%" echo     ^)
>>"%_OUT%" echo   ^)
>>"%_OUT%" echo ^)
>>"%_OUT%" echo if "!_OPENED!"=="0" start %LOCAL_URL%
exit /b 0

:: ============================================================
:: SUBROUTINE: Apply LAN setting
:: Adds or removes Windows Firewall inbound rule for the
:: chat server port when network access is toggled.
:: Requires elevation for netsh; silently skips if denied.
:: ============================================================
:APPLY_LAN_SETTING
set "_FW_RULE=AlphaInference Chat Server"
if /I "!ALPHA_EXPOSE_LAN!"=="1" (
    echo.
    echo  [*] Network access enabled - configuring firewall ...
    netsh advfirewall firewall show rule name="!_FW_RULE!" >nul 2>&1
    if errorlevel 1 (
        netsh advfirewall firewall add rule name="!_FW_RULE!" dir=in action=allow protocol=TCP localport=%SERVER_PORT% >nul 2>&1
        if errorlevel 1 (
            echo  [WARN] Could not add firewall rule ^(run as Administrator to allow LAN access^).
        ) else (
            echo  [OK] Firewall rule added for port %SERVER_PORT%.
        )
    ) else (
        echo  [OK] Firewall rule already exists for port %SERVER_PORT%.
    )
) else (
    :: Silently remove rule if it exists when switching back to local-only
    netsh advfirewall firewall show rule name="!_FW_RULE!" >nul 2>&1
    if not errorlevel 1 (
        netsh advfirewall firewall delete rule name="!_FW_RULE!" >nul 2>&1
        echo  [OK] Firewall rule removed ^(local-only mode^).
    )
)
exit /b 0