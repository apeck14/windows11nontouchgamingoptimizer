"""Game config writes/undo use disposable files; NVIDIA mutations use a fake driver."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PS = str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')

SETUP = r'''
. $env:TEST_ENGINE -NoRun
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-mw4.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'players'
$script:fixtureRoot=$root
$null=New-Item -ItemType Directory -Path $root
function Get-Mw4Roots { $script:fixtureRoot }
function Assert-Mw4Closed {}
function Get-CimInstance { [pscustomobject]@{PNPDeviceID='PCI\VEN_1002'} }
function Open-Mw4Driver { throw 'Must not access the real NVIDIA driver' }
'''

DRIVER = r'''
class FakeDriver {
    [hashtable]$State=@{}
    [int]$Writes=0
    [int]$Resets=0
    [int]$Saves=0
    [bool]$SilentFailure=$false
    [bool]$FailSave=$false
    FakeDriver() {
        $this.State[0x00A879CF]=@{Data=1;UserOverride=$true}
        $this.State[0x10835002]=@{Data=60;UserOverride=$false}
        $this.State[0x0064B541]=@{Data=0;UserOverride=$false}
    }
    [IntPtr] FindProfile([string]$app) { return [IntPtr]1 }
    [object] Read([IntPtr]$p,[int]$id) { return $this.State[$id] }
    [void] Write([IntPtr]$p,[int]$id,[int]$v) {
        $this.Writes++
        if (-not $this.SilentFailure) { $this.State[$id]=@{Data=$v;UserOverride=$true} }
    }
    [void] Reset([IntPtr]$p,[int]$id) {
        $this.Resets++
        $value=if($id -eq 0x10835002){60}else{0}
        $this.State[$id]=@{Data=$value;UserOverride=$false}
    }
    [void] Save() { $this.Saves++; if($this.FailSave){throw 'Save failed'} }
    [void] Reload() {}
    [void] Dispose() {}
}
$script:fakeDriver=[FakeDriver]::new()
$driver=$script:fakeDriver
function Get-CimInstance { [pscustomobject]@{PNPDeviceID='PCI\VEN_10DE'} }
function Open-Mw4Driver { $script:fakeDriver }
'''


@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell required')
class Mw4Tests(unittest.TestCase):
    def run_case(self, body):
        with tempfile.TemporaryDirectory(prefix='mw4-tests-', dir=ROOT.parent) as folder:
            folder = Path(folder)
            script = folder/'case.ps1'
            script.write_text(SETUP+body, encoding='utf-8')
            env = os.environ.copy()
            env.update(TEST_ENGINE=str(ROOT/'optimizer-operations.ps1'),
                       OPTIMIZER_RESULTS=str(folder/'results.jsonl'), LOG_FILE=str(folder/'log.txt'))
            result = subprocess.run([PS, '-NoProfile', '-File', str(script)], env=env,
                                    capture_output=True, text=True, timeout=30)
            journal = folder/'results.jsonl'
            detail = journal.read_text(encoding='utf-8-sig') if journal.exists() else ''
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr+detail)
            return [json.loads(s) for s in journal.read_text(encoding='utf-8-sig').splitlines()] if journal.exists() else []

    def test_parser_compatible_only_preserves_format_preferences_and_is_idempotent(self):
        self.run_case(r'''
$text=@'
1
NvidiaReflex@0;12;99 = Enabled // one of Disabled, Enabled, Enabled + boost
NvidiaReflex@1;12;99 = Enabled // one of Disabled, Enabled
  DxrMode:0.0 = "On" // one of Off, On
DxrMode@1;1;1 = Ultra // one of Off, Low, Medium, High, Ultra
WeaponMotionBlur@0;1;1 = true
ShadowQuality@0;1;1 = Very_Low // one of Very_Low, Low, High
TerrainQuality@0;1;1 = High // one of Very Low, Low, Medium, High
FilmGrain@0;1;1 = 0.2 // 0.000000 to 1.000000
ResolutionMultiplier@0;1;1 = 75 // 0 to 200
TextureQuality@0;1;1 = 0 // 0 to 3
RendererWorkerCount@0;1;1 = 9 // -1 to 16
MouseSensitivity@0;1;1 = 2.7
ConfigCloudStorageEnabled@0;1;1 = true
Unknown@1;2;3 = $(throw 'Never evaluated')
'@
$text=$text.Replace("`r`n","`n").Replace("`n","`r`n")
$result=Convert-Mw4Config $text $true
if($result.Changes.Count -ne 6 -or $result.Skipped -ne 1){throw ('Incorrect compatible changes: '+($result | ConvertTo-Json -Depth 5))}
if($result.Text -notmatch '  DxrMode:0.0 = "Off" // one of Off, On'){throw 'Lost syntax'}
foreach($line in $text -split "`r`n" | Where-Object {$_ -match '^(Resolution|Texture|Renderer|Mouse|ConfigCloud|Unknown|ShadowQuality|NvidiaReflex@1)'}) {
    if(-not $result.Text.Contains($line)){throw "Modified protected line: $line"}
}
if((Convert-Mw4Config $result.Text $true).Text -cne $result.Text){throw 'Not idempotent'}
if((Convert-Mw4Config $text $false).Text -notmatch 'NvidiaReflex@0;12;99 = Enabled //'){throw 'Changed NVIDIA preference on AMD'}
''')

    def test_real_file_apply_backup_rerun_and_restore_preserve_bytes(self):
        rows = self.run_case(r'''
$original="1`r`nWeaponMotionBlur@0;1;1 = true`r`nCustom@0;1;1 = cafe`r`n"
foreach($pair in @(@('s.1.0.cod26.txt',[Text.UTF8Encoding]::new($false)),@('s.9.0.cod99.txt0',[Text.UTF8Encoding]::new($true)),@('options.4.cod22.cst',[Text.UnicodeEncoding]::new($false,$true)))) {
    [IO.File]::WriteAllText((Join-Path $root $pair[0]),$original,$pair[1])
}
$before=@{}
Get-Mw4Files | ForEach-Object {$before[$_.FullName]=Get-Mw4Hash ([IO.File]::ReadAllBytes($_.FullName))}
Invoke-Mw4Optimization
foreach($file in Get-Mw4Files) {if([IO.File]::ReadAllText($file.FullName) -cne $original.Replace('= true','= false')){throw 'Bad write'}}
$backups=@(Get-ChildItem (Get-Mw4BackupRoot) -Directory)
if($backups.Count -ne 1){throw 'No backup'}
Invoke-Mw4Optimization
if(@(Get-ChildItem (Get-Mw4BackupRoot) -Directory).Count -ne 1){throw 'No-op replaced backup'}
Restore-Mw4Optimization
Restore-Mw4Optimization
foreach($file in Get-Mw4Files) {if((Get-Mw4Hash ([IO.File]::ReadAllBytes($file.FullName))) -cne $before[$file.FullName]){throw 'Restore changed bytes/BOM'}}
''')
        self.assertEqual(sum(r['Status'] == 'Applied' for r in rows), 6)
        self.assertFalse(any(r['Status'] == 'Failed' for r in rows))

    def test_discovery_excludes_beta_backup_and_account_files(self):
        self.run_case(r'''
foreach($name in @('s.1.0.cod26.txt','s.1.0.cod25.txt0','s.1.0.cod25.txt1','s.3.1.cod99.txt','options.4.cod22.cst',
    's.1.0.bt.cod26.txt','s.1.0.cod26.txt.bak','s.1.0.cod26.txt.tmp','g.cod26.1.0.l.txt','notes.txt')) {
    Set-Content -LiteralPath (Join-Path $root $name) -Value 'irrelevant'
}
if(@(Get-Mw4Files).Count -ne 5){throw 'Discovery matched unrelated files or rejected future version'}
''')

    def test_readonly_files_and_post_apply_edits_are_preserved(self):
        rows = self.run_case(r'''
$path=Join-Path $root 's.1.0.cod26.txt'
[IO.File]::WriteAllText($path,'WeaponMotionBlur@0;1;1 = true')
(Get-Item $path).IsReadOnly=$true
try {Invoke-Mw4Optimization; if(Test-Path (Get-Mw4BackupRoot)){throw 'Read-only config was touched'}}
finally {(Get-Item $path).IsReadOnly=$false}
Invoke-Mw4Optimization
[IO.File]::AppendAllText($path,"`nNewUserPreference=1")
$hash=Get-Mw4Hash ([IO.File]::ReadAllBytes($path))
Restore-Mw4Optimization
if((Get-Mw4Hash ([IO.File]::ReadAllBytes($path))) -ne $hash){throw 'Overwrote newer user preferences'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Unsupported', 'Applied', 'Failed'])

    def test_running_game_blocks_all_writes(self):
        self.run_case(r'''
# Reload the real guard, but supply a process list instead of running any game.
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-mw4.ps1')
function Get-Process { [pscustomobject]@{ProcessName='cod26-cod'} }
function Get-Mw4Files { throw 'Must stop before scanning/mutating files' }
$blocked=$false
try {Invoke-Mw4Optimization} catch { $blocked=$_.Exception.Message -like 'Close Call of Duty*' }
if(-not $blocked){throw 'Running game did not block edits'}
''')

    def test_backup_failure_stops_before_mutation(self):
        self.run_case(r'''
$path=Join-Path $root 's.1.0.cod26.txt'
$text='WeaponMotionBlur@0;1;1 = true'
[IO.File]::WriteAllText($path,$text)
$script:blockedBackup=Join-Path $root 'not-a-directory'
[IO.File]::WriteAllText($script:blockedBackup,'occupied')
function Get-Mw4BackupRoot { $script:blockedBackup }
$failed=$false
try {Invoke-Mw4Optimization} catch {$failed=$true}
if(-not $failed -or [IO.File]::ReadAllText($path) -cne $text){throw 'Changed config without backup'}
''')

    def test_unknown_config_is_skipped_without_claiming_it_is_optimized(self):
        rows = self.run_case(r'''
$path=Join-Path $root 's.1.0.cod99.txt'
[IO.File]::WriteAllText($path,'UnknownFutureKey@0;1;1 = true')
Invoke-Mw4Optimization
if(Test-Path (Get-Mw4BackupRoot)){throw 'Unknown config created a backup'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Unsupported'])

    def test_missing_driver_profiles_and_settings_are_skipped(self):
        rows = self.run_case(r'''
class MissingDriver {
    [IntPtr] FindProfile([string]$app) {
        if($app -eq 'cod26-cod.exe'){return [IntPtr]1}
        return [IntPtr]::Zero
    }
    [object] Read([IntPtr]$p,[int]$id) {return $null}
}
$plan=@(Get-Mw4DriverPlan ([MissingDriver]::new()) @('cod.exe','cod26-cod.exe'))
if($plan.Count){throw 'Created changes for unsupported profiles/settings'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Unsupported']*4)

    def test_file_changes_during_planning_are_not_overwritten(self):
        self.run_case(r'''
$path=Join-Path $root 's.1.0.cod26.txt'
[IO.File]::WriteAllText($path,'WeaponMotionBlur@0;1;1 = true')
$hash=Get-Mw4Hash ([IO.File]::ReadAllBytes($path))
[IO.File]::WriteAllText($path,'newer user settings')
$failed=$false
try {Set-Mw4File $path $hash ([Text.Encoding]::UTF8.GetBytes('replace'))} catch {$failed=$true}
if(-not $failed -or [IO.File]::ReadAllText($path) -ne 'newer user settings'){throw 'Overwrote concurrent edits'}
''')

    def test_driver_deduplicates_profile_and_restores_overrides_and_inheritance(self):
        rows = self.run_case(DRIVER+r'''
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod26.txt'),'1')
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod25.txt0'),'1')
Invoke-Mw4Optimization
if($driver.Writes -ne 3 -or $driver.Saves -ne 3){throw 'Shared profile modified more than once'}
Invoke-Mw4Optimization
if($driver.Writes -ne 3){throw 'No-op rewrote driver settings'}
Restore-Mw4Optimization
if($driver.Resets -ne 2 -or $driver.Writes -ne 4){throw 'Did not preserve inherited vs explicit settings'}
Restore-Mw4Optimization
if($driver.Resets -ne 2 -or $driver.Writes -ne 4){throw 'Restore not idempotent'}
''')
        self.assertFalse(any(r['Status'] == 'Failed' for r in rows))
        self.assertEqual(sum(r['Status'] == 'Applied' for r in rows), 6)

    def test_silent_driver_failure_is_never_reported_as_success(self):
        rows = self.run_case(DRIVER+r'''
$driver.SilentFailure=$true
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod26.txt'),'1')
Invoke-Mw4Optimization
''')
        self.assertEqual(sum(r['Status'] == 'Failed' for r in rows), 3)
        self.assertFalse(any(r['Status'] == 'Applied' for r in rows))

    def test_driver_save_failure_and_later_user_edit_are_not_overwritten(self):
        rows = self.run_case(DRIVER+r'''
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod26.txt'),'1')
Invoke-Mw4Optimization
$driver.State[0x10835002]=@{Data=120;UserOverride=$true}
Restore-Mw4Optimization
if($driver.State[0x10835002].Data -ne 120){throw 'Overwrote user FPS cap'}
$driver.FailSave=$true
Invoke-Mw4Optimization
''')
        self.assertEqual(sum(r['Status'] == 'Failed' for r in rows), 4)


if __name__ == '__main__':
    unittest.main()
