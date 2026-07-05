@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
title AlphaInference - Local LLM Setup
color 0A

:: ============================================================
::  AlphaInference - Local LLM Manager
::  Copyright (c) AlphaBridge IT Solution (TM)
::  All rights reserved.
:: ============================================================

:: ============================================================
:: CONFIGURATION
:: ============================================================
set "BASE_DIR=%~dp0"
set "VENDOR_DIR=%BASE_DIR%vendor"
set "MODELS_DIR=%BASE_DIR%models"
set "PYTHON_DIR=%VENDOR_DIR%\python"
set "OLLAMA_DIR=%VENDOR_DIR%\ollama"
set "SD_DIR=%VENDOR_DIR%\stable-diffusion"
set "TEMP_DIR=%VENDOR_DIR%\temp"
set "HF_CACHE=%VENDOR_DIR%\hf_cache"
set "LOG_DIR=%BASE_DIR%logs"

:: Use portable Hugging Face cache paths for reliable resume across restarts.
set "HF_HOME=%HF_CACHE%"
set "HF_HUB_CACHE=%HF_CACHE%\hub"
set "HUGGINGFACE_HUB_CACHE=%HF_CACHE%\hub"

set "PYTHON_VERSION=3.11.9"
set "PYTHON_URL=https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip"
set "GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py"
set "OLLAMA_URL=https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip"

set "MAX_RETRIES=10"
set "RETRY_DELAY=5"

:: ============================================================
:: OLLAMA environment - set ONCE so every ollama.exe call
:: inherits the same model path. Keeps models across restarts.
:: ============================================================
set "OLLAMA_MODELS=%BASE_DIR%models\ollama"
set "OLLAMA_HOST=127.0.0.1:11434"

:: ============================================================
:: Create base dirs
:: ============================================================
for %%D in (
    "%VENDOR_DIR%"
    "%TEMP_DIR%"
    "%MODELS_DIR%"
    "%MODELS_DIR%\chat"
    "%MODELS_DIR%\image"
    "%MODELS_DIR%\ollama"
    "%HF_CACHE%"
    "%HF_HUB_CACHE%"
    "%LOG_DIR%"
) do (
    if not exist "%%~D" mkdir "%%~D" 2>nul
)

set "_LOG_TS=%DATE%_%TIME%"
set "_LOG_TS=%_LOG_TS: =0%"
set "_LOG_TS=%_LOG_TS:/=-%"
set "_LOG_TS=%_LOG_TS::=-%"
set "_LOG_TS=%_LOG_TS:.=-%"
set "_LOG_TS=%_LOG_TS:,=-%"
set "LOG_FILE=%LOG_DIR%\install_%_LOG_TS%.log"
> "%LOG_FILE%" echo ==========================================================
>>"%LOG_FILE%" echo AlphaInference install.bat log
>>"%LOG_FILE%" echo Started: %DATE% %TIME%
>>"%LOG_FILE%" echo BaseDir: %BASE_DIR%
>>"%LOG_FILE%" echo ==========================================================

:: ============================================================
:: Detect download tool
:: ============================================================
set "DL_TOOL=certutil"
where curl.exe >nul 2>&1
if not errorlevel 1 set "DL_TOOL=curl"
if "%DL_TOOL%"=="certutil" (
    where bitsadmin.exe >nul 2>&1
    if not errorlevel 1 set "DL_TOOL=bitsadmin"
)
set "RESUME_SUPPORT=NO"
if "%DL_TOOL%"=="curl" set "RESUME_SUPPORT=YES"
if "%DL_TOOL%"=="bitsadmin" set "RESUME_SUPPORT=YES"

:: ============================================================
:: Detect system info tool
:: ============================================================
set "SYS_TOOL=wmic"
set "PS_EXE="
where powershell.exe >nul 2>&1
if not errorlevel 1 set "PS_EXE=powershell.exe"
if not defined PS_EXE (
    where pwsh.exe >nul 2>&1
    if not errorlevel 1 set "PS_EXE=pwsh.exe"
)
if defined PS_EXE (
    "!PS_EXE!" -NoProfile -Command "$null" >nul 2>&1
    if not errorlevel 1 set "SYS_TOOL=powershell"
)

:: Safety default for locked-down machines: avoid PowerShell parsing/policy issues
if not defined ALPHA_SAFE_SYSINFO set "ALPHA_SAFE_SYSINFO=1"
if /I "%ALPHA_SAFE_SYSINFO%"=="1" (
    set "SYS_TOOL=wmic"
    set "PS_EXE="
)

goto :MAIN_MENU


:: ============================================================
:: MAIN MENU
:: ============================================================
:MAIN_MENU
cls
echo.
echo  +----------------------------------------------------------+
echo  ^|         AlphaInference - Local LLM Manager               ^|
echo  ^|            Run AI Models 100%% Offline                    ^|
echo  ^|       AlphaBridge IT Solution (TM)                       ^|
echo  +----------------------------------------------------------+
echo  ^|                                                          ^|
echo  ^|   [1] Setup and Install  (First Time)                    ^|
echo  ^|   [2] Download / Import Models                           ^|
echo  ^|   [3] Uninstall / Remove Models                          ^|
echo  ^|   [4] Start Chat Server                                  ^|
echo  ^|   [5] System Info + All Imported Models                  ^|
echo  ^|   [6] Exit                                               ^|
echo  ^|                                                          ^|
echo  +----------------------------------------------------------+
set "_TL=Tool: %DL_TOOL%  Resume: %RESUME_SUPPORT%  Sys: %SYS_TOOL%"
set "_PAD=                                                          "
set "_TL_PADDED=!_TL!!_PAD!"
set "_TL_PADDED=!_TL_PADDED:~0,56!"
echo  ^| !_TL_PADDED! ^|
echo  +----------------------------------------------------------+
echo.
set "choice="
set /p "choice=  Select [1-6]: "

if "!choice!"=="1" goto :SETUP_INSTALL
if "!choice!"=="2" goto :DOWNLOAD_MODELS_MENU
if "!choice!"=="3" goto :UNINSTALL_MENU
if "!choice!"=="4" goto :START_CHAT
if "!choice!"=="5" goto :SYSTEM_INFO
if "!choice!"=="6" goto :DO_EXIT
goto :MAIN_MENU

:DO_EXIT
echo.
echo  Goodbye - AlphaBridge IT Solution (TM)
echo.
:: Safe blind kill - taskkill silently ignores if not running
taskkill /f /im ollama.exe >nul 2>&1
endlocal
exit /b 0


:: ============================================================
:: HELPER - show pending partials OUTSIDE any box drawing
:: ============================================================
:SHOW_PARTIALS_HINT
set "_SPC=0"
for %%F in (
    "%TEMP_DIR%\*.partial"
    "%MODELS_DIR%\image\*.partial"
    "%MODELS_DIR%\chat\*.partial"
) do (
    if exist "%%F" set /a _SPC+=1
)
if !_SPC! GTR 0 (
    echo.
    echo  [!] !_SPC! pending download^(s^) - select Download menu to resume.
)
exit /b 0


:: ============================================================
:: 1. SETUP AND INSTALL
:: ============================================================
:SETUP_INSTALL
cls
echo.
echo  ==========================================================
echo   Setup and Install All Components
echo   AlphaBridge IT Solution (TM)
echo  ==========================================================
echo.
echo  [*] Creating directories ...
for %%D in (
    "%VENDOR_DIR%"
    "%MODELS_DIR%"
    "%PYTHON_DIR%"
    "%OLLAMA_DIR%"
    "%SD_DIR%"
    "%TEMP_DIR%"
    "%HF_CACHE%"
    "%MODELS_DIR%\chat"
    "%MODELS_DIR%\image"
    "%MODELS_DIR%\ollama"
) do (
    if not exist "%%~D" mkdir "%%~D" 2>nul
)
echo  [OK] Done.
echo.

:: ---- Python ----
echo  ----------------------------------------------------------
echo   1.1  Python Embeddable v%PYTHON_VERSION%
echo  ----------------------------------------------------------
echo.

if exist "%PYTHON_DIR%\python.exe" (
    echo  [SKIP] Python already installed.
    goto :SETUP_PY_PACKAGES
)

set "_DL_URL=%PYTHON_URL%"
set "_DL_OUT=%TEMP_DIR%\python-embed.zip"
set "_DL_NAME=Python %PYTHON_VERSION%"
call :DO_DOWNLOAD
if "!DL_OK!"=="0" (
    echo  [ERROR] Cannot continue without Python.
    pause & goto :MAIN_MENU
)

call :DO_UNZIP "%TEMP_DIR%\python-embed.zip" "%PYTHON_DIR%"
del "%TEMP_DIR%\python-embed.zip" 2>nul

echo  [*] Enabling pip support ...
set "PTH="
for /f "delims=" %%F in ('dir /b "%PYTHON_DIR%\python*._pth" 2^>nul') do set "PTH=%PYTHON_DIR%\%%F"
if defined PTH (
    > "%TEMP_DIR%\_pth.tmp" (
        for /f "usebackq tokens=* delims=" %%L in ("!PTH!") do (
            set "LINE=%%L"
            if "!LINE!"=="#import site" (
                echo import site
            ) else (
                echo !LINE!
            )
        )
    )
    move /y "%TEMP_DIR%\_pth.tmp" "!PTH!" >nul 2>&1
)

set "_DL_URL=%GET_PIP_URL%"
set "_DL_OUT=%TEMP_DIR%\get-pip.py"
set "_DL_NAME=pip installer"
call :DO_DOWNLOAD
if "!DL_OK!"=="0" (
    echo  [ERROR] Cannot download pip.
    pause & goto :MAIN_MENU
)

echo  [*] Installing pip ...
"%PYTHON_DIR%\python.exe" "%TEMP_DIR%\get-pip.py" --no-warn-script-location --quiet 2>nul
if errorlevel 1 (
    "%PYTHON_DIR%\python.exe" "%TEMP_DIR%\get-pip.py" --no-warn-script-location 2>nul
    if errorlevel 1 (
        echo  [ERROR] pip installation failed.
        pause & goto :MAIN_MENU
    )
)
del "%TEMP_DIR%\get-pip.py" 2>nul
echo  [OK] Python ready.
echo.

:SETUP_PY_PACKAGES
echo  ----------------------------------------------------------
echo   Python Packages
echo  ----------------------------------------------------------
echo.
set "PKG_I=0"
set "PKG_TOTAL=6"
for %%P in (flask flask-cors requests huggingface_hub tqdm psutil) do (
    set /a PKG_I+=1
    echo  [!PKG_I!/%PKG_TOTAL%] %%P
    "%PYTHON_DIR%\python.exe" -m pip show %%P >nul 2>&1
    if errorlevel 1 (
        echo         Installing ...
        "%PYTHON_DIR%\python.exe" -m pip install --no-warn-script-location --quiet %%P 2>nul
        if errorlevel 1 (
            "%PYTHON_DIR%\python.exe" -m pip install --no-warn-script-location %%P 2>nul
            if errorlevel 1 (
                echo         [FAIL] Could not install %%P
            ) else (
                echo         [OK]
            )
        ) else (
            echo         [OK]
        )
    ) else (
        echo         [SKIP] Already installed.
    )
)
echo.

:: ---- Ollama ----
echo  ----------------------------------------------------------
echo   1.2  Ollama LLM Runtime
echo  ----------------------------------------------------------
echo.

if exist "%OLLAMA_DIR%\ollama.exe" (
    echo  [SKIP] Ollama already installed.
    goto :SETUP_SD
)

set "_DL_URL=%OLLAMA_URL%"
set "_DL_OUT=%TEMP_DIR%\ollama.zip"
set "_DL_NAME=Ollama"
call :DO_DOWNLOAD
if "!DL_OK!"=="0" (
    echo  [ERROR] Ollama download failed.
    pause & goto :MAIN_MENU
)

call :DO_UNZIP "%TEMP_DIR%\ollama.zip" "%OLLAMA_DIR%"
del "%TEMP_DIR%\ollama.zip" 2>nul

if not exist "%OLLAMA_DIR%\ollama.exe" (
    echo  [*] Locating ollama.exe in subdirectories ...
    set "_OL_FOUND=0"
    for /r "%OLLAMA_DIR%" %%F in (ollama.exe) do (
        if "!_OL_FOUND!"=="0" (
            copy "%%F" "%OLLAMA_DIR%\ollama.exe" >nul 2>&1
            if not errorlevel 1 (
                echo  [OK] Found at %%F
                set "_OL_FOUND=1"
            )
        )
    )
    if "!_OL_FOUND!"=="0" echo  [WARN] ollama.exe not found in archive.
)

if exist "%OLLAMA_DIR%\ollama.exe" (
    echo  [OK] Ollama installed.
) else (
    echo  [WARN] Ollama install may be incomplete.
)
echo.

:SETUP_SD
echo.
echo  ----------------------------------------------------------
echo   1.3  Stable Diffusion.cpp
echo  ----------------------------------------------------------
echo.

if exist "%SD_DIR%\sd-cli.exe" (
    echo  [SKIP] SD.cpp already installed ^(sd-cli.exe^).
    goto :SETUP_VERIFY
)
if exist "%SD_DIR%\sd.exe" (
    echo  [SKIP] SD.cpp already installed ^(sd.exe^).
    goto :SETUP_VERIFY
)

echo  [*] Resolving latest SD.cpp release ...
call :RESOLVE_SD_URL
if "!_SD_RESOLVED!"=="0" (
    echo  [WARN] Could not find SD.cpp URL.
    echo         https://github.com/leejet/stable-diffusion.cpp/releases
    goto :SETUP_VERIFY
)

echo  [OK] Found: !_SD_ASSET_NAME!
set "_DL_URL=!_SD_RESOLVED_URL!"
set "_DL_OUT=%TEMP_DIR%\sd-cpp.zip"
set "_DL_NAME=!_SD_ASSET_NAME!"
call :DO_DOWNLOAD

if "!DL_OK!"=="1" (
    call :DO_UNZIP "%TEMP_DIR%\sd-cpp.zip" "%SD_DIR%"
    del "%TEMP_DIR%\sd-cpp.zip" 2>nul

    if not exist "%SD_DIR%\sd-cli.exe" (
        set "_SDCLI_FOUND=0"
        for /r "%SD_DIR%" %%F in (sd-cli.exe) do (
            if "!_SDCLI_FOUND!"=="0" (
                copy "%%F" "%SD_DIR%\sd-cli.exe" >nul 2>&1
                for %%D in ("%%~dpFstable-diffusion.dll") do (
                    if exist "%%~D" copy "%%~D" "%SD_DIR%\stable-diffusion.dll" >nul 2>&1
                )
                set "_SDCLI_FOUND=1"
            )
        )
    )
    if not exist "%SD_DIR%\sd-cli.exe" (
        if not exist "%SD_DIR%\sd.exe" (
            set "_SDEXE_FOUND=0"
            for /r "%SD_DIR%" %%F in (sd.exe) do (
                if "!_SDEXE_FOUND!"=="0" (
                    copy "%%F" "%SD_DIR%\sd.exe" >nul 2>&1
                    set "_SDEXE_FOUND=1"
                )
            )
        )
    )

    if exist "%SD_DIR%\sd-cli.exe" (
        echo  [OK] SD.cpp installed ^(sd-cli.exe^).
    ) else if exist "%SD_DIR%\sd.exe" (
        echo  [OK] SD.cpp installed ^(sd.exe^).
    ) else (
        echo  [WARN] No sd executable found in archive.
    )
) else (
    echo  [WARN] SD.cpp download failed - optional component.
)
echo.

:SETUP_VERIFY
echo.
echo  ----------------------------------------------------------
echo   1.5  Verification
echo  ----------------------------------------------------------
echo.
if exist "%BASE_DIR%chatUI.html"    (echo  [OK] chatUI.html)    else (echo  [--] chatUI.html missing)
if exist "%BASE_DIR%chat_server.py" (echo  [OK] chat_server.py) else (echo  [--] chat_server.py missing)
if exist "%BASE_DIR%start_chat.bat" (echo  [OK] start_chat.bat) else (echo  [--] start_chat.bat missing)
echo.

echo  ==========================================================
echo   SUMMARY
echo  ==========================================================
echo.
set "PASS=0"
set "FAIL=0"
if exist "%PYTHON_DIR%\python.exe"  (echo  [OK]   Python & set /a PASS+=1) else (echo  [FAIL] Python & set /a FAIL+=1)
if exist "%OLLAMA_DIR%\ollama.exe"  (echo  [OK]   Ollama & set /a PASS+=1) else (echo  [FAIL] Ollama & set /a FAIL+=1)

if exist "%SD_DIR%\sd-cli.exe" (
    echo  [OK]   SD.cpp ^(sd-cli.exe^)
    set /a PASS+=1
) else if exist "%SD_DIR%\sd.exe" (
    echo  [OK]   SD.cpp ^(sd.exe^)
    set /a PASS+=1
) else (
    echo  [--]   SD.cpp ^(optional^)
)

if exist "%BASE_DIR%chat_server.py" (echo  [OK]   Server & set /a PASS+=1) else (echo  [FAIL] Server & set /a FAIL+=1)
if exist "%BASE_DIR%chatUI.html"    (echo  [OK]   UI     & set /a PASS+=1) else (echo  [FAIL] UI     & set /a FAIL+=1)
echo.
echo  Passed: !PASS!  Failed: !FAIL!
if !FAIL!==0 (echo  All components ready!) else (echo  Some components missing.)
echo.
echo  Directories:
echo    Chat downloads: %MODELS_DIR%\chat
echo    Image models:   %MODELS_DIR%\image
echo    Ollama store:   %OLLAMA_MODELS%
echo.
del /q "%TEMP_DIR%\*.zip" 2>nul
pause
goto :MAIN_MENU


:: ============================================================
:: 2. DOWNLOAD / IMPORT MODELS MENU
:: ============================================================
:DOWNLOAD_MODELS_MENU
cls
echo.
echo  ==========================================================
echo   Download / Import Models
echo   AlphaBridge IT Solution (TM)
echo  ==========================================================
echo.
echo   [1] Recommended Models
echo   [2] Download from HuggingFace
echo   [3] Import Local File  ^(browse for file^)
echo   [4] Import from models\chat  ^(scan folder -^> Ollama^)
echo   [5] Manage models\image  ^(scan folder^)
echo   [6] List All Models
echo   [7] Model Manager  ^(HF/URL/local + registry^)
echo   [8] Back to Main Menu
echo.
call :SHOW_PARTIALS_HINT
echo.
set "dc="
set /p "dc=  Select [1-8]: "
if "!dc!"=="1" goto :DOWNLOAD_RECOMMENDED
if "!dc!"=="2" goto :DOWNLOAD_HF
if "!dc!"=="3" goto :IMPORT_LOCAL
if "!dc!"=="4" goto :IMPORT_SCAN_CHAT
if "!dc!"=="5" goto :IMPORT_SCAN_IMAGE
if "!dc!"=="6" goto :LIST_ALL_MODELS
if "!dc!"=="7" goto :MODEL_MANAGER_MENU
if "!dc!"=="8" goto :MAIN_MENU
goto :DOWNLOAD_MODELS_MENU


:: ============================================================
:: 2.0  List ALL models
:: ============================================================
:LIST_ALL_MODELS
cls
echo.
echo  ==========================================================
echo   All Imported Models
echo  ==========================================================
echo.
echo  -- Chat Models (Ollama registered) -----------------------
echo.
if not exist "%OLLAMA_DIR%\ollama.exe" (
    echo   Ollama not installed.
) else (
    call :ENSURE_OLLAMA
    echo.
    set "_OL_COUNT=0"
    "%OLLAMA_DIR%\ollama.exe" list > "%TEMP_DIR%\_ollist.txt" 2>nul
    if exist "%TEMP_DIR%\_ollist.txt" (
        for /f "usebackq skip=1 tokens=1,2,3,4,5" %%A in ("%TEMP_DIR%\_ollist.txt") do (
            set /a _OL_COUNT+=1
            echo   !_OL_COUNT!. %%A   %%B %%C   %%D %%E
        )
        del "%TEMP_DIR%\_ollist.txt" 2>nul
    )
    if !_OL_COUNT!==0 echo   None registered.
)

echo.
echo  -- Chat Downloads (models\chat - awaiting import) --------
echo.
call :LIST_CHAT_FILES_DISPLAY

echo.
echo  -- Image Models (models\image) ---------------------------
echo.
call :LIST_IMAGE_MODELS_DISPLAY

echo  Directories:
echo    Chat downloads: %MODELS_DIR%\chat
echo    Image files:    %MODELS_DIR%\image
echo    Ollama store:   %OLLAMA_MODELS%
echo.
pause
goto :DOWNLOAD_MODELS_MENU


:: ============================================================
:: 2.1  Recommended Models
:: ============================================================
:DOWNLOAD_RECOMMENDED
cls
echo.
echo  ==========================================================
echo   2.1  Recommended Models
echo  ==========================================================
echo.

call :GET_RAM_GB
call :GET_VRAM

echo   RAM: !_RAM_GB! GB  VRAM: !_VRAM_GB! GB  GPU: !_GPU_NAME!
echo.

if not exist "%OLLAMA_DIR%\ollama.exe" (
    echo  [WARN] Ollama not installed. Chat models unavailable.
    echo         Run Setup first ^(option 1^).
    echo.
) else (
    call :ENSURE_OLLAMA
    echo.
)

echo  -- Chat Models (Ollama pull) ------------------------------
echo.
set "MC=0"
if !_RAM_GB! GEQ 32 (
    set /a MC+=1 & echo   [!MC!] llama3.1:8b        ~4.7 GB   General purpose
    set "M!MC!=llama3.1:8b"
    set /a MC+=1 & echo   [!MC!] codellama:13b      ~7.4 GB   Code generation
    set "M!MC!=codellama:13b"
    set /a MC+=1 & echo   [!MC!] mixtral:8x7b       ~26  GB   Mixture of experts
    set "M!MC!=mixtral:8x7b"
    set /a MC+=1 & echo   [!MC!] gemma2:9b          ~5.5 GB   Google
    set "M!MC!=gemma2:9b"
) else if !_RAM_GB! GEQ 16 (
    set /a MC+=1 & echo   [!MC!] llama3.2:3b        ~2.0 GB   Fast
    set "M!MC!=llama3.2:3b"
    set /a MC+=1 & echo   [!MC!] llama3.1:8b        ~4.7 GB   Best balance
    set "M!MC!=llama3.1:8b"
    set /a MC+=1 & echo   [!MC!] mistral:7b         ~4.1 GB   Fast inference
    set "M!MC!=mistral:7b"
    set /a MC+=1 & echo   [!MC!] codellama:7b       ~3.8 GB   Code focused
    set "M!MC!=codellama:7b"
    set /a MC+=1 & echo   [!MC!] gemma2:9b          ~5.5 GB   Google
    set "M!MC!=gemma2:9b"
) else if !_RAM_GB! GEQ 8 (
    set /a MC+=1 & echo   [!MC!] llama3.2:1b        ~1.3 GB   Lightweight
    set "M!MC!=llama3.2:1b"
    set /a MC+=1 & echo   [!MC!] llama3.2:3b        ~2.0 GB   Good balance
    set "M!MC!=llama3.2:3b"
    set /a MC+=1 & echo   [!MC!] phi3:mini          ~2.3 GB   Microsoft compact
    set "M!MC!=phi3:mini"
    set /a MC+=1 & echo   [!MC!] gemma2:2b          ~1.6 GB   Google compact
    set "M!MC!=gemma2:2b"
) else (
    set /a MC+=1 & echo   [!MC!] llama3.2:1b        ~1.3 GB   Minimal
    set "M!MC!=llama3.2:1b"
    set /a MC+=1 & echo   [!MC!] tinyllama:1.1b     ~0.6 GB   Ultra light
    set "M!MC!=tinyllama:1.1b"
    set /a MC+=1 & echo   [!MC!] phi3:mini          ~2.3 GB   If RAM allows
    set "M!MC!=phi3:mini"
)

echo.
echo  -- Image Models (file download) --------------------------
echo.
set /a MC+=1 & echo   [!MC!] Stable Diffusion 1.5  ~4.0 GB   Best quality
set "M!MC!=SD15"
set /a MC+=1 & echo   [!MC!] SD Turbo              ~2.0 GB   Faster
set "M!MC!=SDTURBO"
set /a MC+=1 & echo   [!MC!] DreamShaper 8         ~2.0 GB   Better details
set "M!MC!=DREAMSHAPER"

echo.
set /a MC+=1 & echo   [!MC!] Back
set "M!MC!=BACK"
echo.
set "ms="
set /p "ms=  Select [1-!MC!]: "
if "!ms!"=="" goto :DOWNLOAD_MODELS_MENU

set "_MS_VALID=0"
for /l %%N in (1,1,!MC!) do (
    if "!ms!"=="%%N" set "_MS_VALID=1"
)
if "!_MS_VALID!"=="0" goto :DOWNLOAD_RECOMMENDED

set "SEL=!M%ms%!"
if not defined SEL goto :DOWNLOAD_RECOMMENDED
if "!SEL!"=="BACK" goto :DOWNLOAD_MODELS_MENU

if "!SEL!"=="SD15" (
    set "IMF=%MODELS_DIR%\image\sd-v1-5.safetensors"
    if exist "!IMF!" (echo  [SKIP] Already downloaded.) else (
        echo.
        echo  [*] Stable Diffusion 1.5  ~4.0 GB
        echo      -> models\image\sd-v1-5.safetensors
        echo.
        set "_CONFIRM="
        set /p "_CONFIRM=  Proceed? [y/n]: "
        if /i "!_CONFIRM!"=="y" (
            set "_DL_URL=https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"
            set "_DL_OUT=!IMF!"
            set "_DL_NAME=Stable Diffusion 1.5"
            call :DO_DOWNLOAD
        ) else (echo  Cancelled.)
    )
    echo. & pause & goto :DOWNLOAD_RECOMMENDED
)

if "!SEL!"=="SDTURBO" (
    set "IMF=%MODELS_DIR%\image\sd-turbo.safetensors"
    if exist "!IMF!" (echo  [SKIP] Already downloaded.) else (
        echo.
        echo  [*] SD Turbo  ~2.0 GB
        echo      -> models\image\sd-turbo.safetensors
        echo.
        set "_CONFIRM="
        set /p "_CONFIRM=  Proceed? [y/n]: "
        if /i "!_CONFIRM!"=="y" (
            set "_DL_URL=https://huggingface.co/stabilityai/sd-turbo/resolve/main/sd_turbo.safetensors"
            set "_DL_OUT=!IMF!"
            set "_DL_NAME=SD Turbo"
            call :DO_DOWNLOAD
        ) else (echo  Cancelled.)
    )
    echo. & pause & goto :DOWNLOAD_RECOMMENDED
)

if "!SEL!"=="DREAMSHAPER" (
    set "IMF=%MODELS_DIR%\image\dreamshaper_8.safetensors"
    if exist "!IMF!" (echo  [SKIP] Already downloaded.) else (
        echo.
        echo  [*] DreamShaper 8  ~2.0 GB
        echo      -> models\image\dreamshaper_8.safetensors
        echo.
        set "_CONFIRM="
        set /p "_CONFIRM=  Proceed? [y/n]: "
        if /i "!_CONFIRM!"=="y" (
            set "_DL_URL=https://huggingface.co/Lykon/dreamshaper-8/resolve/main/dreamshaper_8.safetensors"
            set "_DL_OUT=!IMF!"
            set "_DL_NAME=DreamShaper 8"
            call :DO_DOWNLOAD
        ) else (echo  Cancelled.)
    )
    echo. & pause & goto :DOWNLOAD_RECOMMENDED
)

:: Chat model via Ollama pull
if not exist "%OLLAMA_DIR%\ollama.exe" (
    echo  [FAIL] Ollama not installed. Run Setup first.
    pause & goto :DOWNLOAD_RECOMMENDED
)
echo.
echo  [*] Downloading !SEL! via Ollama ...
echo  ----------------------------------------------------------
call :SET_OLLAMA_BUSY "pull !SEL!"
"%OLLAMA_DIR%\ollama.exe" pull !SEL!
set "_PULL_ERR=!errorlevel!"
call :CLEAR_OLLAMA_BUSY
echo  ----------------------------------------------------------
echo.
if !_PULL_ERR! NEQ 0 (
    echo  [FAIL] Run again to resume.
) else (
    echo  [OK] !SEL! ready. Available in Chat dropdown.
)
echo.
pause
goto :DOWNLOAD_RECOMMENDED


:: ============================================================
:: 2.2  HuggingFace Download
:: ============================================================
:DOWNLOAD_HF
cls
echo.
echo  ==========================================================
echo   2.2  Download from HuggingFace
echo  ==========================================================
echo.
if not exist "%PYTHON_DIR%\python.exe" (
    echo  [ERROR] Python required. Run Setup first.
    pause & goto :DOWNLOAD_MODELS_MENU
)

call :WRITE_HF_SCRIPTS_V2

echo  Enter HuggingFace repo:
echo    Example: TheBloke/Llama-2-7B-GGUF
echo.
echo  Destinations:
echo    .gguf / .bin / .pt  -^> models\chat\
echo    .safetensors        -^> models\image\
echo.
set "hf_input="
set /p "hf_input=  Repo ID or URL ^(or 'back'^): "
if /i "!hf_input!"=="back" goto :DOWNLOAD_MODELS_MENU
if "!hf_input!"=="" goto :DOWNLOAD_HF

echo.
set "hf_token="
set /p "hf_token=  HF Token ^(Enter to skip^): "
echo.

set "HF_TOK=!hf_token!"
if "!HF_TOK!"=="" set "HF_TOK=NONE"

"%PYTHON_DIR%\python.exe" "%TEMP_DIR%\_hf_browse.py" "!hf_input!" "!HF_TOK!" "%TEMP_DIR%\_hf_files.json" > "%TEMP_DIR%\_hf_out.txt" 2>&1
type "%TEMP_DIR%\_hf_out.txt"

if not exist "%TEMP_DIR%\_hf_files.json" (
    echo.
    echo  [FAIL] Could not resolve repository.
    pause & goto :DOWNLOAD_HF
)

echo.
set "fc="
set /p "fc=  File number: "
if "!fc!"=="" goto :DOWNLOAD_HF

set "_FC_VALID=0"
for /f "delims=0123456789" %%X in ("!fc!x") do (
    if "%%X"=="x" set "_FC_VALID=1"
)
if "!_FC_VALID!"=="0" (echo  [WARN] Enter a number. & pause & goto :DOWNLOAD_HF)

"%PYTHON_DIR%\python.exe" "%TEMP_DIR%\_hf_sel.py" "%TEMP_DIR%\_hf_files.json" "!fc!" "%TEMP_DIR%\_hf_sel.json" > "%TEMP_DIR%\_hf_out.txt" 2>&1
type "%TEMP_DIR%\_hf_out.txt"

if not exist "%TEMP_DIR%\_hf_sel.json" (
    echo  Cancelled or invalid.
    pause & goto :DOWNLOAD_HF
)

echo.
set "cdl="
set /p "cdl=  Download? [y/n]: "
if /i not "!cdl!"=="y" goto :DOWNLOAD_HF

echo.
echo  ----------------------------------------------------------
"%PYTHON_DIR%\python.exe" "%TEMP_DIR%\_hf_dl.py" "%TEMP_DIR%\_hf_sel.json" "!HF_TOK!" "%TEMP_DIR%\_hf_done.json" "%MODELS_DIR%\chat" "%MODELS_DIR%\image" "%MAX_RETRIES%" "%RETRY_DELAY%"
set "HF_ERR=!errorlevel!"
echo  ----------------------------------------------------------

if !HF_ERR!==2 (echo  [PAUSED] Partial saved. Run again to resume. & pause & goto :DOWNLOAD_MODELS_MENU)
if !HF_ERR! NEQ 0 (echo  [FAIL] Run again to resume. & pause & goto :DOWNLOAD_HF)

if not exist "%TEMP_DIR%\_hf_done.json" (echo  [FAIL] Result missing. & pause & goto :DOWNLOAD_HF)

set "_RES_LINE=0"
set "DLPATH="
set "DLFN="
"%PYTHON_DIR%\python.exe" -c "import json;d=json.load(open(r'%TEMP_DIR%\_hf_done.json'));print(d.get('local_path',''));print(d.get('filename',''))" > "%TEMP_DIR%\_hf_result.txt" 2>nul
for /f "usebackq tokens=*" %%L in ("%TEMP_DIR%\_hf_result.txt") do (
    set /a _RES_LINE+=1
    if !_RES_LINE!==1 set "DLPATH=%%L"
    if !_RES_LINE!==2 set "DLFN=%%L"
)
del "%TEMP_DIR%\_hf_result.txt" 2>nul

echo.
if not defined DLPATH (
    echo  [FAIL] Could not read result path.
) else (
    echo "!DLFN!" | findstr /i "\.gguf" >nul 2>&1
    if not errorlevel 1 (
        :: GGUF downloaded - detect architecture to confirm correct folder
        if exist "%PYTHON_DIR%\python.exe" if exist "%BASE_DIR%gguf_detect.py" (
            echo  [*] Detecting GGUF model type from header ...
            set "_GD_ARCH=unknown"
            set "_GD_TYPE=unknown"
            "%PYTHON_DIR%\python.exe" "%BASE_DIR%gguf_detect.py" "!DLPATH!" > "%TEMP_DIR%\_gguf_det.txt" 2>nul
            for /f "usebackq tokens=1,2 delims==" %%A in ("%TEMP_DIR%\_gguf_det.txt") do (
                if "%%A"=="arch" set "_GD_ARCH=%%B"
                if "%%A"=="type" set "_GD_TYPE=%%B"
            )
            del "%TEMP_DIR%\_gguf_det.txt" 2>nul
            echo  [*] Architecture: !_GD_ARCH!  Type: !_GD_TYPE!
            if /i "!_GD_TYPE!"=="image" (
                set "_IMG_MOVE=%MODELS_DIR%\image\!DLFN!"
                move "!DLPATH!" "!_IMG_MOVE!" >nul 2>&1
                if errorlevel 1 (
                    echo  [WARN] Could not move to models\image\ - file stays in models\chat\
                    echo  [OK] Saved to: models\chat\
                ) else (
                    echo  [OK] Moved to: models\image\
                    echo  Available in Image generation dropdown.
                )
            ) else (
                echo  [OK] Saved to: models\chat\
                echo  Use option [4] to register with Ollama.
            )
        ) else (
            echo  [OK] Saved to: models\chat\
            echo  Use option [4] to register with Ollama.
        )
    ) else (
        echo "!DLFN!" | findstr /i "\.bin \.pt" >nul 2>&1
        if not errorlevel 1 (
            echo  [OK] Saved to: models\chat\
            echo  Use option [4] to register with Ollama.
        ) else (
            echo  [OK] Saved to: models\image\
            echo  Available in Image dropdown.
        )
    )
)

del "%TEMP_DIR%\_hf_*.json" "%TEMP_DIR%\_hf_*.txt" 2>nul
echo.
pause
goto :DOWNLOAD_MODELS_MENU


:: ============================================================
:: 2.3  Import Local File
:: ============================================================
:IMPORT_LOCAL
cls
echo.
echo  ==========================================================
echo   2.3  Import Local Model File
echo  ==========================================================
echo.
echo  Supported: .gguf  .bin  .pt  .safetensors  .ckpt
echo.
echo   [1] Chat model   ^(.gguf / .bin / .pt^)  -^> models\chat\
echo   [2] Image model  ^(.safetensors / .ckpt^) -^> models\image\
echo   [3] Back
echo.
set "imp_type="
set /p "imp_type=  Select [1-3]: "
if "!imp_type!"=="3" goto :DOWNLOAD_MODELS_MENU
if "!imp_type!"=="" goto :IMPORT_LOCAL
if not "!imp_type!"=="1" if not "!imp_type!"=="2" goto :IMPORT_LOCAL

if "!imp_type!"=="1" (
    set "IMP_DEST=%MODELS_DIR%\chat"
    set "IMP_LABEL=Chat"
    set "IMP_VALID_EXTS=.gguf .bin .pt"
) else (
    set "IMP_DEST=%MODELS_DIR%\image"
    set "IMP_LABEL=Image"
    set "IMP_VALID_EXTS=.safetensors .ckpt .gguf"
)

echo.
set "lpath="
set /p "lpath=  Full file path ^(or 'back'^): "
if /i "!lpath!"=="back" goto :IMPORT_LOCAL
if "!lpath!"=="" goto :IMPORT_LOCAL
set "lpath=!lpath:"=!"

if not exist "!lpath!" (
    echo  [FAIL] File not found: !lpath!
    pause & goto :IMPORT_LOCAL
)

for %%F in ("!lpath!") do (
    set "LF_NAME=%%~nxF"
    set "LF_EXT=%%~xF"
)
if "!LF_NAME!"=="" (echo  [FAIL] Not a file path. & pause & goto :IMPORT_LOCAL)

call :GET_FILESIZE_SAFE "!lpath!" LF_SZ_STR
echo.
echo  File: !LF_NAME!
echo  Size: !LF_SZ_STR!
echo  Dest: !IMP_DEST!

set "_EXT_OK=0"
for %%E in (!IMP_VALID_EXTS!) do (
    if /i "!LF_EXT!"=="%%E" set "_EXT_OK=1"
)
if "!_EXT_OK!"=="0" (
    echo.
    echo  [WARN] Extension '!LF_EXT!' unusual for !IMP_LABEL! models.
    set "_FORCE="
    set /p "_FORCE=  Continue anyway? [y/n]: "
    if /i not "!_FORCE!"=="y" goto :IMPORT_LOCAL
)

echo.
echo  [*] Copying ...
copy "!lpath!" "!IMP_DEST!\!LF_NAME!" >nul 2>&1
if errorlevel 1 (
    echo  [FAIL] Copy failed. Check permissions and disk space.
    pause & goto :IMPORT_LOCAL
)
echo  [OK] Copied: !LF_NAME!

if "!imp_type!"=="1" (
    echo  Use option [4] to register with Ollama.
) else (
    echo  Available in Image dropdown.
)
echo.
pause
goto :DOWNLOAD_MODELS_MENU


:: ============================================================
:: 2.4  Import from models\chat -> Ollama
::
:: FIX: Modelfile path is written with quoted FROM line so
::      spaces in BASE_DIR are handled by Ollama correctly.
:: ============================================================
:IMPORT_SCAN_CHAT
cls
echo.
echo  ==========================================================
echo   2.4  Import from models\chat into Ollama
echo  ==========================================================
echo.

if not exist "%OLLAMA_DIR%\ollama.exe" (
    echo  [FAIL] Ollama not installed. Run Setup first.
    pause & goto :DOWNLOAD_MODELS_MENU
)

echo  Scanning: %MODELS_DIR%\chat
echo.

set "_SC_TOTAL=0"
for %%F in ("%MODELS_DIR%\chat\*") do (
    if exist "%%F" (
        set "_SCN=%%~nxF"
        set "_SCX=%%~xF"
        set "_SC_SKIP=0"
        echo "!_SCN!" | findstr /i "\.partial" >nul 2>&1
        if not errorlevel 1 set "_SC_SKIP=1"
        if "!_SC_SKIP!"=="0" (
            set "_SC_MATCH=0"
            if /i "!_SCX!"==".gguf" set "_SC_MATCH=1"
            if /i "!_SCX!"==".bin"  set "_SC_MATCH=1"
            if /i "!_SCX!"==".pt"   set "_SC_MATCH=1"
            if "!_SC_MATCH!"=="1" (
                set /a _SC_TOTAL+=1
                call :GET_FILESIZE_SAFE "%%~F" _SCSZ
                echo   [!_SC_TOTAL!] !_SCN!  ^(!_SCSZ!^)
                set "_SCF!_SC_TOTAL!=%%~F"
                set "_SCN!_SC_TOTAL!=!_SCN!"
            )
        )
    )
)

if !_SC_TOTAL!==0 (
    echo   No model files found in models\chat\
    echo.
    echo   Download GGUF files first via options [1], [2], or [3].
    echo.
    pause & goto :DOWNLOAD_MODELS_MENU
)

set /a _SC_CANCEL=_SC_TOTAL+1
echo.
echo   [!_SC_CANCEL!] Cancel
echo.
set "sc_sel="
set /p "sc_sel=  Select file to register with Ollama: "
if "!sc_sel!"=="" goto :DOWNLOAD_MODELS_MENU

set "_SC_VALID=0"
for /f "delims=0123456789" %%X in ("!sc_sel!x") do (
    if "%%X"=="x" set "_SC_VALID=1"
)
if "!_SC_VALID!"=="0" goto :DOWNLOAD_MODELS_MENU
set /a "_SC_SEL_N=sc_sel" 2>nul
if !_SC_SEL_N! GEQ !_SC_CANCEL! goto :DOWNLOAD_MODELS_MENU
if !_SC_SEL_N! LEQ 0 goto :DOWNLOAD_MODELS_MENU

set "SC_FILE=!_SCF%sc_sel%!"
set "SC_NAME=!_SCN%sc_sel%!"
if not defined SC_FILE goto :DOWNLOAD_MODELS_MENU

echo.
call :GET_FILESIZE_SAFE "!SC_FILE!" _SCFSZ
echo  Selected: !SC_NAME!  ^(!_SCFSZ!^)
echo.

set "SUGGESTED=!SC_NAME!"
set "SUGGESTED=!SUGGESTED:.gguf=!"
set "SUGGESTED=!SUGGESTED:.bin=!"
set "SUGGESTED=!SUGGESTED:.pt=!"
set "SUGGESTED=!SUGGESTED:.=-!"
set "SUGGESTED=!SUGGESTED:_=-!"
set "SUGGESTED=!SUGGESTED: =-!"

echo  Suggested name: !SUGGESTED!
set "mname="
set /p "mname=  Ollama name ^(Enter for suggested^): "
if "!mname!"=="" set "mname=!SUGGESTED!"

set "mname=!mname: =-!"
set "mname=!mname:&=!"
set "mname=!mname:|=!"
set "mname=!mname:<=!"
set "mname=!mname:>=!"
set "mname=!mname:^=!"
set "mname=!mname:"=!"
if "!mname!"=="" set "mname=imported-model"

echo.
echo  Registering as: !mname!
echo  Source:         !SC_FILE!
echo.

:: FIX: Write quoted FROM path so spaces in path are safe for
::      Ollama's Modelfile parser. Double-quotes are valid in
::      Ollama FROM directives.
> "%TEMP_DIR%\Modelfile" echo FROM "!SC_FILE!"

call :ENSURE_OLLAMA
echo.
call :SET_OLLAMA_BUSY "create !mname!"
"%OLLAMA_DIR%\ollama.exe" create !mname! -f "%TEMP_DIR%\Modelfile"
set "_CREATE_ERR=!errorlevel!"
call :CLEAR_OLLAMA_BUSY
del "%TEMP_DIR%\Modelfile" 2>nul

if !_CREATE_ERR! NEQ 0 (
    echo.
    echo  [FAIL] Ollama could not register the model.
    echo         Ensure the file is a valid GGUF.
) else (
    echo.
    echo  [OK] Registered: !mname!
    echo       Now available in Chat dropdown.
    echo.
    set "deldl="
    set /p "deldl=  Delete original file from models\chat? [y/n]: "
    if /i "!deldl!"=="y" (
        del "!SC_FILE!" 2>nul
        if errorlevel 1 (echo  [WARN] Could not delete.) else (echo  [OK] Deleted.)
    )
)
echo.
pause
goto :DOWNLOAD_MODELS_MENU


:: ============================================================
:: 2.5  Manage models\image
:: ============================================================
:IMPORT_SCAN_IMAGE
cls
echo.
echo  ==========================================================
echo   2.5  Manage models\image
echo  ==========================================================
echo.
echo  Scanning: %MODELS_DIR%\image
echo.

set "_SI_TOTAL=0"
for %%F in ("%MODELS_DIR%\image\*") do (
    if exist "%%F" (
        set "_SIN=%%~nxF"
        set "_SI_SKIP=0"
        echo "!_SIN!" | findstr /i "\.partial" >nul 2>&1
        if not errorlevel 1 set "_SI_SKIP=1"
        if "!_SI_SKIP!"=="0" (
            set /a _SI_TOTAL+=1
            call :GET_FILESIZE_SAFE "%%~F" _SISZ
            echo   [!_SI_TOTAL!] !_SIN!  ^(!_SISZ!^)
            set "_SIF!_SI_TOTAL!=%%~F"
            set "_SIN!_SI_TOTAL!=!_SIN!"
        )
    )
)

if !_SI_TOTAL!==0 (
    echo   No image models found.
    echo.
    echo   Download via options [1], [2], or [3].
    echo.
    pause & goto :DOWNLOAD_MODELS_MENU
)

echo.
echo  Files here are automatically available in Image dropdown.
echo.
echo   [R] Rename   [D] Delete   [B] Back
echo.
set "si_act="
set /p "si_act=  Action: "
if /i "!si_act!"=="B" goto :DOWNLOAD_MODELS_MENU
if /i "!si_act!"=="R" goto :IMG_RENAME
if /i "!si_act!"=="D" goto :IMG_DELETE
goto :IMPORT_SCAN_IMAGE

:IMG_RENAME
echo.
set "si_rn="
set /p "si_rn=  File number to rename: "
if "!si_rn!"=="" goto :IMPORT_SCAN_IMAGE
set "_RN_VALID=0"
for /f "delims=0123456789" %%X in ("!si_rn!x") do if "%%X"=="x" set "_RN_VALID=1"
if "!_RN_VALID!"=="0" goto :IMPORT_SCAN_IMAGE
set /a "_RN_N=si_rn" 2>nul
if !_RN_N! GTR !_SI_TOTAL! goto :IMPORT_SCAN_IMAGE
if !_RN_N! LEQ 0 goto :IMPORT_SCAN_IMAGE
set "_RNF=!_SIF%si_rn%!"
set "_RNN=!_SIN%si_rn%!"
if not defined _RNF goto :IMPORT_SCAN_IMAGE
echo  Current: !_RNN!
set "new_name="
set /p "new_name=  New filename ^(with extension^): "
if "!new_name!"=="" goto :IMPORT_SCAN_IMAGE
set "new_name=!new_name:"=!"
if "!new_name!"=="" goto :IMPORT_SCAN_IMAGE
ren "!_RNF!" "!new_name!" 2>nul
if errorlevel 1 (echo  [FAIL] Rename failed.) else (echo  [OK] Renamed.)
pause & goto :IMPORT_SCAN_IMAGE

:IMG_DELETE
echo.
set "si_del="
set /p "si_del=  File number to delete: "
if "!si_del!"=="" goto :IMPORT_SCAN_IMAGE
set "_DLV=0"
for /f "delims=0123456789" %%X in ("!si_del!x") do if "%%X"=="x" set "_DLV=1"
if "!_DLV!"=="0" goto :IMPORT_SCAN_IMAGE
set /a "_DEL_N=si_del" 2>nul
if !_DEL_N! GTR !_SI_TOTAL! goto :IMPORT_SCAN_IMAGE
if !_DEL_N! LEQ 0 goto :IMPORT_SCAN_IMAGE
set "_DLF=!_SIF%si_del%!"
set "_DLN=!_SIN%si_del%!"
if not defined _DLF goto :IMPORT_SCAN_IMAGE
set "si_conf="
set /p "si_conf=  Delete '!_DLN!'? [y/n]: "
if /i "!si_conf!"=="y" (
    del "!_DLF!" 2>nul
    if errorlevel 1 (echo  [FAIL]) else (echo  [OK] Deleted.)
) else (echo  Cancelled.)
pause & goto :IMPORT_SCAN_IMAGE


:: ============================================================
:: 2.7  Model Manager - Multi-source
:: ============================================================
:MODEL_MANAGER_MENU
cls
echo.
echo  ==========================================================
echo   2.7  Model Manager  ^(Multi-source^)
echo  ==========================================================
echo.
if not exist "%PYTHON_DIR%\python.exe" (
    echo  [FAIL] Python not installed. Run Setup first.
    pause & goto :DOWNLOAD_MODELS_MENU
)
if not exist "%BASE_DIR%model_manager.py" (
    echo  [FAIL] model_manager.py missing.
    pause & goto :DOWNLOAD_MODELS_MENU
)

echo   [1] Init / Repair Registry
echo   [2] Download from HuggingFace
echo   [3] Download from Direct URL
echo   [4] Import Local File/Folder
echo   [5] List Registry JSON
echo   [6] Back
echo.
set "mmc="
set /p "mmc=  Select [1-6]: "

if "!mmc!"=="1" (
    "%PYTHON_DIR%\python.exe" "%BASE_DIR%model_manager.py" init
    echo.
    pause
    goto :MODEL_MANAGER_MENU
)

if "!mmc!"=="2" goto :MM_HF
if "!mmc!"=="3" goto :MM_URL
if "!mmc!"=="4" goto :MM_LOCAL
if "!mmc!"=="5" (
    "%PYTHON_DIR%\python.exe" "%BASE_DIR%model_manager.py" list
    echo.
    pause
    goto :MODEL_MANAGER_MENU
)
if "!mmc!"=="6" (
    set "MM_PRESET_TASK="
    goto :DOWNLOAD_MODELS_MENU
)
goto :MODEL_MANAGER_MENU


:MM_SELECT_TASK
if defined MM_PRESET_TASK (
    set "MM_TASK=!MM_PRESET_TASK!"
    set "MM_PRESET_TASK="
    exit /b 0
)
echo.
echo   Task type:
echo    [1] chat
echo    [2] image
echo    [3] cancel
set "mmt="
set /p "mmt=  Select [1-3]: "
if "!mmt!"=="1" (set "MM_TASK=chat" & exit /b 0)
if "!mmt!"=="2" (set "MM_TASK=image" & exit /b 0)
set "MM_TASK="
exit /b 1


:MM_HF
call :MM_SELECT_TASK
if not defined MM_TASK goto :MODEL_MANAGER_MENU
echo.
set "mm_repo="
set /p "mm_repo=  HuggingFace repo ID ^(e.g. org/model^): "
if "!mm_repo!"=="" goto :MODEL_MANAGER_MENU
set "mm_name="
set /p "mm_name=  Local name ^(Enter for auto^): "
set "mm_file="
set /p "mm_file=  Single file path in repo ^(Enter for snapshot^): "
set "mm_pat="
set /p "mm_pat=  Snapshot allow patterns comma-list ^(optional^): "
set "mm_token="
set /p "mm_token=  HF token ^(Enter to skip^): "
echo.
"%PYTHON_DIR%\python.exe" "%BASE_DIR%model_manager.py" download-hf --task "!MM_TASK!" --repo "!mm_repo!" --name "!mm_name!" --file "!mm_file!" --allow-patterns "!mm_pat!" --token "!mm_token!"
echo.
pause
goto :MODEL_MANAGER_MENU


:MM_URL
call :MM_SELECT_TASK
if not defined MM_TASK goto :MODEL_MANAGER_MENU
echo.
set "mm_url="
set /p "mm_url=  Direct URL: "
if "!mm_url!"=="" goto :MODEL_MANAGER_MENU
set "mm_name="
set /p "mm_name=  Local model name: "
if "!mm_name!"=="" goto :MODEL_MANAGER_MENU
set "mm_fn="
set /p "mm_fn=  Output filename ^(optional^): "
set "mm_sha="
set /p "mm_sha=  SHA256 ^(optional^): "
echo.
"%PYTHON_DIR%\python.exe" "%BASE_DIR%model_manager.py" download-url --task "!MM_TASK!" --url "!mm_url!" --name "!mm_name!" --filename "!mm_fn!" --sha256 "!mm_sha!"
echo.
pause
goto :MODEL_MANAGER_MENU


:MM_LOCAL
call :MM_SELECT_TASK
if not defined MM_TASK goto :MODEL_MANAGER_MENU
echo.
if /I "!MM_TASK!"=="chat" (
    echo   Chat import usually expects a .gguf file.
) else if /I "!MM_TASK!"=="image" (
    echo   Image import usually expects .safetensors/.ckpt/.pt/.pth files.
)
echo.
set "mm_path="
set /p "mm_path=  Local file/folder path: "
if "!mm_path!"=="" goto :MODEL_MANAGER_MENU
set "mm_name="
set /p "mm_name=  Local model name ^(Enter for auto^): "
echo.
"%PYTHON_DIR%\python.exe" "%BASE_DIR%model_manager.py" import-local --task "!MM_TASK!" --path "!mm_path!" --name "!mm_name!"
echo.
pause
goto :MODEL_MANAGER_MENU


:MM_INSTALL_VIDEO_RUNTIME
cls
echo.
echo  ==========================================================
echo   Feature Removed
echo  ==========================================================
echo.
echo  Video runtime support has been removed from this build.
echo.
pause
goto :MODEL_MANAGER_MENU


:INSTALL_VIDEO_RUNTIME_PACKAGES
echo.
echo  [INFO] Video runtime support has been removed from this build.
echo.
exit /b 0

:MM_HF_VIDEO_RECOMMENDED
cls
echo.
echo  ==========================================================
echo   Feature Removed
echo  ==========================================================
echo.
echo  Recommended video model download has been removed.
echo.
pause
goto :MODEL_MANAGER_MENU


:: ============================================================
:: 3. UNINSTALL MENU
:: ============================================================
:UNINSTALL_MENU
cls
echo.
echo  ==========================================================
echo   Uninstall / Remove
echo   AlphaBridge IT Solution (TM)
echo  ==========================================================
echo.
echo   [1] Remove Chat Model from Ollama
echo   [2] Remove Image Model
echo   [3] Remove file from models\chat
echo   [4] Clean Temp / Cache
echo   [5] Full Cleanup
echo   [6] Back
echo.
set "uc="
set /p "uc=  Select [1-6]: "
if "!uc!"=="1" goto :REMOVE_CHAT
if "!uc!"=="2" goto :REMOVE_IMAGE
if "!uc!"=="3" goto :REMOVE_CHAT_FILE
if "!uc!"=="4" goto :CLEAN_TEMP
if "!uc!"=="5" goto :FULL_CLEANUP
if "!uc!"=="6" goto :MAIN_MENU
goto :UNINSTALL_MENU

:REMOVE_CHAT
cls
echo.
echo  Remove Chat Model from Ollama
echo  ==========================================================
if not exist "%OLLAMA_DIR%\ollama.exe" (echo  [FAIL] Ollama not installed. & pause & goto :UNINSTALL_MENU)
call :ENSURE_OLLAMA
echo.
set "_OLRM_COUNT=0"
"%OLLAMA_DIR%\ollama.exe" list > "%TEMP_DIR%\_olrm.txt" 2>nul
if exist "%TEMP_DIR%\_olrm.txt" (
    for /f "usebackq skip=1 tokens=1" %%A in ("%TEMP_DIR%\_olrm.txt") do (
        set /a _OLRM_COUNT+=1
        echo   [!_OLRM_COUNT!] %%A
        set "_OLRM!_OLRM_COUNT!=%%A"
    )
    del "%TEMP_DIR%\_olrm.txt" 2>nul
)
if !_OLRM_COUNT!==0 (echo   No models registered. & pause & goto :UNINSTALL_MENU)
set /a _OLRM_CANCEL=_OLRM_COUNT+1
echo.
echo   [!_OLRM_CANCEL!] Cancel
echo.
set "rm_sel="
set /p "rm_sel=  Select: "
if "!rm_sel!"=="" goto :UNINSTALL_MENU
set "_RMS_VALID=0"
for /f "delims=0123456789" %%X in ("!rm_sel!x") do if "%%X"=="x" set "_RMS_VALID=1"
if "!_RMS_VALID!"=="0" goto :UNINSTALL_MENU
set /a "_RMS_N=rm_sel" 2>nul
if !_RMS_N! GEQ !_OLRM_CANCEL! goto :UNINSTALL_MENU
if !_RMS_N! LEQ 0 goto :UNINSTALL_MENU
set "rm_model=!_OLRM%rm_sel%!"
if not defined rm_model goto :UNINSTALL_MENU
set "crm="
set /p "crm=  Remove '!rm_model!'? [y/n]: "
if /i not "!crm!"=="y" goto :UNINSTALL_MENU
call :SET_OLLAMA_BUSY "rm !rm_model!"
"%OLLAMA_DIR%\ollama.exe" rm !rm_model!
call :CLEAR_OLLAMA_BUSY
if errorlevel 1 (echo  [FAIL]) else (echo  [OK] Removed.)
pause & goto :UNINSTALL_MENU

:REMOVE_IMAGE
cls
echo.
echo  Remove Image Model
echo  ==========================================================
echo.
call :BUILD_IMAGE_LIST
if !_IMG_TOTAL!==0 (echo  No image models found. & pause & goto :UNINSTALL_MENU)
set /a _IMG_CANCEL=_IMG_TOTAL+1
echo   [!_IMG_CANCEL!] Cancel
echo.
set "ir="
set /p "ir=  Select: "
if "!ir!"=="" goto :UNINSTALL_MENU
set "_IR_VALID=0"
for /f "delims=0123456789" %%X in ("!ir!x") do if "%%X"=="x" set "_IR_VALID=1"
if "!_IR_VALID!"=="0" goto :UNINSTALL_MENU
set /a "_IR_N=ir" 2>nul
if !_IR_N! GEQ !_IMG_CANCEL! goto :UNINSTALL_MENU
if !_IR_N! LEQ 0 goto :UNINSTALL_MENU
set "RIMF=!_IMGF%ir%!"
if not defined RIMF goto :UNINSTALL_MENU
for %%N in ("!RIMF!") do set "RIMN=%%~nxN"
set "cir="
set /p "cir=  Delete '!RIMN!'? [y/n]: "
if /i "!cir!"=="y" (
    del "!RIMF!" 2>nul
    if errorlevel 1 (echo  [FAIL]) else (echo  [OK] Deleted.)
) else (echo  Cancelled.)
pause & goto :UNINSTALL_MENU

:REMOVE_CHAT_FILE
cls
echo.
echo  Remove file from models\chat
echo  ==========================================================
echo.
set "_CF_TOTAL=0"
for %%F in ("%MODELS_DIR%\chat\*") do (
    if exist "%%F" (
        set "_CFN=%%~nxF"
        set "_CF_SKIP=0"
        echo "!_CFN!" | findstr /i "\.partial" >nul 2>&1
        if not errorlevel 1 set "_CF_SKIP=1"
        if "!_CF_SKIP!"=="0" (
            set /a _CF_TOTAL+=1
            call :GET_FILESIZE_SAFE "%%~F" _CFSZ
            echo   [!_CF_TOTAL!] !_CFN!  ^(!_CFSZ!^)
            set "_CFF!_CF_TOTAL!=%%~F"
            set "_CFN!_CF_TOTAL!=!_CFN!"
        )
    )
)
if !_CF_TOTAL!==0 (echo   No files in models\chat\ & pause & goto :UNINSTALL_MENU)
set /a _CF_CANCEL=_CF_TOTAL+1
echo.
echo   [!_CF_CANCEL!] Cancel
echo.
set "cf_sel="
set /p "cf_sel=  Select: "
if "!cf_sel!"=="" goto :UNINSTALL_MENU
set "_CFV=0"
for /f "delims=0123456789" %%X in ("!cf_sel!x") do if "%%X"=="x" set "_CFV=1"
if "!_CFV!"=="0" goto :UNINSTALL_MENU
set /a "_CF_N=cf_sel" 2>nul
if !_CF_N! GEQ !_CF_CANCEL! goto :UNINSTALL_MENU
if !_CF_N! LEQ 0 goto :UNINSTALL_MENU
set "RCFF=!_CFF%cf_sel%!"
set "RCFN=!_CFN%cf_sel%!"
if not defined RCFF goto :UNINSTALL_MENU
set "cfconf="
set /p "cfconf=  Delete '!RCFN!'? [y/n]: "
if /i "!cfconf!"=="y" (
    del "!RCFF!" 2>nul
    if errorlevel 1 (echo  [FAIL]) else (echo  [OK] Deleted.)
) else (echo  Cancelled.)
pause & goto :UNINSTALL_MENU

:REMOVE_VIDEO
cls
echo.
echo  Feature Removed
echo  ==========================================================
echo.
echo  Video-specific uninstall flow is no longer available.
echo.
pause & goto :UNINSTALL_MENU

:CLEAN_TEMP
cls
echo.
echo  Clean Temp / Cache
echo  ==========================================================
echo.
call :GET_DIRSIZE_SAFE "%TEMP_DIR%" _TSZ
call :GET_DIRSIZE_SAFE "%HF_CACHE%" _HSZ
set "PC=0"
for /r "%BASE_DIR%" %%F in (*.partial) do set /a PC+=1
echo   Temp dir:  !_TSZ!
echo   HF cache:  !_HSZ!
echo   Partials:  !PC! file(s)
echo.
echo   [1] Clean temp and cache  ^(keep partials^)
echo   [2] Clean everything including partials
echo   [3] Cancel
echo.
set "cc="
set /p "cc=  Select: "
if "!cc!"=="1" (
    rd /s /q "%TEMP_DIR%" 2>nul & mkdir "%TEMP_DIR%" 2>nul
    rd /s /q "%HF_CACHE%" 2>nul & mkdir "%HF_CACHE%" 2>nul
    echo  [OK] Cleaned.
) else if "!cc!"=="2" (
    set "r2="
    set /p "r2=  Type YES to confirm: "
    if "!r2!"=="YES" (
        rd /s /q "%TEMP_DIR%" 2>nul & mkdir "%TEMP_DIR%" 2>nul
        rd /s /q "%HF_CACHE%" 2>nul & mkdir "%HF_CACHE%" 2>nul
        for /r "%BASE_DIR%" %%F in (*.partial) do del "%%F" 2>nul
        echo  [OK] Cleaned.
    ) else (echo  Cancelled.)
) else (echo  Cancelled.)
pause & goto :UNINSTALL_MENU

:FULL_CLEANUP
cls
echo.
echo  FULL CLEANUP
echo  ==========================================================
echo.
echo  Removes: Ollama models, chat files, image files,
echo           temp, cache, partials, generated images,
echo           chat history.
echo.
set "fc2="
set /p "fc2=  Type YES to confirm: "
if not "!fc2!"=="YES" (echo  Cancelled. & pause & goto :UNINSTALL_MENU)
echo.
echo  [1/7] Ollama models ...
if exist "%OLLAMA_DIR%\ollama.exe" (
    call :ENSURE_OLLAMA
    "%OLLAMA_DIR%\ollama.exe" list > "%TEMP_DIR%\_cleanup.txt" 2>nul
    if exist "%TEMP_DIR%\_cleanup.txt" (
        for /f "usebackq skip=1 tokens=1" %%M in ("%TEMP_DIR%\_cleanup.txt") do (
            echo       %%M
            call :SET_OLLAMA_BUSY "rm %%M"
            "%OLLAMA_DIR%\ollama.exe" rm %%M 2>nul
            call :CLEAR_OLLAMA_BUSY
        )
        del "%TEMP_DIR%\_cleanup.txt" 2>nul
    )
) else (echo       Ollama not installed.)
echo  [2/7] Chat files ...
if exist "%MODELS_DIR%\chat"  del /q "%MODELS_DIR%\chat\*.*"  2>nul
echo  [3/7] Image models ...
if exist "%MODELS_DIR%\image" del /q "%MODELS_DIR%\image\*.*" 2>nul
echo  [4/7] Temp ...
rd /s /q "%TEMP_DIR%" 2>nul & mkdir "%TEMP_DIR%" 2>nul
rd /s /q "%HF_CACHE%" 2>nul & mkdir "%HF_CACHE%" 2>nul
echo  [5/7] Partials ...
for /r "%BASE_DIR%" %%F in (*.partial) do del "%%F" 2>nul
echo  [6/7] Generated images ...
if exist "%BASE_DIR%generated_images" rd /s /q "%BASE_DIR%generated_images" 2>nul
echo  [7/7] Chat history ...
if exist "%BASE_DIR%chat_history" rd /s /q "%BASE_DIR%chat_history" 2>nul
echo.
echo  [OK] Done.
pause & goto :UNINSTALL_MENU


:: ============================================================
:: 4. START CHAT
:: ============================================================
:START_CHAT
cls
echo.
echo  ==========================================================
echo   Start Chat Server
echo   AlphaBridge IT Solution (TM)
echo  ==========================================================
echo.
if not exist "%PYTHON_DIR%\python.exe" (echo  [FAIL] Python not installed. & pause & goto :MAIN_MENU)
if not exist "%BASE_DIR%chat_server.py" (echo  [FAIL] chat_server.py missing. & pause & goto :MAIN_MENU)
if not exist "%OLLAMA_DIR%\ollama.exe" echo  [WARN] Ollama not installed.

call :ENSURE_OLLAMA
echo.
echo  [*] Starting server ...
echo.
set "_SC_LAN="
set /p "_SC_LAN=  Make this app discoverable over the network? [y/n]: "
if /I "!_SC_LAN!"=="y" (
    set "ALPHA_EXPOSE_LAN=1"
    echo  [*] Network access enabled.
) else (
    set "ALPHA_EXPOSE_LAN=0"
    echo  [*] Local-only mode.
)
echo.
if exist "%BASE_DIR%start_chat.bat" (
    start "" cmd /c "set ALPHA_EXPOSE_LAN=!ALPHA_EXPOSE_LAN! && "%BASE_DIR%start_chat.bat""
) else (
    start "" "%PYTHON_DIR%\python.exe" "%BASE_DIR%chat_server.py"
)

echo  [*] Waiting ...
set "_SRV_UP=0"
for /l %%I in (1,1,15) do (
    if "!_SRV_UP!"=="0" (
        timeout /t 1 /nobreak >nul
        if "%DL_TOOL%"=="curl" (
            curl.exe -s -o nul --connect-timeout 2 "http://127.0.0.1:5000" >nul 2>&1
            if not errorlevel 1 set "_SRV_UP=1"
        ) else (
            if %%I==5 set "_SRV_UP=1"
        )
    )
)
if "!_SRV_UP!"=="1" (
    echo  [OK] Server started.
    echo  Open: http://127.0.0.1:5000
) else (
    echo  [WARN] May still be starting. Check: http://127.0.0.1:5000
)
echo.
pause
goto :MAIN_MENU


:: ============================================================
:: 5. SYSTEM INFO
:: ============================================================
:SYSTEM_INFO
cls
call :LOG "SYSTEM_INFO entered"
call :LOG "SYSTEM_INFO mode SYS_TOOL=%SYS_TOOL% ALPHA_SAFE_SYSINFO=%ALPHA_SAFE_SYSINFO%"
echo.
echo  ==========================================================
echo   System Information
echo   AlphaBridge IT Solution (TM)
echo  ==========================================================
echo.
call :GET_RAM_GB
set "_SI_RC=!errorlevel!"
call :LOG "GET_RAM_GB rc=!_SI_RC! RAM=!_RAM_GB!"
call :GET_VRAM
set "_SI_RC=!errorlevel!"
call :LOG "GET_VRAM rc=!_SI_RC! VRAM=!_VRAM_GB! GPU_NAME=!_GPU_NAME!"
call :GET_CPU_NAME
set "_SI_RC=!errorlevel!"
call :LOG "GET_CPU_NAME rc=!_SI_RC! CPU=!_CPU_NAME!"
call :GET_GPU_NAME_WMI
set "_SI_RC=!errorlevel!"
call :LOG "GET_GPU_NAME_WMI rc=!_SI_RC! GPU_DISPLAY=!_GPU_DISPLAY!"
echo   RAM:  !_RAM_GB! GB
echo   CPU:  !_CPU_NAME!
echo   GPU:  !_GPU_DISPLAY!
if !_VRAM_GB! GTR 0 echo   VRAM: !_VRAM_GB! GB  ^(!_GPU_NAME!^)
echo   Tool: %DL_TOOL%  Resume: %RESUME_SUPPORT%  Sys: %SYS_TOOL%
echo   Log:  %LOG_FILE%
echo.
echo  -- Components ------------------------------------------------
if exist "%PYTHON_DIR%\python.exe"  (echo   [OK] Python %PYTHON_VERSION%) else (echo   [--] Python)
if exist "%OLLAMA_DIR%\ollama.exe"  (echo   [OK] Ollama)                  else (echo   [--] Ollama)
if exist "%SD_DIR%\sd-cli.exe" (echo   [OK] SD.cpp ^(sd-cli.exe^)) else if exist "%SD_DIR%\sd.exe" (echo   [OK] SD.cpp ^(sd.exe^)) else (echo   [--] SD.cpp)
if exist "%BASE_DIR%chat_server.py" (echo   [OK] Server) else (echo   [--] Server)
if exist "%BASE_DIR%chatUI.html"    (echo   [OK] UI)     else (echo   [--] UI)
echo.
echo  -- Directories -----------------------------------------------
echo   Chat downloads: %MODELS_DIR%\chat
echo   Image models:   %MODELS_DIR%\image
echo   Ollama store:   %OLLAMA_MODELS%
echo.
echo  -- Chat Models (Ollama) --------------------------------------
if exist "%OLLAMA_DIR%\ollama.exe" (
    call :ENSURE_OLLAMA
    echo.
    call :LOG "SYSTEM_INFO listing Ollama models"
    "%OLLAMA_DIR%\ollama.exe" list > "%TEMP_DIR%\_sys_ollama_list.txt" 2>&1
    if exist "%TEMP_DIR%\_sys_ollama_list.txt" (
        findstr /v "console mode handle" "%TEMP_DIR%\_sys_ollama_list.txt"
        del "%TEMP_DIR%\_sys_ollama_list.txt" 2>nul
    )
) else (echo   Ollama not installed.)
echo.
echo  -- Chat Downloads (models\chat) ------------------------------
call :LIST_CHAT_FILES_DISPLAY
call :LOG "SYSTEM_INFO listed chat files"
echo.
echo  -- Image Models (models\image) -------------------------------
call :LIST_IMAGE_MODELS_DISPLAY
call :LOG "SYSTEM_INFO listed image files"
echo.
echo  -- Partial Downloads -----------------------------------------
echo.
call :LIST_PARTIALS_DETAIL
call :LOG "SYSTEM_INFO listed partials"
echo.
call :LOG "SYSTEM_INFO completed"
pause & goto :MAIN_MENU


:: ############################################################
:: SUBROUTINES
:: ############################################################


:: ============================================================
:: :DO_DOWNLOAD
:: ============================================================
:LOG
set "_LOG_MSG=%~1"
if not defined LOG_FILE exit /b 0
>>"%LOG_FILE%" echo [%DATE% %TIME%] %_LOG_MSG%
exit /b 0


:: ============================================================
:: :DO_DOWNLOAD
:: ============================================================
:DO_DOWNLOAD
set "DL_OK=0"
set "_PARTIAL=%_DL_OUT%.partial"

echo.
echo  [DOWNLOAD] %_DL_NAME%

if exist "%_DL_OUT%" (
    for %%F in ("%_DL_OUT%") do set "_EX_SZ=%%~zF"
    if !_EX_SZ! GTR 1000 (
        echo  [SKIP] Already exists.
        set "DL_OK=1"
        exit /b 0
    )
    del "%_DL_OUT%" 2>nul
)

if exist "!_PARTIAL!" (
    call :GET_FILESIZE_SAFE "!_PARTIAL!" _PMB
    echo  [RESUME] Partial: !_PMB!
)

for /l %%A in (1,1,%MAX_RETRIES%) do (
    if "!DL_OK!"=="0" (
        if %%A GTR 1 (
            echo.
            echo  [RETRY] Attempt %%A of %MAX_RETRIES%  ^(wait %RETRY_DELAY%s^)
            timeout /t %RETRY_DELAY% /nobreak >nul
        ) else (
            echo  [*] Attempt %%A of %MAX_RETRIES%
        )

        if "%DL_TOOL%"=="curl" (
            curl.exe -L -C - --progress-bar -f --connect-timeout 30 -o "!_PARTIAL!" "!_DL_URL!" 2>&1
            set "_CURL_RC=!errorlevel!"
            if !_CURL_RC!==0 (
                if exist "!_PARTIAL!" (
                    for %%F in ("!_PARTIAL!") do set "_CSZ=%%~zF"
                    if !_CSZ! GTR 1000 (
                        move /y "!_PARTIAL!" "%_DL_OUT%" >nul 2>&1
                        set "DL_OK=1"
                    )
                )
            ) else if !_CURL_RC!==22 (
                echo  [FAIL] HTTP 4xx - permanent.
                del "!_PARTIAL!" 2>nul
                exit /b 0
            ) else if !_CURL_RC!==33 (
                echo  [WARN] Resume unsupported, restarting ...
                del "!_PARTIAL!" 2>nul
                curl.exe -L --progress-bar -f --connect-timeout 30 -o "!_PARTIAL!" "!_DL_URL!" 2>&1
                if not errorlevel 1 (
                    if exist "!_PARTIAL!" (
                        for %%F in ("!_PARTIAL!") do set "_CSZ=%%~zF"
                        if !_CSZ! GTR 1000 (
                            move /y "!_PARTIAL!" "%_DL_OUT%" >nul 2>&1
                            set "DL_OK=1"
                        )
                    )
                )
            ) else (
                echo  [WARN] curl rc=!_CURL_RC!, retrying ...
            )
        )

        if "%DL_TOOL%"=="bitsadmin" if "!DL_OK!"=="0" (
            set "_BJOB=ll_%RANDOM%_%%A"
            bitsadmin /reset >nul 2>&1
            bitsadmin /create "!_BJOB!" >nul 2>&1
            bitsadmin /addfile "!_BJOB!" "!_DL_URL!" "!_PARTIAL!" >nul 2>&1
            bitsadmin /setpriority "!_BJOB!" foreground >nul 2>&1
            bitsadmin /resume "!_BJOB!" >nul 2>&1
            set "_BDONE=0"
            for /l %%P in (1,1,600) do (
                if "!_BDONE!"=="0" if "!DL_OK!"=="0" (
                    timeout /t 2 /nobreak >nul
                    bitsadmin /info "!_BJOB!" /verbose > "!_PARTIAL!.bstate" 2>nul
                    findstr /i "TRANSFERRED" "!_PARTIAL!.bstate" >nul 2>&1
                    if not errorlevel 1 (
                        bitsadmin /complete "!_BJOB!" >nul 2>&1
                        if exist "!_PARTIAL!" (
                            move /y "!_PARTIAL!" "%_DL_OUT%" >nul 2>&1
                            set "DL_OK=1"
                        )
                        set "_BDONE=1"
                    )
                    if "!_BDONE!"=="0" (
                        findstr /i "ERROR" "!_PARTIAL!.bstate" >nul 2>&1
                        if not errorlevel 1 (
                            findstr /i "404 403 401" "!_PARTIAL!.bstate" >nul 2>&1
                            if not errorlevel 1 (
                                echo  [FAIL] Permanent HTTP error.
                                bitsadmin /cancel "!_BJOB!" >nul 2>&1
                                del "!_PARTIAL!" "!_PARTIAL!.bstate" 2>nul
                                set "_BDONE=1"
                                set "DL_OK=FATAL"
                            ) else (
                                bitsadmin /cancel "!_BJOB!" >nul 2>&1
                                set "_BDONE=1"
                            )
                        )
                    )
                    del "!_PARTIAL!.bstate" 2>nul
                )
            )
            if "!DL_OK!"=="FATAL" (set "DL_OK=0" & exit /b 0)
            if "!DL_OK!"=="0" if "!_BDONE!"=="0" bitsadmin /cancel "!_BJOB!" >nul 2>&1
        )

        if "%DL_TOOL%"=="certutil" if "!DL_OK!"=="0" (
            certutil -urlcache -split -f "!_DL_URL!" "!_PARTIAL!" > "%TEMP_DIR%\_cert_out.txt" 2>&1
            if errorlevel 1 (
                findstr /i "404 403 401" "%TEMP_DIR%\_cert_out.txt" >nul 2>&1
                if not errorlevel 1 (
                    echo  [FAIL] HTTP error - permanent.
                    del "!_PARTIAL!" "%TEMP_DIR%\_cert_out.txt" 2>nul
                    certutil -urlcache -delete "!_DL_URL!" >nul 2>&1
                    exit /b 0
                )
                echo  [WARN] certutil failed, retrying ...
            ) else (
                if exist "!_PARTIAL!" (
                    for %%F in ("!_PARTIAL!") do set "_CSZ=%%~zF"
                    if !_CSZ! GTR 1000 (
                        move /y "!_PARTIAL!" "%_DL_OUT%" >nul 2>&1
                        set "DL_OK=1"
                    )
                )
            )
            del "%TEMP_DIR%\_cert_out.txt" 2>nul
            certutil -urlcache -delete "!_DL_URL!" >nul 2>&1
        )
    )
)

if "!DL_OK!"=="1" (
    call :GET_FILESIZE_SAFE "%_DL_OUT%" _DLSZ
    echo  [OK] %_DL_NAME%  !_DLSZ!
) else (
    echo.
    echo  [FAIL] After %MAX_RETRIES% attempts.
    if exist "!_PARTIAL!" (
        call :GET_FILESIZE_SAFE "!_PARTIAL!" _PLSZ
        echo  [INFO] Partial ^(!_PLSZ!^) saved - run again to resume.
    )
)
exit /b 0


:: ============================================================
:: :DO_UNZIP
:: ============================================================
:DO_UNZIP
set "_UZ_ZIP=%~1"
set "_UZ_DST=%~2"
echo  [*] Extracting %~nx1 ...
if not exist "%_UZ_DST%" mkdir "%_UZ_DST%" 2>nul
where tar.exe >nul 2>&1
if not errorlevel 1 (
    tar -xf "%_UZ_ZIP%" -C "%_UZ_DST%" >nul 2>&1
    if not errorlevel 1 (echo  [OK] Extracted ^(tar^). & exit /b 0)
    echo  [WARN] tar failed, trying VBScript ...
)
set "_VBS=%TEMP_DIR%\_unzip_helper.vbs"
> "%_VBS%" (
    echo Set fso = CreateObject^("Scripting.FileSystemObject"^)
    echo Set sh  = CreateObject^("Shell.Application"^)
    echo src = "%_UZ_ZIP%"
    echo dst = "%_UZ_DST%"
    echo If Not fso.FolderExists^(dst^) Then fso.CreateFolder^(dst^)
    echo Set zf = sh.NameSpace^(src^)
    echo Set df = sh.NameSpace^(dst^)
    echo If IsNull^(zf^) Or IsNull^(df^) Then WScript.Quit 1
    echo df.CopyHere zf.Items, 16+256+512
    echo WScript.Sleep 3000
)
cscript //nologo "%_VBS%" 2>nul
set "_VBS_RC=!errorlevel!"
del "%_VBS%" 2>nul
if "!_VBS_RC!"=="0" (echo  [OK] Extracted ^(VBScript^).) else (echo  [WARN] Extraction may have issues.)
exit /b 0


:: ============================================================
:: :RESOLVE_SD_URL
:: ============================================================
:RESOLVE_SD_URL
set "_SD_RESOLVED=0"
set "_SD_RESOLVED_URL="
set "_SD_ASSET_NAME="
set "_SD_JSON=%TEMP_DIR%\_sd_releases.json"
if exist "%_SD_JSON%" del "%_SD_JSON%" 2>nul
if "%DL_TOOL%"=="curl" (
    curl.exe -s -L --connect-timeout 15 -A "LocalLacy/1.0" "https://api.github.com/repos/leejet/stable-diffusion.cpp/releases?per_page=5" -o "%_SD_JSON%" 2>nul
) else (
    certutil -urlcache -split -f "https://api.github.com/repos/leejet/stable-diffusion.cpp/releases?per_page=5" "%_SD_JSON%" >nul 2>&1
    certutil -urlcache -delete "https://api.github.com/repos/leejet/stable-diffusion.cpp/releases?per_page=5" >nul 2>&1
)
if not exist "%_SD_JSON%" (echo  [WARN] GitHub API unreachable. & exit /b 0)
for %%F in ("%_SD_JSON%") do set "_SD_JSON_SZ=%%~zF"
if !_SD_JSON_SZ! LSS 100 (echo  [WARN] Empty response. & del "%_SD_JSON%" 2>nul & exit /b 0)
if exist "%PYTHON_DIR%\python.exe" (
    call :WRITE_SD_FIND_SCRIPT
    "%PYTHON_DIR%\python.exe" "%TEMP_DIR%\_sd_find.py" "%_SD_JSON%" > "%TEMP_DIR%\_sd_result.txt" 2>nul
    set "_SL=0"
    for /f "usebackq tokens=*" %%L in ("%TEMP_DIR%\_sd_result.txt") do (
        set /a _SL+=1
        if !_SL!==1 set "_SD_RESOLVED_URL=%%L"
        if !_SL!==2 set "_SD_ASSET_NAME=%%L"
    )
    del "%TEMP_DIR%\_sd_find.py" "%TEMP_DIR%\_sd_result.txt" 2>nul
    if defined _SD_RESOLVED_URL if not "!_SD_RESOLVED_URL!"=="" set "_SD_RESOLVED=1"
) else (
    findstr /i "browser_download_url" "%_SD_JSON%" > "%TEMP_DIR%\_sd_grep.txt" 2>nul
    for /f "usebackq tokens=*" %%U in ("%TEMP_DIR%\_sd_grep.txt") do (
        if "!_SD_RESOLVED!"=="0" (
            set "_URAW=%%U"
            echo "!_URAW!" | findstr /i "win" >nul 2>&1
            if not errorlevel 1 (
                echo "!_URAW!" | findstr /i "\.zip" >nul 2>&1
                if not errorlevel 1 (
                    echo "!_URAW!" | findstr /i "arm rocm vulkan" >nul 2>&1
                    if errorlevel 1 (
                        for /f "tokens=2 delims=: " %%V in ("!_URAW!") do (
                            if "!_SD_RESOLVED!"=="0" (
                                set "_CLEAN=%%V"
                                set "_CLEAN=!_CLEAN:~1,-1!"
                                if defined _CLEAN (
                                    set "_SD_RESOLVED_URL=https:!_CLEAN!"
                                    set "_SD_ASSET_NAME=sd-cpp-win.zip"
                                    set "_SD_RESOLVED=1"
                                )
                            )
                        )
                    )
                )
            )
        )
    )
    del "%TEMP_DIR%\_sd_grep.txt" 2>nul
)
del "%_SD_JSON%" 2>nul
exit /b 0


:: ============================================================
:: :ENSURE_OLLAMA
:: ============================================================
:ENSURE_OLLAMA
if not exist "%OLLAMA_DIR%\ollama.exe" (echo  [FAIL] Ollama not installed. & exit /b 1)
tasklist /fi "imagename eq ollama.exe" 2>nul | findstr /i "ollama.exe" >nul 2>&1
if not errorlevel 1 (echo  [OK] Ollama running. & exit /b 0)
echo  [*] Starting Ollama ...
start /b "" "%OLLAMA_DIR%\ollama.exe" serve >nul 2>&1
<nul set /p "=  Waiting: "
for /l %%I in (1,1,20) do (
    timeout /t 1 /nobreak >nul
    <nul set /p "=."
    if "%DL_TOOL%"=="curl" (
        curl.exe -s -o nul --connect-timeout 2 "http://127.0.0.1:11434/api/tags" >nul 2>&1
        if not errorlevel 1 (echo  Ready! & exit /b 0)
    ) else (
        if %%I==10 (echo  OK & exit /b 0)
    )
)
echo.
echo  [WARN] Ollama slow to start.
exit /b 0


:: ============================================================
:: :LIST_PARTIALS_DETAIL
:: ============================================================
:SET_OLLAMA_BUSY
set "_OL_BUSY_FILE=%TEMP_DIR%\ollama_busy.lock"
> "!_OL_BUSY_FILE!" echo %DATE% %TIME% ^| %~1
exit /b 0


:CLEAR_OLLAMA_BUSY
set "_OL_BUSY_FILE=%TEMP_DIR%\ollama_busy.lock"
if exist "!_OL_BUSY_FILE!" del "!_OL_BUSY_FILE!" 2>nul
exit /b 0


:: ============================================================
:: :LIST_PARTIALS_DETAIL
:: ============================================================
:LIST_PARTIALS_DETAIL
set "_PD=0"
for /r "%BASE_DIR%" %%F in (*.partial) do (
    set "_PD=1"
    call :GET_FILESIZE_SAFE "%%F" _PDSZ
    for %%N in ("%%F") do echo   %%~nxN  !_PDSZ!
)
if "!_PD!"=="0" echo   None.
exit /b 0


:: ============================================================
:: :LIST_CHAT_FILES_DISPLAY
:: ============================================================
:LIST_CHAT_FILES_DISPLAY
set "_CFD=0"
if not exist "%MODELS_DIR%\chat" (echo   None. & exit /b 0)
for %%F in ("%MODELS_DIR%\chat\*") do (
    if exist "%%F" (
        set "_CFDN=%%~nxF"
        set "_CFD_SKIP=0"
        echo "!_CFDN!" | findstr /i "\.partial" >nul 2>&1
        if not errorlevel 1 set "_CFD_SKIP=1"
        if "!_CFD_SKIP!"=="0" (
            set /a _CFD+=1
            call :GET_FILESIZE_SAFE "%%~F" _CFDSZ
            echo   !_CFD!. !_CFDN!  ^(!_CFDSZ!^)
        )
    )
)
if !_CFD!==0 echo   None.
exit /b 0


:: ============================================================
:: :LIST_IMAGE_MODELS_DISPLAY
:: ============================================================
:LIST_IMAGE_MODELS_DISPLAY
set "_IMD=0"
if not exist "%MODELS_DIR%\image" (echo   None. & exit /b 0)
for %%F in ("%MODELS_DIR%\image\*") do (
    if exist "%%F" (
        set "_IMGN=%%~nxF"
        set "_IMD_SKIP=0"
        echo "!_IMGN!" | findstr /i "\.partial" >nul 2>&1
        if not errorlevel 1 set "_IMD_SKIP=1"
        if "!_IMD_SKIP!"=="0" (
            set /a _IMD+=1
            call :GET_FILESIZE_SAFE "%%~F" _IMDSZ
            echo   !_IMD!. !_IMGN!  ^(!_IMDSZ!^)
        )
    )
)
if !_IMD!==0 echo   None.
exit /b 0


:: ============================================================
:: :LIST_VIDEO_MODELS_DISPLAY
:: ============================================================
:LIST_VIDEO_MODELS_DISPLAY
set "_VMD=0"
if not exist "%MODELS_DIR%\video" (echo   None. & exit /b 0)
for %%F in ("%MODELS_DIR%\video\*") do (
    if exist "%%F" (
        set "_VDN=%%~nxF"
        set "_VMD_SKIP=0"
        echo "!_VDN!" | findstr /i "\.partial" >nul 2>&1
        if not errorlevel 1 set "_VMD_SKIP=1"
        if "!_VMD_SKIP!"=="0" (
            set /a _VMD+=1
            if exist "%%F\NUL" (
                echo   !_VMD!. !_VDN!  ^(folder^)
            ) else (
                call :GET_FILESIZE_SAFE "%%~F" _VMDSZ
                echo   !_VMD!. !_VDN!  ^(!_VMDSZ!^)
            )
        )
    )
)
if !_VMD!==0 echo   None.
exit /b 0


:: ============================================================
:: :BUILD_IMAGE_LIST
:: ============================================================
:BUILD_IMAGE_LIST
set "_IMG_TOTAL=0"
if not exist "%MODELS_DIR%\image" exit /b 0
for %%F in ("%MODELS_DIR%\image\*") do (
    if exist "%%F" (
        set "_IMGN=%%~nxF"
        set "_BI_SKIP=0"
        echo "!_IMGN!" | findstr /i "\.partial" >nul 2>&1
        if not errorlevel 1 set "_BI_SKIP=1"
        if "!_BI_SKIP!"=="0" (
            set /a _IMG_TOTAL+=1
            call :GET_FILESIZE_SAFE "%%~F" _IBSZ
            echo   [!_IMG_TOTAL!] !_IMGN!  ^(!_IBSZ!^)
            set "_IMGF!_IMG_TOTAL!=%%~F"
        )
    )
)
exit /b 0


:: ============================================================
:: :GET_FILESIZE_SAFE
::
:: FIX: Batch set /a is 32-bit signed, max ~2.1 GB.
::      For files larger than 2 GB we delegate to PowerShell
::      (64-bit math) or perform string-based division that
::      avoids overflow entirely.
::
:: Strategy:
::   1. Try PowerShell (fast, exact, no overflow).
::   2. Fallback: string-trim the last 9 chars to get GB
::      (divides by 10^9 via string, not arithmetic).
:: ============================================================
:GET_FILESIZE_SAFE
set "_GFS_FILE=%~1"
set "_GFS_VAR=%~2"
if not exist "%_GFS_FILE%" (set "%_GFS_VAR%=0 B" & exit /b 0)

for %%F in ("%_GFS_FILE%") do set "_GFS_RAW=%%~zF"
if not defined _GFS_RAW (set "%_GFS_VAR%=? B" & exit /b 0)
if "!_GFS_RAW!"=="0" (set "%_GFS_VAR%=0 B" & exit /b 0)

:: Delegate to PowerShell for accurate large-file formatting.
:: PowerShell uses 64-bit doubles so handles files up to ~8 EB.
if "%SYS_TOOL%"=="powershell" (
    set "_GFS_PS_OUT="
    for /f "usebackq tokens=*" %%R in (`"!PS_EXE!" -NoProfile -Command ^
        "$b=[long]'!_GFS_RAW!'; if($b -ge 1GB){'{0:F2} GB' -f ($b/1GB)} elseif($b -ge 1MB){'{0:F1} MB' -f ($b/1MB)} elseif($b -ge 1KB){'{0} KB' -f [int]($b/1KB)} else{\"$b B\"}" 2^>nul`) do (
        set "_GFS_PS_OUT=%%R"
    )
    if defined _GFS_PS_OUT (
        set "%_GFS_VAR%=!_GFS_PS_OUT!"
        exit /b 0
    )
)

:: String-based GB fallback (no arithmetic, no overflow).
:: Count digits in _GFS_RAW. If >= 10 digits the file is >= 1 GB.
set "_GFS_LEN=0"
set "_GFS_TMP=!_GFS_RAW!"
:_GFS_COUNTLOOP
if "!_GFS_TMP!"=="" goto :_GFS_COUNTDONE
set "_GFS_TMP=!_GFS_TMP:~1!"
set /a _GFS_LEN+=1
goto :_GFS_COUNTLOOP
:_GFS_COUNTDONE

if !_GFS_LEN! GEQ 10 (
    :: Strip last 9 digits = divide by 10^9 ~ GB
    set /a "_GFS_TRIM=_GFS_LEN - 9"
    call set "_GFS_GB_INT=%%_GFS_RAW:~0,!_GFS_TRIM!%%"
    :: First decimal: digit at position _GFS_TRIM
    call set "_GFS_GB_DEC=%%_GFS_RAW:~!_GFS_TRIM!,1%%"
    set "%_GFS_VAR%=!_GFS_GB_INT!.!_GFS_GB_DEC! GB"
    exit /b 0
)

:: File is under 1 GB - safe for 32-bit set /a
set /a "_GFS_KB=_GFS_RAW / 1024" 2>nul
set /a "_GFS_MB=_GFS_KB / 1024" 2>nul
if !_GFS_MB! GEQ 1 (
    set /a "_GFS_MBR=(_GFS_KB * 10 / 1024) %% 10"
    set "%_GFS_VAR%=!_GFS_MB!.!_GFS_MBR! MB"
) else if !_GFS_KB! GEQ 1 (
    set "%_GFS_VAR%=!_GFS_KB! KB"
) else (
    set "%_GFS_VAR%=!_GFS_RAW! B"
)
exit /b 0


:: ============================================================
:: :GET_DIRSIZE_SAFE
::
:: FIX: Accumulating sizes with set /a overflows for large dirs.
::      We delegate to PowerShell. Fallback uses per-file
::      string-trim accumulation to stay in 32-bit range by
::      only summing MB values.
:: ============================================================
:GET_DIRSIZE_SAFE
set "_GDS_DIR=%~1"
set "_GDS_VAR=%~2"
if not exist "%_GDS_DIR%" (set "%_GDS_VAR%=0 MB" & exit /b 0)

:: PowerShell path - accurate and overflow-safe
if "%SYS_TOOL%"=="powershell" (
    set "_GDS_PS_OUT="
    for /f "usebackq tokens=*" %%R in (`"!PS_EXE!" -NoProfile -Command ^
        "$b=(Get-ChildItem -Path '!_GDS_DIR!' -Recurse -File -ErrorAction SilentlyContinue ^| Measure-Object -Property Length -Sum).Sum; if(!$b){$b=0}; if($b -ge 1GB){'{0:F2} GB' -f ($b/1GB)} elseif($b -ge 1MB){'{0:F0} MB' -f ($b/1MB)} else{'{0} KB' -f [int]($b/1KB)}" 2^>nul`) do (
        set "_GDS_PS_OUT=%%R"
    )
    if defined _GDS_PS_OUT (
        set "%_GDS_VAR%=!_GDS_PS_OUT!"
        exit /b 0
    )
)

:: Fallback: sum sizes in MB to avoid 32-bit overflow.
:: Each file is divided to MB first before accumulating.
set "_GDS_MB=0"
for /r "%_GDS_DIR%" %%F in (*) do (
    for %%S in ("%%F") do (
        set /a "_GDS_MB+=%%~zS / 1048576" 2>nul
    )
)
if !_GDS_MB! GEQ 1024 (
    set /a "_GDS_GB=_GDS_MB / 1024"
    set /a "_GDS_GBR=(_GDS_MB * 10 / 1024) %% 10"
    set "%_GDS_VAR%=!_GDS_GB!.!_GDS_GBR! GB"
) else (
    set "%_GDS_VAR%=!_GDS_MB! MB"
)
exit /b 0


:: ============================================================
:: :GET_RAM_GB
:: ============================================================
:GET_RAM_GB
set "_RAM_GB=0"
if "%SYS_TOOL%"=="powershell" (
    for /f "usebackq tokens=*" %%R in (`"!PS_EXE!" -NoProfile -Command "[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)" 2^>nul`) do (
        for /f "delims=0123456789" %%X in ("%%Rx") do (
            if "%%X"=="x" set "_RAM_GB=%%R"
        )
    )
)
if "!_RAM_GB!"=="0" (
    for /f "usebackq tokens=2 delims==" %%A in (`wmic computersystem get TotalPhysicalMemory /value 2^>nul ^| findstr "="`) do (
        set "_RAM_RAW=%%A"
        set "_RAM_T=!_RAM_RAW: =!"
        if defined _RAM_T (
            set "_RAM_GB=!_RAM_T:~0,-9!"
            if "!_RAM_GB!"=="" set "_RAM_GB=0"
        )
    )
)
if "!_RAM_GB!"==""  set "_RAM_GB=8"
if "!_RAM_GB!"=="0" set "_RAM_GB=8"
for /f "delims=0123456789" %%X in ("!_RAM_GB!x") do if not "%%X"=="x" set "_RAM_GB=8"
exit /b 0


:: ============================================================
:: :GET_VRAM
::
:: FIX: Added non-NVIDIA fallback via PowerShell CIM
::      Win32_VideoController.AdapterRAM for AMD / Intel.
::      nvidia-smi is still tried first for accuracy.
:: ============================================================
:GET_VRAM
set "_VRAM_GB=0"
set "_GPU_NAME=None"

:: Policy-safe path: use only nvidia-smi when available, otherwise keep defaults.
:: This avoids fragile command parsing on restricted cmd environments.
where nvidia-smi.exe >nul 2>&1
if errorlevel 1 exit /b 0

for /f "tokens=1,2,3,4 delims=," %%A in ('nvidia-smi --query-gpu^=name,memory.total --format^=csv,noheader,nounits 2^>nul') do (
    set "_GPU_NAME=%%A"
    set "_VRAM_RAW=%%B"
    set "_VRAM_RAW=!_VRAM_RAW: =!"
    set /a "_VRAM_TMP=!_VRAM_RAW! / 1024" 2>nul
    if not errorlevel 1 (
        if !_VRAM_TMP! GTR 0 set "_VRAM_GB=!_VRAM_TMP!"
    )
)
exit /b 0


:: ============================================================
:: :GET_CPU_NAME
:: ============================================================
:GET_CPU_NAME
set "_CPU_NAME=Unknown"
if "%SYS_TOOL%"=="powershell" (
    for /f "usebackq delims=" %%C in (`"!PS_EXE!" -NoProfile -Command "(Get-CimInstance Win32_Processor ^| Select-Object -First 1).Name.Trim()" 2^>nul`) do (
        if not "%%C"=="" set "_CPU_NAME=%%C"
    )
)
if "!_CPU_NAME!"=="Unknown" (
    for /f "usebackq tokens=2 delims==" %%C in (`wmic cpu get Name /value 2^>nul ^| findstr "="`) do set "_CPU_NAME=%%C"
)
exit /b 0


:: ============================================================
:: :GET_GPU_NAME_WMI
:: ============================================================
:GET_GPU_NAME_WMI
set "_GPU_DISPLAY=Unknown"
if "%SYS_TOOL%"=="powershell" (
    for /f "usebackq delims=" %%G in (`"!PS_EXE!" -NoProfile -Command "(Get-CimInstance Win32_VideoController ^| Where-Object {$_.Name -notmatch 'Remote^|Mirror^|Basic Display'} ^| Select-Object -ExpandProperty Name) -join ', '" 2^>nul`) do (
        if not "%%G"=="" set "_GPU_DISPLAY=%%G"
    )
)
if "!_GPU_DISPLAY!"=="Unknown" (
    for /f "usebackq tokens=2 delims==" %%G in (`wmic path win32_videocontroller get Name /value 2^>nul ^| findstr "="`) do (
        if "!_GPU_DISPLAY!"=="Unknown" (set "_GPU_DISPLAY=%%G") else (set "_GPU_DISPLAY=!_GPU_DISPLAY!, %%G")
    )
)
exit /b 0


:: ============================================================
:: :WRITE_HF_SCRIPTS_V2
:: ============================================================
:WRITE_HF_SCRIPTS_V2
call :_WRITE_BROWSE
call :_WRITE_SELECT
call :_WRITE_DOWNLOAD
exit /b 0

:_WRITE_BROWSE
set "_OUT=%TEMP_DIR%\_hf_browse.py"
if exist "%_OUT%" del "%_OUT%" 2>nul
>"%_OUT%"  echo import sys, json
>>"%_OUT%" echo repo_raw = sys.argv[1]
>>"%_OUT%" echo _t = sys.argv[2] if len(sys.argv) ^> 2 else 'NONE'
>>"%_OUT%" echo token = None if _t == 'NONE' else _t
>>"%_OUT%" echo out_file = sys.argv[3]
>>"%_OUT%" echo repo = repo_raw.strip()
>>"%_OUT%" echo if 'huggingface.co/' in repo:
>>"%_OUT%" echo     repo = repo.split('huggingface.co/')[-1].strip('/')
>>"%_OUT%" echo parts = repo.split('/')
>>"%_OUT%" echo repo_id = (parts[0] + '/' + parts[1]) if len(parts) ^>= 2 else repo
>>"%_OUT%" echo print('  Repo: ' + repo_id)
>>"%_OUT%" echo try:
>>"%_OUT%" echo     from huggingface_hub import HfApi
>>"%_OUT%" echo     api = HfApi()
>>"%_OUT%" echo     info = api.repo_info(repo_id, token=token, files_metadata=True)
>>"%_OUT%" echo     exts = ('.gguf', '.safetensors', '.bin', '.pt')
>>"%_OUT%" echo     files = [{'name': s.rfilename, 'size': s.size or 0} for s in info.siblings if s.rfilename.endswith(exts)]
>>"%_OUT%" echo     if not files:
>>"%_OUT%" echo         print('  No model files found.')
>>"%_OUT%" echo         sys.exit(1)
>>"%_OUT%" echo     print('  Found ' + str(len(files)) + ' file(s):')
>>"%_OUT%" echo     print()
>>"%_OUT%" echo     for i, f in enumerate(files, 1):
>>"%_OUT%" echo         sz = f['size']
>>"%_OUT%" echo         s2 = (str(round(sz/1073741824,2))+' GB') if sz^>=1073741824 else (str(round(sz/1048576))+' MB') if sz^>=1048576 else (str(round(sz/1024))+' KB')
>>"%_OUT%" echo         print('   [' + str(i) + '] ' + f['name'] + '  (' + s2 + ')')
>>"%_OUT%" echo     print()
>>"%_OUT%" echo     print('   [' + str(len(files)+1) + '] Cancel')
>>"%_OUT%" echo     json.dump({'repo_id': repo_id, 'files': files}, open(out_file, 'w'))
>>"%_OUT%" echo except Exception as e:
>>"%_OUT%" echo     print('  ERROR: ' + str(e))
>>"%_OUT%" echo     sys.exit(1)
exit /b 0

:_WRITE_SELECT
set "_OUT=%TEMP_DIR%\_hf_sel.py"
if exist "%_OUT%" del "%_OUT%" 2>nul
>"%_OUT%"  echo import sys, json
>>"%_OUT%" echo data = json.load(open(sys.argv[1]))
>>"%_OUT%" echo try:
>>"%_OUT%" echo     idx = int(sys.argv[2]) - 1
>>"%_OUT%" echo except (ValueError, IndexError):
>>"%_OUT%" echo     print('  Invalid selection.')
>>"%_OUT%" echo     sys.exit(1)
>>"%_OUT%" echo if idx ^< 0 or idx ^>= len(data['files']):
>>"%_OUT%" echo     print('  Out of range.')
>>"%_OUT%" echo     sys.exit(1)
>>"%_OUT%" echo f = data['files'][idx]
>>"%_OUT%" echo sz = f['size']
>>"%_OUT%" echo s2 = (str(round(sz/1073741824,2))+' GB') if sz^>=1073741824 else (str(round(sz/1048576,1))+' MB') if sz^>=1048576 else (str(round(sz/1024))+' KB')
>>"%_OUT%" echo print('  File: ' + f['name'])
>>"%_OUT%" echo print('  Size: ' + s2)
>>"%_OUT%" echo json.dump({'repo_id': data['repo_id'], 'filename': f['name'], 'size': sz, 'size_str': s2}, open(sys.argv[3], 'w'))
exit /b 0

:_WRITE_DOWNLOAD
set "_OUT=%TEMP_DIR%\_hf_dl.py"
if exist "%_OUT%" del "%_OUT%" 2>nul
>"%_OUT%"  echo import sys, json, os, time, warnings
>>"%_OUT%" echo warnings.filterwarnings('ignore')
>>"%_OUT%" echo import requests
>>"%_OUT%" echo from huggingface_hub import hf_hub_url
>>"%_OUT%" echo sel       = json.load(open(sys.argv[1]))
>>"%_OUT%" echo _t        = sys.argv[2]
>>"%_OUT%" echo token     = None if _t == 'NONE' else _t
>>"%_OUT%" echo out_r     = sys.argv[3]
>>"%_OUT%" echo chat_dir  = sys.argv[4]
>>"%_OUT%" echo image_dir = sys.argv[5]
>>"%_OUT%" echo max_r     = int(sys.argv[6])
>>"%_OUT%" echo delay     = int(sys.argv[7])
>>"%_OUT%" echo fname      = sel['filename']
>>"%_OUT%" echo repo       = sel['repo_id']
>>"%_OUT%" echo total_size = sel.get('size', 0)
>>"%_OUT%" echo dest = chat_dir if fname.endswith(('.gguf','.bin','.pt')) else image_dir
>>"%_OUT%" echo os.makedirs(dest, exist_ok=True)
>>"%_OUT%" echo def fmt_size(b):
>>"%_OUT%" echo     b=int(b)
>>"%_OUT%" echo     if b^>=1073741824: return str(round(b/1073741824,2))+' GB'
>>"%_OUT%" echo     if b^>=1048576: return str(round(b/1048576,1))+' MB'
>>"%_OUT%" echo     if b^>=1024: return str(round(b/1024))+' KB'
>>"%_OUT%" echo     return str(b)+' B'
>>"%_OUT%" echo def fmt_time(s):
>>"%_OUT%" echo     s=int(s)
>>"%_OUT%" echo     if s^>3600: return str(s//3600)+'h '+str((s%%3600)//60)+'m'
>>"%_OUT%" echo     if s^>60: return str(s//60)+'m '+str(s%%60)+'s'
>>"%_OUT%" echo     return str(s)+'s'
>>"%_OUT%" echo url = hf_hub_url(repo_id=repo, filename=fname)
>>"%_OUT%" echo final_path = os.path.join(dest, os.path.basename(fname))
>>"%_OUT%" echo partial_path = final_path + '.partial'
>>"%_OUT%" echo print('  File:  ' + fname)
>>"%_OUT%" echo print('  From:  ' + repo)
>>"%_OUT%" echo print('  To:    ' + final_path)
>>"%_OUT%" echo if total_size ^> 0: print('  Size:  ' + fmt_size(total_size))
>>"%_OUT%" echo print()
>>"%_OUT%" echo if os.path.exists(final_path):
>>"%_OUT%" echo     if total_size ^> 0 and os.path.getsize(final_path) ^>= total_size:
>>"%_OUT%" echo         print('  [SKIP] Already complete.')
>>"%_OUT%" echo         sel['local_path'] = final_path
>>"%_OUT%" echo         json.dump(sel, open(out_r,'w'))
>>"%_OUT%" echo         sys.exit(0)
>>"%_OUT%" echo resume_from = os.path.getsize(partial_path) if os.path.exists(partial_path) else 0
>>"%_OUT%" echo if resume_from ^> 0: print('  Resume: ' + fmt_size(resume_from) + ' done')
>>"%_OUT%" echo print()
>>"%_OUT%" echo headers = {}
>>"%_OUT%" echo if token: headers['Authorization'] = 'Bearer ' + token
>>"%_OUT%" echo def download_with_resume():
>>"%_OUT%" echo     global resume_from
>>"%_OUT%" echo     h = dict(headers)
>>"%_OUT%" echo     if resume_from ^> 0: h['Range'] = 'bytes='+str(resume_from)+'-'
>>"%_OUT%" echo     r = requests.get(url, headers=h, stream=True, timeout=30, allow_redirects=True)
>>"%_OUT%" echo     if resume_from ^> 0 and r.status_code == 200:
>>"%_OUT%" echo         print('  [WARN] Server no resume, restarting.')
>>"%_OUT%" echo         resume_from = 0
>>"%_OUT%" echo         if os.path.exists(partial_path): os.remove(partial_path)
>>"%_OUT%" echo     r.raise_for_status()
>>"%_OUT%" echo     cl = r.headers.get('content-length')
>>"%_OUT%" echo     file_total = (resume_from + int(cl)) if cl else (total_size or 0)
>>"%_OUT%" echo     downloaded = resume_from
>>"%_OUT%" echo     start_time = time.time()
>>"%_OUT%" echo     last_print = 0
>>"%_OUT%" echo     with open(partial_path, 'ab' if resume_from^>0 else 'wb') as f:
>>"%_OUT%" echo         for chunk in r.iter_content(chunk_size=1048576):
>>"%_OUT%" echo             if not chunk: continue
>>"%_OUT%" echo             f.write(chunk)
>>"%_OUT%" echo             downloaded += len(chunk)
>>"%_OUT%" echo             now = time.time()
>>"%_OUT%" echo             if now - last_print ^>= 0.5:
>>"%_OUT%" echo                 last_print = now
>>"%_OUT%" echo                 elapsed = now - start_time
>>"%_OUT%" echo                 speed = (downloaded-resume_from)/elapsed if elapsed^>0 else 0
>>"%_OUT%" echo                 pct = downloaded*100.0/file_total if file_total^>0 else 0
>>"%_OUT%" echo                 bar = '#'*int(30*pct/100) + '-'*(30-int(30*pct/100))
>>"%_OUT%" echo                 eta = ' ETA '+fmt_time((file_total-downloaded)/speed) if speed^>0 and file_total^>0 else ''
>>"%_OUT%" echo                 sys.stdout.write('\r  ['+bar+'] '+str(round(pct,1))+'%% '+fmt_size(downloaded)+'/'+fmt_size(file_total)+' @ '+fmt_size(int(speed))+'/s'+eta+'   ')
>>"%_OUT%" echo                 sys.stdout.flush()
>>"%_OUT%" echo     print()
>>"%_OUT%" echo     if os.path.exists(final_path): os.remove(final_path)
>>"%_OUT%" echo     os.rename(partial_path, final_path)
>>"%_OUT%" echo     return final_path
>>"%_OUT%" echo for attempt in range(1, max_r+1):
>>"%_OUT%" echo     try:
>>"%_OUT%" echo         if attempt ^> 1:
>>"%_OUT%" echo             print('  Attempt '+str(attempt)+'/'+str(max_r))
>>"%_OUT%" echo             if os.path.exists(partial_path): resume_from = os.path.getsize(partial_path)
>>"%_OUT%" echo         path = download_with_resume()
>>"%_OUT%" echo         print('  [OK] '+path)
>>"%_OUT%" echo         sel['local_path'] = path
>>"%_OUT%" echo         json.dump(sel, open(out_r,'w'))
>>"%_OUT%" echo         sys.exit(0)
>>"%_OUT%" echo     except KeyboardInterrupt:
>>"%_OUT%" echo         print('\n  [PAUSED] '+partial_path)
>>"%_OUT%" echo         sys.exit(2)
>>"%_OUT%" echo     except requests.exceptions.HTTPError as e:
>>"%_OUT%" echo         sc = e.response.status_code if e.response is not None else 0
>>"%_OUT%" echo         print('\n  [WARN] HTTP '+str(sc))
>>"%_OUT%" echo         if sc in (401,403,404,410):
>>"%_OUT%" echo             print('  [FAIL] Permanent error.')
>>"%_OUT%" echo             sys.exit(1)
>>"%_OUT%" echo         if attempt ^< max_r:
>>"%_OUT%" echo             print('  Retry in '+str(delay)+'s ...')
>>"%_OUT%" echo             time.sleep(delay)
>>"%_OUT%" echo         else:
>>"%_OUT%" echo             print('  [FAIL] Partial: '+partial_path)
>>"%_OUT%" echo             sys.exit(1)
>>"%_OUT%" echo     except Exception as e:
>>"%_OUT%" echo         print('\n  [WARN] '+str(e))
>>"%_OUT%" echo         if attempt ^< max_r:
>>"%_OUT%" echo             print('  Retry in '+str(delay)+'s ...')
>>"%_OUT%" echo             time.sleep(delay)
>>"%_OUT%" echo         else:
>>"%_OUT%" echo             print('  [FAIL] Partial: '+partial_path)
>>"%_OUT%" echo             sys.exit(1)
exit /b 0


:: ============================================================
:: :WRITE_SD_FIND_SCRIPT
:: ============================================================
:WRITE_SD_FIND_SCRIPT
set "_OUT=%TEMP_DIR%\_sd_find.py"
if exist "%_OUT%" del "%_OUT%" 2>nul
>"%_OUT%"  echo import json, sys, os
>>"%_OUT%" echo prefer_cuda = os.environ.get('SD_PREFER_CUDA','0')=='1'
>>"%_OUT%" echo patterns = ['cuda12-x64','cuda11-x64','cuda-x64','win-avx2-x64','win-avx-x64','win-x64'] if prefer_cuda else ['win-avx2-x64','win-avx-x64','win-x64','cuda12-x64','cuda11-x64','cuda-x64']
>>"%_OUT%" echo try:
>>"%_OUT%" echo     releases = json.load(open(sys.argv[1]))
>>"%_OUT%" echo     for rel in releases:
>>"%_OUT%" echo         if rel.get('draft') or rel.get('prerelease'): continue
>>"%_OUT%" echo         for pat in patterns:
>>"%_OUT%" echo             for asset in rel.get('assets',[]):
>>"%_OUT%" echo                 name = asset['name'].lower()
>>"%_OUT%" echo                 if not name.endswith('.zip'): continue
>>"%_OUT%" echo                 if pat in name and ('win' in name or 'cuda' in name):
>>"%_OUT%" echo                     if any(x in name for x in ('arm','rocm','vulkan')): continue
>>"%_OUT%" echo                     print(asset['browser_download_url'])
>>"%_OUT%" echo                     print(asset['name'])
>>"%_OUT%" echo                     sys.exit(0)
>>"%_OUT%" echo     sys.exit(1)
>>"%_OUT%" echo except Exception as e:
>>"%_OUT%" echo     print('ERROR:',e,file=sys.stderr)
>>"%_OUT%" echo     sys.exit(1)
exit /b 0