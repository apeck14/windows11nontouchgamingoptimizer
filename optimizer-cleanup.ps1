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
        if (Test-Path -LiteralPath $root.Path -PathType Container) { $pending.Push($root.Path) }
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
            [pscustomobject]@{Path=$downloads; Category='Old download - review'; Days=90; Extensions=@('.exe','.msi','.msix','.zip','.7z','.rar','.iso')}
        }
        [pscustomobject]@{Path=(Join-Path $env:LOCALAPPDATA 'CrashDumps'); Category='Old crash dump'; Days=30; Extensions=@('.dmp')}
        $videos = [Environment]::GetFolderPath('MyVideos')
        if ($videos) {
            [pscustomobject]@{Path=(Join-Path $videos 'Captures'); Category='Old recording - review'; Days=90; Extensions=@('.mp4','.mkv','.wmv')}
        }
    }
}

function Test-CleanupPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    if ($drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS') { return $false }
    foreach ($protected in @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial)) {
        if ($protected -and ($full.TrimEnd('\') -ieq $protected.TrimEnd('\') -or $full.StartsWith($protected.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))) { return $false }
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($item) {
        # Reparse points, offline content and cloud recall placeholders are excluded.
        if ([long]$item.Attributes -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) { return $false }
        $item = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
    }
    return $true
}

function Get-CleanupCandidates([string]$Scope) {
    foreach ($root in @(Get-CleanupRoots $Scope)) {
        if (-not (Test-Path -LiteralPath $root.Path -PathType Container)) { continue }
        if (-not (Test-CleanupPath $root.Path)) { continue }
        $cutoff = (Get-Date).AddDays(-$root.Days)
        # Enumerate ourselves so recursion never enters a junction or cloud folder.
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($root.Path)
        while ($pending.Count) {
            foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-CleanupPath $item.FullName)) { continue }
                if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
                if ($item.LastWriteTime -ge $cutoff -or ($root.Extensions -and $item.Extension -notin $root.Extensions)) { continue }
                [pscustomobject]@{Category=$root.Category; MB=[math]::Round($item.Length/1MB,2); Modified=$item.LastWriteTime; Path=$item.FullName; Bytes=$item.Length}
            }
        }
    }
}

function Show-AppInventory {
    $paths = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $apps = @(Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Select-Object @{n='App';e={$_.DisplayName}},Publisher,@{n='EstimatedMB';e={[math]::Round($_.EstimatedSize/1024,1)}})
    $apps += @(Get-AppxPackage -ErrorAction Stop | Select-Object @{n='App';e={$_.Name}},Publisher,@{n='EstimatedMB';e={$null}})
    Write-Host 'Installed apps are listed for review only; installed applications cannot be recycled safely.'
    $apps | Sort-Object App -Unique | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
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
    $files = @(Get-CleanupCandidates $Scope | Sort-Object Path -Unique)
    if ($Scope -eq 'Deep') {
        Show-StorageSummary
        Show-AppInventory
        if ($files.Count) { $files = @($files | Out-GridView -Title 'Select files to recycle, then click OK. Nothing is preselected.' -PassThru) }
    }
    if (-not $files.Count) { Write-OperationResult AlreadyConfigured 'Recycle cleanup' 'No eligible files selected.'; return }
    $failed = $false
    foreach ($file in $files) {
        try {
            $current = Get-Item -LiteralPath $file.Path -Force -ErrorAction Stop
            if ($current.Length -ne $file.Bytes -or $current.LastWriteTime -ne $file.Modified) { throw 'File changed after scanning; skipped.' }
            Move-CleanupFileToRecycleBin $file.Path
            Write-OperationResult Applied ('Recycle '+$file.Path) 'Shell recycling completed; original path is absent.' $true
        } catch {
            $failed = $true
            Write-OperationResult Failed ('Recycle '+$file.Path) $_.Exception.Message
        }
    }
    if ($failed) { throw 'Some files could not be recycled. No permanent-delete fallback was attempted.' }
}
