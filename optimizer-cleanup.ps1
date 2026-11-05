# Loaded by optimizer-operations.ps1. File cleanup has no permanent-delete path.
function Initialize-RecycleApi {
    if ('OptimizerRecycle' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OptimizerRecycle {
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem {}
    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOperation {
        void Advise(IntPtr sink, out uint cookie);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr properties);
        void SetOwnerWindow(uint window);
        void ApplyPropertiesToItem(IShellItem item);
        void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void MoveItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void MoveItems(IntPtr items, IShellItem destination);
        void CopyItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void CopyItems(IntPtr items, IShellItem destination);
        void DeleteItem(IShellItem item, IntPtr sink);
        void DeleteItems(IntPtr items);
        void NewItem(IShellItem destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name,
            [MarshalAs(UnmanagedType.LPWStr)] string template, IntPtr sink);
        void PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IShellItem item);
    public static void File(string path) {
        IFileOperation operation=null; IShellItem item=null;
        try {
            operation=(IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("3AD05575-8857-4850-9277-11B85BDB8E09")));
            // Recycle, record undo, fail on errors, never silently confirm permanent deletion.
            operation.SetOperationFlags(0x00080000 | 0x20000000 | 0x00100000 | 0x0400 | 0x4000 | 0x0004);
            Guid iid=new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item);
            operation.DeleteItem(item, IntPtr.Zero);
            operation.PerformOperations();
            bool aborted; operation.GetAnyOperationsAborted(out aborted);
            if(aborted) throw new InvalidOperationException("Recycling was cancelled or failed; no permanent-delete retry.");
        } finally {
            if(item!=null) Marshal.FinalReleaseComObject(item);
            if(operation!=null) Marshal.FinalReleaseComObject(operation);
        }
    }
}
'@
}

function Get-DownloadsFolder {
    $shell = New-Object -ComObject Shell.Application
    try { $shell.Namespace('shell:Downloads').Self.Path }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
}

function Get-StorageRoots {
    foreach ($pair in @(@('Pictures','MyPictures'),@('Videos','MyVideos'),@('Music','MyMusic'),@('Documents','MyDocuments'),@('Desktop','DesktopDirectory'))) {
        $path = [Environment]::GetFolderPath($pair[1])
        if ($path) { [pscustomobject]@{Category=$pair[0];Path=$path} }
    }
    $downloads = Get-DownloadsFolder
    if ($downloads) { [pscustomobject]@{Category='Downloads';Path=$downloads} }
    foreach ($path in @($env:ProgramFiles,${env:ProgramFiles(x86)},(Join-Path $env:LOCALAPPDATA 'Programs')) | Select-Object -Unique) {
        if ($path) { [pscustomobject]@{Category='Apps';Path=$path} }
    }
    foreach ($path in @($env:LOCALAPPDATA,$env:APPDATA)) {
        if ($path) { [pscustomobject]@{Category='App data & caches';Path=$path} }
    }
}

function Measure-StorageRoots($Roots) {
    $roots = @($Roots | Where-Object { $_.Path -and [IO.Path]::IsPathRooted($_.Path) } |
        ForEach-Object { [pscustomobject]@{Category=$_.Category;Path=[IO.Path]::GetFullPath($_.Path).TrimEnd('\')} } |
        Sort-Object Path -Unique)
    foreach ($root in $roots) {
        Write-Host ("Measuring {0}: {1}" -f $root.Category,$root.Path)
        [long]$bytes = 0; $partial = $false
        $pending = [Collections.Generic.Stack[string]]::new()
        try {
            $directory = Get-Item -LiteralPath $root.Path -Force -ErrorAction Stop
            if (-not $directory.PSIsContainer -or ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($root.Path))).DriveType -ne 'Fixed') { throw 'Not a local folder.' }
            for ($ancestor=$directory; $ancestor; $ancestor=$ancestor.Parent) {
                if ([long]$ancestor.Attributes -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) { throw 'Linked or cloud path.' }
            }
            $pending.Push($root.Path)
        } catch { $partial=$true }
        while ($pending.Count) {
            $path = $pending.Pop()
            try {
                $directory = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ([long]$directory.Attributes -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) { $partial=$true; continue }
                foreach ($item in Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop) {
                    if ([long]$item.Attributes -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) { $partial=$true; continue }
                    if ($item.PSIsContainer) {
                        # Nested known folders are measured in their own category, once.
                        if ($item.FullName.TrimEnd('\') -notin $roots.Path) { $pending.Push($item.FullName) }
                    } else { $bytes += $item.Length }
                }
            } catch { $partial=$true }
        }
        [pscustomobject]@{Category=$root.Category;Path=$root.Path;Bytes=$bytes;Partial=$partial}
    }
}

function Show-StorageSummary {
    Write-Host "`nSTORAGE OVERVIEW - current usage, before emptying the Recycle Bin"
    [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        Select-Object @{n='Drive';e={$_.Name}},@{n='Used GB';e={[math]::Round(($_.TotalSize-$_.TotalFreeSpace)/1GB,2)}},
            @{n='Free GB';e={[math]::Round($_.AvailableFreeSpace/1GB,2)}},@{n='Total GB';e={[math]::Round($_.TotalSize/1GB,2)}} |
        Format-Table -AutoSize | Out-String | Write-Host
    $usage = @(Measure-StorageRoots @(Get-StorageRoots))
    $usage | Group-Object Category | ForEach-Object {
        [pscustomobject]@{Category=$_.Name; 'Used GB (estimate)'=[math]::Round(($_.Group | Measure-Object Bytes -Sum).Sum/1GB,2);
            Coverage=if ($_.Group.Partial -contains $true) {'Partial'} else {'Scanned'};
            'Investigate folders'=($_.Group.Path -join '; ')}
    } | Sort-Object 'Used GB (estimate)' -Descending | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    Write-Host 'Category sizes are file-size estimates, not additive disk totals. Windows, other users, custom app/game libraries and the Recycle Bin are not categorized.'
    Write-Host 'Links, cloud placeholders and inaccessible folders are skipped. For a complete breakdown, open Settings > System > Storage.'
}

function Get-CleanupRoots([string]$Scope) {
    [pscustomobject]@{Path=(Join-Path $env:LOCALAPPDATA 'Temp'); Category='Old temporary file'; Days=30; Extensions=$null}
    if ($Scope -eq 'Deep') {
        $downloads = Get-DownloadsFolder
        if ($downloads) {
            [pscustomobject]@{Path=$downloads; Category='Old download - review'; Days=90; Extensions=@('.exe','.msi','.msix','.msixbundle','.appx','.appxbundle','.cab','.msp','.zip','.7z','.rar','.iso')}
        }
        [pscustomobject]@{Path=(Join-Path $env:LOCALAPPDATA 'CrashDumps'); Category='Old crash dump'; Days=30; Extensions=@('.dmp')}
        foreach ($path in @($env:LOCALAPPDATA,$env:ProgramData)) {
            [pscustomobject]@{Path=(Join-Path $path 'Microsoft\Windows\WER\ReportArchive'); Category='Archived crash report - review'; Days=30; Extensions=$null}
        }
        $videos = [Environment]::GetFolderPath('MyVideos')
        if ($videos) {
            [pscustomobject]@{Path=(Join-Path $videos 'Captures'); Category='Old recording - review'; Days=90; Extensions=@('.mp4','.mkv','.wmv')}
        }
    }
}

function Test-CleanupPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in @([IO.Path]::GetPathRoot($full),$env:USERPROFILE,$env:PUBLIC,$env:LOCALAPPDATA,$env:APPDATA)) {
        if ($root -and $full.TrimEnd('\') -ieq $root.TrimEnd('\')) { return $false }
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    if ($drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS') { return $false }
    $archive = Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'
    $inArchive = $full.StartsWith($archive+'\',[StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\') -ieq $archive
    $protectedPaths = @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial)
    if (-not $inArchive) { $protectedPaths += $env:ProgramData }
    foreach ($protected in $protectedPaths) {
        if ($protected -and ($full.TrimEnd('\') -ieq $protected.TrimEnd('\') -or $full.StartsWith($protected.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))) { return $false }
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    while ($item) {
        # Reparse points, offline content and cloud recall placeholders are excluded.
        if ([long]$item.Attributes -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) { return $false }
        $item = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
    }
    return $true
}

function Get-CleanupCandidates([string]$Scope) {
    Get-CleanupFiles @(Get-CleanupRoots $Scope)
}

function Get-CleanupFiles($Roots) {
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root.Path -PathType Container)) { continue }
        if (-not (Test-CleanupPath $root.Path)) { continue }
        $cutoff = (Get-Date).AddDays(-$root.Days)
        # Enumerate ourselves so recursion never enters a junction or cloud folder.
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($root.Path)
        while ($pending.Count) {
            try { $items=@(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) }
            catch { if ($root.PackageRoot) { throw }; continue }
            foreach ($item in $items) {
                if (-not (Test-CleanupPath $item.FullName)) {
                    if ($root.PackageRoot) { throw 'Driver package contains an inaccessible or linked path.' }
                    continue
                }
                if ($item.PSIsContainer) { if (-not $root.LooseOnly) { $pending.Push($item.FullName) }; continue }
                if (($null -ne $root.Days -and $item.LastWriteTime -ge $cutoff) -or ($root.Extensions -and $item.Extension -notin $root.Extensions)) { continue }
                if ($root.Automatic -and $item.CreationTime -ge $cutoff) { continue }
                [pscustomobject]@{Category=$root.Category; MB=[math]::Round($item.Length/1MB,2); Modified=$item.LastWriteTime; Created=$item.CreationTime; Path=$item.FullName; Bytes=$item.Length; Processes=$root.Processes; PackageRoot=$root.PackageRoot}
            }
        }
    }
}

function Test-CleanupBusy($Processes, [string]$PackageRoot) {
    if (-not $Processes -and -not $PackageRoot) { return $false }
    foreach ($process in Get-Process -ErrorAction Stop) {
        if ($process.ProcessName -in $Processes) { return $true }
        if ($PackageRoot -and $process.Path -and $process.Path.StartsWith($PackageRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-AutomaticCleanupRoots {
    $browsers=@('chrome','msedge','brave','firefox','opera','vivaldi')
    $downloads=Get-DownloadsFolder
    if ($downloads) {
        [pscustomobject]@{Path=$downloads;Category='Abandoned download';Days=30;Extensions=@('.crdownload','.part');LooseOnly=$true;Automatic=$true;Processes=$browsers}
    }
    foreach ($app in @(
        @($env:LOCALAPPDATA,'Google\Chrome\User Data\Crashpad\reports','chrome'),
        @($env:LOCALAPPDATA,'Microsoft\Edge\User Data\Crashpad\reports','msedge'),
        @($env:LOCALAPPDATA,'BraveSoftware\Brave-Browser\User Data\Crashpad\reports','brave'),
        @($env:APPDATA,'Mozilla\Firefox\Crash Reports','firefox'),
        @($env:APPDATA,'discord\Crashpad\reports','Discord'),
        @($env:APPDATA,'discordcanary\Crashpad\reports','DiscordCanary'),
        @($env:APPDATA,'discordptb\Crashpad\reports','DiscordPTB')
    )) {
        [pscustomobject]@{Path=(Join-Path $app[0] $app[1]);Category='Old application crash report';Days=30;Extensions=@('.dmp','.extra','.txt');Automatic=$true;Processes=@($app[2])}
    }
    $profiles=Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    if (Test-CleanupPath $profiles) {
        foreach ($profile in Get-ChildItem -LiteralPath $profiles -Directory) {
            [pscustomobject]@{Path=(Join-Path $profile.FullName 'minidumps');Category='Old application crash report';Days=30;Extensions=@('.dmp','.extra');Automatic=$true;Processes=@('firefox')}
        }
    }
}

function Get-DriverExtractionRoots {
    foreach ($vendor in @('AMD','NVIDIA')) {
        [pscustomobject]@{Path=(Join-Path $env:SystemDrive $vendor);Vendor=$vendor}
    }
}

function Get-OldDriverExtractionFiles {
    $processes=@('setup','msiexec','AMDSoftwareInstaller','InstallManagerApp','NVIDIAInstaller','NVI2')
    foreach ($root in Get-DriverExtractionRoots) {
        if (-not (Test-CleanupPath $root.Path) -or (Test-CleanupBusy $processes $root.Path)) { continue }
        $packages=@(foreach ($folder in Get-ChildItem -LiteralPath $root.Path -Directory) {
            try {
                if (-not (Test-CleanupPath $folder.FullName)) { continue }
                $setup=Join-Path $folder.FullName 'Setup.exe'
                $drivers=Join-Path $folder.FullName $(if ($root.Vendor -eq 'AMD') {'Packages\Drivers\Display'} else {'Display.Driver'})
                if (-not (Test-CleanupPath $setup) -or -not (Test-CleanupPath $drivers)) { continue }
                $signature=Get-AuthenticodeSignature -LiteralPath $setup
                $publisher=if ($root.Vendor -eq 'AMD') {'Advanced Micro Devices'} else {'NVIDIA Corporation'}
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch [regex]::Escape($publisher)) { continue }
                $spec=[pscustomobject]@{Path=$folder.FullName;Category='Old extracted driver installer';Days=$null;Processes=$processes;PackageRoot=$folder.FullName}
                $files=@(Get-CleanupFiles @($spec))
                if (-not @($files | Where-Object { $_.Path.StartsWith($drivers+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($_.Path) -eq '.inf' }).Count) { continue }
                [pscustomobject]@{Files=$files;Newest=($files | ForEach-Object {$_.Modified; $_.Created} | Sort-Object -Descending | Select-Object -First 1);Path=$folder.FullName}
            } catch { continue }
        })
        # Retain the most recent recognized package, even when every package is old.
        foreach ($package in @($packages | Sort-Object Newest,Path -Descending | Select-Object -Skip 1)) {
            if ($package.Newest -lt (Get-Date).AddDays(-30)) { $package.Files }
        }
    }
}

function Get-AutomaticCleanupFiles {
    foreach ($root in Get-AutomaticCleanupRoots) {
        if (-not (Test-CleanupBusy $root.Processes '')) { Get-CleanupFiles @($root) }
    }
    Get-OldDriverExtractionFiles
}

function Get-CleanupHash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        # Compare all NTFS data, including metadata/custom alternate streams.
        $parts = @(foreach ($entry in @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop | Sort-Object Stream)) {
            $source = if ($entry.Stream -eq ':$DATA') { $Path } else { '\\?\'+$Path+':'+$entry.Stream }
            $stream = [IO.File]::OpenRead($source)
            try { $entry.Stream+':'+[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
            finally { $stream.Dispose() }
        })
        if (-not $parts.Count) { throw 'No readable file streams.' }
        [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`0")))).Replace('-','')
    } finally { $sha.Dispose() }
}

function Get-DuplicateDownloads {
    $downloads = Get-DownloadsFolder
    if (-not $downloads -or -not (Test-Path -LiteralPath $downloads -PathType Container) -or -not (Test-CleanupPath $downloads)) { return }
    # Only loose downloads: never deduplicate inside extracted/portable applications.
    $files = @(Get-ChildItem -LiteralPath $downloads -File -ErrorAction Stop | Where-Object {
        $_.Length -gt 0 -and $_.Extension -in @('.exe','.msi','.msix','.msixbundle','.appx','.appxbundle','.cab','.msp','.zip','.7z','.rar','.iso') -and (Test-CleanupPath $_.FullName)
    })
    foreach ($size in @($files | Group-Object Length,Extension | Where-Object Count -gt 1)) {
        $hashed = @(foreach ($file in $size.Group) {
            try {
                [pscustomobject]@{File=$file;Hash=(Get-CleanupHash $file.FullName)}
            } catch { Write-Warning "Could not compare $($file.FullName): $_" }
        })
        foreach ($group in @($hashed | Group-Object Hash | Where-Object Count -gt 1)) {
            $copies = @($group.Group | Sort-Object {$_.File.CreationTimeUtc},{$_.File.Name})
            $keeper = $copies[0].File.FullName
            foreach ($copy in $copies | Select-Object -Skip 1) {
                [pscustomobject]@{Path=$copy.File.FullName;Bytes=$copy.File.Length;Modified=$copy.File.LastWriteTime;KeepPath=$keeper;Hash=$copy.Hash}
            }
        }
    }
}

function Get-AppInventory {
    $paths = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $apps = @(Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Select-Object @{n='App';e={$_.DisplayName}},@{n='Path';e={$_.InstallLocation}})
    $apps += @(Get-AppxPackage -ErrorAction Stop | Select-Object @{n='App';e={$_.Name}},@{n='Path';e={$_.InstallLocation}})
    $apps | Sort-Object App,Path -Unique
}

function Show-AppInventory {
    $apps = @(Get-AppInventory)
    Write-Host 'Installed apps are listed for review only; installed applications cannot be recycled safely.'
    $roots = @(foreach ($base in @(Get-StorageRoots | Where-Object Category -eq 'Apps')) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $base.Path -Directory -ErrorAction SilentlyContinue)) {
            [pscustomobject]@{Category=$folder.Name;Path=$folder.FullName}
        }
    })
    Write-Host "`nLARGEST APPLICATION FOLDERS - measured estimates; shared folders may contain several apps"
    Measure-StorageRoots $roots | Sort-Object Bytes -Descending | Select-Object -First 15 | ForEach-Object {
        $folder = $_
        $names = @($apps | Where-Object { $_.Path -and ($_.Path.TrimEnd('\') -ieq $folder.Path -or $_.Path.StartsWith($folder.Path+'\',[StringComparison]::OrdinalIgnoreCase)) } | Select-Object -ExpandProperty App -Unique)
        [pscustomobject]@{Folder=$folder.Category;GB=[math]::Round($folder.Bytes/1GB,2);Apps=($names -join '; ');Partial=$folder.Partial;Path=$folder.Path}
    } | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
}

function Move-CleanupFileToRecycleBin([string]$Path) {
    # Recheck immediately before the operation, including all parent directories.
    if (-not (Test-CleanupPath $Path)) { throw 'File no longer passes cleanup safety checks.' }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer) { throw 'Only individual files can be recycled.' }
    $handle = [IO.File]::Open($Path,'Open','Read','None')
    $handle.Dispose()
    Initialize-RecycleApi
    [OptimizerRecycle]::File($Path)
    if (Test-Path -LiteralPath $Path) { throw 'File remains at its original path; recycling was not confirmed.' }
}

function Invoke-RecycleCleanup([string]$Scope) {
    if ($Scope -notin @('Safe','Deep')) { throw 'Unknown cleanup scope.' }
    Write-Host 'Files go to the Recycle Bin only. Space is not reclaimed until you empty it manually.'
    Write-Host 'Windows Storage Sense or other cleanup software may empty the bin independently.'
    $success = $true
    if ($Scope -eq 'Deep') {
        Show-StorageSummary
        Show-AppInventory
        Write-Host 'Automatically recycling identical loose installer/archive downloads; the oldest-created copy is kept.'
        $success = Invoke-RecycleFiles @(Get-DuplicateDownloads)
        Write-Host 'Automatically recycling old crash reports, abandoned downloads and older verified driver extractions; the newest driver package is kept.'
        if (-not (Invoke-RecycleFiles @(Get-AutomaticCleanupFiles))) { $success=$false }
    }
    $files = @(Get-CleanupCandidates $Scope | Sort-Object Path -Unique)
    if ($Scope -eq 'Deep') {
        if ($files.Count) { $files = @($files | Out-GridView -Title 'Select files to recycle, then click OK. Nothing is preselected.' -PassThru) }
    }
    if (-not $files.Count) { Write-OperationResult AlreadyConfigured 'Recycle cleanup' 'No other eligible files selected.' }
    elseif (-not (Invoke-RecycleFiles $files)) { $success=$false }
    if (-not $success) { throw 'Some files could not be recycled. No permanent-delete fallback was attempted.' }
}

function Invoke-RecycleFiles($Files) {
    $failed = $false
    foreach ($file in $Files) {
        $keeper = $null
        try {
            if (Test-CleanupBusy $file.Processes $file.PackageRoot) { throw 'Related application or installer is running; skipped.' }
            $current = Get-Item -LiteralPath $file.Path -Force -ErrorAction Stop
            if ($current.Length -ne $file.Bytes -or $current.LastWriteTime -ne $file.Modified) { throw 'File changed after scanning; skipped.' }
            if ($file.Created -and $current.CreationTime -ne $file.Created) { throw 'File was replaced after scanning; skipped.' }
            if ($file.KeepPath) {
                if ($file.Path -ieq $file.KeepPath -or -not (Test-CleanupPath $file.KeepPath)) { throw 'Retained copy is unavailable; skipped.' }
                # Hold the survivor against writes/deletion throughout recycling its duplicate.
                $keeper = [IO.File]::Open($file.KeepPath,'Open','Read','Read')
                if ((Get-CleanupHash $file.KeepPath) -ne $file.Hash -or
                    (Get-CleanupHash $file.Path) -ne $file.Hash) { throw 'Duplicate content changed; skipped.' }
            }
            Move-CleanupFileToRecycleBin $file.Path
            $detail = 'Shell recycling completed; original path is absent.'
            if ($file.KeepPath) { $detail += ' Retained identical copy: '+$file.KeepPath }
            Write-OperationResult Applied ('Recycle '+$file.Path) $detail $true $file.Bytes ([bool]$file.KeepPath)
        } catch {
            $failed = $true
            Write-OperationResult Failed ('Recycle '+$file.Path) $_.Exception.Message
        } finally { if ($keeper) { $keeper.Dispose() } }
    }
    return -not $failed
}
