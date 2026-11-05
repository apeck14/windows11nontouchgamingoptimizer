param(
    [ValidateSet('Operation', 'Summary', 'Initialize', 'CheckUser', 'StorageType')][string]$Mode = 'Operation',
    [switch]$NoRun
)

# Shared result handling for the batch UI. Dot-source with -NoRun for tests.
# No expression evaluation: command arguments are tokenized and passed to a
# small allowlist of native programs. Every result states its verification level.
$ErrorActionPreference = 'Stop'

function Get-CurrentUserSid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Get-DesktopUserSids {
    $session = (Get-Process -Id $PID).SessionId
    Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$session" -ErrorAction Stop | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -ne 0) { throw 'Could not identify the desktop user.' }
        $owner.Sid
    } | Sort-Object -Unique
}

function Assert-UserContext {
    $users = @(Get-DesktopUserSids)
    if ($users.Count -ne 1 -or $users[0] -ne (Get-CurrentUserSid)) {
        throw 'Run the optimizer from the gaming user desktop using that same account for administrator approval. No changes applied.'
    }
}

function Get-SystemStorageType {
    $disks = @(Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop | Get-Disk -ErrorAction Stop)
    if ($disks.Count -ne 1) { return 'Unknown' }
    $disk = $disks[0]
    $matches = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object {
        ($disk.UniqueId -and $disk.UniqueId.Trim() -and $_.UniqueId -and $disk.UniqueId.Trim() -eq $_.UniqueId.Trim()) -or
        ($disk.SerialNumber -and $disk.SerialNumber.Trim() -and $_.SerialNumber -and $disk.SerialNumber.Trim() -eq $_.SerialNumber.Trim())
    })
    if ($matches.Count -eq 1 -and [string]$matches[0].MediaType -in @('SSD','HDD')) { return [string]$matches[0].MediaType }
    return 'Unknown'
}

function Test-ManagedCoreParking {
    $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
    if (-not $cpu.Count -or -not $cpu[0].Name) { throw 'Could not identify the processor; power tuning skipped.' }
    return [bool]@($cpu | Where-Object { $_.Name -match '\bRyzen\s+9\s+(?:79(?:00|50)X3D|99(?:00|50)X(?:3D)?|7945HX3D|9955HX3D)\b' }).Count
}

function Set-GamingCoreParking {
    if (Test-ManagedCoreParking) {
        Write-OperationResult AlreadyConfigured 'CPU core parking' 'Preserved for AMD driver-managed gaming scheduling.' $true
        return
    }
    $scheme = Get-ActivePowerScheme
    Invoke-GenericChange @('powercfg','-setacvalueindex',[string]$scheme,'SUB_PROCESSOR','CPMINCORES','100')
    $result = Invoke-NativeOperation powercfg @('-setactive',[string]$scheme)
    if ($result.Code -ne 0) { throw ('Could not activate core-parking settings: '+$result.Output) }
}

function Write-OperationResult {
    param([string]$Status, [string]$Operation, [string]$Detail, [bool]$Verified = $false, [long]$Bytes = 0, [bool]$Duplicate = $false)
    $entry = [ordered]@{
        Time = (Get-Date).ToString('o'); Status = $Status; Operation = $Operation
        Detail = $Detail; Verified = $Verified
    }
    if ($env:OPTIMIZER_ACTION_ID) { $entry.Action = $env:OPTIMIZER_ACTION_ID }
    if ($Operation -like 'Recycle *') { $entry.Bytes=$Bytes; $entry.Duplicate=$Duplicate }
    if (-not $env:OPTIMIZER_RESULTS) { throw 'Result journal is not configured.' }
    $entry | ConvertTo-Json -Compress -Depth 8 | Add-Content -LiteralPath $env:OPTIMIZER_RESULTS -Encoding UTF8
    $message = '[{0}] {1}: {2}' -f $Status.ToUpperInvariant(), $Operation, $Detail
    if ($env:LOG_FILE) { Add-Content -LiteralPath $env:LOG_FILE -Value $message -Encoding UTF8 }
    if ($Status -eq 'Failed') {
        $label = switch -Regex ($Operation) {
            '^Service (?:sc (?:stop|start|config) )?"?([^"\s]+)' { 'Service '+$Matches[1]; break }
            '^Recycle ' { 'Recycle '+[IO.Path]::GetFileName($Operation.Substring(8)); break }
            '^Registry |^HK[CLU]' { 'Windows setting'; break }
            '^Restore ' { 'Restore point'; break }
            '^Native ' { 'System command'; break }
            default { $Operation }
        }
        $reason = if ($Detail -match 'access.*denied|returned 5\b|0x80070005') {'Windows denied access.'}
            elseif ($Detail -match 'read.back|did not match|not.*verified') {'Could not verify the change.'}
            else {'Could not complete this change.'}
        Write-Host ("[ERROR] {0}: {1} Details are in the log." -f $label,$reason) -ForegroundColor Red
    } elseif ($Status -eq 'Applied' -and $Verified -and $Operation -in @('System restore point','AC power mode')) {
        Write-Host ("[OK] {0}" -f $Operation) -ForegroundColor Green
    }
}

function Split-OperationArguments {
    param([string]$Text)
    @([regex]::Matches($Text, '"([^"]*)"|(\S+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    })
}

function Get-ArgumentValue {
    param([string[]]$Tokens, [string]$Flag)
    for ($i = 0; $i -lt $Tokens.Count - 1; $i++) {
        if ($Tokens[$i] -ieq $Flag) { return $Tokens[$i + 1] }
    }
    return $null
}

function Invoke-NativeOperation {
    param([string]$Program, [string[]]$Arguments)
    $allowed = @('reg', 'sc', 'schtasks', 'powercfg', 'netsh', 'bcdedit', 'fsutil')
    $name = [IO.Path]::GetFileNameWithoutExtension($Program).ToLowerInvariant()
    if ($name -notin $allowed) { throw "Native program is not allowed: $Program" }
    $path = Join-Path $env:SystemRoot "System32\$name.exe"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Native program is missing: $path" }
    # PowerShell 5.1 must not turn native stderr records into terminating errors.
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $path @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    if ($output -and $env:LOG_FILE) { Add-Content -LiteralPath $env:LOG_FILE -Value $output -Encoding UTF8 }
    [pscustomobject]@{Code = $code; Output = $output}
}

function Get-RegistryState {
    param([string]$Path, [string]$Name)
    $providerPath = 'Registry::' + $Path.Replace('HKLM\', 'HKEY_LOCAL_MACHINE\').Replace('HKCU\', 'HKEY_CURRENT_USER\')
    if (-not (Test-Path -LiteralPath $providerPath -ErrorAction Stop)) { return @{Exists = $false} }
    $key = Get-Item -LiteralPath $providerPath -ErrorAction Stop
    if ($Name -notin $key.GetValueNames()) { return @{Exists = $false} }
    @{
        Exists = $true
        Type = $key.GetValueKind($Name).ToString()
        Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
}

function Test-RegistryValue {
    param($State, [string]$Type, [string]$Value)
    if (-not $State.Exists) { return $false }
    $kinds = @{REG_DWORD='DWord'; REG_QWORD='QWord'; REG_SZ='String'; REG_EXPAND_SZ='ExpandString'; REG_MULTI_SZ='MultiString'; REG_BINARY='Binary'}
    if ($State.Type -ne $kinds[$Type]) { return $false }
    switch ($Type) {
        REG_DWORD { return ([uint32]([int64]$State.Value -band 4294967295L) -eq [uint32]$Value) }
        REG_QWORD { return ([uint64]$State.Value -eq [uint64]$Value) }
        REG_BINARY { return (($State.Value | ForEach-Object {$_.ToString('x2')}) -join '') -ieq $Value }
        REG_MULTI_SZ { return (($State.Value -join '\0') -ceq $Value) }
        default { return ([string]$State.Value -ceq $Value) }
    }
}

function Invoke-RegistryChange {
    param([string[]]$Tokens)
    $action = $Tokens[1]; $path = $Tokens[2]
    $name = Get-ArgumentValue $Tokens '/v'
    if (-not $name) { throw 'Registry operation requires a named value.' }
    $before = Get-RegistryState $path $name
    $type = Get-ArgumentValue $Tokens '/t'; $value = Get-ArgumentValue $Tokens '/d'
    $matches = if ($action -ieq 'add') { Test-RegistryValue $before $type $value } else { -not $before.Exists }
    if ($matches) { Write-OperationResult AlreadyConfigured "$path [$name]" 'Requested registry state is already present.' $true; return }
    $result = Invoke-NativeOperation reg $Tokens[1..($Tokens.Count-1)]
    if ($result.Code -ne 0) { throw "reg.exe returned $($result.Code): $($result.Output.Trim())" }
    $after = Get-RegistryState $path $name
    $matches = if ($action -ieq 'add') { Test-RegistryValue $after $type $value } else { -not $after.Exists }
    if (-not $matches) { throw 'Registry read-back did not match the requested state.' }
    Write-OperationResult Applied "$path [$name]" 'Registry value verified. Runtime effect may require a restart.' $true
}

function Get-ServiceStartup {
    param([string]$Name)
    $key = Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name" -ErrorAction Stop
    if ($key.Start -eq 2 -and $key.PSObject.Properties['DelayedAutoStart'] -and $key.DelayedAutoStart -eq 1) { return 'delayed-auto' }
    switch ($key.Start) { 2 {'auto'} 3 {'demand'} 4 {'disabled'} default {[string]$key.Start} }
}

function Invoke-ServiceChange {
    param([string[]]$Tokens)
    $action = $Tokens[1]; $name = $Tokens[2]
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue -ErrorVariable lookupError
    if (-not $service) {
        if ($lookupError -and $lookupError[0].CategoryInfo.Category -ne 'ObjectNotFound') { throw $lookupError[0] }
        Write-OperationResult Unsupported "Service $name" 'Service is not installed.'; return
    }
    if ($action -ieq 'config') {
        $wanted = Get-ArgumentValue $Tokens 'start='
        if (-not $wanted) { throw 'Unsupported service configuration.' }
        if ((Get-ServiceStartup $name) -eq $wanted) { Write-OperationResult AlreadyConfigured "Service $name startup" $wanted $true; return }
    } else {
        $wanted = if ($action -ieq 'stop') {'Stopped'} elseif ($action -ieq 'start') {'Running'} else {throw 'Unsupported service action.'}
        if ([string]$service.Status -eq $wanted) { Write-OperationResult AlreadyConfigured "Service $name" $wanted $true; return }
    }
    $result = Invoke-NativeOperation sc $Tokens[1..($Tokens.Count-1)]
    if ($result.Code -ne 0) { throw "sc.exe returned $($result.Code): $($result.Output.Trim())" }
    if ($action -ieq 'config') {
        if ((Get-ServiceStartup $name) -ne $wanted) { throw 'Service startup read-back does not match.' }
    } else {
        $service.WaitForStatus($wanted, [TimeSpan]::FromSeconds(15))
        $service.Refresh()
        if ([string]$service.Status -ne $wanted) { throw 'Service did not reach its requested state.' }
    }
    Write-OperationResult Applied "Service $name $action" $wanted $true
}

function Invoke-TaskChange {
    param([string[]]$Tokens)
    $name = Get-ArgumentValue $Tokens '/TN'
    $index = $name.LastIndexOf('\')
    $path = $name.Substring(0,$index+1); $leaf = $name.Substring($index+1)
    $task = Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -eq $path -and $_.TaskName -eq $leaf }
    if (-not $task) { Write-OperationResult Unsupported "Task $name" 'Task is not installed.'; return }
    $wanted = '/Enable' -in $Tokens
    if ([bool]$task.Settings.Enabled -eq $wanted) { Write-OperationResult AlreadyConfigured "Task $name" "Enabled=$wanted" $true; return }
    $result = Invoke-NativeOperation schtasks $Tokens[1..($Tokens.Count-1)]
    if ($result.Code -ne 0) { throw "schtasks.exe returned $($result.Code): $($result.Output.Trim())" }
    $after = Get-ScheduledTask -TaskPath $path -TaskName $leaf -ErrorAction Stop
    if ([bool]$after.Settings.Enabled -ne $wanted) { throw 'Scheduled-task read-back does not match.' }
    Write-OperationResult Applied "Task $name" "Enabled=$wanted" $true
}

function Invoke-FeatureChange {
    param([string]$Action, [string]$Name)
    # Enumerate first: unsupported names are not attempted or reported as failures.
    $feature = Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object FeatureName -EQ $Name
    if (-not $feature) { Write-OperationResult Unsupported "Feature $Name" 'Not present in this Windows installation.'; return }
    $wanted = if ($Action -eq 'Disable') {'Disabled'} else {'Enabled'}
    if ([string]$feature.State -eq $wanted -or ($wanted -eq 'Disabled' -and [string]$feature.State -eq 'DisabledWithPayloadRemoved')) {
        Write-OperationResult AlreadyConfigured "Feature $Name" ([string]$feature.State) $true; return
    }
    if ([string]$feature.State -match 'Pending$') { Write-OperationResult RestartRequired "Feature $Name" "Current state: $($feature.State). Restart before retrying."; return }
    $result = if ($Action -eq 'Disable') {
        Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop
    } else { Enable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop }
    $after = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
    if ($result.RestartNeeded -or [string]$after.State -match 'Pending$') {
        Write-OperationResult RestartRequired "Feature $Name" "Operation accepted; current state $($after.State)."; return
    }
    if ([string]$after.State -ne $wanted) { throw "Feature state is $($after.State), expected $wanted." }
    Write-OperationResult Applied "Feature $Name" $wanted $true
}

function Invoke-MemoryChange {
    param([string]$Property, [bool]$Wanted)
    $before = Get-MMAgent -ErrorAction Stop
    if ([bool]$before.$Property -eq $Wanted) { Write-OperationResult AlreadyConfigured "Memory $Property" "$Wanted" $true; return }
    if ($Property -eq 'MemoryCompression' -and $Wanted) { Enable-MMAgent -MemoryCompression -ErrorAction Stop }
    elseif ($Property -eq 'PageCombining' -and -not $Wanted) { Disable-MMAgent -PageCombining -ErrorAction Stop }
    else { throw 'Unsupported memory operation.' }
    if ([bool](Get-MMAgent -ErrorAction Stop).$Property -ne $Wanted) { throw 'Memory-manager read-back does not match.' }
    Write-OperationResult Applied "Memory $Property" "$Wanted" $true
}

function Invoke-PagefileChange {
    param([string]$Policy)
    if ($Policy -ne 'Auto') { throw 'Only system-managed page files are supported.' }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.AutomaticManagedPagefile) { Write-OperationResult AlreadyConfigured 'Page file' 'System-managed.' $true; return }
    $cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$true} -ErrorAction Stop | Out-Null
    if (-not (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).AutomaticManagedPagefile) { throw 'Automatic page-file management was not enabled.' }
    Write-OperationResult RestartRequired 'Page file' 'System-managed configuration verified; restart to activate.' $true
}

function Initialize-PowerApi {
    if ('OptimizerPower' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class OptimizerPower {
    // SYSTEM_POWER_CAPABILITIES layout from the Windows SDK (BOOLEAN is one byte).
    [StructLayout(LayoutKind.Explicit, Size=76)]
    public struct Capabilities {
        [FieldOffset(2)] public byte Lid;
        [FieldOffset(20)] public byte AoAc;
        [FieldOffset(30)] public byte Batteries;
        [FieldOffset(31)] public byte ShortTermBatteries;
    }
    [DllImport("powrprof.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.U1)]
    static extern bool GetPwrCapabilities(out Capabilities capabilities);
    [DllImport("powrprof.dll")]
    static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("powrprof.dll")]
    static extern uint PowerGetUserConfiguredACPowerMode(out Guid mode);
    [DllImport("powrprof.dll")]
    static extern uint PowerSetUserConfiguredACPowerMode(ref Guid mode);
    [DllImport("powrprof.dll")]
    static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid group, ref Guid setting, out uint value);
    public static Capabilities ReadCapabilities() {
        Capabilities value;
        if (!GetPwrCapabilities(out value)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return value;
    }
    public static Guid ReadActiveScheme() {
        IntPtr value; uint code=PowerGetActiveScheme(IntPtr.Zero, out value);
        if(code!=0) throw new Win32Exception((int)code);
        try { return (Guid)Marshal.PtrToStructure(value, typeof(Guid)); }
        finally { LocalFree(value); }
    }
    public static Guid ReadACMode() {
        Guid value; uint code=PowerGetUserConfiguredACPowerMode(out value);
        if(code!=0) throw new Win32Exception((int)code);
        return value;
    }
    public static void SetACMode(Guid value) {
        uint code=PowerSetUserConfiguredACPowerMode(ref value);
        if(code!=0) throw new Win32Exception((int)code);
    }
    public static uint ReadACValue(Guid scheme, Guid group, Guid setting) {
        uint value; uint code=PowerReadACValueIndex(IntPtr.Zero,ref scheme,ref group,ref setting,out value);
        if(code!=0) throw new Win32Exception((int)code);
        return value;
    }
}
'@
}

function Get-PowerCapabilities {
    Initialize-PowerApi
    $caps = [OptimizerPower]::ReadCapabilities()
    @{ModernStandby=($caps.AoAc -ne 0); Portable=($caps.Lid -ne 0 -or ($caps.Batteries -ne 0 -and $caps.ShortTermBatteries -eq 0))}
}

function Get-ActivePowerScheme { Initialize-PowerApi; [OptimizerPower]::ReadActiveScheme() }
function Get-ACPowerMode { Initialize-PowerApi; [OptimizerPower]::ReadACMode() }
function Set-ACPowerMode([guid]$Mode) { Initialize-PowerApi; [OptimizerPower]::SetACMode($Mode) }
function Get-ACPowerValue([guid]$Scheme,[guid]$Group,[guid]$Setting) { Initialize-PowerApi; [OptimizerPower]::ReadACValue($Scheme,$Group,$Setting) }

function Set-DeliveryOptimization {
    Invoke-RegistryChange @('reg','add','HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization','/v','DODownloadMode','/t','REG_DWORD','/d','0','/f')
    if ((Get-ServiceStartup 'DoSvc') -eq 'disabled') {
        Invoke-ServiceChange @('sc','config','DoSvc','start=','delayed-auto')
    } else {
        Write-OperationResult AlreadyConfigured 'Delivery Optimization service' 'Available to Windows; startup type preserved.' $true
    }
}

function Get-PerformancePlans {
    Get-CimInstance -Namespace root/cimv2/power -ClassName Win32_PowerPlan -ErrorAction Stop | ForEach-Object {
        $id = [regex]::Match($_.InstanceID,'[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}','IgnoreCase').Value
        if (-not $id) { throw 'Could not identify a power plan.' }
        [pscustomobject]@{Id=$id;Name=$_.ElementName;Active=$_.IsActive}
    }
}

function Invoke-PerformancePlan {
    $managed = Test-ManagedCoreParking
    if ($managed) { Invoke-GenericChange @('powercfg','-setactive','381b4222-f694-41f0-9685-ff5bb260df2e') }
    $caps = Get-PowerCapabilities
    if ($managed -or $caps.ModernStandby -or $caps.Portable) {
        $wanted = [guid]'ded574b5-45a0-4f42-8737-46345c09c238'
        $status = 'AlreadyConfigured'
        if ((Get-ACPowerMode) -ne $wanted) { Set-ACPowerMode $wanted; $status = 'Applied' }
        if ((Get-ACPowerMode) -ne $wanted) { throw 'AC power mode read-back did not match Best performance.' }
        Write-OperationResult $status 'AC power mode' 'Best performance preference verified. Existing power plan and battery mode preserved; Windows/OEM thermal limits still apply.' $true
        return
    }
    $plans = @(Get-PerformancePlans)
    $copies = @($plans | Where-Object Name -in @('Ultimate Performance','Gaming Optimizer'))
    $keeper = $copies | Sort-Object Active -Descending | Select-Object -First 1
    if (-not $keeper) {
        $guid = 'b5414e12-0874-43e7-8a39-4618bfcf9a45'
        if ($plans.Id -contains $guid) { throw 'Optimizer power-plan ID belongs to another named plan; left untouched.' }
        $created = Invoke-NativeOperation powercfg @('-duplicatescheme','e9a42b02-d5df-448d-aa00-03f14749eb61',$guid)
        if ($created.Code -ne 0) {
            Write-OperationResult Failed 'Create performance power plan' $created.Output.Trim()
            Invoke-GenericChange @('powercfg','-setactive','SCHEME_MIN'); return
        }
        $named = Invoke-NativeOperation powercfg @('-changename',$guid,'Gaming Optimizer')
        if ($named.Code -ne 0) { throw 'Could not name optimizer power plan.' }
        $keeper = Get-PerformancePlans | Where-Object Id -eq $guid
        if (-not $keeper -or $keeper.Name -ne 'Gaming Optimizer') { throw 'Created power plan could not be verified.' }
        Write-OperationResult Applied 'Create performance power plan' "Created and verified $guid." $true
    }
    Invoke-GenericChange @('powercfg','-setactive',$keeper.Id)
    foreach ($copy in @($copies | Where-Object Id -ne $keeper.Id)) {
        $removed = Invoke-NativeOperation powercfg @('/delete',$copy.Id)
        if ($removed.Code -ne 0 -or @(Get-PerformancePlans | Where-Object Id -eq $copy.Id).Count) { throw "Could not remove duplicate performance plan $($copy.Id)." }
        Write-OperationResult Applied 'Remove duplicate performance plan' $copy.Id $true
    }
}

function Wait-OptimizerRestorePoint($Description, $Before) {
    # Windows may expose the point after CreateRestorePoint has returned success.
    for ($attempt=0; $attempt -lt 60; $attempt++) {
        $point = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction Stop |
            Where-Object { $_.Description -eq $Description -and $_.SequenceNumber -notin $Before })
        if ($point.Count -eq 1) { return $point[0] }
        if ($attempt -lt 59) { Start-Sleep -Seconds 2 }
    }
    throw 'Windows did not expose a new matching restore point within two minutes. No checkpoint has been verified.'
}

function New-OptimizerRestorePoint {
    $policy = 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
    foreach ($name in @('DisableSR','DisableConfig')) {
        $state = Get-RegistryState $policy $name
        if ($state.Exists -and $state.Value -eq 1) { throw 'System Protection is disabled by policy. Contact your administrator.' }
    }
    Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop -WarningAction Stop
    $before = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction Stop | ForEach-Object SequenceNumber)
    $description = 'Gaming Optimizer - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' - ' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $path = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    $frequency = Get-RegistryState $path $name
    if ($frequency.Exists -and $frequency.Type -ne 'DWord') { throw 'Unexpected restore-point frequency registry type; left unchanged.' }
    # Permit a fresh pre-change checkpoint even if Windows created one today.
    # Restore the user's frequency immediately, including on failure.
    $frequencyChanged = $false
    try {
        New-ItemProperty -LiteralPath $key -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        $frequencyChanged = $true
        $result = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{
            Description=$description; RestorePointType=[uint32]12; EventType=[uint32]100
        } -ErrorAction Stop
        if ($result.ReturnValue -ne 0) { throw "Windows restore-point creation returned $($result.ReturnValue). Check System Protection and available disk space." }
        $point = @(Wait-OptimizerRestorePoint $description $before)
    } finally {
        if ($frequencyChanged -and $frequency.Exists) {
            New-ItemProperty -LiteralPath $key -Name $name -PropertyType DWord -Value $frequency.Value -Force -ErrorAction Stop | Out-Null
        } elseif ($frequencyChanged) {
            Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop
        }
    }
    Write-OperationResult Applied 'System restore point' "Verified #$($point[0].SequenceNumber): $description. Open System Restore with menu R or rstrui.exe." $true
}

function Enable-WindowedOptimizations {
    $build = [int](Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop)
    if ($build -lt 22621) {
        Write-OperationResult Unsupported 'Windowed game optimizations' 'Requires Windows 11 22H2 or newer.'; return
    }
    $path = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
    $name = 'DirectXUserGlobalSettings'
    $state = Get-RegistryState $path $name
    $settings = if ($state.Exists) { [string]$state.Value } else { '' }
    # This is a compound preference. Preserve Auto HDR, VRR and unknown flags.
    $parts = @($settings -split ';' | Where-Object { $_ -and $_ -notmatch '^\s*SwapEffectUpgradeEnable\s*=' })
    $wanted = (($parts + 'SwapEffectUpgradeEnable=1') -join ';') + ';'
    Invoke-RegistryChange @('reg','add',$path,'/v',$name,'/t','REG_SZ','/d',$wanted,'/f')
}

function Set-MemoryIntegrity {
    param([bool]$Enable)
    $path = 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $locked = Get-RegistryState $path 'Locked'
    $vbsLocked = Get-RegistryState 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'Locked'
    $policy = Get-RegistryState 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'HypervisorEnforcedCodeIntegrity'
    if (($locked.Exists -and $locked.Value -eq 1) -or ($vbsLocked.Exists -and $vbsLocked.Value -eq 1) -or $policy.Exists) {
        Write-OperationResult Unsupported 'Memory integrity' 'Enforced by policy or UEFI lock; no attempt to bypass it was made.'; return
    }
    $wanted = [int]$Enable
    $before = Get-RegistryState $path 'Enabled'
    $running = 2 -in @((Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop).SecurityServicesRunning)
    if (-not $Enable) { Write-Host 'Memory integrity will be off: less protection; some anti-cheat systems may require it on.' -ForegroundColor Yellow }
    if (-not $before.Exists -or $before.Value -ne $wanted) {
        Invoke-RegistryChange @('reg','add',$path,'/v','Enabled','/t','REG_DWORD','/d',"$wanted",'/f')
        Write-OperationResult RestartRequired 'Memory integrity' "Saved Enabled=$wanted. Restart and check Windows Security before assuming the runtime state changed." $true
    } elseif ($running -ne $Enable) {
        Write-OperationResult RestartRequired 'Memory integrity' "Enabled=$wanted is configured, but the running HVCI state differs. Restart to apply."
    } else {
        Write-OperationResult AlreadyConfigured 'Memory integrity' "Configured and running state agree: Enabled=$wanted." $true
    }
}

function Get-DisplayModes {
    if (-not ('OptimizerDisplay' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class OptimizerDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Device {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Key;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Mode {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
        public ushort SpecVersion, DriverVersion, Size, DriverExtra;
        public uint Fields;
        public int X, Y;
        public uint Orientation, FixedOutput;
        public short Color, Duplex, YResolution, TTOption, Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string FormName;
        public ushort LogPixels;
        public uint BitsPerPel, Width, Height, Flags, Frequency;
        public uint ICMMethod, ICMIntent, MediaType, DitherType, Reserved1, Reserved2, PanningWidth, PanningHeight;
    }
    public class Info {
        public string Name;
        public uint Width, Height, CurrentHz, HighestHz;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string device, uint index, ref Device data, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string name, int index, ref Mode mode);
    static Mode NewMode() { return new Mode { Size=(ushort)Marshal.SizeOf(typeof(Mode)) }; }
    public static Info[] Read() {
        var result=new List<Info>();
        for(uint i=0;;i++) {
            var device=new Device { Size=Marshal.SizeOf(typeof(Device)) };
            if(!EnumDisplayDevices(null,i,ref device,0)) break;
            if((device.Flags & 1)==0 || (device.Flags & 8)!=0) continue;
            var current=NewMode();
            if(!EnumDisplaySettings(device.Name,-1,ref current)) continue;
            uint highest=current.Frequency;
            for(int j=0;;j++) {
                var mode=NewMode();
                if(!EnumDisplaySettings(device.Name,j,ref mode)) break;
                if(mode.Width==current.Width && mode.Height==current.Height &&
                   mode.BitsPerPel==current.BitsPerPel && mode.Orientation==current.Orientation &&
                   mode.Frequency>highest) highest=mode.Frequency;
            }
            result.Add(new Info { Name=device.Name, Width=current.Width, Height=current.Height,
                CurrentHz=current.Frequency, HighestHz=highest });
        }
        return result.ToArray();
    }
}
'@
    }
    [OptimizerDisplay]::Read()
}

function Show-GraphicsConfiguration {
    $screens = @(Get-DisplayModes)
    if (-not $screens.Count) { Write-OperationResult Unverified 'Display refresh' 'No active display modes could be read.' }
    foreach ($screen in $screens) {
        $detail = "$($screen.Width)x$($screen.Height) at $($screen.CurrentHz) Hz; highest enumerated rate at this resolution: $($screen.HighestHz) Hz."
        if ($screen.HighestHz -gt $screen.CurrentHz) {
            Write-OperationResult Unverified "Display $($screen.Name)" "$detail Review Settings > System > Display > Advanced display. No mode was changed."
        } else { Write-OperationResult AlreadyConfigured "Display $($screen.Name)" $detail $true }
    }
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
    if (-not $env:OPTIMIZER_FULL_RUN) { Write-Host ('Detected graphics adapters: ' + (($gpus | ForEach-Object Name) -join ', ')) }
    $key = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (Test-Path -LiteralPath $key) {
        $preferences = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        foreach ($property in $preferences.PSObject.Properties) {
            if ($property.Name -match '\.exe$' -and $property.Value -match 'GpuPreference=([012]);?') {
                $label = @('Windows default','power saving','high performance')[[int]$Matches[1]]
                if (-not $env:OPTIMIZER_FULL_RUN) { Write-Host ("GPU preference: {0} = {1}" -f $property.Name,$label) }
            }
        }
    }
    Write-OperationResult Unverified 'Per-game GPU selection' 'Adapter names and saved preferences do not prove which GPU a game uses. Check Settings > System > Display > Graphics and the running game GPU engine; no preferences were changed.'
}

function Get-NativeDesiredState {
    param([string[]]$Tokens)
    $exe = [IO.Path]::GetFileNameWithoutExtension($Tokens[0]).ToLowerInvariant()
    if ($exe -eq 'netsh' -and $Tokens.Count -eq 6 -and ($Tokens[1..4] -join ' ') -eq 'interface tcp set global') {
        $pair = $Tokens[5] -split '=',2
        if ($pair[0] -eq 'autotuninglevel') {
            $value = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
            return [string]$value.AutoTuningLevelLocal -ieq $pair[1]
        }
        $names = @{rss='ReceiveSideScaling';rsc='ReceiveSegmentCoalescing'}
        if ($names.ContainsKey($pair[0]) -and $pair[1] -ne 'default') {
            $value = Get-NetOffloadGlobalSetting -ErrorAction Stop
            return [string]$value.($names[$pair[0]]) -ieq $pair[1]
        }
    }
    if ($exe -eq 'powercfg' -and $Tokens[1] -eq '-setacvalueindex') {
        $scheme = $Tokens[2]
        if ($scheme -eq 'SCHEME_CURRENT') {
            $scheme = Get-ActivePowerScheme
        }
        $aliases = @{SUB_PROCESSOR='54533251-82be-4824-96c1-47b60b740d00';CPMINCORES='0cc5b647-c1df-4637-891a-dec35c318583'}
        $group = $Tokens[3]; $setting = $Tokens[4]
        if ($aliases.ContainsKey($group)) { $group=$aliases[$group] }
        if ($aliases.ContainsKey($setting)) { $setting=$aliases[$setting] }
        return (Get-ACPowerValue $scheme $group $setting) -eq [uint32]$Tokens[5]
    }
    if ($exe -eq 'fsutil' -and $Tokens[1] -eq 'behavior' -and $Tokens[2] -eq 'set') {
        $query = Invoke-NativeOperation fsutil @('behavior','query',$Tokens[3])
        if ($query.Code -eq 0 -and $query.Output -match '=\s*(\d+)') { return ($Matches[1] -eq $Tokens[4]) }
    }
    if ($exe -eq 'powercfg' -and $Tokens[1] -eq '-setactive') {
        $active = Get-ActivePowerScheme
        $desired = if ($Tokens[2] -eq 'SCHEME_MIN') {'8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'} else {$Tokens[2]}
        if ($desired -match '^[a-f\d-]{36}$') { return $active -eq [guid]$desired }
    }
    if ($exe -eq 'bcdedit' -and $Tokens[1] -eq '/deletevalue') {
        $query = Invoke-NativeOperation bcdedit @('/enum','{current}')
        if ($query.Code -eq 0) {
            return -not ($query.Output -match ('(?im)^\s*' + [regex]::Escape($Tokens[2]) + '\s+'))
        }
    }
    # A missing checker is unknown, never an implied match.
    return $null
}

function Invoke-GenericChange {
    param([string[]]$Tokens)
    $name = [IO.Path]::GetFileNameWithoutExtension($Tokens[0]).ToLowerInvariant()
    $before = Get-NativeDesiredState $Tokens
    if ($before -eq $true) { Write-OperationResult AlreadyConfigured ($Tokens -join ' ') 'Requested state verified.' $true; return }
    $result = Invoke-NativeOperation $Tokens[0] $Tokens[1..($Tokens.Count-1)]
    if ($result.Code -eq 3010) { Write-OperationResult RestartRequired ($Tokens -join ' ') 'Restart required; operation may be deferred.'; return }
    if ($result.Code -ne 0) { throw "Exit $($result.Code): $($result.Output.Trim())" }
    if ($name -eq 'reg' -and $Tokens[1] -eq 'export') {
        $export = Get-Content -LiteralPath $Tokens[3] -Raw -ErrorAction Stop
        $key = $Tokens[2] -replace '^HKCU\\','HKEY_CURRENT_USER\' -replace '^HKLM\\','HKEY_LOCAL_MACHINE\'
        if ($export -notmatch '^Windows Registry Editor Version 5\.00' -or $export -notmatch ('(?m)^\['+[regex]::Escape($key)+'\]\r?$')) { throw 'Registry export is missing its header or requested root key.' }
        Write-OperationResult Applied ($Tokens -join ' ') 'Registry export format and root key verified.' $true
        return
    }
    $after = Get-NativeDesiredState $Tokens
    if ($after -eq $false) { throw 'Command succeeded but read-back does not match.' }
    if ($null -eq $after) {
        Write-OperationResult Unverified ($Tokens -join ' ') 'Command succeeded; no reliable read-back check is implemented.'
    } elseif ($name -eq 'bcdedit') {
        Write-OperationResult RestartRequired ($Tokens -join ' ') 'Boot configuration verified; restart to activate.' $true
    } else { Write-OperationResult Applied ($Tokens -join ' ') 'Requested state verified.' $true }
}

function Show-OperationSummary {
    if (-not (Test-Path -LiteralPath $env:OPTIMIZER_RESULTS)) { Write-Host 'No operations recorded in this session.'; return 0 }
    $entries = @(Get-Content -LiteralPath $env:OPTIMIZER_RESULTS | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
    if ($env:OPTIMIZER_ACTION_ID) { $entries = @($entries | Where-Object Action -eq $env:OPTIMIZER_ACTION_ID) }
    if (-not $entries.Count) { Write-Host 'No operations recorded in this session.'; return 0 }
    $scope = if ($env:OPTIMIZER_ACTION_ID) {'this action'} else {'this session'}
    Write-Host "`nSUMMARY - $scope" -ForegroundColor Cyan
    $changed = @($entries | Where-Object { $_.Verified -and $_.Status -in @('Applied','RestartRequired') })
    $areas = @($changed | Where-Object { $_.Operation -notlike 'Recycle *' -and $_.Operation -notlike 'reg export *' -and $_.Operation -ne 'System restore point' } | ForEach-Object {
        switch -Regex ($_.Operation) {
            '^Service |^Task ' {'Services & background tasks'; break}
            'GameBar|GameDVR|GameConfigStore|GraphicsDrivers|DirectX|Mouse|mouclass|kbdclass' {'Gaming, graphics & input'; break}
            '^Memory|Memory Management|^Page file|DeviceGuard' {'Memory & security'; break}
            '^powercfg|power plan|^AC power' {'Power settings'; break}
            'Tcpip|^netsh|DeliveryOptimization' {'Networking'; break}
            'Visual|Desktop|WindowMetrics|DWM|Explorer' {'Desktop & visuals'; break}
            default {'Other Windows settings'}
        }
    } | Sort-Object -Unique)
    if ($areas.Count) { Write-Host ('Updated: '+($areas -join '; ')) -ForegroundColor Green }
    else { Write-Host 'No new configuration changes confirmed.' }
    if (@($changed | Where-Object Operation -eq 'System restore point').Count) { Write-Host 'Restore point: created and verified. Use R to restore.' -ForegroundColor Green }
    $recycled = @($changed | Where-Object Operation -like 'Recycle *')
    if ($recycled.Count) {
        $gb = ($recycled | Measure-Object Bytes -Sum).Sum / 1GB
        $duplicates = @($recycled | Where-Object Duplicate -eq $true).Count
        $noun = if ($recycled.Count -eq 1) {'file'} else {'files'}
        Write-Host ('Recycled: {0} {1} | ~{2:N2} GB | Duplicates: {3}' -f $recycled.Count,$noun,$gb,$duplicates) -ForegroundColor Green
        Write-Host 'Space is still occupied in the Recycle Bin; empty it manually to free space.'
    } elseif (@($entries | Where-Object Operation -like 'Recycle *').Count) {
        Write-Host 'Recycled: no files.'
    }
    if (@($entries | Where-Object Status -eq 'RestartRequired').Count) { Write-Host 'Restart: needed to finish applying some settings.' -ForegroundColor Yellow }
    $failed = @($entries | Where-Object Status -eq 'Failed').Count
    $unverified = @($entries | Where-Object Status -eq 'Unverified').Count
    $skipped = @($entries | Where-Object Status -eq 'Unsupported').Count
    if ($failed -or $unverified) { Write-Host ("Review: $failed failed; $unverified unverified.") -ForegroundColor $(if ($failed) {'Red'} else {'Yellow'}) }
    if ($skipped) { Write-Host ("Skipped: $skipped unavailable items (not errors).") -ForegroundColor DarkGray }
    Write-Host ('Details: '+$env:LOG_FILE)
    if ($failed) { Write-Host 'PARTIAL RESULT - see the log for failures.' -ForegroundColor Red; return 1 }
    if ($unverified -or @($entries | Where-Object Status -eq 'RestartRequired').Count) { Write-Host 'INCOMPLETE VERIFICATION - restart/review as noted above.' -ForegroundColor Yellow; return 2 }
    Write-Host 'Completed.' -ForegroundColor Green
    return 0
}

function Invoke-Operation {
    param([string]$Text)
    $tokens = @(Split-OperationArguments $Text)
    $label = $Text
    try {
        if ($tokens.Count -lt 2) { throw 'Missing operation arguments.' }
        switch ($tokens[0]) {
            Registry { Invoke-RegistryChange $tokens[1..($tokens.Count-1)] }
            Service { Invoke-ServiceChange $tokens[1..($tokens.Count-1)] }
            Task { Invoke-TaskChange $tokens[1..($tokens.Count-1)] }
            Feature { Invoke-FeatureChange $tokens[1] $tokens[2] }
            Apps { . (Join-Path $PSScriptRoot 'optimizer-cleanup.ps1'); Show-AppInventory }
            Cleanup { . (Join-Path $PSScriptRoot 'optimizer-cleanup.ps1'); Invoke-RecycleCleanup $tokens[1] }
            Memory { Invoke-MemoryChange $tokens[1] ($tokens[2] -eq '1') }
            Pagefile { Invoke-PagefileChange $tokens[1] }
            Plan { Invoke-PerformancePlan }
            Parking { Set-GamingCoreParking }
            Delivery { Set-DeliveryOptimization }
            Restore { New-OptimizerRestorePoint }
            Windowed { Enable-WindowedOptimizations }
            Integrity { Set-MemoryIntegrity ($tokens[1] -eq 'On') }
            Graphics { Show-GraphicsConfiguration }
            Native { Invoke-GenericChange $tokens[1..($tokens.Count-1)] }
            default { throw 'Unknown operation kind.' }
        }
    } catch { Write-OperationResult Failed $label $_.Exception.Message; return 1 }
    return 0
}

if ($NoRun) { return }
try {
    if ($Mode -eq 'Initialize') {
        foreach ($path in @($env:OPTIMIZER_RESULTS, $env:LOG_FILE)) {
            if (-not $path) { throw 'Reporting paths are not configured.' }
            $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $stream.Dispose()
        }
        exit 0
    }
    if ($Mode -eq 'CheckUser') { Assert-UserContext; exit 0 }
    if ($Mode -eq 'StorageType') { Get-SystemStorageType; exit 0 }
    if ($Mode -eq 'Summary') { exit (Show-OperationSummary) }
    exit (Invoke-Operation $env:OPTIMIZER_OPERATION)
} catch {
    Write-Error "Result handling failed: $_" -ErrorAction Continue
    exit 1
}
