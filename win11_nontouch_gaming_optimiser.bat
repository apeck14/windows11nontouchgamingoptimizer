@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "REGISTRY_BACKUP_DONE="
set "OPTIMIZER_FULL_RUN="
pushd "%SCRIPT_DIR%" >nul 2>&1

title Windows 11 Non-Touch Gaming Optimizer - by Matt Hurley
color 0A

for /f %%A in ('"prompt $E & for %%B in (1) do rem"') do set "ESC=%%A"
if defined ESC (
    set "CLR_TITLE=%ESC%[95;1m"
    set "CLR_SUBTITLE=%ESC%[96m"
    set "CLR_MENU=%ESC%[93;1m"
    set "CLR_SUCCESS=%ESC%[92m"
    set "CLR_WARNING=%ESC%[93m"
    set "CLR_RESET=%ESC%[0m"
) else (
    set "CLR_TITLE="
    set "CLR_SUBTITLE="
    set "CLR_MENU="
    set "CLR_SUCCESS="
    set "CLR_WARNING="
    set "CLR_RESET="
)

:: ---------------------------------------------------------------------------
:: Windows 11 Non-Touch Gaming Optimizer
:: by Matt Hurley
::
:: Menu-driven utility focused on:
::   - Reviewing apps and disabling optional touch/pen components
::   - Maximizing gaming FPS and responsiveness  
::   - Optimizing network latency and throughput
::   - Reducing RAM/CPU usage from background services
::   - Changes are logged; undo is partial and cannot recover deleted files
:: ---------------------------------------------------------------------------

set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

set "OPERATIONS_SCRIPT=%SCRIPT_DIR%optimizer-operations.ps1"
if not exist "%SCRIPT_DIR%optimizer-cleanup.ps1" (
    echo [!] Missing optimizer-cleanup.ps1. Extract the complete repository ZIP.
    exit /b 1
)
if not exist "%OPERATIONS_SCRIPT%" (
    echo [!] Missing optimizer-operations.ps1. Download and extract the complete repository ZIP.
    exit /b 1
)

set "RELAUNCHED="
if /I "%~1"=="-Elevated" (
    set "RELAUNCHED=1"
    shift
)

call :EnsureAdmin
set "ADMIN_STATUS=%errorlevel%"
if "%ADMIN_STATUS%"=="2" exit /b 0
if not "%ADMIN_STATUS%"=="0" exit /b %ADMIN_STATUS%

for /f %%I in ('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "STAMP=%%I"
set "LOG_DIR=%SCRIPT_DIR%logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "LOG_FILE=%LOG_DIR%\nontouch_gaming_optimizer_%STAMP%.log"
set "OPTIMIZER_RESULTS=%LOG_DIR%\operation_results_%STAMP%.jsonl"
"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%OPERATIONS_SCRIPT%" -Mode Initialize
if errorlevel 1 (
    echo [!] Cannot write the operation journal. No optimizations will be attempted.
    exit /b 1
)
call :Log "=== Windows 11 Non-Touch Gaming Optimizer started ==="

call :DetectOS
call :DetectHardware
call :DetectChassisType
if errorlevel 1 exit /b 1
call :DetectRAM
call :DetectStorageType
call :Log "Initialization complete - entering menu"

:Menu
cls
call :Banner
if errorlevel 1 (
    echo [!] Error displaying banner
    pause
    exit /b 1
)
call :Log "Awaiting menu selection"
echo    %CLR_MENU%[1 / F]%CLR_RESET% FULL OPTIMIZATION - All gaming tweaks in one run
echo    %CLR_MENU%[3]%CLR_RESET% Set up protection and create restore point
echo    %CLR_MENU%[R]%CLR_RESET% Open Windows System Restore
echo    %CLR_MENU%[4]%CLR_RESET% Review installed apps (no uninstall)
echo    %CLR_MENU%[5]%CLR_RESET% Disable touchscreen, pen, and ink features
echo    %CLR_MENU%[6]%CLR_RESET% Gaming settings - includes memory integrity OFF
echo    %CLR_MENU%[7]%CLR_RESET% Optimize services, telemetry, and indexing
echo    %CLR_MENU%[8]%CLR_RESET% Network optimizations (apply/revert)
echo    %CLR_MENU%[9]%CLR_RESET% Disable animations and visual effects
echo    %CLR_MENU%[A]%CLR_RESET% Optimize startup programs and services
echo    %CLR_MENU%[B]%CLR_RESET% Recycle user temporary files older than 30 days
echo    %CLR_MENU%[C]%CLR_RESET% Advanced: GPU and storage optimizations
echo    %CLR_MENU%[D]%CLR_RESET% Advanced: Audio latency reduction
echo    %CLR_MENU%[E]%CLR_RESET% Optional: Disable Xbox services (breaks Game Bar)
echo    %CLR_MENU%[J]%CLR_RESET% Deeper cleanup - select files to recycle
echo    %CLR_MENU%[G]%CLR_RESET% Check display refresh and GPU preferences
echo    %CLR_MENU%[M]%CLR_RESET% Memory integrity on/off
echo    %CLR_MENU%[H]%CLR_RESET% Help / README
echo    %CLR_MENU%[P]%CLR_RESET% View operation results
echo    %CLR_MENU%[V]%CLR_RESET% Verify optimizations status
echo    %CLR_MENU%[U]%CLR_RESET% UNDO - Partial rollback of key settings
echo    %CLR_MENU%[0]%CLR_RESET% Exit
set "choice="
set /p "choice=> "
set "choice=%choice:~0,1%"
set "OPTIMIZER_ACTION_ID=%RANDOM%-%RANDOM%"
if /I "%choice%"=="P" set "OPTIMIZER_ACTION_ID="
if /I "%choice%"=="1" (call :FullOptimization & call :PauseReturn & goto Menu)
if /I "%choice%"=="F" (call :FullOptimization & call :PauseReturn & goto Menu)
if /I "%choice%"=="3" (call :CreateRestorePoint & call :PauseReturn & goto Menu)
if /I "%choice%"=="R" (start "" "%SystemRoot%\System32\rstrui.exe" & goto Menu)
if /I "%choice%"=="4" (call :Debloat & call :PauseReturn & goto Menu)
if /I "%choice%"=="5" (call :DisableTouchFeatures & call :PauseReturn & goto Menu)
if /I "%choice%"=="6" (call :GamingTweaksMenu & call :PauseReturn & goto Menu)
if /I "%choice%"=="7" (call :OptimizeServices & call :PauseReturn & goto Menu)
if /I "%choice%"=="8" (call :NetworkMenu & goto Menu)
if /I "%choice%"=="9" (call :DisableAnimations & call :PauseReturn & goto Menu)
if /I "%choice%"=="A" (call :OptimizeStartup & call :PauseReturn & goto Menu)
if /I "%choice%"=="B" (call :FreeDiskSpace & call :PauseReturn & goto Menu)
if /I "%choice%"=="C" (call :AdvancedGPUStorage & call :PauseReturn & goto Menu)
if /I "%choice%"=="D" (call :OptimizeAudio & call :PauseReturn & goto Menu)
if /I "%choice%"=="E" (call :DisableXboxServices & call :PauseReturn & goto Menu)
if /I "%choice%"=="J" (call :RunOperation Cleanup Deep & call :PauseReturn & goto Menu)
if /I "%choice%"=="G" (call :RunOperation Graphics Check & call :PauseReturn & goto Menu)
if /I "%choice%"=="M" (call :MemoryIntegrityMenu & call :PauseReturn & goto Menu)
if /I "%choice%"=="H" (call :ShowHelp & call :PauseReturn & goto Menu)
if /I "%choice%"=="P" (call :ShowChangesSummary & call :PauseReturn & goto Menu)
if /I "%choice%"=="V" (call :VerifyOptimizations & call :PauseReturn & goto Menu)
if /I "%choice%"=="U" (call :UndoChanges & call :PauseReturn & goto Menu)
if "%choice%"=="0" goto End
echo [!] Unknown selection. Please try again.
call :PauseReturn
goto Menu

:FullOptimization
call :Log "Running FULL optimization sequence"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%FULL GAMING OPTIMIZATION%CLR_RESET%
echo   This will apply ALL gaming optimizations for maximum performance.
echo   %CLR_WARNING%Estimated time: 5-10 minutes%CLR_RESET%
call :WarnIfOnBattery
if errorlevel 1 exit /b 1
call :PrepareOptimization
if errorlevel 1 exit /b 1
set "OPTIMIZER_FULL_RUN=1"
echo [*] Step 1/13: Disabling touch/pen components...
call :DisableTouchFeatures
echo [*] Step 2/13: Applying gaming tweaks...
call :ApplyGamingTweaks
echo [*] Step 3/13: Optimizing services and telemetry...
call :OptimizeServices
echo [*] Step 4/13: Applying network optimizations...
call :ApplyNetworkTweaks
echo [*] Step 5/13: Optimizing visual effects...
call :DisableAnimations
echo [*] Step 6/13: Optimizing startup...
call :OptimizeStartup
echo [*] Step 7/13: Recycling old temporary files...
call :FreeDiskSpace
echo [*] Step 8/13: GPU and storage optimizations...
set "AUTO_ADVANCED_CONFIRM=1"
call :AdvancedGPUStorage
set "AUTO_ADVANCED_CONFIRM="
echo [*] Step 9/13: Audio latency reduction...
call :OptimizeAudio
echo [*] Step 10/13: Finalizing memory optimizations...
call :OptimizeMemory
echo [*] Step 11/13: Optimizing page file...
call :OptimizePageFile
echo [*] Step 12/13: Disabling CPU core parking...
call :DisableCoreParking
echo [*] Step 13/13: Tuning storage-specific settings...
call :OptimizeStorageByType
set "OPTIMIZER_FULL_RUN="
call :Log "Full optimization attempts finished; review operation results"
call :ShowChangesSummary
exit /b %errorlevel%

:PrepareOptimization
call :CreateRestorePoint
if not errorlevel 1 exit /b 0
echo [!] A new restore point is unavailable. You can still apply the tweaks.
choice /c YN /n /d N /t 30 /m "Continue without a new restore point? (Y/N, default=N): "
if not "%errorlevel%"=="1" (
    call :Log "Optimization cancelled after restore point failure"
    exit /b 1
)
call :Log "User chose to optimize without a new restore point"
exit /b 0

:CreateRestorePoint
call :Log "Creating system restore point"
if not defined OPTIMIZER_FULL_RUN echo [*] Checking restore point prerequisites...
call :EnsureShadowServices
if errorlevel 1 (
    echo [!] Required System Restore services are unavailable. No optimizations applied.
    call :Log "Restore point prerequisites missing"
    exit /b 1
)
if not defined OPTIMIZER_FULL_RUN echo [*] Enabling System Protection and creating a verified restore point...
call :RunOperation Restore Create
if errorlevel 1 (
    echo [!] No new restore point was verified. Check the log for the exact error.
    echo     Open SystemPropertiesProtection.exe to review protection and disk space.
    call :Log "Restore point setup or creation failed"
    exit /b 1
)
echo [+] Restore point created and verified. Use menu R to open System Restore.
exit /b 0

:ApplyNetworkTweaksSafe
call :Log "Applying SAFE network tweaks"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%APPLYING SAFE NETWORK OPTIMIZATIONS%CLR_RESET%
if not defined OPTIMIZER_FULL_RUN echo [*] Applying low-risk tweaks for gaming (keeps Windows TCP defaults)...
REM Restore normal receive-window growth, including after older Full runs.
call :RunOperation Native netsh interface tcp set global autotuninglevel=normal
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpNoDelay /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpAckFrequency /t REG_DWORD /d 1 /f

REM Delivery Optimization (P2P updates) off for latency + bandwidth stability
call :RunOperation Service sc stop DoSvc
call :RunOperation Service sc config DoSvc start= disabled
for %%T in ("\Microsoft\Windows\Delivery Optimization\Maintenance" "\Microsoft\Windows\Delivery Optimization\Download") do (
    call :RunOperation Task schtasks /Change /TN "%%~T" /Disable
)
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DODownloadMode /t REG_DWORD /d 0 /f

call :Log "Safe network changes attempted; see results"
exit /b 0

:Debloat
call :RunOperation Apps Review
exit /b %errorlevel%

:DisableTouchFeatures
call :Log "Disabling touch/pen stack"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%DISABLING TOUCH/PEN FEATURES%CLR_RESET%
if not defined OPTIMIZER_FULL_RUN echo [*] Disabling touchscreen, pen, handwriting, and touch keyboard components...
for %%S in (TabletInputService TextInputManagementService TouchInput WTabletServiceCon WTabletServicePen PenService TabletInputHost) do (
    call :RunOperation Service sc stop %%S
    call :RunOperation Service sc config %%S start= disabled
)
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v EnableTabletModeAutoSwitch /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell" /v TabletMode /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell" /v TabletModeAutoSwitch /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\PenWorkspace" /v PenWorkspaceButtonDesiredVisibility /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\TabletTip\1.7" /v EnableAutocorrection /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\TabletTip\1.7" /v EnableTextPrediction /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\TabletTip\1.7" /v EnableSpellchecking /t REG_DWORD /d 0 /f
call :RunOperation Feature Disable "TabletPC-OC"
call :RunOperation Feature Disable "InkAndHandwritingServices"
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Wisp\Pen\SysEventParameters" /v FlicksEnabled /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Wisp\Touch" /v TouchGate /t REG_DWORD /d 0 /f
call :Log "Touch/pen changes attempted; see results"
exit /b 0

:MemoryIntegrityMenu
choice /c 123 /n /m "Memory integrity: [1] Off (less protection) [2] On [3] Back: "
if errorlevel 3 exit /b 0
if errorlevel 2 (
    call :RunOperation Integrity On
) else (
    call :RunOperation Integrity Off
)
exit /b %errorlevel%

:GamingTweaksMenu
call :WarnIfOnBattery
if errorlevel 1 exit /b 1
call :ApplyGamingTweaks
exit /b %errorlevel%

:ApplyGamingTweaks
call :BackupRegistryKeys
call :RunOperation Windowed Enable
call :RunOperation Integrity Off
call :RunOperation Graphics Check
call :Log "Applying gaming tweaks"
if not defined OPTIMIZER_FULL_RUN echo %CLR_TITLE%  ^|                 GAMING PERFORMANCE TWEAKS                         ^|%CLR_RESET%
if not defined DVR_PREF_SET (
    if not defined OPTIMIZER_FULL_RUN echo [*] Disable Game DVR recording for gaming performance; Game Bar stays installed.
    choice /c YN /n /d Y /t 5 /m "Disable Game DVR recording? (Y/N, default=Y): "
    if "!errorlevel!"=="1" (
        set "DISABLE_DVR=1"
    ) else (
        set "DISABLE_DVR=0"
    )
    set "DVR_PREF_SET=1"
)
call :Log "Gaming tweaks: power plan"
if not defined OPTIMIZER_FULL_RUN echo [*] Applying the performance power setting supported by this hardware...
call :RunOperation Plan Ultimate

if not defined OPTIMIZER_FULL_RUN echo [*] Tuning Game Mode, GPU scheduling, and visual effects...
call :RunOperation Registry reg add "HKCU\Software\Microsoft\GameBar" /v AllowAutoGameMode /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\GameBar" /v AutoGameModeEnabled /t REG_DWORD /d 1 /f
if "%DISABLE_DVR%"=="1" (
    call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v HistoricalCaptureEnabled /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 0 /f
    call :Log "Gaming tweaks: Game DVR disable requested; see operation results"
) else (
    call :Log "Gaming tweaks: existing Game DVR settings preserved"
)

call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /t REG_DWORD /d 2 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Desktop" /v MenuShowDelay /t REG_SZ /d 0 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Desktop" /v WaitToKillAppTimeout /t REG_SZ /d 2000 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Desktop" /v HungAppTimeout /t REG_SZ /d 1000 /f
call :Log "Gaming tweaks: scheduler priorities"

if not defined OPTIMIZER_FULL_RUN echo [*] Prioritizing multimedia + game scheduler values...
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 10 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d "High" /f

call :Log "Gaming tweaks: latency + input"

if not defined OPTIMIZER_FULL_RUN echo [*] Optimizing for low latency and high throughput...
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Latency Sensitive" /t REG_SZ /d "True" /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "NoLazyMode" /t REG_DWORD /d 1 /f

if not defined OPTIMIZER_FULL_RUN echo [*] Optimizing mouse and keyboard input for gaming...
call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseSpeed /t REG_SZ /d 0 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseThreshold1 /t REG_SZ /d 0 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseThreshold2 /t REG_SZ /d 0 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseSensitivity /t REG_SZ /d 10 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\mouclass\Parameters" /v MouseDataQueueSize /t REG_DWORD /d 20 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters" /v KeyboardDataQueueSize /t REG_DWORD /d 20 /f

if not defined OPTIMIZER_FULL_RUN echo [*] Enabling full Game Mode stack...
call :RunOperation Registry reg add "HKCU\Software\Microsoft\GameBar" /v UseNexusForGameBarEnabled /t REG_DWORD /d 0 /f

if not defined OPTIMIZER_FULL_RUN echo [*] Restoring automatic Windows timer selection...
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" /v GlobalTimerResolutionRequests /t REG_DWORD /d 1 /f
REM Remove legacy debug timer overrides instead of forcing platform timers.
for %%B in (useplatformclock disabledynamictick) do (
    call :RunOperation Native bcdedit /deletevalue %%B
)

if not defined OPTIMIZER_FULL_RUN echo [*] Prioritizing foreground apps (games) over background tasks...
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 38 /f
call :Log "Gaming tweaks: telemetry disable"

call :RunOperation Service sc stop "DiagTrack"
call :RunOperation Service sc config "DiagTrack" start= disabled

call :Log "Gaming changes attempted; see results"
if /I "%GPU_VENDOR%"=="NVIDIA" (
    if not defined OPTIMIZER_FULL_RUN echo     %CLR_WARNING%Tip:%CLR_RESET% Open NVIDIA Control Panel ^> Low Latency Mode = Ultra
)
if /I "%GPU_VENDOR%"=="AMD Radeon" (
    if not defined OPTIMIZER_FULL_RUN echo     %CLR_WARNING%Tip:%CLR_RESET% Open AMD Software ^> Anti-Lag = Enabled
)
if /I "%GPU_VENDOR%"=="Intel Arc" (
    if not defined OPTIMIZER_FULL_RUN echo     %CLR_WARNING%Tip:%CLR_RESET% Open Intel Graphics Command Center for game optimizations
)
exit /b 0

:OptimizeServices
call :Log "Optimizing services/indexing"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%OPTIMIZING SERVICES AND TELEMETRY%CLR_RESET%
if not defined OPTIMIZER_FULL_RUN echo [*] Reducing background services, indexing, telemetry, and tips...
for %%S in (SysMain WSearch DiagTrack dmwappushservice RetailDemo RemoteRegistry MapsBroker TrkWks) do (
    call :RunOperation Service sc stop %%S
    call :RunOperation Service sc config %%S start= disabled
)
call :RunOperation Service sc config WSearch start= demand
for %%T in (
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
    "\Microsoft\Windows\Feedback\Siuf\DmClient"
    "\Microsoft\Windows\Autochk\Proxy"
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector"
) do (
    call :RunOperation Task schtasks /Change /TN "%%~T" /Disable
)
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v CortanaConsent /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v BingSearchEnabled /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338388Enabled /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowSyncProviderNotifications /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" /v DisabledByGroupPolicy /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableSoftLanding /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsSpotlightFeatures /t REG_DWORD /d 1 /f
call :Log "Service/telemetry attempts finished; see results"
exit /b 0

:NetworkMenu
:NetworkOptions
cls
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%NETWORK OPTIMIZATION MENU%CLR_RESET%
echo    %CLR_MENU%[1]%CLR_RESET% Apply SAFE network tweaks
echo    %CLR_MENU%[2]%CLR_RESET% Apply AGGRESSIVE tweaks - may affect VPN/throughput
echo    %CLR_MENU%[3]%CLR_RESET% Revert network tweaks to defaults
echo    %CLR_MENU%[4]%CLR_RESET% Return to main menu
choice /c 1234 /n /m "Select an option: "
set "netopt=%errorlevel%"
if "%netopt%"=="4" exit /b 0
if "%netopt%"=="1" call :ApplyNetworkTweaksSafe
if "%netopt%"=="2" call :ApplyNetworkTweaks
if "%netopt%"=="3" call :RevertNetworkTweaks
call :PauseReturn
goto NetworkOptions

:ApplyNetworkTweaks
call :Log "Applying network tweaks"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%APPLYING NETWORK OPTIMIZATIONS%CLR_RESET%
if not defined OPTIMIZER_FULL_RUN echo [*] Applying safe TCP/IP and bandwidth tweaks for gaming...
call :RunOperation Native netsh interface tcp set global autotuninglevel=normal
call :RunOperation Native netsh interface tcp set global ecncapability=disabled
call :RunOperation Native netsh interface tcp set global rss=enabled
call :RunOperation Native netsh interface tcp set global rsc=disabled
call :RunOperation Native netsh interface tcp set global chimney=disabled
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpTimedWaitDelay /t REG_DWORD /d 30 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /t REG_DWORD /d 65534 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v Tcp1323Opts /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpNoDelay /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpAckFrequency /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v DefaultTTL /t REG_DWORD /d 64 /f

call :RunOperation Service sc stop DoSvc
call :RunOperation Service sc config DoSvc start= disabled
call :RunOperation Task schtasks /Change /TN "\Microsoft\Windows\Delivery Optimization\Maintenance" /Disable
call :RunOperation Task schtasks /Change /TN "\Microsoft\Windows\Delivery Optimization\Download" /Disable
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DODownloadMode /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DOMaxUploadBandwidth /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DOMaxUploadPercentage /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" /v TcpAckFrequency /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" /v TCPNoDelay /t REG_DWORD /d 1 /f
call :Log "Network changes attempted; see results"
exit /b 0

:RevertNetworkTweaks
call :Log "Reverting network tweaks"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%REVERTING NETWORK TWEAKS%CLR_RESET%
if not defined OPTIMIZER_FULL_RUN echo [*] Reverting network-related tweaks to Windows defaults...
call :RunOperation Native netsh interface tcp set global autotuninglevel=normal
call :RunOperation Native netsh interface tcp set global ecncapability=default
call :RunOperation Native netsh interface tcp set global rss=enabled
call :RunOperation Native netsh interface tcp set global rsc=default
call :RunOperation Native netsh interface tcp set global chimney=default
for %%V in (TcpTimedWaitDelay MaxUserPort Tcp1323Opts TcpNoDelay TcpAckFrequency DefaultTTL) do (
    call :RunOperation Registry reg delete "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v %%V /f
)
call :RunOperation Service sc config DoSvc start= delayed-auto
call :RunOperation Service sc start DoSvc
for %%T in ("\Microsoft\Windows\Delivery Optimization\Maintenance" "\Microsoft\Windows\Delivery Optimization\Download") do (
    call :RunOperation Task schtasks /Change /TN "%%~T" /Enable
)
for %%V in (DODownloadMode DOMaxUploadBandwidth DOMaxUploadPercentage) do (
    call :RunOperation Registry reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v %%V /f
)
call :RunOperation Registry reg delete "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" /v TcpAckFrequency /f
call :RunOperation Registry reg delete "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" /v TCPNoDelay /f
call :Log "Network reset attempted; see results"
exit /b 0

:DisableAnimations
call :Log "Animations menu"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%VISUAL EFFECTS OPTIMIZATION%CLR_RESET%
echo   Your system has capable hardware. Choose your preference:
echo   %CLR_MENU%[1]%CLR_RESET% BALANCED (Recommended) - Keep smooth animations, disable extras
echo       Keeps: Window animations, taskbar effects, transparency
echo       Disables: Aero Peek, thumbnail previews, listview effects
echo   %CLR_MENU%[2]%CLR_RESET% MINIMAL - Disable most animations for max FPS
echo       Disables most visual effects for raw performance
echo   %CLR_MENU%[3]%CLR_RESET% SKIP - Keep current Windows settings
choice /c 123 /n /d 1 /t 15 /m "Select option (auto-selects Balanced in 15s): "
set "ANIM_CHOICE=%errorlevel%"

if "%ANIM_CHOICE%"=="3" (
    if not defined OPTIMIZER_FULL_RUN echo [*] Skipping visual effects changes.
    call :Log "User skipped animation changes"
    exit /b 0
)

if "%ANIM_CHOICE%"=="1" (
    if not defined OPTIMIZER_FULL_RUN echo [*] Applying BALANCED visual settings...
    REM Keep animations but disable extras
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 1 /f
    call :RunOperation Registry reg add "HKCU\Control Panel\Desktop\WindowMetrics" /v MinAnimate /t REG_SZ /d 1 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 3 /f
    REM Disable non-essential extras
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\DWM" /v EnableAeroPeek /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\DWM" /v AlwaysHibernateThumbnails /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewAlphaSelect /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewShadow /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v DisallowShaking /t REG_DWORD /d 1 /f
    REM Keep transparency and smooth scrolling
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 1 /f
    call :Log "Balanced visual settings attempted; see results"
    if not defined OPTIMIZER_FULL_RUN echo [*] Balanced visuals requested. Review the verified operation results.
) else (
    if not defined OPTIMIZER_FULL_RUN echo [*] Applying MINIMAL visual settings for max FPS...
    call :RunOperation Registry reg add "HKCU\Control Panel\Desktop\WindowMetrics" /v MinAnimate /t REG_SZ /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 3 /f
    call :RunOperation Registry reg add "HKCU\Control Panel\Desktop" /v UserPreferencesMask /t REG_BINARY /d 9012038010000000 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\DWM" /v EnableAeroPeek /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\DWM" /v AlwaysHibernateThumbnails /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewAlphaSelect /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewShadow /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v DisallowShaking /t REG_DWORD /d 1 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarDa /t REG_DWORD /d 0 /f
    call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f
    call :Log "Minimal visual settings attempted; see results"
    if not defined OPTIMIZER_FULL_RUN echo [*] Minimal visuals requested. Review the verified operation results.
    echo     Restart Explorer for immediate effect: taskkill /f /im explorer.exe ^& start explorer.exe
)
exit /b 0

:OptimizeStartup
call :Log "Optimizing startup"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%OPTIMIZING STARTUP PROGRAMS%CLR_RESET%
if not defined OPTIMIZER_FULL_RUN echo [*] Reducing startup delays and disabling unnecessary startup items...
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /t REG_DWORD /d 0 /f
call :RunOperation Task schtasks /Change /TN "\Microsoft\Windows\Application Experience\StartupAppTask" /Disable
call :RunOperation Task schtasks /Change /TN "\Microsoft\Windows\Application Experience\PcaPatchDbTask" /Disable
call :RunOperation Task schtasks /Change /TN "\Microsoft\Windows\Maps\MapsUpdateTask" /Disable
call :RunOperation Task schtasks /Change /TN "\Microsoft\Windows\Maps\MapsToastTask" /Disable
call :RunOperation Task schtasks /Change /TN "\Microsoft\Windows\CloudExperienceHost\CreateObjectTask" /Disable
call :RunOperation Feature Disable "Printing-XPSServices-Features"
call :RunOperation Feature Disable "WorkFolders-Client"
call :RunOperation Feature Disable "FaxServicesClientPackage"
call :Log "Startup changes attempted; see results"
exit /b 0

:FreeDiskSpace
call :Log "Recycling old user temporary files"
call :RunOperation Cleanup Safe
exit /b %errorlevel%

:OptimizeMemory
call :Log "Optimizing memory"
if not defined OPTIMIZER_FULL_RUN echo [*] Enabling memory compression and optimizing paging...
if defined RAM_GB (
    if %RAM_GB% LSS 8 (
        echo     %CLR_WARNING%[!] WARNING: Low RAM detected ^(%RAM_GB%GB^). DisablePagingExecutive may cause instability.%CLR_RESET%
        echo     %CLR_WARNING%    Consider adding more RAM for better gaming performance.%CLR_RESET%
        call :Log "Low RAM warning: %RAM_GB%GB detected - DisablePagingExecutive may cause issues"
    )
)
call :RunOperation Memory MemoryCompression 1
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v DisablePagingExecutive /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v LargeSystemCache /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v ClearPageFileAtShutdown /t REG_DWORD /d 0 /f
call :Log "Memory changes attempted; see results"
exit /b 0

:OptimizePageFile
call :Log "Enabling system-managed page file"
call :RunOperation Pagefile Auto
exit /b %errorlevel%

:DisableCoreParking
call :Log "Disabling CPU core parking"
if not defined OPTIMIZER_FULL_RUN echo [*] Disabling CPU core parking for better gaming performance...
REM Extract the actual GUID from powercfg output (format: "Power Scheme GUID: 12345678-1234-...")
for /f "tokens=4" %%G in ('powercfg /getactivescheme 2^>nul ^| findstr "GUID"') do set "SCHEME_GUID=%%G"
if not defined SCHEME_GUID (
    call :Log "Warning: Could not get active power scheme GUID, using default"
    set "SCHEME_GUID=SCHEME_CURRENT"
)
call :RunOperation Native powercfg -setacvalueindex %SCHEME_GUID% SUB_PROCESSOR CPMINCORES 100
call :RunOperation Native powercfg -setactive %SCHEME_GUID%
call :Log "Core parking change attempted; see results"
exit /b 0

:OptimizeStorageByType
call :Log "Optimizing storage by type: %STORAGE_TYPE%"
if not defined OPTIMIZER_FULL_RUN echo [*] Applying storage-specific optimizations...
if /I "%STORAGE_TYPE%"=="SSD" (
    echo     Storage: SSD detected - Optimizing for solid state
    call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v NtfsDisableLastAccessUpdate /t REG_DWORD /d 1 /f
    call :RunOperation Native fsutil behavior set DisableDeleteNotify 0
    if %RAM_GB% GEQ 8 (
        call :RunOperation Memory PageCombining 0
        call :Log "SSD operations attempted; see results for TRIM and page combining"
    ) else (
        call :Log "SSD operations attempted; see results for TRIM"
    )
) else if /I "%STORAGE_TYPE%"=="HDD" (
    echo     Storage: HDD detected - Enabling prefetch
    call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" /v EnablePrefetcher /t REG_DWORD /d 3 /f
    call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" /v EnableSuperfetch /t REG_DWORD /d 3 /f
    call :Log "HDD: Prefetch enabled, maintenance schedule preserved"
) else (
    echo     Storage: Unknown type - Applying safe defaults
    call :Log "Storage type unknown, skipping type-specific optimizations"
)
exit /b 0

:AdvancedGPUStorage
call :Log "Applying GPU and storage optimizations"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%ADVANCED GPU AND STORAGE OPTIMIZATIONS%CLR_RESET%
if not "%AUTO_ADVANCED_CONFIRM%"=="1" (
    set "advConfirm="
    set /p "advConfirm=These tweaks are aggressive and hardware-dependent. Continue? (Y/N): "
    if /I not "!advConfirm!"=="Y" (
        echo [!] Advanced GPU/storage optimizations skipped.
        call :Log "User skipped advanced GPU/storage tweaks"
        exit /b 0
    )
)
if not defined OPTIMIZER_FULL_RUN echo [*] Applying GPU optimizations (NVIDIA/AMD agnostic)...
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultD3TransitionLatencyActivelyUsed /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultD3TransitionLatencyIdleLongTime /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultD3TransitionLatencyIdleMonitorOff /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultD3TransitionLatencyIdleNoContext /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultD3TransitionLatencyIdleShortTime /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultD3TransitionLatencyIdleVeryLongTime /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultLatencyToleranceIdle0 /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultLatencyToleranceIdle1 /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultLatencyToleranceMemory /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultLatencyToleranceNoContext /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultLatencyToleranceNoContextMonitorOff /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultLatencyToleranceOther /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultLatencyToleranceTimerPeriod /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultMemoryRefreshLatencyToleranceActivelyUsed /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultMemoryRefreshLatencyToleranceMonitorOff /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v DefaultMemoryRefreshLatencyToleranceNoContext /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v Latency /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v MaxIAverageGraphicsLatencyInOneBucket /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v MiracastPerfTrackGraphicsLatency /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v MonitorLatencyTolerance /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v MonitorRefreshLatencyTolerance /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v TransitionLatency /t REG_DWORD /d 1 /f

if not defined OPTIMIZER_FULL_RUN echo [*] Optimizing storage for SSDs and gaming drives...
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v NtfsDisableLastAccessUpdate /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v NtfsDisable8dot3NameCreation /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v DontVerifyRandomDrivers /t REG_DWORD /d 1 /f
call :RunOperation Native fsutil behavior set DisableDeleteNotify 0

if not defined OPTIMIZER_FULL_RUN echo [*] Optimizing process priorities...
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing" /v "Scheduling Category" /t REG_SZ /d "High" /f

call :Log "GPU/storage changes attempted; see results"
if not defined OPTIMIZER_FULL_RUN echo     %CLR_WARNING%Note:%CLR_RESET% For NVIDIA GPUs, also set Low Latency Mode in NVIDIA Control Panel.
if not defined OPTIMIZER_FULL_RUN echo     %CLR_WARNING%Note:%CLR_RESET% For AMD GPUs, enable Anti-Lag in AMD Software.
exit /b 0

:OptimizeAudio
call :Log "Optimizing audio latency"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%AUDIO LATENCY REDUCTION%CLR_RESET%
if not defined OPTIMIZER_FULL_RUN echo [*] Reducing audio latency for gaming and streaming...
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Audio" /v "Scheduling Category" /t REG_SZ /d "High" /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Scheduling Category" /t REG_SZ /d "High" /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\AudioSrv" /v DependOnService /t REG_MULTI_SZ /d "AudioEndpointBuilder\0RpcSs" /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Audiosrv" /v Start /t REG_DWORD /d 2 /f

call :Log "Audio changes attempted; see results"
if not defined OPTIMIZER_FULL_RUN echo     %CLR_WARNING%Tip:%CLR_RESET% In Sound settings, enable Exclusive Mode for gaming headset.
exit /b 0

:DisableXboxServices
call :Log "Disabling Xbox services"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%DISABLE XBOX SERVICES%CLR_RESET%
echo   %CLR_WARNING%WARNING:%CLR_RESET% This will disable:
echo   - Xbox Game Bar (Win+G)
echo   - Xbox app and Game Pass integration
echo   - Xbox Live cloud saves
echo   - Some Xbox controller features
echo   Only proceed if you DON'T use these features!
set /p "confirm=Type YES to disable Xbox services: "
if /I not "!confirm!"=="YES" (
    echo [!] Xbox services NOT disabled (user cancelled).
    call :Log "User cancelled Xbox service disable"
    exit /b 0
)
if not defined OPTIMIZER_FULL_RUN echo [*] Disabling Xbox-related services...
call :RunOperation Service sc stop "XblAuthManager"
call :RunOperation Service sc config "XblAuthManager" start= disabled
call :RunOperation Service sc stop "XblGameSave"
call :RunOperation Service sc config "XblGameSave" start= disabled
call :RunOperation Service sc stop "XboxGipSvc"
call :RunOperation Service sc config "XboxGipSvc" start= disabled
call :RunOperation Service sc stop "XboxNetApiSvc"
call :RunOperation Service sc config "XboxNetApiSvc" start= disabled
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\xbgm" /v Start /t REG_DWORD /d 4 /f

call :Log "Xbox service changes attempted; see results"
echo     To re-enable, use the UNDO option or run:
echo     sc config XblAuthManager start= demand
echo     sc config XblGameSave start= demand
exit /b 0


:ShowHelp
echo Full optimization attempts a restore point before making changes.
echo Individual actions do not create a restore point automatically. File cleanup only recycles.
echo Review [P] Operation results for failures and restart requirements.
echo [V] checks selected live settings; it is not a performance score.
echo Spotify is preserved. Xbox services change only if you choose [E].
echo [U] is a partial reset, not a restoration of your original settings.
echo Deleted files and removed apps cannot be recovered with [U].
echo Full documentation: %SCRIPT_DIR%README.md
echo Log files: %LOG_DIR%
exit /b 0

:UndoChanges
set "MOUSE_RESTORED="
echo [!] Partial rollback only. Original service states were not saved.
echo     Remote Registry and Routing/Remote Access will not be enabled.
choice /c YN /n /d N /t 15 /m "Apply partial rollback defaults? (Y/N, default=N): "
if not "%errorlevel%"=="1" exit /b 1
call :Log "Undo routine requested"
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%REVERTING CHANGES%CLR_RESET%
if not defined OPTIMIZER_FULL_RUN echo [*] Attempting to revert services, registry settings, and network changes...
for %%S in (TabletInputService TextInputManagementService TouchInput WTabletServiceCon WTabletServicePen PenService TabletInputHost SysMain WSearch DiagTrack dmwappushservice RetailDemo MapsBroker TrkWks DoSvc XblAuthManager XblGameSave XboxGipSvc XboxNetApiSvc) do (
    call :RunOperation Service sc config %%S start= demand
    call :RunOperation Service sc start %%S
)
if exist "%LOG_DIR%\mouse_settings_backup.reg" (
    call :RunOperation Native reg import "%LOG_DIR%\mouse_settings_backup.reg"
    if not errorlevel 1 (
        set "MOUSE_RESTORED=1"
        call :Log "Mouse settings import command completed; see operation results"
    ) else (
        call :Log "Mouse settings import failed"
    )
)
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 3 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v AllowTelemetry /t REG_DWORD /d 3 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v CortanaConsent /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v BingSearchEnabled /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 0 /f
for %%K in (EnableAutocorrection EnableTextPrediction EnableSpellchecking) do (
    call :RunOperation Registry reg delete "HKCU\Software\Microsoft\TabletTip\1.7" /v %%K /f
)
call :RunOperation Registry reg add "HKCU\Software\Microsoft\GameBar" /v AllowAutoGameMode /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR" /v value /t REG_DWORD /d 1 /f
call :RunOperation Registry reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /f
call :RunOperation Registry reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v HistoricalCaptureEnabled /f
call :RunOperation Registry reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v GameDVR_Enabled /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 2 /f
call :RunOperation Native bcdedit /deletevalue useplatformclock
call :RunOperation Native bcdedit /deletevalue disabledynamictick
call :RevertNetworkTweaks
call :RunOperation Feature Enable "TabletPC-OC"
call :RunOperation Feature Enable "InkAndHandwritingServices"
call :RunOperation Registry reg add "HKCU\Control Panel\Desktop\WindowMetrics" /v MinAnimate /t REG_SZ /d 1 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 0 /f
if not defined MOUSE_RESTORED (
    call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseSpeed /t REG_SZ /d 1 /f
    call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseThreshold1 /t REG_SZ /d 6 /f
    call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseThreshold2 /t REG_SZ /d 10 /f
)
call :Log "Undo routine completed"
if not defined OPTIMIZER_FULL_RUN echo [*] Partial rollback attempted. Check the log; this is not a complete restore.
echo     Check %LOG_FILE% for details. %CLR_WARNING%Restart recommended.%CLR_RESET%
exit /b 0

:DetectOS
set "OS_CAPTION=Windows"
set "OS_MAJOR=10"
for /f "tokens=4 delims=[] " %%I in ('ver') do (
    for /f "tokens=1 delims=." %%J in ("%%I") do set "OS_MAJOR=%%J"
)
for /f "tokens=2 delims=:" %%I in ('systeminfo ^| findstr /B /C:"OS Name"') do (
    for /f "tokens=* delims= " %%J in ("%%I") do set "OS_CAPTION=%%J"
)
call :Log "Detected OS: %OS_CAPTION% (major %OS_MAJOR%)"
if %OS_MAJOR% GEQ 10 (
    echo Detected: %OS_CAPTION% - Compatible
) else (
    echo [!] Warning: %OS_CAPTION% detected. This optimizer targets Windows 10/11.
    call :Log "Warning - unsupported OS version"
)
exit /b 0

:DetectHardware
set "GPU_VENDOR=Unknown"
set "CPU_VENDOR=Unknown"
set "GPU_RAW="
set "CPU_RAW="

REM === GPU Detection - PowerShell, prefer discrete GPU ===
REM First try to find NVIDIA
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1 -ExpandProperty Name"`) do (
    set "GPU_RAW=%%I"
)
REM If no NVIDIA, try AMD
if not defined GPU_RAW (
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'AMD|Radeon' } | Select-Object -First 1 -ExpandProperty Name"`) do (
        set "GPU_RAW=%%I"
    )
)
REM If no AMD, try Intel Arc
if not defined GPU_RAW (
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'Arc' } | Select-Object -First 1 -ExpandProperty Name"`) do (
        set "GPU_RAW=%%I"
    )
)
REM Fallback to any non-virtual Intel GPU
if not defined GPU_RAW (
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'Intel' -and $_.Name -notmatch 'Virtual|Remote|Vivi|Sharing' } | Select-Object -First 1 -ExpandProperty Name"`) do (
        set "GPU_RAW=%%I"
    )
)
if defined GPU_RAW (
    echo !GPU_RAW! | findstr /I "NVIDIA GeForce RTX GTX" >nul && set "GPU_VENDOR=NVIDIA"
    echo !GPU_RAW! | findstr /I "AMD Radeon" >nul && set "GPU_VENDOR=AMD Radeon"
    echo !GPU_RAW! | findstr /I "Arc" >nul && set "GPU_VENDOR=Intel Arc"
    if "!GPU_VENDOR!"=="Unknown" (
        echo !GPU_RAW! | findstr /I "Intel" >nul && set "GPU_VENDOR=Intel Graphics"
    )
    if "!GPU_VENDOR!"=="Unknown" set "GPU_VENDOR=!GPU_RAW!"
    call :Log "GPU detected raw: !GPU_RAW!"
)

REM === CPU Detection - PowerShell ===
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1).Name"`) do (
    set "CPU_RAW=%%I"
)
if defined CPU_RAW (
    echo !CPU_RAW! | findstr /I "Intel" >nul && set "CPU_VENDOR=Intel"
    echo !CPU_RAW! | findstr /I "AMD Ryzen" >nul && set "CPU_VENDOR=AMD Ryzen"
    echo !CPU_RAW! | findstr /I "AMD" >nul && if "!CPU_VENDOR!"=="Unknown" set "CPU_VENDOR=AMD"
    if "!CPU_VENDOR!"=="Unknown" set "CPU_VENDOR=!CPU_RAW!"
    call :Log "CPU detected raw: !CPU_RAW!"
)
call :Log "Hardware detected: GPU=%GPU_VENDOR%, CPU=%CPU_VENDOR%"
exit /b 0

:EnsureShadowServices
set "ENSURE_SHADOW_ERROR="
for %%S in (VSS swprv) do (
    sc query %%S >nul 2>&1
    if errorlevel 1 (
        call :Log "Shadow copy service %%S missing or inaccessible"
        set "ENSURE_SHADOW_ERROR=1"
    ) else (
        call :RunOperation Service sc config %%S start= demand
        if errorlevel 1 set "ENSURE_SHADOW_ERROR=1"
        REM Start-Service also succeeds when the service is already running.
        call :RunOperation Service sc start %%S
        if errorlevel 1 set "ENSURE_SHADOW_ERROR=1"
    )
)
if defined ENSURE_SHADOW_ERROR (
    set "ENSURE_SHADOW_ERROR="
    exit /b 1
)
exit /b 0

:Banner
if not defined OPTIMIZER_FULL_RUN echo %CLR_TITLE%           WINDOWS 11 GAMING OPTIMIZER v2.5                      %CLR_RESET%
echo %CLR_SUBTITLE%                         by Matt Hurley%CLR_RESET%
echo   %CLR_SUCCESS%[*]%CLR_RESET% Maximize FPS ^| Reduce Latency ^| Optimize Performance
if defined GPU_VENDOR echo   %CLR_SUCCESS%[*]%CLR_RESET% Detected GPU: %GPU_VENDOR%
if defined CPU_VENDOR echo   %CLR_SUCCESS%[*]%CLR_RESET% Detected CPU: %CPU_VENDOR%
if defined RAM_GB echo   RAM: %RAM_GB% GB ^| Storage: %STORAGE_TYPE%
if "%IS_LAPTOP%"=="1" echo   %CLR_WARNING%[!]%CLR_RESET% System Type: %CHASSIS_TYPE% - Battery impact warning enabled
echo   %CLR_WARNING%[!]%CLR_RESET% Run as administrator. Changes logged to:
echo       %LOG_FILE%
echo   %CLR_SUBTITLE%[H] Help/README ^| [P] Report ^| [V] Verify ^| [U] Undo%CLR_RESET%
exit /b 0

:PauseReturn
if defined OPTIMIZER_RESULTS if not defined RESULT_SUMMARY_SHOWN call :ShowChangesSummary
pause
exit /b 0

:IsAdmin
>nul 2>&1 fltmc
if %errorlevel%==0 exit /b 0
fsutil dirty query %SystemDrive% >nul 2>&1
if %errorlevel%==0 exit /b 0
exit /b 1

:EnsureAdmin
call :IsAdmin
if %errorlevel%==0 exit /b 0
if defined RELAUNCHED (
    color 0C
    echo [!] Administrative approval denied or unavailable.
    echo     Right-click the script and choose "Run as administrator".
    pause
    exit /b 1
)
if not defined OPTIMIZER_FULL_RUN echo [*] Requesting administrator approval via UAC...
set "OPTIMIZER_SCRIPT=%~f0"
"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -Command "$p=Start-Process -FilePath $env:OPTIMIZER_SCRIPT -ArgumentList '-Elevated' -WorkingDirectory $env:SCRIPT_DIR -Verb RunAs -PassThru; exit 0" >nul 2>&1
if errorlevel 1 (
    echo [!] Automatic UAC prompt failed. Run this script as administrator.
    pause
    exit /b 1
)
if not defined OPTIMIZER_FULL_RUN echo [*] An elevated window is launching. Close this one if prompted.
timeout /t 2 /nobreak >nul
exit /b 2



:DetectChassisType
set "CHASSIS_TYPE=Unknown"
set "IS_LAPTOP=0"
set "CHASSIS_CODE="
REM PowerShell for chassis detection
for /f "usebackq delims=" %%I in (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_SystemEnclosure).ChassisTypes[0]"`) do (
    set "CHASSIS_CODE=%%I"
)
if defined CHASSIS_CODE (
    if "%CHASSIS_CODE%"=="8" set "CHASSIS_TYPE=Laptop" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="9" set "CHASSIS_TYPE=Laptop" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="10" set "CHASSIS_TYPE=Laptop" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="11" set "CHASSIS_TYPE=Laptop" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="14" set "CHASSIS_TYPE=Laptop" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="18" set "CHASSIS_TYPE=Laptop" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="21" set "CHASSIS_TYPE=Laptop" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="30" set "CHASSIS_TYPE=Tablet" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="31" set "CHASSIS_TYPE=Convertible" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="32" set "CHASSIS_TYPE=Detachable" & set "IS_LAPTOP=1"
    if "%CHASSIS_CODE%"=="3" set "CHASSIS_TYPE=Desktop"
    if "%CHASSIS_CODE%"=="4" set "CHASSIS_TYPE=Desktop"
    if "%CHASSIS_CODE%"=="5" set "CHASSIS_TYPE=Desktop"
    if "%CHASSIS_CODE%"=="6" set "CHASSIS_TYPE=Desktop"
    if "%CHASSIS_CODE%"=="7" set "CHASSIS_TYPE=Desktop"
    if "%CHASSIS_CODE%"=="15" set "CHASSIS_TYPE=Desktop"
    if "%CHASSIS_CODE%"=="16" set "CHASSIS_TYPE=Desktop"
)
call :Log "Chassis type: %CHASSIS_TYPE% (code %CHASSIS_CODE%, laptop=%IS_LAPTOP%)"
if "%IS_LAPTOP%"=="1" (
    echo %CLR_WARNING%  [!] LAPTOP DETECTED%CLR_RESET%
    echo   This optimizer applies aggressive power tweaks that may:
    echo   - Significantly reduce battery life
    echo   - Increase heat and fan noise
    echo   - Disable power-saving features
    echo   %CLR_SUCCESS%Recommended for laptops:%CLR_RESET%
    echo   - Only run while plugged in
    echo   - Skip GPU/Storage advanced tweaks [C]
    echo   - Consider creating a separate power plan for gaming
    choice /c YN /n /t 10 /d N /m "Continue with optimization on laptop? (Y/N, auto-No in 10s): "
    if not "!errorlevel!"=="1" (
        call :Log "User cancelled - laptop warning"
        echo [!] Optimization cancelled. Exiting to protect battery life.
        timeout /t 3 >nul
        exit /b 1
    )
    call :Log "User accepted laptop warning, proceeding"
)
exit /b 0

:WarnIfOnBattery
REM If this is a laptop and it is currently discharging on battery, warn before applying aggressive CPU/power tweaks.
if not "%IS_LAPTOP%"=="1" exit /b 0

set "BAT_STATUS="
for /f "usebackq delims=" %%B in (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$b=Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1; if($b){$b.BatteryStatus}else{''}"`) do set "BAT_STATUS=%%B"
if not defined BAT_STATUS exit /b 0

REM BatteryStatus: 1=Discharging, 2=AC, 3=Fully Charged (AC)
if "%BAT_STATUS%"=="1" (
    echo   %CLR_WARNING%LAPTOP ON BATTERY DETECTED%CLR_RESET%
    echo   You're running on battery power. Applying performance power settings
    echo   and core parking changes can increase drain/heat.
    echo   %CLR_WARNING%Recommendation:%CLR_RESET% Plug in AC power, then rerun.
    choice /c YN /n /t 10 /d N /m "Continue anyway? (Y/N, auto-No in 10s): "
    if not "!errorlevel!"=="1" (
        call :Log "User aborted due to on-battery warning"
        echo [!] Optimization cancelled. Plug in power and try again.
        timeout /t 3 >nul
        exit /b 1
    )
    call :Log "User continued despite on-battery warning"
)
exit /b 0

:DetectRAM
set "RAM_GB="
REM PowerShell for RAM detection
for /f "usebackq delims=" %%I in (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[int]([Math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB),0))"`) do (
    set "RAM_GB=%%I"
)
if defined RAM_GB (
    call :Log "Detected RAM: %RAM_GB% GB"
) else (
    call :Log "Warning: Could not detect RAM amount"
)
exit /b 0

:DetectStorageType
set "STORAGE_TYPE=Unknown"
REM PowerShell for storage detection
for /f "usebackq delims=" %%I in (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d = Get-PhysicalDisk | Where-Object { $_.DeviceID -eq '0' }; if ($d) { $d.MediaType } else { 'Unknown' }"`) do (
    if "%%I"=="SSD" set "STORAGE_TYPE=SSD"
    if "%%I"=="HDD" set "STORAGE_TYPE=HDD"
)
call :Log "Detected storage type: %STORAGE_TYPE%"
exit /b 0

:BackupRegistryKeys
if defined REGISTRY_BACKUP_DONE exit /b 0
call :Log "Backing up selected registry keys"
if not defined OPTIMIZER_FULL_RUN echo [*] Creating registry backup before changes...
if not exist "%LOG_DIR%\mouse_settings_backup.reg" (
    call :RunOperation Native reg export "HKCU\Control Panel\Mouse" "%LOG_DIR%\mouse_settings_backup.reg" /y
)
call :RunOperation Native reg export "HKCU\Software\Microsoft\GameBar" "%LOG_DIR%\backup_gamebar_%STAMP%.reg" /y
call :RunOperation Native reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" "%LOG_DIR%\backup_gamedvr_%STAMP%.reg" /y
call :RunOperation Native reg export "HKCU\System\GameConfigStore" "%LOG_DIR%\backup_gameconfig_%STAMP%.reg" /y
call :RunOperation Native reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "%LOG_DIR%\backup_multimedia_%STAMP%.reg" /y
call :RunOperation Native reg export "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "%LOG_DIR%\backup_priority_%STAMP%.reg" /y
call :RunOperation Native reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "%LOG_DIR%\backup_visualfx_%STAMP%.reg" /y
call :RunOperation Native reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "%LOG_DIR%\backup_telemetry_%STAMP%.reg" /y
call :Log "Registry backup attempts finished: %LOG_DIR%\backup_*_%STAMP%.reg"
set "REGISTRY_BACKUP_DONE=1"
exit /b 0

:ShowChangesSummary
set "RESULT_SUMMARY_SHOWN=1"
"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%OPERATIONS_SCRIPT%" -Mode Summary
exit /b %errorlevel%

:VerifyOptimizations
call :Log "Running verification check"
cls
if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%LIMITED CONFIGURATION CHECKS%CLR_RESET%
echo   These legacy checks cover only selected registry and service values.
echo   Use the operation results for failures, unsupported settings and restart requirements.
set "VERIFY_PASS=0"
set "VERIFY_FAIL=0"

echo   %CLR_SUBTITLE%Power Plan:%CLR_RESET%
powercfg /getactivescheme
echo     Portable/Modern Standby PCs retain their plan; see AC power mode in operation results.

echo   %CLR_SUBTITLE%Game Mode:%CLR_RESET%
reg query "HKCU\Software\Microsoft\GameBar" /v AutoGameModeEnabled 2>nul | findstr "0x1" >nul
if not errorlevel 1 (
    echo     %CLR_SUCCESS%[PASS]%CLR_RESET% Game Mode enabled
    set /a VERIFY_PASS+=1
) else (
    echo     %CLR_WARNING%[WARN]%CLR_RESET% Game Mode not enabled
    set /a VERIFY_FAIL+=1
)

echo   %CLR_SUBTITLE%GPU Scheduling:%CLR_RESET%
reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode 2>nul | findstr "0x2" >nul
if not errorlevel 1 (
    echo     %CLR_SUCCESS%[PASS]%CLR_RESET% GPU scheduling registry preference is enabled
    set /a VERIFY_PASS+=1
) else (
    echo     %CLR_WARNING%[WARN]%CLR_RESET% GPU scheduling not enabled
    set /a VERIFY_FAIL+=1
)

echo   %CLR_SUBTITLE%Telemetry:%CLR_RESET%
sc query DiagTrack | findstr "STOPPED" >nul 2>&1
if not errorlevel 1 (
    echo     %CLR_SUCCESS%[PASS]%CLR_RESET% Diagnostic tracking disabled
    set /a VERIFY_PASS+=1
) else (
    echo     %CLR_WARNING%[WARN]%CLR_RESET% Diagnostic tracking still running
    set /a VERIFY_FAIL+=1
)

echo   %CLR_SUBTITLE%Visual Effects:%CLR_RESET%
reg query "HKCU\Software\Microsoft\Windows\DWM" /v EnableAeroPeek 2>nul | findstr "0x0" >nul
if not errorlevel 1 (
    echo     %CLR_SUCCESS%[PASS]%CLR_RESET% Visual effects optimized (Aero Peek disabled)
    set /a VERIFY_PASS+=1
) else (
    echo     %CLR_WARNING%[WARN]%CLR_RESET% Visual effects not optimized
    set /a VERIFY_FAIL+=1
)

echo   %CLR_SUBTITLE%Network:%CLR_RESET%
reg query "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpNoDelay 2>nul | findstr "0x1" >nul
if not errorlevel 1 (
    echo     %CLR_SUCCESS%[PASS]%CLR_RESET% TCP optimizations applied
    set /a VERIFY_PASS+=1
) else (
    echo     %CLR_WARNING%[WARN]%CLR_RESET% Network not optimized
    for %%V in (TcpNoDelay TcpAckFrequency) do (
        for /f "tokens=*" %%R in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v %%V 2^>nul') do echo     %%R
    )
    set /a VERIFY_FAIL+=1
)

echo   %CLR_SUBTITLE%Startup:%CLR_RESET%
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec 2>nul | findstr "0x0" >nul
if not errorlevel 1 (
    echo     %CLR_SUCCESS%[PASS]%CLR_RESET% Startup delay removed
    set /a VERIFY_PASS+=1
) else (
    echo     %CLR_WARNING%[WARN]%CLR_RESET% Startup delay present
    set /a VERIFY_FAIL+=1
)

echo   %CLR_SUBTITLE%Core Parking:%CLR_RESET%
set "COREPARK_OK=0"
set "COREPARK_LINE="
for /f "tokens=*" %%L in ('powercfg -query SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 2^>nul ^| findstr /I "Current AC Power Setting Index"') do (
    set "COREPARK_LINE=%%L"
    echo %%L | findstr /I "0x00000064" >nul && set "COREPARK_OK=1"
)
if "%COREPARK_OK%"=="1" (
    echo     %CLR_SUCCESS%[PASS]%CLR_RESET% CPU core parking disabled (CPMINCORES=100)
    set /a VERIFY_PASS+=1
) else (
    echo     %CLR_WARNING%[WARN]%CLR_RESET% Core parking may still be active
    if defined COREPARK_LINE echo     Current: %COREPARK_LINE%
    set /a VERIFY_FAIL+=1
)

if not defined OPTIMIZER_FULL_RUN echo   %CLR_TITLE%LIMITED CHECK SUMMARY - NOT A PERFORMANCE SCORE%CLR_RESET%
echo   Selected checks: %CLR_SUCCESS%%VERIFY_PASS% matched%CLR_RESET%, %CLR_WARNING%%VERIFY_FAIL% need review%CLR_RESET%.
if %VERIFY_FAIL% GTR 0 (
    echo   Checks Failed: %CLR_WARNING%[%VERIFY_FAIL%/%VERIFY_TOTAL%]%CLR_RESET%
    echo   %CLR_WARNING%Recommendation:%CLR_RESET% Run option [1] FULL or [6] Gaming Tweaks
)
call :Log "Verification: %VERIFY_PASS% passed, %VERIFY_FAIL% failed"
exit /b 0

:RunOperation
set "RESULT_SUMMARY_SHOWN="
set "OPTIMIZER_OPERATION=%*"
"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%OPERATIONS_SCRIPT%"
exit /b %errorlevel%

:Log
set "MESSAGE=%~1"
>>"%LOG_FILE%" echo %DATE% %TIME% - !MESSAGE!
exit /b 0

:End
call :Log "User exited script"
echo Review %LOG_FILE% and the operation journal for confirmed results.
popd >nul 2>&1
endlocal
exit /b 0
