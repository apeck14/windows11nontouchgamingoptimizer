param(
    [ValidateSet('Operation', 'Summary', 'Record', 'Initialize')][string]$Mode = 'Operation',
    [switch]$NoRun
)

# Shared result handling for the batch UI. Dot-source with -NoRun for tests.
# No expression evaluation: command arguments are tokenized and passed to a
# small allowlist of native programs. Every result states its verification level.
$ErrorActionPreference = 'Stop'

function Write-OperationResult {
    param([string]$Status, [string]$Operation, [string]$Detail, [bool]$Verified = $false)
    $entry = [ordered]@{
        Time = (Get-Date).ToString('o'); Status = $Status; Operation = $Operation
        Detail = $Detail; Verified = $Verified
    }
    if (-not $env:OPTIMIZER_RESULTS) { throw 'Result journal is not configured.' }
    $entry | ConvertTo-Json -Compress -Depth 8 | Add-Content -LiteralPath $env:OPTIMIZER_RESULTS -Encoding UTF8
    $message = '[{0}] {1}: {2}' -f $Status.ToUpperInvariant(), $Operation, $Detail
    Write-Host $message
    if ($env:LOG_FILE) { Add-Content -LiteralPath $env:LOG_FILE -Value $message -Encoding UTF8 }
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
    $allowed = @('reg', 'sc', 'schtasks', 'powercfg', 'netsh', 'bcdedit', 'fsutil', 'dism')
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

function Invoke-AppRemoval {
    param([string]$Name)
    $failed = $false
    # Preserve existing effective scope: current account plus provisioning.
    # Each scope has an independent result; enumeration failure is never absence.
    try {
        $packages = @(Get-AppxPackage -Name $Name -ErrorAction Stop)
        if (-not $packages.Count) { Write-OperationResult AlreadyConfigured "App $Name (current user)" 'Not installed.' $true }
        elseif (@($packages | Where-Object NonRemovable).Count) { Write-OperationResult Unsupported "App $Name (current user)" 'Windows marks this package non-removable.' }
        else {
            foreach ($package in $packages) { Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop }
            if (@(Get-AppxPackage -Name $Name -ErrorAction Stop).Count) { throw 'Package remains registered after removal.' }
            Write-OperationResult Applied "App $Name (current user)" 'Removal verified.' $true
        }
    } catch { $failed = $true; Write-OperationResult Failed "App $Name (current user)" $_.Exception.Message }
    try {
        $packages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object DisplayName -EQ $Name)
        if (-not $packages.Count) { Write-OperationResult AlreadyConfigured "App $Name (provisioning)" 'Not provisioned.' $true }
        else {
            foreach ($package in $packages) { Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null }
            if (@(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object DisplayName -EQ $Name).Count) { throw 'Package remains provisioned after removal.' }
            Write-OperationResult Applied "App $Name (provisioning)" 'Removal verified for future users.' $true
        }
    } catch { $failed = $true; Write-OperationResult Failed "App $Name (provisioning)" $_.Exception.Message }
    return -not $failed
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
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($Policy -eq 'Auto') {
        if ($cs.AutomaticManagedPagefile) { Write-OperationResult AlreadyConfigured 'Page file' 'System-managed.' $true; return }
        $cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$true} -ErrorAction Stop | Out-Null
        if (-not (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).AutomaticManagedPagefile) { throw 'Automatic page-file management was not enabled.' }
    } else {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        $wanted = $env:SystemDrive + '\pagefile.sys 4096 4096'
        $current = @(Get-ItemPropertyValue -LiteralPath $key -Name PagingFiles -ErrorAction Stop)
        if (-not $cs.AutomaticManagedPagefile -and $current.Count -eq 1 -and $current[0] -eq $wanted) { Write-OperationResult AlreadyConfigured 'Page file' 'Fixed 4 GB configured.' $true; return }
        $cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$false} -ErrorAction Stop | Out-Null
        Set-ItemProperty -LiteralPath $key -Name PagingFiles -Value @($wanted) -ErrorAction Stop
        $after = @(Get-ItemPropertyValue -LiteralPath $key -Name PagingFiles -ErrorAction Stop)
        if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).AutomaticManagedPagefile -or $after.Count -ne 1 -or $after[0] -ne $wanted) { throw 'Fixed page-file configuration did not match.' }
    }
    Write-OperationResult RestartRequired 'Page file' "Saved and verified $Policy configuration; restart to activate." $true
}

function Invoke-PerformancePlan {
    $template = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $result = Invoke-NativeOperation powercfg @('-duplicatescheme',$template)
    $guid = $template
    if ($result.Code -eq 0 -and $result.Output -match '[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}') {
        $guid = $Matches[0]
        $list = Invoke-NativeOperation powercfg @('/list')
        if ($list.Code -eq 0 -and $list.Output -match [regex]::Escape($guid)) {
            Write-OperationResult Applied 'Create performance power plan' "Created and verified $guid." $true
        } else { throw 'Power plan creation returned success but the plan is not listed.' }
    } else {
        Write-OperationResult Failed 'Create performance power plan' "Exit $($result.Code): $($result.Output.Trim()). Trying existing plan, then High Performance."
    }
    try { Invoke-GenericChange @('powercfg','-setactive',$guid) }
    catch {
        Write-OperationResult Failed "Activate power plan $guid" $_.Exception.Message
        Invoke-GenericChange @('powercfg','-setactive','SCHEME_MIN')
    }
}

function Get-NativeDesiredState {
    param([string[]]$Tokens)
    $exe = [IO.Path]::GetFileNameWithoutExtension($Tokens[0]).ToLowerInvariant()
    if ($exe -eq 'powercfg' -and $Tokens[1] -eq '/h') {
        $state = Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop
        return ([bool]$state -eq ($Tokens[2] -eq 'on'))
    }
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
    if ($exe -eq 'powercfg' -and $Tokens[1] -in @('-setacvalueindex','-setdcvalueindex')) {
        $scheme = $Tokens[2]
        if ($scheme -eq 'SCHEME_CURRENT') {
            $query = Invoke-NativeOperation powercfg @('/getactivescheme')
            if ($query.Code -ne 0 -or $query.Output -notmatch '[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}') { return $null }
            $scheme = $Matches[0]
        }
        $aliases = @{SUB_PROCESSOR='54533251-82be-4824-96c1-47b60b740d00';SUB_SLEEP='238c9fa8-0aad-41ed-83f4-97be242c8f20';CPMINCORES='0cc5b647-c1df-4637-891a-dec35c318583'}
        $group = $Tokens[3]; $setting = $Tokens[4]
        if ($aliases.ContainsKey($group)) { $group=$aliases[$group] }
        if ($aliases.ContainsKey($setting)) { $setting=$aliases[$setting] }
        $property = if ($Tokens[1] -eq '-setacvalueindex') {'ACSettingIndex'} else {'DCSettingIndex'}
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\$group\$setting"
        if (-not (Test-Path -LiteralPath $key)) { return $false }
        $state = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        if (-not $state.PSObject.Properties[$property]) { return $false }
        return $state.$property -eq [uint32]$Tokens[5]
    }
    if ($exe -eq 'fsutil' -and $Tokens[1] -eq 'behavior' -and $Tokens[2] -eq 'set') {
        $query = Invoke-NativeOperation fsutil @('behavior','query',$Tokens[3])
        if ($query.Code -eq 0 -and $query.Output -match '=\s*(\d+)') { return ($Matches[1] -eq $Tokens[4]) }
    }
    if ($exe -eq 'powercfg' -and $Tokens[1] -eq '-setactive') {
        $query = Invoke-NativeOperation powercfg @('/getactivescheme')
        $desired = if ($Tokens[2] -eq 'SCHEME_MIN') {'8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'} else {$Tokens[2]}
        if ($desired -match '^[a-f\d-]{36}$' -and $query.Code -eq 0) { return $query.Output -match [regex]::Escape($desired) }
    }
    if ($exe -eq 'bcdedit' -and $Tokens[1] -in @('/set','/deletevalue')) {
        $query = Invoke-NativeOperation bcdedit @('/enum','{current}')
        if ($query.Code -eq 0) {
            $pattern = '(?im)^\s*' + [regex]::Escape($Tokens[2]) + '\s+(\S+)'
            if ($Tokens[1] -eq '/deletevalue') { return -not ($query.Output -match $pattern) }
            if ($query.Output -match $pattern) {
                $actual = $Matches[1].ToLowerInvariant(); $desired = $Tokens[3].ToLowerInvariant()
                if ($actual -in @('yes','true') -and $desired -in @('yes','true')) { return $true }
                if ($actual -in @('no','false') -and $desired -in @('no','false')) { return $true }
                return $actual -eq $desired
            }
            return $false
        }
    }
    # A missing checker is unknown, never an implied match.
    return $null
}

function Invoke-GenericChange {
    param([string[]]$Tokens)
    $name = [IO.Path]::GetFileNameWithoutExtension($Tokens[0]).ToLowerInvariant()
    if ($name -eq 'dism' -and (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        Write-OperationResult RestartRequired ($Tokens -join ' ') 'Deferred: Windows servicing has pending operations. Restart before retrying.'; return
    }
    $before = Get-NativeDesiredState $Tokens
    if ($before -eq $true) { Write-OperationResult AlreadyConfigured ($Tokens -join ' ') 'Requested state verified.' $true; return }
    $result = Invoke-NativeOperation $Tokens[0] $Tokens[1..($Tokens.Count-1)]
    if ($result.Code -eq 3010 -or $result.Output -match '0x800f0806') { Write-OperationResult RestartRequired ($Tokens -join ' ') 'Restart required; operation may be deferred.'; return }
    if ($result.Code -ne 0) { throw "Exit $($result.Code): $($result.Output.Trim())" }
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
    if (-not $entries.Count) { Write-Host 'No operations recorded in this session.'; return 0 }
    Write-Host "`nOPERATION RESULTS - cumulative for this session"
    $entries | Group-Object Status | Sort-Object Name | ForEach-Object { Write-Host ('  {0}: {1}' -f $_.Name, $_.Count) }
    $attention = @($entries | Where-Object Status -In @('Failed','RestartRequired','Unverified','Unsupported'))
    foreach ($entry in $attention) { Write-Host ('  [{0}] {1}: {2}' -f $entry.Status, $entry.Operation, $entry.Detail) }
    Write-Host "Journal: $env:OPTIMIZER_RESULTS"
    Write-Host 'Verified configuration is not a measurement of FPS or latency. Some saved settings activate after restart.'
    if (@($entries | Where-Object Status -EQ 'Failed').Count) { Write-Host 'PARTIAL RESULT: one or more operations failed.'; return 1 }
    if (@($entries | Where-Object Status -In @('Unverified','RestartRequired')).Count) { Write-Host 'INCOMPLETE VERIFICATION: review unverified and restart-required entries.'; return 2 }
    Write-Host 'All supported, attempted operations have verified requested states.'
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
            Appx { if (-not (Invoke-AppRemoval $tokens[1])) { return 1 } }
            Memory { Invoke-MemoryChange $tokens[1] ($tokens[2] -eq '1') }
            Pagefile { Invoke-PagefileChange $tokens[1] }
            Plan { Invoke-PerformancePlan }
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
    if ($Mode -eq 'Summary') { exit (Show-OperationSummary) }
    if ($Mode -eq 'Record') {
        Write-OperationResult $env:OPTIMIZER_STATUS $env:OPTIMIZER_LABEL $env:OPTIMIZER_DETAIL ($env:OPTIMIZER_VERIFIED -eq '1')
        exit 0
    }
    exit (Invoke-Operation $env:OPTIMIZER_OPERATION)
} catch {
    Write-Error "Result handling failed: $_" -ErrorAction Continue
    exit 1
}
