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
    # State models the system database; Cache models the loaded NVAPI session.
    [hashtable]$State=@{}
    [hashtable]$Cache=@{}
    [int]$Writes=0
    [int]$Resets=0
    [int]$Saves=0
    [bool]$SilentFailure=$false
    [bool]$FailSave=$false
    [int]$FailSaveNumber=0
    FakeDriver() {
        $this.State[0x00A879CF]=@{Data=1;UserOverride=$true}
        $this.State[0x10835002]=@{Data=60;UserOverride=$false}
        $this.State[0x0064B541]=@{Data=0;UserOverride=$false}
        $this.State[0x1057EB71]=@{Data=5;UserOverride=$false}
        $this.Reload()
    }
    [IntPtr] FindProfile([string]$app) { return [IntPtr]1 }
    [object] Read([IntPtr]$p,[int]$id) { return $this.Cache[$id] }
    [void] Write([IntPtr]$p,[int]$id,[int]$v) {
        $this.Writes++
        if (-not $this.SilentFailure) { $this.Cache[$id]=@{Data=$v;UserOverride=$true} }
    }
    [void] Reset([IntPtr]$p,[int]$id) {
        $this.Resets++
        $value=if($id -eq 0x10835002){60}elseif($id -eq 0x1057EB71){5}else{0}
        $this.Cache[$id]=@{Data=$value;UserOverride=$false}
    }
    [void] Save() { $this.Saves++; if($this.FailSave -or $this.Saves -eq $this.FailSaveNumber){throw 'Save failed'}; $this.State=$this.Cache.Clone() }
    [void] Reload() { $this.Cache=$this.State.Clone() }
    [void] Dispose() {}
}
$script:fakeDriver=[FakeDriver]::new()
$driver=$script:fakeDriver
function Get-CimInstance { [pscustomobject]@{PNPDeviceID='PCI\VEN_10DE'} }
function Open-Mw4Driver { $script:fakeDriver.Reload(); $script:fakeDriver }
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

    def test_warzone_paired_configs_disable_both_depth_of_field_formats_and_restore(self):
        rows = self.run_case(r'''
$text=@'
DepthOfField@0;57752;20945 = true
DepthOfField@1;29449;43096 = On // one of Off, On, Script
DepthOfField@2;1;1 = 2 // 0 to 3
DepthOfFieldQuality@0;11629;11445 = High // one of Low, High
TextureFilter@0;63279;8284 = aniso 16x // one of aniso 2x, aniso 4x, aniso 8x, aniso 16x
BulletImpacts@0;57752;20945 = true
'@
$hashes=@{}
foreach($slot in @(0,1)) {
    $path=Join-Path $root "s.1.0.cod25.txt$slot"
    # Paired files can contain different preferences; never copy one over the other.
    [IO.File]::WriteAllText($path,($text+"`r`nMouseSensitivity@0;1;1 = $slot"))
    $hashes[$path]=Get-Mw4Hash ([IO.File]::ReadAllBytes($path))
}
Invoke-Mw4Optimization
foreach($path in $hashes.Keys) {
    $actual=[IO.File]::ReadAllText($path)
    if($actual -notmatch 'DepthOfField@0;57752;20945 = false' -or $actual -notmatch 'DepthOfField@1;29449;43096 = Off //'){throw 'Warzone depth of field stayed enabled'}
    foreach($line in $text -split "\r?\n" | Where-Object {$_ -notmatch '^DepthOfField@[01];'}) {
        if(-not $actual.Contains($line)){throw "Unexpected change: $line"}
    }
}
Invoke-Mw4Optimization
if(@(Get-ChildItem -LiteralPath (Get-Mw4BackupRoot) -Directory).Count -ne 1){throw 'No-op replaced original backup'}
Restore-Mw4Optimization
foreach($path in $hashes.Keys) {if((Get-Mw4Hash ([IO.File]::ReadAllBytes($path))) -ne $hashes[$path]){throw 'Paired config did not restore exactly'}}
''')
        self.assertEqual(sum(r['Status'] == 'Applied' for r in rows), 6)
        self.assertFalse(any(r['Status'] == 'Failed' for r in rows))

    def test_older_warzone_configs_accept_bracketed_domains_and_preserve_unknown_values(self):
        rows = self.run_case(r'''
$text=@'
DepthOfField:0.0 = "true"
MotionBlur:0.0 = "On" // one of [Off, On, Cinematic Only]
NvidiaReflex:0.0 = "Enabled" // one of [Disabled, Enabled, Enabled + boost]
SSRMode:0.0 = "Deferred HQ" // one of [Off, Deferred LQ, Deferred HQ]
SSRMode:1.0 = "Future" // one of [Future, New Mode]
TextureFilter:0.0 = "TEXTURE_FILTER_ANISO16X"
'@
$path=Join-Path $root 'options.3.cod22.txt'
[IO.File]::WriteAllText($path,$text)
if(@(Get-Mw4Files).Count -ne 1){throw 'Older retail config was not discovered'}
$converted=Convert-Mw4Config $text $true
if($converted.Changes.Count -ne 4 -or $converted.Skipped -ne 1){throw 'Older compatible settings were skipped'}
if($converted.Text -notmatch 'NvidiaReflex:0.0 = "Enabled \+ boost" // one of \['){throw 'Bracketed Reflex domain did not retain formatting'}
Invoke-Mw4Optimization
if([IO.File]::ReadAllText($path) -cne (Convert-Mw4Config $text $false).Text){throw 'Applied config differs from preset'}
Restore-Mw4Optimization
if([IO.File]::ReadAllText($path) -cne $text){throw 'Older config restore differs'}
''')
        self.assertEqual(sum(r['Status'] == 'Applied' for r in rows), 4)
        self.assertFalse(any(r['Status'] == 'Failed' for r in rows))

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

    def test_expanded_effects_preset_writes_real_files_and_restores(self):
        rows = self.run_case(r'''
$text=@'
ShaderQuality@0;19450;7764 = Default // one of Default, Medium, Low
ShadingQuality@0;14472;11445 = High // one of Low, High
SSRQuality@0;63075;11445 = High // one of Off, Low, Medium, High
ReflectionProbeHalfResolution@0;57752;48403 = false
ParticleQuality@0;60198;58629 = high // one of very low, low, medium, high
DeferredPhysics@0;6619;43096 = High Quality // one of Low Quality, Medium Quality, High Quality
WaterCausticsMode@0;41499;11445 = High Quality // one of Off, Low Quality, High Quality
WaterWaveWetness@0;57752;20945 = true
WeatherGridVolumesQuality@0;38459;58629 = Ultra // one of Off, Low, Medium, High, Ultra
AmbientLightingQuality@0;20439;58629 = Ultra // one of Off, Low, Medium, High, Ultra
ScreenSpaceShadowQuality@0;42742;43096 = High // one of Off, Low, High
VolumetricQuality@0;4276;43096 = QUALITY_VERYHIGH // one of QUALITY_LOW, QUALITY_MEDIUM, QUALITY_HIGH, QUALITY_VERYHIGH
Tessellation@0;27349;11445 = 2_All // one of 0_Off, 1_Near, 2_All
GPUUploadHeaps@0;57752;20945 = false
TextureQuality@0;61129;7764 = 0 // 0 to 3
ModelQuality@0;15002;43096 = High Quality // one of Low Quality, Medium Quality, High Quality
'@
$path=Join-Path $root 's.1.0.cod26.txt'
[IO.File]::WriteAllText($path,$text)
$hash=Get-Mw4Hash ([IO.File]::ReadAllBytes($path))
Invoke-Mw4Optimization
$updated=[IO.File]::ReadAllText($path)
foreach($expected in @('ShaderQuality@0;19450;7764 = Low','ShadingQuality@0;14472;11445 = Low',
    'SSRQuality@0;63075;11445 = Off','ReflectionProbeHalfResolution@0;57752;48403 = true',
    'ParticleQuality@0;60198;58629 = low','DeferredPhysics@0;6619;43096 = Low Quality',
    'WaterCausticsMode@0;41499;11445 = Off','WaterWaveWetness@0;57752;20945 = false',
    'WeatherGridVolumesQuality@0;38459;58629 = Low','AmbientLightingQuality@0;20439;58629 = Low',
    'ScreenSpaceShadowQuality@0;42742;43096 = Low','VolumetricQuality@0;4276;43096 = QUALITY_MEDIUM',
    'Tessellation@0;27349;11445 = 1_Near','GPUUploadHeaps@0;57752;20945 = false',
    'TextureQuality@0;61129;7764 = 0','ModelQuality@0;15002;43096 = High Quality')) {
    if(-not $updated.Contains($expected)){throw "Unexpected result: $expected"}
}
Invoke-Mw4Optimization
if(@(Get-ChildItem (Get-Mw4BackupRoot) -Directory).Count -ne 1){throw 'Repeated apply changed the backup'}
Restore-Mw4Optimization
if((Get-Mw4Hash ([IO.File]::ReadAllBytes($path))) -ne $hash){throw 'Expanded preset did not restore exactly'}
''')
        self.assertEqual(sum(r['Status'] == 'Applied' and r['Operation'].startswith('MW4 config ') for r in rows), 13)
        self.assertFalse(any(r['Status'] == 'Failed' for r in rows))

    def test_expanded_preset_keeps_lower_quality_and_skips_changed_value_domains(self):
        self.run_case(r'''
$text=@'
ParticleQuality@0;1;1 = very low // one of very low, low, medium, high
DeferredPhysics@0;1;1 = Off // one of Off, Low Quality, High Quality
WeatherGridVolumesQuality@0;1;1 = Off // one of Off, Low, High
AmbientLightingQuality@0;1;1 = Off // one of Off, Low, High
ScreenSpaceShadowQuality@0;1;1 = Off // one of Off, Low, High
VolumetricQuality@0;1;1 = QUALITY_LOW // one of QUALITY_LOW, QUALITY_MEDIUM, QUALITY_HIGH
Tessellation@0;1;1 = 0_Off // one of 0_Off, 1_Near, 2_All
ShaderQuality@0;1;1 = Automatic // one of Automatic, Normal, Advanced
GPUUploadHeaps@0;1;1 = 2 // 0 to 3
SSRQuality@0;1;1 = High // one of Low, Medium, High
'@
$result=Convert-Mw4Config $text $true
if($result.Text -cne $text -or $result.Changes.Count -ne 0 -or $result.Skipped -ne 2){throw 'Raised quality or forced incompatible values'}
''')

    def test_antilag2_hardware_gate_excludes_old_unknown_and_other_vendor_gpus(self):
        self.run_case(r'''
foreach($name in @('AMD Radeon RX 5500 XT','AMD Radeon RX 6800M','AMD Radeon RX 7600S',
    'AMD Radeon RX 7900XTX','AMD Radeon RX 9070 XT','AMD Radeon(TM) 610M',
    'AMD Radeon 680M','AMD Radeon 780M Graphics','AMD Radeon 890M','AMD Radeon(TM) 8060S Graphics')) {
    $gpu=[pscustomobject]@{PNPDeviceID='PCI\VEN_1002&DEV_1234';Name=$name}
    if(-not (Test-Mw4AntiLag2Support @($gpu))){throw "Missed RDNA GPU: $name"}
    foreach($vendor in @('10DE','8086','10020')) {
        $gpu.PNPDeviceID="PCI\VEN_$vendor"
        if(Test-Mw4AntiLag2Support @($gpu)){throw "Accepted wrong vendor: $vendor"}
    }
}
foreach($name in @('AMD Radeon RX 580','AMD Radeon RX Vega 64','AMD Radeon VII',
    'AMD Radeon HD 5770','AMD Radeon(TM) Graphics','Microsoft Basic Display Adapter','')) {
    if(Test-Mw4AntiLag2Support @([pscustomobject]@{PNPDeviceID='PCI\VEN_1002';Name=$name})){throw "Accepted unknown/old GPU: $name"}
}
if(Test-Mw4AntiLag2Support @()){throw 'Accepted empty inventory'}
if(Test-Mw4AntiLag2Support @([pscustomobject]@{PNPDeviceID='PCI\VEN_1002'})){throw 'Accepted missing model'}
if(-not (Test-Mw4AntiLag2Support @(
    [pscustomobject]@{PNPDeviceID='PCI\VEN_8086';Name='Intel UHD Graphics'},
    [pscustomobject]@{PNPDeviceID='PCI\VEN_1002';Name='AMD Radeon RX 6600'}))){throw 'Missed secondary adapter'}
''')

    def test_antilag2_only_changes_compatible_existing_values_on_supported_hardware(self):
        self.run_case(r'''
$text=@'
AmdAntilag2@0;57752;20945 = false
AmdAntilag2:0.0 = "false" // one of [false, true]
AmdAntilag2@1;1;1 = true
AmdAntilag2@2;1;1 = 2 // 0 to 3
AmdAntilag2@3;1;1 = false // one of false, disabled
'@
$result=Convert-Mw4Config $text $false $true
if($result.Changes.Count -ne 2 -or $result.Skipped -ne 2){throw 'Incorrect compatible changes'}
$expected=$text -replace '(?m)(^AmdAntilag2@0;57752;20945 = )false','$1true' -replace '= "false"','= "true"'
if($result.Text -cne $expected){throw 'Changed incompatible values or formatting'}
if((Convert-Mw4Config $result.Text $false $true).Changes.Count){throw 'Not idempotent'}
foreach($nvidia in @($false,$true)) {
    if((Convert-Mw4Config $text $nvidia).Text -cne $text){throw 'Changed Anti-Lag 2 without eligible Radeon'}
}
if((Convert-Mw4Config 'Unrelated@0;1;1 = false' $false $true).Text -cne 'Unrelated@0;1;1 = false'){throw 'Added missing setting'}
''')

    def test_radeon_antilag2_file_apply_noop_and_restore_preserve_upload_heaps(self):
        rows = self.run_case(r'''
function Get-CimInstance { [pscustomobject]@{PNPDeviceID='PCI\VEN_1002';Name='AMD Radeon RX 7800 XT'} }
$text="AmdAntilag2@0;57752;20945 = false`r`nGPUUploadHeaps@0;57752;20945 = false"
$path=Join-Path $root 's.1.0.cod26.txt'
[IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($true))
$hash=Get-Mw4Hash ([IO.File]::ReadAllBytes($path))
Invoke-Mw4Optimization
if([IO.File]::ReadAllText($path) -cne $text.Replace('AmdAntilag2@0;57752;20945 = false','AmdAntilag2@0;57752;20945 = true')){throw 'Incorrect Radeon preset'}
Invoke-Mw4Optimization
if(@(Get-ChildItem (Get-Mw4BackupRoot) -Directory).Count -ne 1){throw 'No-op replaced backup'}
Restore-Mw4Optimization
if((Get-Mw4Hash ([IO.File]::ReadAllBytes($path))) -ne $hash){throw 'Restore changed original bytes'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied', 'AlreadyConfigured', 'Applied'])

    def test_upload_heaps_and_unsupported_antilag2_are_noops_without_backups(self):
        rows = self.run_case(r'''
$path=Join-Path $root 's.1.0.cod26.txt'
foreach($name in @('AMD Radeon RX 580','AMD Radeon(TM) Graphics')) {
    $script:gpuName=$name
    function Get-CimInstance { [pscustomobject]@{PNPDeviceID='PCI\VEN_1002';Name=$script:gpuName} }
    foreach($value in @('true','false','2')) {
        $text="GPUUploadHeaps@0;1;1 = $value`r`nAmdAntilag2@0;1;1 = false"
        [IO.File]::WriteAllText($path,$text)
        Invoke-Mw4Optimization
        if([IO.File]::ReadAllText($path) -cne $text){throw 'Changed preserved settings'}
        if(Test-Path (Get-Mw4BackupRoot)){throw 'Created backup for a no-op'}
    }
}
''')
        self.assertTrue(all(r['Status'] == 'Unsupported' for r in rows))

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

    def test_manifest_write_failure_blocks_both_file_and_driver_changes(self):
        self.run_case(DRIVER+r'''
$path=Join-Path $root 's.1.0.cod26.txt'
$text='WeaponMotionBlur@0;1;1 = true'
[IO.File]::WriteAllText($path,$text)
function Set-Content {throw 'Manifest write denied'}
$message=''
try {Invoke-Mw4Optimization} catch {$message=$_.Exception.Message}
if($message -ne 'Manifest write denied'){throw 'Manifest failure was swallowed'}
if([IO.File]::ReadAllText($path) -cne $text -or $driver.Writes -or $driver.Saves){throw 'Applied changes without a restorable manifest'}
''')

    def test_corrupt_backup_is_rejected_without_blocking_other_file_restore(self):
        rows = self.run_case(r'''
$text='WeaponMotionBlur@0;1;1 = true'
foreach($name in @('s.1.0.cod26.txt0','s.1.0.cod26.txt1')) {[IO.File]::WriteAllText((Join-Path $root $name),$text)}
Invoke-Mw4Optimization
$backup=Get-ChildItem -LiteralPath (Get-Mw4BackupRoot) -Directory | Select-Object -First 1
$manifest=Get-Content -LiteralPath (Join-Path $backup.FullName 'manifest.json') -Raw | ConvertFrom-Json
[IO.File]::WriteAllText((Join-Path $backup.FullName $manifest.Files[0].Backup),'corrupt backup')
Restore-Mw4Optimization
if([IO.File]::ReadAllText($manifest.Files[0].Path) -cne $text.Replace('true','false')){throw 'Corrupt backup overwrote config'}
if([IO.File]::ReadAllText($manifest.Files[1].Path) -cne $text){throw 'Valid backup was not restored'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied', 'Applied', 'Failed', 'Applied'])
        self.assertIn('integrity check failed', rows[2]['Detail'])

    def test_invalid_utf8_is_preserved_without_creating_a_backup(self):
        rows = self.run_case(r'''
$path=Join-Path $root 's.1.0.cod26.txt'
[byte[]]$bytes=[Text.Encoding]::UTF8.GetBytes("WeaponMotionBlur@0;1;1 = true`n") + @(0xC3,0x28)
[IO.File]::WriteAllBytes($path,$bytes)
Invoke-Mw4Optimization
if((Get-Mw4Hash ([IO.File]::ReadAllBytes($path))) -ne (Get-Mw4Hash $bytes)){throw 'Invalid encoding was rewritten'}
if(Test-Path -LiteralPath (Get-Mw4BackupRoot)){throw 'Invalid config created a backup'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Failed'])

    def test_failed_driver_save_never_leaks_into_a_later_successful_save(self):
        for failure in range(1, 5):
            with self.subTest(failed_save=failure):
                rows = self.run_case(DRIVER+f'\n$driver.FailSaveNumber={failure}\n'+r'''
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod26.txt'),'1')
$before=$driver.State.Clone()
$ids=@(0x00A879CF,0x10835002,0x0064B541,0x1057EB71)
Invoke-Mw4Optimization
$failedId=$ids[$driver.FailSaveNumber-1]
if($driver.State[$failedId].Data -ne $before[$failedId].Data -or $driver.State[$failedId].UserOverride -ne $before[$failedId].UserOverride){throw 'Failed write leaked into another save'}
if($driver.Saves -ne 4){throw 'Independent driver changes stopped after one failed save'}
Restore-Mw4Optimization
foreach($id in $ids) {
    if($driver.State[$id].Data -ne $before[$id].Data -or $driver.State[$id].UserOverride -ne $before[$id].UserOverride){throw 'Partial apply did not restore original driver state'}
}
''')
                self.assertEqual(sum(r['Status'] == 'Failed' for r in rows), 1)
                self.assertEqual(sum(r['Status'] == 'Applied' for r in rows), 6)

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
        self.assertEqual([r['Status'] for r in rows], ['Unsupported']*5)

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

    def test_zero_film_grain_does_not_create_repeated_changes_or_backups(self):
        rows = self.run_case(r'''
$path=Join-Path $root 's.1.0.cod26.txt'
$text='FilmGrain@0;1;1 = 0.000000 // 0.000000 to 1.000000'
[IO.File]::WriteAllText($path,$text)
Invoke-Mw4Optimization
if([IO.File]::ReadAllText($path) -cne $text -or (Test-Path (Get-Mw4BackupRoot))){throw 'Rewrote an already disabled effect'}
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured'])

    def test_driver_edit_after_planning_is_preserved(self):
        rows = self.run_case(DRIVER+r'''
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod26.txt'),'1')
$script:checks=0
function Assert-Mw4Closed {
    $script:checks++
    if($script:checks -eq 3){$script:fakeDriver.State[0x00A879CF]=@{Data=2;UserOverride=$true}}
}
Invoke-Mw4Optimization
if($driver.State[0x00A879CF].Data -ne 2 -or $driver.Writes -ne 3){throw 'Overwrote a newer driver setting with cached state'}
''')
        self.assertEqual(sum(r['Status'] == 'Failed' for r in rows), 1)

    def test_driver_edit_during_restore_is_preserved(self):
        rows = self.run_case(DRIVER+r'''
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod26.txt'),'1')
Invoke-Mw4Optimization
$script:checks=0
function Assert-Mw4Closed {
    $script:checks++
    if($script:checks -eq 2){$script:fakeDriver.State[0x00A879CF]=@{Data=2;UserOverride=$true}}
}
Restore-Mw4Optimization
if($driver.State[0x00A879CF].Data -ne 2 -or $driver.Writes -ne 4){throw 'Restore overwrote a newer driver setting with cached state'}
''')
        self.assertEqual(sum(r['Status'] == 'Failed' for r in rows), 1)

    def test_driver_deduplicates_profile_and_restores_overrides_and_inheritance(self):
        rows = self.run_case(DRIVER+r'''
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod26.txt'),'1')
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod25.txt0'),'1')
Invoke-Mw4Optimization
if($driver.Writes -ne 4 -or $driver.Saves -ne 4){throw 'Shared profile modified more than once'}
Invoke-Mw4Optimization
if($driver.Writes -ne 4){throw 'No-op rewrote driver settings'}
Restore-Mw4Optimization
if($driver.Resets -ne 3 -or $driver.Writes -ne 5){throw 'Did not preserve inherited vs explicit settings'}
Restore-Mw4Optimization
if($driver.Resets -ne 3 -or $driver.Writes -ne 5){throw 'Restore not idempotent'}
''')
        self.assertFalse(any(r['Status'] == 'Failed' for r in rows))
        self.assertEqual(sum(r['Status'] == 'Applied' for r in rows), 8)

    def test_silent_driver_failure_is_never_reported_as_success(self):
        rows = self.run_case(DRIVER+r'''
$driver.SilentFailure=$true
[IO.File]::WriteAllText((Join-Path $root 's.1.0.cod26.txt'),'1')
Invoke-Mw4Optimization
''')
        self.assertEqual(sum(r['Status'] == 'Failed' for r in rows), 4)
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
        self.assertEqual(sum(r['Status'] == 'Failed' for r in rows), 5)


if __name__ == '__main__':
    unittest.main()
