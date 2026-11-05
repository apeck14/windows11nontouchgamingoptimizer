@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "REGISTRY_BACKUP_DONE="
pushd "%SCRIPT_DIR%" >nul 2>&1

title Windows 11 Gaming Optimizer
color 0A

for /f %%A in ('"prompt $E & for %%B in (1) do rem"') do set "ESC=%%A"
if defined ESC (
    set "CLR_TITLE=%ESC%[95;1m"
    set "CLR_MENU=%ESC%[93;1m"
    set "CLR_SUCCESS=%ESC%[92m"
    set "CLR_WARNING=%ESC%[93m"
    set "CLR_RESET=%ESC%[0m"
) else (
    set "CLR_TITLE="
    set "CLR_MENU="
    set "CLR_SUCCESS="
    set "CLR_WARNING="
    set "CLR_RESET="
)

set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

set "OPERATIONS_SCRIPT=%SCRIPT_DIR%optimizer-operations.ps1"
for %%F in (optimizer-cleanup.ps1 optimizer-operations.ps1 optimizer-mw4.ps1 optimizer-nvidia.cs) do if not exist "%SCRIPT_DIR%%%F" (
    echo [!] Missing %%F. Extract the complete repository ZIP.
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

"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%OPERATIONS_SCRIPT%" -Mode CheckUser
if errorlevel 1 (
    pause
    exit /b 1
)

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
call :Log "=== Windows 11 Gaming Optimizer started ==="

call :DetectHardware
call :DetectChassisType
if errorlevel 1 exit /b 1
call :DetectRAM
call :DetectStorageType
call :Log "Initialization complete - entering menu"

:Menu
cls
call :Banner
call :Log "Awaiting menu selection"
echo    %CLR_MENU%[1]%CLR_RESET% Full optimization - Windows gaming tweaks
echo    %CLR_MENU%[2]%CLR_RESET% Quick cleanup - recycle old temporary files
echo    %CLR_MENU%[3]%CLR_RESET% Deep cleanup - storage review and file cleanup
echo    %CLR_MENU%[4]%CLR_RESET% MW4 / Warzone - competitive game settings
echo    %CLR_MENU%[R]%CLR_RESET% Recovery - restore points, undo, memory integrity
echo    %CLR_MENU%[P]%CLR_RESET% Results from this session
echo    %CLR_MENU%[H]%CLR_RESET% Help
echo    %CLR_MENU%[0]%CLR_RESET% Exit
set "choice="
set /p "choice=> "
set "choice=%choice:~0,1%"
set "OPTIMIZER_ACTION_ID=%RANDOM%-%RANDOM%"
if /I "%choice%"=="P" set "OPTIMIZER_ACTION_ID="
if /I "%choice%"=="1" (call :FullOptimization & call :PauseReturn & goto Menu)
if /I "%choice%"=="2" (call :FreeDiskSpace & call :PauseReturn & goto Menu)
if /I "%choice%"=="3" (call :RunOperation Cleanup Deep & call :PauseReturn & goto Menu)
if /I "%choice%"=="4" (call :RunOperation MW4 Apply & call :PauseReturn & goto Menu)
if /I "%choice%"=="R" (call :RecoveryMenu & goto Menu)
if /I "%choice%"=="H" (call :ShowHelp & call :PauseReturn & goto Menu)
if /I "%choice%"=="P" (call :ShowChangesSummary & call :PauseReturn & goto Menu)
if "%choice%"=="0" goto End
echo [!] Unknown selection. Please try again.
call :PauseReturn
goto Menu

:RecoveryMenu
echo   %CLR_TITLE%RECOVERY%CLR_RESET%
echo   [1] Create a restore point
echo   [2] Open Windows System Restore
echo   [3] Partial undo - reset selected settings
echo   [4] Memory integrity on/off
echo   [5] Restore MW4 / Warzone settings
echo   [0] Back
choice /c 123450 /n /m "Select: "
set "recovery_choice=%errorlevel%"
if "%recovery_choice%"=="1" (call :CreateRestorePoint & call :PauseReturn)
if "%recovery_choice%"=="2" start "" "%SystemRoot%\System32\rstrui.exe"
if "%recovery_choice%"=="3" (call :UndoChanges & call :PauseReturn)
if "%recovery_choice%"=="4" (call :MemoryIntegrityMenu & call :PauseReturn)
if "%recovery_choice%"=="5" (call :RunOperation MW4 Restore & call :PauseReturn)
exit /b 0

:FullOptimization
call :Log "Running FULL optimization sequence"
echo   %CLR_TITLE%FULL GAMING OPTIMIZATION%CLR_RESET%
echo   This will apply all Windows gaming optimizations.
echo   %CLR_WARNING%Estimated time: 5-10 minutes%CLR_RESET%
call :WarnIfOnBattery
if errorlevel 1 exit /b 1
call :PrepareOptimization
if errorlevel 1 exit /b 1
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
call :AdvancedGPUStorage
echo [*] Step 9/13: Audio latency reduction...
call :OptimizeAudio
echo [*] Step 10/13: Finalizing memory optimizations...
call :OptimizeMemory
echo [*] Step 11/13: Optimizing page file...
call :OptimizePageFile
echo [*] Step 12/13: Configuring CPU core parking...
call :DisableCoreParking
echo [*] Step 13/13: Tuning storage-specific settings...
call :OptimizeStorageByType
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
echo [*] Checking restore point prerequisites...
call :EnsureShadowServices
if errorlevel 1 (
    echo [!] Required System Restore services are unavailable. No optimizations applied.
    call :Log "Restore point prerequisites missing"
    exit /b 1
)
echo [*] Enabling System Protection and creating a verified restore point...
call :RunOperation Restore Create
if errorlevel 1 (
    echo [!] No new restore point was verified. Check the log for the exact error.
    echo     Open SystemPropertiesProtection.exe to review protection and disk space.
    call :Log "Restore point setup or creation failed"
    exit /b 1
)
echo [+] Restore point created and verified. Use Recovery, then System Restore, to revert.
exit /b 0

:DisableTouchFeatures
call :Log "Disabling touch/pen stack"
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

:ApplyGamingTweaks
call :BackupRegistryKeys
call :RunOperation Windowed Enable
call :RunOperation Integrity Off
call :RunOperation Graphics Check
call :Log "Applying gaming tweaks"
if not defined DVR_PREF_SET (
    choice /c YN /n /d Y /t 5 /m "Disable Game DVR recording? (Y/N, default=Y): "
    if "!errorlevel!"=="1" (
        set "DISABLE_DVR=1"
    ) else (
        set "DISABLE_DVR=0"
    )
    set "DVR_PREF_SET=1"
)
call :Log "Gaming tweaks: power plan"
call :RunOperation Plan Ultimate
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
call :RunOperation Registry reg add "HKCU\Control Panel\Desktop" /v WaitToKillAppTimeout /t REG_SZ /d 2000 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Desktop" /v HungAppTimeout /t REG_SZ /d 1000 /f
call :Log "Gaming tweaks: scheduler priorities"
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 10 /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d "High" /f

call :Log "Gaming tweaks: latency + input"
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Latency Sensitive" /t REG_SZ /d "True" /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "NoLazyMode" /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseSpeed /t REG_SZ /d 0 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseThreshold1 /t REG_SZ /d 0 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseThreshold2 /t REG_SZ /d 0 /f
call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseSensitivity /t REG_SZ /d 10 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\mouclass\Parameters" /v MouseDataQueueSize /t REG_DWORD /d 20 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters" /v KeyboardDataQueueSize /t REG_DWORD /d 20 /f
call :RunOperation Registry reg add "HKCU\Software\Microsoft\GameBar" /v UseNexusForGameBarEnabled /t REG_DWORD /d 0 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" /v GlobalTimerResolutionRequests /t REG_DWORD /d 1 /f
REM Remove legacy debug timer overrides instead of forcing platform timers.
for %%B in (useplatformclock disabledynamictick) do (
    call :RunOperation Native bcdedit /deletevalue %%B
)
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 38 /f
call :Log "Gaming changes attempted; see results"
exit /b 0

:OptimizeServices
call :Log "Optimizing services/indexing"
for %%S in (SysMain DiagTrack dmwappushservice RetailDemo RemoteRegistry MapsBroker TrkWks) do (
    call :RunOperation Service sc stop %%S
    call :RunOperation Service sc config %%S start= disabled
)
call :RunOperation Service sc stop WSearch
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

:ApplyNetworkTweaks
call :Log "Applying network tweaks"
call :RunOperation Native netsh interface tcp set global autotuninglevel=normal
call :RunOperation Native netsh interface tcp set global ecncapability=disabled
call :RunOperation Native netsh interface tcp set global rss=enabled
call :RunOperation Native netsh interface tcp set global rsc=disabled
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpTimedWaitDelay /t REG_DWORD /d 30 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /t REG_DWORD /d 65534 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v Tcp1323Opts /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpNoDelay /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpAckFrequency /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v DefaultTTL /t REG_DWORD /d 64 /f

call :RunOperation Delivery Configure
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" /v TcpAckFrequency /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" /v TCPNoDelay /t REG_DWORD /d 1 /f
call :Log "Network changes attempted; see results"
exit /b 0

:RevertNetworkTweaks
call :Log "Reverting network tweaks"
echo   %CLR_TITLE%REVERTING NETWORK TWEAKS%CLR_RESET%
echo [*] Reverting network-related tweaks to Windows defaults...
call :RunOperation Native netsh interface tcp set global autotuninglevel=normal
call :RunOperation Native netsh interface tcp set global ecncapability=default
call :RunOperation Native netsh interface tcp set global rss=enabled
call :RunOperation Native netsh interface tcp set global rsc=default
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
    call :Log "User skipped animation changes"
    exit /b 0
)

call :RunOperation Registry reg add "HKCU\Control Panel\Desktop" /v MenuShowDelay /t REG_SZ /d 0 /f

if "%ANIM_CHOICE%"=="1" (
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
) else (
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
    echo     Restart Explorer for immediate effect: taskkill /f /im explorer.exe ^& start explorer.exe
)
exit /b 0

:OptimizeStartup
call :Log "Optimizing startup"
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
call :Log "Configuring CPU core parking"
call :RunOperation Parking Configure
call :Log "Core parking change attempted; see results"
exit /b 0

:OptimizeStorageByType
call :Log "Optimizing storage by type: %STORAGE_TYPE%"
if /I "%STORAGE_TYPE%"=="SSD" (
    echo     Storage: SSD detected - Optimizing for solid state
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
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v NtfsDisableLastAccessUpdate /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v NtfsDisable8dot3NameCreation /t REG_DWORD /d 1 /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v DontVerifyRandomDrivers /t REG_DWORD /d 1 /f
call :RunOperation Native fsutil behavior set DisableDeleteNotify 0
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing" /v "Scheduling Category" /t REG_SZ /d "High" /f

call :Log "GPU/storage changes attempted; see results"
exit /b 0

:OptimizeAudio
call :Log "Optimizing audio latency"
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Audio" /v "Scheduling Category" /t REG_SZ /d "High" /f
call :RunOperation Registry reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Scheduling Category" /t REG_SZ /d "High" /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\AudioSrv" /v DependOnService /t REG_MULTI_SZ /d "AudioEndpointBuilder\0RpcSs" /f
call :RunOperation Registry reg add "HKLM\SYSTEM\CurrentControlSet\Services\Audiosrv" /v Start /t REG_DWORD /d 2 /f

call :Log "Audio changes attempted; see results"
exit /b 0

:ShowHelp
echo Full optimization includes gaming, network, visual, startup, and quick cleanup changes.
echo Quick cleanup recycles old temporary files. Deep cleanup reviews storage and more files.
echo Full creates a restore point first. Recovery contains restore and partial undo options.
echo Full disables memory integrity; re-enable it in Recovery if needed.
echo Apps stay installed. Recycled files occupy space until you empty the Recycle Bin.
echo Results show failures and restart requirements. Partial undo is not a full restore.
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
echo   %CLR_TITLE%REVERTING CHANGES%CLR_RESET%
echo [*] Attempting to revert services, registry settings, and network changes...
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
if not defined MOUSE_RESTORED (
    call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseSpeed /t REG_SZ /d 1 /f
    call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseThreshold1 /t REG_SZ /d 6 /f
    call :RunOperation Registry reg add "HKCU\Control Panel\Mouse" /v MouseThreshold2 /t REG_SZ /d 10 /f
)
call :Log "Undo routine completed"
echo [*] Partial rollback attempted. Check the log; this is not a complete restore.
echo     Check %LOG_FILE% for details. %CLR_WARNING%Restart recommended.%CLR_RESET%
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
echo %CLR_TITLE%           WINDOWS 11 GAMING OPTIMIZER                      %CLR_RESET%
echo   %CLR_SUCCESS%[*]%CLR_RESET% Maximize FPS ^| Reduce Latency ^| Optimize Performance
if defined GPU_VENDOR echo   %CLR_SUCCESS%[*]%CLR_RESET% Detected GPU: %GPU_VENDOR%
if defined CPU_VENDOR echo   %CLR_SUCCESS%[*]%CLR_RESET% Detected CPU: %CPU_VENDOR%
if defined RAM_GB echo   RAM: %RAM_GB% GB ^| Storage: %STORAGE_TYPE%
if "%IS_LAPTOP%"=="1" echo   %CLR_WARNING%[!]%CLR_RESET% System Type: %CHASSIS_TYPE% - Battery impact warning enabled
echo   %CLR_WARNING%[!]%CLR_RESET% Run as administrator. Changes logged to:
echo       %LOG_FILE%
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
echo [*] Requesting administrator approval via UAC...
set "OPTIMIZER_SCRIPT=%~f0"
"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -Command "$p=Start-Process -FilePath $env:OPTIMIZER_SCRIPT -ArgumentList '-Elevated' -WorkingDirectory $env:SCRIPT_DIR -Verb RunAs -PassThru; exit 0" >nul 2>&1
if errorlevel 1 (
    echo [!] Automatic UAC prompt failed. Run this script as administrator.
    pause
    exit /b 1
)
echo [*] An elevated window is launching. Close this one if prompted.
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
for /f "usebackq delims=" %%I in (`""%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -Command ". $env:OPERATIONS_SCRIPT -Mode StorageType""`) do (
    if "%%I"=="SSD" set "STORAGE_TYPE=SSD"
    if "%%I"=="HDD" set "STORAGE_TYPE=HDD"
)
call :Log "Detected storage type: %STORAGE_TYPE%"
exit /b 0

:BackupRegistryKeys
if defined REGISTRY_BACKUP_DONE exit /b 0
call :Log "Backing up selected registry keys"
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
