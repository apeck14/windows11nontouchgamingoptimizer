# Competitive preset. Only edit existing, compatible keys; never evaluate config text.
function Get-Mw4Roots {
    @((Join-Path $env:LOCALAPPDATA 'Activision\Call of Duty\players'),
      (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Call of Duty\players')) | Select-Object -Unique
}

function Assert-Mw4Closed {
    if (Get-Process -ErrorAction Stop | Where-Object ProcessName -Match '^(cod(?:hq|\d+(?:-cod)?)?|ModernWarfare(?:II|III)?)$') {
        throw 'Close Call of Duty and its game hub, then try again. No game processes are stopped automatically.'
    }
}

function Test-Mw4Path {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 1MB -or ($item.Attributes -band [IO.FileAttributes]::ReadOnly)) { return $false }
    while ($item) {
        if ($item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Offline)) { return $false }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
    return $true
}

function Get-Mw4Files {
    foreach ($root in Get-Mw4Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $root -File -Force | Where-Object {
            $_.Name -match '^(?:s\.\d+(?:\.\d+)*\.cod\d+\.txt[01]?|options\.\d+\.cod\d+\.cst)$'
        } | Sort-Object Name
    }
}

function Convert-Mw4Config {
    param([string]$Text, [bool]$Nvidia)
    # Values come from the game's descriptions/ranges. Keep lower existing quality levels.
    $rules = @{
        VSync=@('disabled'); CapFps=@('false')
        DLSSFrameGeneration=@('false'); FSRFrameInterpolation=@('false'); IntelXeFG=@('false')
        DxrMode=@('Off'); MotionBlur=@('Off'); WeaponMotionBlur=@('false'); EnableVelocityBasedBlur=@('false')
        DofEnable=@('Off'); DofWeaponDisable=@('true'); DofWorldDisable=@('true'); FilmGrain=@('0')
        ShadowQuality=@('Low','Very_Low'); ShadowFilteringQuality=@('Low'); TerrainQuality=@('Low','Very Low')
    }
    if ($Nvidia) { $rules.NvidiaReflex=@('Enabled + boost') }
    $changes = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[string]]::new()
    $found = [Collections.Generic.List[string]]::new()
    $pattern = '(?m)^(?<prefix>[ \t]*(?<key>\w+)(?:@[0-9;]+|:[0-9.]+)[ \t]*=[ \t]*)(?<value>[^\r\n]*?)(?<suffix>[ \t]*(?://[^\r\n]*)?)(?=\r?$)'
    $converted = [regex]::Replace($Text, $pattern, [Text.RegularExpressions.MatchEvaluator]{param($m)
        $key = $m.Groups['key'].Value
        if (-not $rules.ContainsKey($key)) { return $m.Value }
        $found.Add($key)
        $raw = $m.Groups['value'].Value
        $quoted = $raw.StartsWith('"') -and $raw.EndsWith('"')
        $current = if ($quoted) { $raw.Substring(1,$raw.Length-2) } else { $raw }
        $target = $rules[$key][0]
        if ($current -cin $rules[$key]) { return $m.Value }
        $comment = $m.Groups['suffix'].Value
        $compatible = $false
        if ($comment -match '//\s*one of (.+)$') {
            $allowed = @($Matches[1] -split ',\s*' | ForEach-Object { $_.Trim().Trim('"') })
            $compatible = $target -cin $allowed -and $current -cin $allowed
        } elseif ($target -in @('true','false')) {
            $compatible = $current -cin @('true','false')
        } elseif ($key -eq 'FilmGrain' -and $comment -match '//\s*0(?:\.0+)? to 1(?:\.0+)?\s*$') {
            $number = 0.0
            $compatible = [double]::TryParse($current,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -and $number -ge 0 -and $number -le 1
        }
        if (-not $compatible) { $skipped.Add($key); return $m.Value }
        $changes.Add([pscustomobject]@{Key=$key;Before=$current;After=$target})
        if ($quoted) { $target = '"'+$target+'"' }
        return $m.Groups['prefix'].Value + $target + $m.Groups['suffix'].Value
    })
    [pscustomobject]@{Text=$converted;Changes=@($changes.ToArray());Skipped=$skipped.Count;Compatible=$found.Count-$skipped.Count}
}

function Get-Mw4Hash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','') }
    finally { $sha.Dispose() }
}

function Get-Mw4Encoding {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        return [pscustomobject]@{Encoding=[Text.UnicodeEncoding]::new($false,$true,$true);Offset=2}
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        return [pscustomobject]@{Encoding=[Text.UnicodeEncoding]::new($true,$true,$true);Offset=2}
    }
    $bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191
    [pscustomobject]@{Encoding=[Text.UTF8Encoding]::new($bom,$true);Offset=$(if ($bom) {3} else {0})}
}

function Set-Mw4File {
    param([string]$Path, [string]$ExpectedHash, [byte[]]$Bytes)
    if (-not (Test-Mw4Path $Path)) { throw 'Config is read-only, linked, offline, or too large; left unchanged.' }
    Assert-Mw4Closed
    if ((Get-Mw4Hash ([IO.File]::ReadAllBytes($Path))) -ne $ExpectedHash) { throw 'Config changed since it was read; left unchanged.' }
    $temporary = $Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        [IO.File]::Replace($temporary,$Path,[NullString]::Value)
        if ((Get-Mw4Hash ([IO.File]::ReadAllBytes($Path))) -ne (Get-Mw4Hash $Bytes)) { throw 'Config read-back did not match.' }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Open-Mw4Driver {
    if (-not ('OptimizerNvidia' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'optimizer-nvidia.cs') }
    [OptimizerNvidia]::new()
}

function Get-Mw4DriverPlan {
    param($Driver, [string[]]$Apps)
    $seen = @{}
    foreach ($app in $Apps) {
        $profile = $Driver.FindProfile($app)
        if ($profile -eq [IntPtr]::Zero) {
            Write-OperationResult Unsupported "MW4 NVIDIA $app" 'No matching application profile in this driver; left unchanged.'
            continue
        }
        if ($seen.ContainsKey($profile.ToString())) { continue }
        $seen[$profile.ToString()] = $true
        # Public NvApiDriverSettings.h IDs: V-Sync, frame limiter, preferred refresh rate.
        foreach ($setting in @(
            @{Id=0x00A879CF;Value=0x08416747;Name='V-Sync off'},
            @{Id=0x10835002;Value=0;Name='Frame limiter off'},
            @{Id=0x0064B541;Value=1;Name='Highest available refresh rate'}
        )) {
            try {
                $old = $Driver.Read($profile,$setting.Id)
                if ($null -eq $old) {
                    Write-OperationResult Unsupported "MW4 NVIDIA $app $($setting.Name)" 'Setting is unavailable.'
                } elseif ($old.Data -eq $setting.Value) {
                    Write-OperationResult AlreadyConfigured "MW4 NVIDIA $app $($setting.Name)" 'Requested driver value is already present.' $true
                } else {
                    [pscustomobject]@{App=$app;Id=$setting.Id;Name=$setting.Name;Before=$old.Data;UserOverride=$old.UserOverride;After=$setting.Value}
                }
            } catch [NotSupportedException] { Write-OperationResult Unsupported "MW4 NVIDIA $app $($setting.Name)" $_.Exception.Message }
        }
    }
}

function Get-Mw4BackupRoot { Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'mw4-backups' }

function Invoke-Mw4Optimization {
    Assert-Mw4Closed
    Write-Host '  MW4 / WARZONE - COMPETITIVE' -ForegroundColor Cyan
    Write-Host '  Prioritizes input latency; tearing and increased GPU power use are possible.'
    $files = @(Get-Mw4Files)
    if (-not $files.Count) {
        Write-Host '  No game configs found. Start the game once, close it, then try again.' -ForegroundColor Yellow
        Write-OperationResult Unsupported 'MW4 game configs' 'No retail Call of Duty config found in LocalAppData or Documents.'
        return
    }
    $nvidia = [bool]@(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' }).Count
    $plans = @()
    foreach ($file in $files) {
        try {
            if (-not (Test-Mw4Path $file.FullName)) {
                Write-OperationResult Unsupported "MW4 config $($file.Name)" 'Read-only, linked, offline, or oversized config; left unchanged.'
                continue
            }
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $encoding = Get-Mw4Encoding $bytes
            $text = $encoding.Encoding.GetString($bytes,$encoding.Offset,$bytes.Length-$encoding.Offset)
            $converted = Convert-Mw4Config $text $nvidia
            if ($converted.Skipped) { Write-OperationResult Unsupported "MW4 config $($file.Name)" "$($converted.Skipped) settings had an incompatible value/range and were preserved." }
            if (-not $converted.Changes.Count) {
                if ($converted.Compatible) {
                    Write-OperationResult AlreadyConfigured "MW4 config $($file.Name)" 'No compatible setting needs changing.' $true
                } elseif (-not $converted.Skipped) {
                    Write-OperationResult Unsupported "MW4 config $($file.Name)" 'No compatible preset settings found; left unchanged.'
                }
                continue
            }
            [byte[]]$updated = $encoding.Encoding.GetPreamble() + $encoding.Encoding.GetBytes($converted.Text)
            $plans += [pscustomobject]@{Path=$file.FullName;Original=$bytes;Updated=$updated;Changes=$converted.Changes}
        } catch { Write-OperationResult Failed "MW4 config $($file.Name)" $_.Exception.Message }
    }
    $driver = $null
    $driverPlan = @()
    try {
        if ($nvidia) {
            try {
                $driver = Open-Mw4Driver
                $apps = @('cod.exe') + @($files | ForEach-Object {
                    if ($_.Name -match '\.(cod\d+)\.') { $Matches[1]+'-cod.exe' }
                } | Select-Object -Unique)
                $driverPlan = @(Get-Mw4DriverPlan $driver $apps)
            } catch [NotSupportedException] { Write-OperationResult Unsupported 'MW4 NVIDIA driver' $_.Exception.Message }
              catch { Write-OperationResult Failed 'MW4 NVIDIA driver' $_.Exception.Message }
        }
        if (-not $plans.Count -and -not $driverPlan.Count) {
            Write-Host '  No further compatible changes to apply. See the summary for skipped items.'
            return
        }
        Assert-Mw4Closed
        $backup = Join-Path (Get-Mw4BackupRoot) ((Get-Date -Format 'yyyyMMdd_HHmmss_fffffff')+'_'+[guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $backup
        $manifest = [ordered]@{Files=@();Driver=$driverPlan}
        foreach ($plan in $plans) {
            $name = [string]$manifest.Files.Count+'-'+[IO.Path]::GetFileName($plan.Path)+'.bak'
            [IO.File]::WriteAllBytes((Join-Path $backup $name),$plan.Original)
            if ((Get-Mw4Hash ([IO.File]::ReadAllBytes((Join-Path $backup $name)))) -ne (Get-Mw4Hash $plan.Original)) { throw 'Backup verification failed; no game changes applied.' }
            $manifest.Files += @{Path=$plan.Path;Backup=$name;Before=(Get-Mw4Hash $plan.Original);After=(Get-Mw4Hash $plan.Updated)}
        }
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
        Write-Host '  Backup saved. Use Recovery > Restore MW4 / Warzone settings to undo.' -ForegroundColor DarkGray
        foreach ($plan in $plans) {
            try {
                Set-Mw4File $plan.Path (Get-Mw4Hash $plan.Original) $plan.Updated
                foreach ($change in $plan.Changes) {
                    Write-OperationResult Applied "MW4 config $([IO.Path]::GetFileName($plan.Path)) $($change.Key)" "$($change.Before) -> $($change.After). Backup: $backup" $true
                }
            } catch { Write-OperationResult Failed "MW4 config $([IO.Path]::GetFileName($plan.Path))" $_.Exception.Message }
        }
        foreach ($change in $driverPlan) {
            try {
                Assert-Mw4Closed
                $profile = $driver.FindProfile($change.App)
                $now = $driver.Read($profile,$change.Id)
                if ($null -eq $now -or $now.Data -ne $change.Before -or $now.UserOverride -ne $change.UserOverride) { throw 'Driver setting changed since backup; left unchanged.' }
                $driver.Write($profile,$change.Id,$change.After)
                $driver.Save()
                $driver.Reload()
                $actual = $driver.Read($driver.FindProfile($change.App),$change.Id)
                if ($null -eq $actual -or $actual.Data -ne $change.After) { throw 'Driver read-back did not match.' }
                Write-OperationResult Applied "MW4 NVIDIA $($change.App) $($change.Name)" "Saved and verified. Backup: $backup" $true
            } catch [NotSupportedException] { $driver.Reload(); Write-OperationResult Unsupported "MW4 NVIDIA $($change.Name)" $_.Exception.Message }
              catch { $driver.Reload(); Write-OperationResult Failed "MW4 NVIDIA $($change.Name)" $_.Exception.Message }
        }
        Write-Host '  Game-file and driver values checked; FPS gains require an in-game benchmark.'
    } finally { if ($driver) { $driver.Dispose() } }
}

function Restore-Mw4Optimization {
    Assert-Mw4Closed
    $root = Get-Mw4BackupRoot
    $latest = if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending | Select-Object -First 1
    }
    if (-not $latest) { Write-Host '  No MW4 / Warzone backup found.' -ForegroundColor Yellow; return }
    $manifest = Get-Content -LiteralPath (Join-Path $latest.FullName 'manifest.json') -Raw | ConvertFrom-Json
    $allowed = @(Get-Mw4Files | ForEach-Object FullName)
    foreach ($file in $manifest.Files) {
        try {
            if ($file.Path -notin $allowed -or $file.Backup -ne [IO.Path]::GetFileName($file.Backup)) { throw 'Backup target is not an existing game config.' }
            $bytes = [IO.File]::ReadAllBytes((Join-Path $latest.FullName $file.Backup))
            if ((Get-Mw4Hash $bytes) -ne $file.Before) { throw 'Backup integrity check failed.' }
            $current = Get-Mw4Hash ([IO.File]::ReadAllBytes($file.Path))
            if ($current -eq $file.Before) {
                Write-OperationResult AlreadyConfigured "MW4 restore $([IO.Path]::GetFileName($file.Path))" 'Original config is already present.' $true
            } else {
                Set-Mw4File $file.Path $file.After $bytes
                Write-OperationResult Applied "MW4 restore $([IO.Path]::GetFileName($file.Path))" 'Original config restored and verified.' $true
            }
        } catch { Write-OperationResult Failed "MW4 restore $([IO.Path]::GetFileName($file.Path))" $_.Exception.Message }
    }
    $driver = $null
    try {
        if (@($manifest.Driver).Count) { $driver = Open-Mw4Driver }
        foreach ($change in $manifest.Driver) {
            try {
                # The manifest may only restore the three DWORD settings owned by this preset.
                if ($change.App -notmatch '^cod(?:\d+-cod)?\.exe$' -or $change.Id -notin @(0x00A879CF,0x10835002,0x0064B541)) { throw 'Unrecognized driver backup entry.' }
                $profile = $driver.FindProfile($change.App)
                if ($profile -eq [IntPtr]::Zero) { throw 'Original application profile is no longer available.' }
                $now = $driver.Read($profile,$change.Id)
                if ($now -and $now.Data -eq $change.Before -and $now.UserOverride -eq $change.UserOverride) {
                    Write-OperationResult AlreadyConfigured "MW4 restore NVIDIA $($change.Name)" 'Original driver value is already present.' $true
                    continue
                }
                if (-not $now -or $now.Data -ne $change.After -or -not $now.UserOverride) { throw 'Driver setting changed after optimization; left unchanged.' }
                Assert-Mw4Closed
                if ($change.UserOverride) { $driver.Write($profile,$change.Id,$change.Before) }
                else { $driver.Reset($profile,$change.Id) }
                $driver.Save()
                $driver.Reload()
                $actual = $driver.Read($driver.FindProfile($change.App),$change.Id)
                if ($change.UserOverride) {
                    if (-not $actual -or -not $actual.UserOverride -or $actual.Data -ne $change.Before) { throw 'Driver restore read-back did not match.' }
                } elseif ($actual -and $actual.UserOverride) { throw 'Driver override was not removed.' }
                Write-OperationResult Applied "MW4 restore NVIDIA $($change.Name)" 'Original driver override/inheritance restored.' $true
            } catch { if ($driver) { $driver.Reload() }; Write-OperationResult Failed "MW4 restore NVIDIA $($change.Name)" $_.Exception.Message }
        }
    } finally { if ($driver) { $driver.Dispose() } }
}
