"""Behavior tests with mocked system changes; real fixture recycling is opt-in."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PS = str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')

@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell required')
class OperationResults(unittest.TestCase):
    def run_case(self, script):
        with tempfile.TemporaryDirectory(prefix='operation-tests-', dir=ROOT.parent) as folder:
            folder = Path(folder).resolve()
            self.assertTrue(folder.is_relative_to(ROOT.parent.resolve()))
            journal = folder / 'results.jsonl'
            fixture = folder / 'case.ps1'
            fixture.write_text(". $env:TEST_ENGINE -NoRun\n" + script, encoding='utf-8')
            env = os.environ.copy()
            env.update(TEST_ENGINE=str(ROOT / 'optimizer-operations.ps1'), OPTIMIZER_RESULTS=str(journal), LOG_FILE=str(folder/'log.txt'))
            result = subprocess.run([PS, '-NoProfile', '-File', str(fixture)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            rows = [json.loads(line) for line in journal.read_text(encoding='utf-8-sig').splitlines()] if journal.exists() else []
            return rows, result.stdout


    def test_managed_cpu_detection_and_parking_preserves_driver_control(self):
        rows, _ = self.run_case(r'''
$script:cpu=''
function Get-CimInstance {param($ClassName,$ErrorAction) [pscustomobject]@{Name=$script:cpu}}
foreach($name in @('AMD Ryzen 9 7950X3D 16-Core Processor','AMD Ryzen 9 9900X','AMD Ryzen 9 9950X','AMD Ryzen 9 9950X3D','AMD Ryzen 9 7945HX3D')) {
    $script:cpu=$name
    if(-not (Test-ManagedCoreParking)){throw "Missed managed CPU: $name"}
}
foreach($name in @('AMD Ryzen 7 5800X3D','AMD Ryzen 7 9800X3D','AMD Ryzen 9 7950X','Intel Core i9-14900K')) {
    $script:cpu=$name
    if(Test-ManagedCoreParking){throw "Unexpected managed CPU: $name"}
}
$script:cpu='AMD Ryzen 9 7950X3D'
function Invoke-NativeOperation {throw 'Must preserve driver parking'}
$null=Invoke-Operation 'Parking Configure'
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured'])

    def test_managed_cpu_selects_balanced_without_creating_or_deleting_plans(self):
        rows, _ = self.run_case(r'''
function Test-ManagedCoreParking {$true}
function Get-PowerCapabilities {@{ModernStandby=$false;Portable=$false}}
$script:active=[guid]'11111111-1111-1111-1111-111111111111'
function Get-ActivePowerScheme {$script:active}
function Get-ACPowerMode {[guid]'ded574b5-45a0-4f42-8737-46345c09c238'}
function Get-PerformancePlans {throw 'Must not enumerate or delete desktop plans'}
function Invoke-NativeOperation {param($Program,$Arguments)
    if($Arguments[0] -ne '-setactive' -or $Arguments[1] -ne '381b4222-f694-41f0-9685-ff5bb260df2e'){throw 'Unexpected power mutation'}
    $script:active=[guid]$Arguments[1]
    [pscustomobject]@{Code=0;Output='localized output'}
}
$null=Invoke-Operation 'Plan Ultimate'
$null=Invoke-Operation 'Plan Ultimate'
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied','AlreadyConfigured','AlreadyConfigured','AlreadyConfigured'])


    def test_core_parking_uses_active_guid_and_reactivates_settings(self):
        self.run_case(r'''
function Test-ManagedCoreParking {$false}
$guid=[guid]'11111111-2222-3333-4444-555555555555'
function Get-ActivePowerScheme {$guid}
$script:changed=$false; $script:activated=$false
function Invoke-GenericChange {param($Tokens)
    if(($Tokens -join ' ') -ne "powercfg -setacvalueindex $guid SUB_PROCESSOR CPMINCORES 100"){throw 'Wrong plan updated'}
    $script:changed=$true
}
function Invoke-NativeOperation {param($Program,$Arguments)
    if(-not $script:changed -or ($Arguments -join ' ') -ne "-setactive $guid"){throw 'Wrong activation order or plan'}
    $script:activated=$true
    [pscustomobject]@{Code=0;Output=''}
}
Set-GamingCoreParking
if(-not $script:activated){throw 'Settings not activated'}
''')

    def test_user_context_rejects_other_or_unknown_desktop_owner(self):
        self.run_case(r'''
function Get-CurrentUserSid {'S-1-5-21-100'}
$script:owners=@('S-1-5-21-100')
function Get-DesktopUserSids {$script:owners}
Assert-UserContext
foreach($owners in @(@('S-1-5-21-200'),@(),@('S-1-5-21-100','S-1-5-21-200'))) {
    $script:owners=$owners
    $failed=$false
    try {Assert-UserContext} catch {$failed=$true}
    if(-not $failed){throw 'Wrong/unknown user was accepted'}
}
''')

    def test_storage_tracks_windows_volume_and_rejects_ambiguous_media(self):
        self.run_case(r'''
$env:SystemDrive='D:'
function Get-Partition {param($DriveLetter,$ErrorAction)
    if($DriveLetter -ne 'D'){throw 'Wrong volume queried'}
    [pscustomobject]@{DiskNumber=3}
}
function Get-Disk {param([Parameter(ValueFromPipeline=$true)]$InputObject)
    process {
        if($InputObject.DiskNumber -ne 3){throw 'Wrong disk queried'}
        [pscustomobject]@{Number=3;UniqueId='os-disk';SerialNumber='serial-3'}
    }
}
$script:physical=@([pscustomobject]@{DeviceID=0;UniqueId='other';SerialNumber='other';MediaType='HDD'},[pscustomobject]@{DeviceID=3;UniqueId='os-disk';SerialNumber='serial-3';MediaType='SSD'})
function Get-PhysicalDisk {$script:physical}
if((Get-SystemStorageType) -ne 'SSD'){throw 'Used disk zero instead of Windows disk'}
$script:physical=@($script:physical[0])
if((Get-SystemStorageType) -ne 'Unknown'){throw 'Guessed unmatched disk'}
$script:physical=@([pscustomobject]@{UniqueId='os-disk';MediaType='SSD'},[pscustomobject]@{UniqueId='os-disk';MediaType='HDD'})
if((Get-SystemStorageType) -ne 'Unknown'){throw 'Guessed ambiguous disk'}
''')

    def test_registry_already_applied_noop_and_native_failure(self):
        rows, _ = self.run_case(r'''
$script:value=0
$script:mutationMode='apply'
function Get-RegistryState {param($Path,$Name) @{Exists=$true;Type='DWord';Value=$script:value}}
function Invoke-NativeOperation {
    param($Program,$Arguments)
    if($script:mutationMode -eq 'denied'){return [pscustomobject]@{Code=5;Output='Access denied'}}
    if($script:mutationMode -eq 'apply'){$script:value=1}
    [pscustomobject]@{Code=0;Output=''}
}
$op='Registry reg add "HKCU\Test" /v Value /t REG_DWORD /d 1 /f'
$null=Invoke-Operation $op
$null=Invoke-Operation $op
$script:value=0; $script:mutationMode='noop'; $null=Invoke-Operation $op
$script:mutationMode='denied'; $null=Invoke-Operation $op
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied','AlreadyConfigured','Failed','Failed'])
        self.assertTrue(rows[0]['Verified'])
        self.assertIn('read-back', rows[2]['Detail'])
        self.assertIn('Access denied', rows[3]['Detail'])

    def test_registry_types_and_dword_high_bit(self):
        self.run_case(r'''
if(-not (Test-RegistryValue @{Exists=$true;Type='DWord';Value=-1} REG_DWORD 4294967295)){throw 'Unsigned DWORD mismatch'}
if(Test-RegistryValue @{Exists=$true;Type='String';Value='1'} REG_DWORD 1){throw 'Wrong registry kind accepted'}
if(-not (Test-RegistryValue @{Exists=$true;Type='MultiString';Value=@('AudioEndpointBuilder','RpcSs')} REG_MULTI_SZ 'AudioEndpointBuilder\0RpcSs')){throw 'Multi-string mismatch'}
if(-not (Test-RegistryValue @{Exists=$true;Type='Binary';Value=[byte[]](0,15,255)} REG_BINARY '000fff')){throw 'Binary mismatch'}
''')

    def test_features_absent_present_pending_and_failed(self):
        rows, _ = self.run_case(r'''
$script:state='absent'; $script:invocations=0
function Get-WindowsOptionalFeature {param([switch]$Online,$FeatureName,$ErrorAction)
    if($script:state -ne 'absent'){[pscustomobject]@{FeatureName='Test';State=$script:state}}
}
function Disable-WindowsOptionalFeature {param([switch]$Online,$FeatureName,[switch]$NoRestart,$ErrorAction)
    $script:invocations++; throw 'Access denied'
}
$null=Invoke-Operation 'Feature Disable Test'
$script:state='Disabled'; $null=Invoke-Operation 'Feature Disable Test'
$script:state='DisabledWithPayloadRemoved'; $null=Invoke-Operation 'Feature Disable Test'
$script:state='DisablePending'; $null=Invoke-Operation 'Feature Disable Test'
$script:state='Enabled'; $null=Invoke-Operation 'Feature Disable Test'
if($script:invocations -ne 1){throw 'Unsupported or already configured feature was modified'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Unsupported','AlreadyConfigured','AlreadyConfigured','RestartRequired','Failed'])

    def test_missing_executable_cannot_reuse_a_success_exit_code(self):
        rows, _ = self.run_case(r'''
function Test-Path {param($LiteralPath,$PathType) $false}
$global:LASTEXITCODE = 0
if ((Invoke-Operation 'Native powercfg -attributes X Y -ATTRIB_HIDE') -ne 1) {throw 'Missing executable returned success'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Failed'])
        self.assertIn('Native program is missing', rows[0]['Detail'])

    def test_empty_journal_reports_no_operations(self):
        rows, stdout = self.run_case(r'''
[IO.File]::WriteAllText($env:OPTIMIZER_RESULTS, '')
if ((Show-OperationSummary) -ne 0) {throw 'Empty journal returned failure'}
''')
        self.assertEqual(rows, [])
        self.assertIn('No operations recorded', stdout)
        self.assertNotIn('All supported, attempted operations have verified', stdout)

    def test_native_unknown_and_failure_have_distinct_results(self):
        rows, _ = self.run_case(r'''
$script:code=0
function Get-NativeDesiredState {param($Tokens) return $null}
function Invoke-NativeOperation {param($Program,$Arguments) [pscustomobject]@{Code=$script:code;Output='diagnostic'}}
$null=Invoke-Operation 'Native powercfg -attributes X Y -ATTRIB_HIDE'
$script:code=1; $null=Invoke-Operation 'Native powercfg -attributes X Y -ATTRIB_HIDE'
$script:code=3010; $null=Invoke-Operation 'Native powercfg -attributes X Y -ATTRIB_HIDE'
''')
        self.assertEqual([r['Status'] for r in rows], ['Unverified','Failed','RestartRequired'])

    def test_service_state_readback_catches_silent_noop(self):
        rows, _ = self.run_case(r'''
$script:startup='demand';$script:apply=$true
function Get-Service {param($Name,$ErrorAction,$ErrorVariable) [pscustomobject]@{Name=$Name;Status='Stopped'}}
function Get-ServiceStartup {param($Name) $script:startup}
function Invoke-NativeOperation {param($Program,$Arguments)
    if($script:apply){$script:startup='disabled'}
    [pscustomobject]@{Code=0;Output=''}
}
$null=Invoke-Operation 'Service sc config Example start= disabled'
$null=Invoke-Operation 'Service sc config Example start= disabled'
$script:startup='demand';$script:apply=$false
$null=Invoke-Operation 'Service sc config Example start= disabled'
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied','AlreadyConfigured','Failed'])


    def test_protected_input_disable_is_skipped_without_hiding_other_service_errors(self):
        rows, stdout = self.run_case(r'''
function Get-Service {param($Name,$ErrorAction,$ErrorVariable) [pscustomobject]@{Name=$Name;Status='Running'}}
function Get-ServiceStartup {param($Name) 'demand'}
$script:code=5
function Invoke-NativeOperation {param($Program,$Arguments) [pscustomobject]@{Code=$script:code;Output='Access denied diagnostic'}}
$null=Invoke-Operation 'Service sc stop TextInputManagementService'
$null=Invoke-Operation 'Service sc config TextInputManagementService start= disabled'
$null=Invoke-Operation 'Service sc stop OtherService'
$null=Invoke-Operation 'Service sc config TextInputManagementService start= auto'
$script:code=1058
$null=Invoke-Operation 'Service sc stop TextInputManagementService'
''')
        self.assertEqual([r['Status'] for r in rows], ['Unsupported','Unsupported','Failed','Failed','Failed'])
        self.assertTrue(all('left unchanged' in r['Detail'] and 'Access denied diagnostic' in r['Detail'] for r in rows[:2]))
        self.assertEqual(stdout.count('[ERROR] Service TextInputManagementService:'), 2)
        self.assertIn('[ERROR] Service OtherService', stdout)

    def test_tasks_are_verified_and_missing_tasks_skipped(self):
        rows, _ = self.run_case(r'''
$script:present=$false; $script:enabled=$true
function Get-ScheduledTask {param($TaskPath,$TaskName,$ErrorAction)
    if($script:present){[pscustomobject]@{TaskPath='\Example\';TaskName='A B';Settings=[pscustomobject]@{Enabled=$script:enabled}}}
}
function Invoke-NativeOperation {param($Program,$Arguments) $script:enabled=$false; [pscustomobject]@{Code=0;Output=''}}
$null=Invoke-Operation 'Task schtasks /Change /TN "\Example\A B" /Disable'
$script:present=$true
$null=Invoke-Operation 'Task schtasks /Change /TN "\Example\A B" /Disable'
$null=Invoke-Operation 'Task schtasks /Change /TN "\Example\A B" /Disable'
''')
        self.assertEqual([r['Status'] for r in rows], ['Unsupported','Applied','AlreadyConfigured'])

    def test_memory_reads_actual_manager_state(self):
        rows, _ = self.run_case(r'''
$script:compressed=$false
function Get-MMAgent {param($ErrorAction) [pscustomobject]@{MemoryCompression=$script:compressed}}
function Enable-MMAgent {param([switch]$MemoryCompression,$ErrorAction) $script:compressed=$true}
$null=Invoke-Operation 'Memory MemoryCompression 1'
$null=Invoke-Operation 'Memory MemoryCompression 1'
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied','AlreadyConfigured'])

    def test_summary_does_not_call_failed_run_successful(self):
        rows, stdout = self.run_case(r'''
Write-OperationResult Applied 'First' 'ok' $true
Write-OperationResult Failed 'Second' 'denied'
Write-OperationResult Unverified 'Third' 'unknown'
$code=Show-OperationSummary
if($code -ne 1){throw 'Summary missed failed operation'}
''')
        self.assertIn('PARTIAL RESULT', stdout)
        self.assertNotIn('All supported, attempted operations have verified', stdout)
        self.assertEqual(len(rows), 3)

    def test_summary_marks_unverified_run_incomplete(self):
        _, stdout = self.run_case(r'''
Write-OperationResult Unverified 'Command' 'unknown'
if((Show-OperationSummary) -ne 2){throw 'Unverified was counted as success'}
''')
        self.assertIn('INCOMPLETE VERIFICATION', stdout)

    def test_summary_counts_only_confirmed_recycling_and_stays_brief(self):
        _, output = self.run_case(r'''
Write-OperationResult Applied 'Recycle C:\first.zip' 'long file detail' $true 2GB $true
Write-OperationResult Applied 'Recycle C:\second.zip' 'long file detail' $true 3GB
Write-OperationResult Failed 'Recycle C:\failed.zip' 'DO_NOT_REPEAT_RAW_ERROR' $false 100GB
Write-OperationResult Applied 'HKCU\Software\Microsoft\GameBar [AutoGameModeEnabled]' 'configured' $true
Write-OperationResult RestartRequired 'Memory integrity' 'restart' $true
Write-Host 'SUMMARY_START'
if((Show-OperationSummary) -ne 1){throw 'Failed operation was not reflected in exit code'}
''')
        summary = output.split('SUMMARY_START', 1)[1]
        self.assertIn('2 files | ~5.00 GB | Duplicates: 1', summary)
        self.assertIn('Gaming, graphics & input', summary)
        self.assertIn('Restart: needed', summary)
        self.assertIn('1 failed', summary)
        self.assertNotIn('DO_NOT_REPEAT_RAW_ERROR', summary)
        self.assertNotIn('C:\\first.zip', summary)
        self.assertLess(len(summary.splitlines()), 15)

    def test_summary_separates_actions_but_keeps_session_report(self):
        _, output = self.run_case(r'''
$env:OPTIMIZER_ACTION_ID='first'
Write-OperationResult Applied 'Memory compression' 'enabled' $true
$env:OPTIMIZER_ACTION_ID='second'
Write-OperationResult Applied 'Recycle C:\copy.zip' 'recycled' $true 1GB $true
Write-Host 'CURRENT_START'
$null=Show-OperationSummary
$env:OPTIMIZER_ACTION_ID=''
Write-Host 'SESSION_START'
$null=Show-OperationSummary
''')
        current, session = output.split('CURRENT_START', 1)[1].split('SESSION_START', 1)
        self.assertNotIn('Memory & security', current)
        self.assertIn('1 file | ~1.00 GB', current)
        self.assertIn('Memory & security', session)
        self.assertIn('1 file | ~1.00 GB', session)

    def test_console_hides_routine_details_and_colors_real_outcomes(self):
        self.run_case(r'''
$script:messages=@()
function Write-Host {param($Object,$ForegroundColor) $script:messages+=,[pscustomobject]@{Text=[string]$Object;Color=[string]$ForegroundColor}}
Write-OperationResult AlreadyConfigured 'HKCU\Noisy' 'already configured' $true
Write-OperationResult Unsupported 'Service Missing' 'Not installed'
Write-OperationResult Applied 'HKCU\Changed' 'registry details' $true
Write-OperationResult Applied 'System restore point' 'checkpoint details' $true
Write-OperationResult Failed 'Service sc stop ProtectedService' "sc.exe returned 5: Access is denied.`nRaw native dump"
if($script:messages.Count -ne 2){throw 'Routine output was not suppressed'}
if($script:messages[0].Color -ne 'Green' -or $script:messages[1].Color -ne 'Red'){throw 'Incorrect status colors'}
if($script:messages[1].Text -notmatch 'ProtectedService' -or $script:messages[1].Text -match 'Raw native dump'){throw 'Error was not concise'}
if((Get-Content -Raw $env:LOG_FILE) -notmatch 'Raw native dump'){throw 'Diagnostic log lost details'}
''')

    def test_power_plan_reuses_active_copy_removes_only_duplicates_and_is_repeatable(self):
        rows, _ = self.run_case(r'''
function Test-ManagedCoreParking {$false}
function Get-ActivePowerScheme { (Invoke-NativeOperation powercfg @('/getactivescheme')).Output }
function Get-PowerCapabilities {@{ModernStandby=$false;Portable=$false}}
$a='11111111-1111-1111-1111-111111111111'; $b='22222222-2222-2222-2222-222222222222'; $c='33333333-3333-3333-3333-333333333333'
$script:plans=@(
    [pscustomobject]@{Id=$a;Name='Ultimate Performance';Active=$true},
    [pscustomobject]@{Id=$b;Name='Ultimate Performance';Active=$false},
    [pscustomobject]@{Id=$c;Name='My custom gaming plan';Active=$false}
)
function Get-PerformancePlans {$script:plans}
function Invoke-NativeOperation {param($Program,$Arguments)
    switch($Arguments[0]){
        '/getactivescheme' {return [pscustomobject]@{Code=0;Output=$a}}
        '/delete' {if($Arguments[1] -ne $b){throw 'Unsafe plan deletion'}; $script:plans=@($script:plans|Where-Object Id -ne $b)}
        default {throw 'Unexpected mutation: duplicate or active plan should be reused'}
    }
    [pscustomobject]@{Code=0;Output=''}
}
$null=Invoke-Operation 'Plan Ultimate'
$null=Invoke-Operation 'Plan Ultimate'
if($script:plans.Count -ne 2 -or $script:plans.Id -notcontains $c){throw 'Custom plan lost'}
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured','Applied','AlreadyConfigured'])

    def test_power_plan_is_created_only_when_missing(self):
        rows, _ = self.run_case(r'''
function Test-ManagedCoreParking {$false}
function Get-ActivePowerScheme { (Invoke-NativeOperation powercfg @('/getactivescheme')).Output }
function Get-PowerCapabilities {@{ModernStandby=$false;Portable=$false}}
$script:plans=@(); $script:active='381b4222-f694-41f0-9685-ff5bb260df2e'; $script:created=0
function Get-PerformancePlans {$script:plans}
function Invoke-NativeOperation {param($Program,$Arguments)
    switch($Arguments[0]) {
        '-duplicatescheme' {$script:created++; $script:plans=@([pscustomobject]@{Id=$Arguments[2];Name='Temporary';Active=$false})}
        '-changename' {$script:plans[0].Name=$Arguments[2]}
        '/getactivescheme' {return [pscustomobject]@{Code=0;Output=$script:active}}
        '-setactive' {$script:active=$Arguments[1]; $script:plans[0].Active=$true}
        default {throw 'Unexpected operation'}
    }
    [pscustomobject]@{Code=0;Output=''}
}
$null=Invoke-Operation 'Plan Ultimate'
$null=Invoke-Operation 'Plan Ultimate'
if($script:created -ne 1 -or $script:plans[0].Name -ne 'Gaming Optimizer'){throw 'Plan was not reused'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied','Applied','AlreadyConfigured'])

    def test_power_plan_rename_noop_is_not_reported_as_verified(self):
        rows, _ = self.run_case(r'''
function Test-ManagedCoreParking {$false}
function Get-ActivePowerScheme { (Invoke-NativeOperation powercfg @('/getactivescheme')).Output }
function Get-PowerCapabilities {@{ModernStandby=$false;Portable=$false}}
$script:plans=@()
function Get-PerformancePlans {$script:plans}
function Invoke-NativeOperation {param($Program,$Arguments)
    if($Arguments[0] -eq '-duplicatescheme'){$script:plans=@([pscustomobject]@{Id=$Arguments[2];Name='Unexpected name';Active=$false})}
    elseif($Arguments[0] -ne '-changename'){throw 'Unverified plan must not be activated or other plans deleted'}
    [pscustomobject]@{Code=0;Output=''}
}
$null=Invoke-Operation 'Plan Ultimate'
''')
        self.assertEqual([r['Status'] for r in rows], ['Failed'])
        self.assertIn('could not be verified', rows[0]['Detail'])

    def test_power_plan_activation_failure_never_deletes_other_plans(self):
        rows, _ = self.run_case(r'''
function Test-ManagedCoreParking {$false}
function Get-ActivePowerScheme { (Invoke-NativeOperation powercfg @('/getactivescheme')).Output }
function Get-PowerCapabilities {@{ModernStandby=$false;Portable=$false}}
function Get-PerformancePlans {@(
    [pscustomobject]@{Id='11111111-1111-1111-1111-111111111111';Name='Ultimate Performance';Active=$false},
    [pscustomobject]@{Id='22222222-2222-2222-2222-222222222222';Name='Ultimate Performance';Active=$false}
)}
function Invoke-GenericChange {throw 'Activation denied'}
function Invoke-NativeOperation {throw 'Must not delete before activation succeeds'}
$null=Invoke-Operation 'Plan Ultimate'
''')
        self.assertEqual(rows[0]['Status'], 'Failed')
        self.assertIn('Activation denied', rows[0]['Detail'])

    def test_delivery_optimization_preserves_available_service_and_repairs_disabled(self):
        rows, _ = self.run_case(r'''
function Invoke-RegistryChange {param($Tokens)
    if(($Tokens -join ' ') -notmatch 'DODownloadMode /t REG_DWORD /d 0'){throw 'Wrong sharing policy'}
    Write-OperationResult AlreadyConfigured 'Sharing policy' 'off' $true
}
$script:startup='demand'
function Get-ServiceStartup {param($Name) $script:startup}
function Invoke-ServiceChange {param($Tokens)
    if(($Tokens -join ' ') -ne 'sc config DoSvc start= delayed-auto'){throw 'Unexpected service mutation'}
    $script:startup='delayed-auto'; Write-OperationResult Applied 'Service repaired' 'available' $true
}
$null=Invoke-Operation 'Delivery Configure'
$script:startup='disabled'; $null=Invoke-Operation 'Delivery Configure'
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured','AlreadyConfigured','AlreadyConfigured','Applied'])

    def test_registry_export_verifies_content_without_skipping_overwrite(self):
        rows, _ = self.run_case(r'''
$path=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'backup [one].reg'
$script:valid=$true
function Invoke-NativeOperation {param($Program,$Arguments)
    $content=if($script:valid){"Windows Registry Editor Version 5.00`r`n`r`n[HKEY_CURRENT_USER\Example]`r`n"}else{"Windows Registry Editor Version 5.00`r`n[HKEY_CURRENT_USER\Wrong]"}
    [IO.File]::WriteAllText($path,$content,[Text.Encoding]::Unicode)
    [pscustomobject]@{Code=0;Output=''}
}
$op='Native reg export "HKCU\Example" "'+$path+'" /y'
$null=Invoke-Operation $op
$script:valid=$false; $null=Invoke-Operation $op
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied','Failed'])
        self.assertTrue(rows[0]['Verified'])

    def test_power_setting_uses_effective_value_without_rewriting_it(self):
        rows, _ = self.run_case(r'''
$guid='11111111-2222-3333-4444-555555555555'
function Invoke-NativeOperation {throw 'Already effective setting must not be rewritten'}
function Get-ACPowerValue {param($Scheme,$Group,$Setting)
    if($Scheme -ne $guid -or $Group -ne '54533251-82be-4824-96c1-47b60b740d00' -or $Setting -ne '0cc5b647-c1df-4637-891a-dec35c318583'){throw 'Power identifiers were not resolved'}
    100
}
$null=Invoke-Operation "Native powercfg -setacvalueindex $guid SUB_PROCESSOR CPMINCORES 100"
''')
        self.assertEqual(rows[0]['Status'], 'AlreadyConfigured')
        self.assertTrue(rows[0]['Verified'])


    def test_ecn_verifies_already_configured_applied_and_noop_failure(self):
        rows, _ = self.run_case(r'''
$script:ecn='Disabled'; $script:apply=$true; $script:writes=0
function Get-NetTCPSetting {param($SettingName,$ErrorAction)
    if($SettingName -ne 'Internet'){throw 'Wrong TCP template'}
    [pscustomobject]@{EcnCapability=$script:ecn}
}
function Invoke-NativeOperation {param($Program,$Arguments)
    if($Program -ne 'netsh' -or ($Arguments -join ' ') -ne 'interface tcp set global ecncapability=disabled'){throw 'Unexpected mutation'}
    $script:writes++
    if($script:apply){$script:ecn='Disabled'}
    [pscustomobject]@{Code=0;Output='localized output'}
}
$op='Native netsh interface tcp set global ecncapability=disabled'
$null=Invoke-Operation $op
if($script:writes -ne 0){throw 'Already disabled ECN was rewritten'}
$script:ecn='Enabled'; $null=Invoke-Operation $op
$script:ecn='Enabled'; $script:apply=$false; $null=Invoke-Operation $op
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured','Applied','Failed'])
        self.assertTrue(all(r['Verified'] for r in rows[:2]))

    def test_pagefile_already_managed_does_not_write(self):
        rows, _ = self.run_case(r'''
function Get-CimInstance {param($ClassName,$ErrorAction) [pscustomobject]@{AutomaticManagedPagefile=$true}}
function Set-CimInstance {throw 'Must not change an already managed page file'}
$null=Invoke-Operation 'Pagefile Auto'
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured'])

    def test_real_read_only_registry_check_does_not_invoke_a_write(self):
        rows, _ = self.run_case(r'''
$path='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$name='ProductName'
$before=Get-RegistryState $path $name
if(-not $before.Exists){throw 'Read-only fixture value is unavailable'}
$types=@{String='REG_SZ';DWord='REG_DWORD'}
$type=$types[$before.Type]
function Invoke-NativeOperation {throw 'Read-only smoke test must never write'}
$null=Invoke-Operation ('Registry reg add "'+$path+'" /v '+$name+' /t '+$type+' /d "'+$before.Value+'" /f')
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured'])

    def test_portable_power_mode_applies_verifies_and_reports_noop_failure(self):
        rows, _ = self.run_case(r'''
function Test-ManagedCoreParking {$false}
function Get-ActivePowerScheme { (Invoke-NativeOperation powercfg @('/getactivescheme')).Output }
function Get-PowerCapabilities {@{ModernStandby=$true;Portable=$true}}
$script:acMode=[guid]::Empty; $script:apply=$true
function Get-ACPowerMode {$script:acMode}
function Set-ACPowerMode {param($Mode) if($script:apply){$script:acMode=$Mode}}
function Invoke-NativeOperation {throw 'Must not duplicate or change portable power plans'}
$null=Invoke-Operation 'Plan Ultimate'
$null=Invoke-Operation 'Plan Ultimate'
$script:acMode=[guid]::Empty; $script:apply=$false
$null=Invoke-Operation 'Plan Ultimate'
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied','AlreadyConfigured','Failed'])

    def test_pagefile_enables_auto_and_checks_readback(self):
        rows, _ = self.run_case(r'''
$script:auto=$false; $script:apply=$true
function Get-CimInstance {param($ClassName,$ErrorAction) [pscustomobject]@{AutomaticManagedPagefile=$script:auto}}
function Set-CimInstance {param($Property,$ErrorAction) if($script:apply){$script:auto=$Property.AutomaticManagedPagefile}}
$null=Invoke-Operation 'Pagefile Auto'
$script:auto=$false; $script:apply=$false
$null=Invoke-Operation 'Pagefile Auto'
''')
        self.assertEqual([r['Status'] for r in rows], ['RestartRequired','Failed'])

    def test_restore_creation_verifies_new_point_and_restores_frequency(self):
        for original, outcome in [('absent','ok'), ('existing','ok'), ('existing','error'), ('existing','returnerror'), ('absent','missing')]:
            with self.subTest(original=original, outcome=outcome):
                rows, _ = self.run_case(r'''
function Start-Sleep {param($Seconds)}
$script:original='ORIGINAL'; $script:outcome='OUTCOME'; $script:description=''; $script:writes=@(); $script:removed=$false
function Get-RegistryState {param($Path,$Name)
    if($Name -eq 'SystemRestorePointCreationFrequency' -and $script:original -eq 'existing'){@{Exists=$true;Type='DWord';Value=1440}}else{@{Exists=$false}}
}
function Enable-ComputerRestore {param($Drive,$ErrorAction,$WarningAction) if($Drive -ne ($env:SystemDrive+'\')){throw 'Wrong drive'}}
function New-ItemProperty {param($LiteralPath,$Name,$PropertyType,$Value,[switch]$Force,$ErrorAction) $script:writes+=,$Value}
function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction) $script:removed=$true}
function Get-CimInstance {param($Namespace,$ClassName,$ErrorAction)
    [pscustomobject]@{SequenceNumber=1;Description='Old checkpoint'}
    if($script:description -and $script:outcome -eq 'ok'){[pscustomobject]@{SequenceNumber=2;Description=$script:description}}
}
function Invoke-CimMethod {param($Namespace,$ClassName,$MethodName,$Arguments,$ErrorAction)
    if($Arguments.EventType -ne 100 -or $Arguments.RestorePointType -ne 12){throw 'Wrong restore event'}
    $script:description=$Arguments.Description
    if($script:outcome -eq 'error'){throw 'Simulated snapshot failure'}
    if($script:outcome -eq 'returnerror'){return [pscustomobject]@{ReturnValue=5}}
    [pscustomobject]@{ReturnValue=0}
}
$null=Invoke-Operation 'Restore Create'
if($script:writes[0] -ne 0){throw 'Frequency not temporarily disabled'}
if($script:original -eq 'existing'){
    if($script:writes.Count -ne 2 -or $script:writes[1] -ne 1440 -or $script:removed){throw 'Existing frequency not restored'}
}elseif(-not $script:removed){throw 'Temporary frequency not removed'}
'''.replace('ORIGINAL', original).replace('OUTCOME', outcome))
                self.assertEqual(rows[0]['Status'], 'Applied' if outcome == 'ok' else 'Failed')
                if outcome == 'ok':
                    self.assertTrue(rows[0]['Verified'])
                    self.assertIn('#2:', rows[0]['Detail'])

    def test_restore_wait_handles_delayed_visibility_and_has_a_bound(self):
        self.run_case(r'''
$script:queries=0; $script:sleeps=0; $script:visible=$true
function Start-Sleep {param($Seconds) if($Seconds -ne 2){throw 'Wrong polling interval'}; $script:sleeps++}
function Get-CimInstance {param($Namespace,$ClassName,$ErrorAction)
    $script:queries++
    [pscustomobject]@{SequenceNumber=1;Description='Old'}
    if($script:visible -and $script:queries -ge 3){[pscustomobject]@{SequenceNumber=2;Description='New'}}
}
$point=Wait-OptimizerRestorePoint 'New' @(1)
if($point.SequenceNumber -ne 2 -or $script:queries -ne 3 -or $script:sleeps -ne 2){throw 'Did not wait for new point'}
$script:visible=$false; $script:queries=0; $script:sleeps=0; $failed=$false
try {Wait-OptimizerRestorePoint 'New' @(1)} catch {$failed=$true}
if(-not $failed -or $script:queries -ne 60 -or $script:sleeps -ne 59){throw 'Polling was not bounded'}
''')

    def test_restore_frequency_write_failure_keeps_original_error(self):
        rows, _ = self.run_case(r'''
function Get-RegistryState {param($Path,$Name) @{Exists=$false}}
function Enable-ComputerRestore {param($Drive,$ErrorAction,$WarningAction)}
function Get-CimInstance {param($Namespace,$ClassName,$ErrorAction)}
function New-ItemProperty {throw 'Frequency write denied'}
function Remove-ItemProperty {throw 'Unexpected cleanup masked original error'}
function Invoke-CimMethod {throw 'Snapshot must not run'}
$null=Invoke-Operation 'Restore Create'
''')
        self.assertEqual(rows[0]['Status'], 'Failed')
        self.assertEqual(rows[0]['Detail'], 'Frequency write denied')

    def test_restore_does_not_override_disabling_policy(self):
        rows, _ = self.run_case(r'''
function Get-RegistryState {param($Path,$Name) @{Exists=$true;Value=1}}
function Enable-ComputerRestore {throw 'Must not enable protection against policy'}
$null=Invoke-Operation 'Restore Create'
''')
        self.assertEqual(rows[0]['Status'], 'Failed')
        self.assertIn('disabled by policy', rows[0]['Detail'])

    def test_cleanup_candidates_are_old_allowed_files_only(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'temp'
$null=New-Item -ItemType Directory $root
foreach($name in @('old.tmp','recent.tmp','old.exe')) {
    $path=Join-Path $root $name
    [IO.File]::WriteAllText($path,'fixture')
    if($name -ne 'recent.tmp'){(Get-Item $path).LastWriteTime=(Get-Date).AddDays(-40)}
}
function Get-CleanupRoots {param($Scope) [pscustomobject]@{Path=$root;Category='Fixture';Days=30;Extensions=@('.tmp')}}
$files=@(Get-CleanupCandidates Safe)
if($files.Count -ne 1 -or (Split-Path $files[0].Path -Leaf) -ne 'old.tmp'){throw 'Incorrect candidate selection'}
if(Test-CleanupPath $env:SystemRoot){throw 'Windows directory accepted'}
if(Test-CleanupPath ([IO.Path]::GetPathRoot($root))){throw 'Drive root accepted'}
if(Test-CleanupPath $env:USERPROFILE){throw 'Profile root accepted'}
if(Test-CleanupPath (Join-Path $root 'vanished.tmp')){throw 'Missing file accepted'}
$env:OneDrive=$root
if(Test-CleanupPath (Join-Path $root 'old.tmp')){throw 'Cloud directory accepted'}
''')

    def test_cleanup_skips_changed_files_and_never_falls_back_after_failure(self):
        rows, _ = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$path=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'file.tmp'
[IO.File]::WriteAllText($path,'fixture')
$script:stamp=(Get-Item $path).LastWriteTime; $script:bytes=7; $script:recycles=0
function Get-CleanupCandidates {param($Scope) [pscustomobject]@{Path=$path;Modified=$script:stamp;Bytes=$script:bytes}}
function Move-CleanupFileToRecycleBin {param($Path) $script:recycles++; throw 'Cannot recycle'}
try { Invoke-RecycleCleanup Safe } catch { Write-OperationResult Failed 'Cleanup Safe' $_.Exception.Message }
# No permanent deletion is available.
if(-not (Test-Path $path) -or $script:recycles -ne 1){throw 'Unsafe failure handling'}
$script:bytes=999
try { Invoke-RecycleCleanup Safe } catch { Write-OperationResult Failed 'Cleanup Safe' $_.Exception.Message }
if($script:recycles -ne 1){throw 'Changed file was recycled'}
''')
        self.assertTrue(all(r['Status'] == 'Failed' for r in rows))
        self.assertTrue(any('changed after scanning' in r['Detail'] for r in rows))

    def test_deep_cleanup_cancel_does_not_recycle(self):
        rows, _ = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$script:inventoryShown=$false
function Get-CleanupCandidates {param($Scope) [pscustomobject]@{Path='example.zip';Modified=(Get-Date);Bytes=7}}
function Show-AppInventory { $script:inventoryShown=$true}
function Get-DuplicateDownloads {}
function Show-StorageSummary {}
function Out-GridView {param($Title,[switch]$PassThru)}
function Move-CleanupFileToRecycleBin {throw 'Cancellation must not recycle'}
Invoke-RecycleCleanup Deep
if(-not $script:inventoryShown){throw 'App inventory was not shown'}
''')
        self.assertEqual(rows[0]['Status'], 'AlreadyConfigured')

    def test_storage_measurement_does_not_double_count_nested_categories(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'documents'
$pictures=Join-Path $root 'pictures'
$null=New-Item -ItemType Directory $pictures -Force
[IO.File]::WriteAllBytes((Join-Path $root 'doc.bin'),[byte[]]::new(10))
[IO.File]::WriteAllBytes((Join-Path $pictures 'photo.bin'),[byte[]]::new(20))
$usage=@(Measure-StorageRoots @(
    [pscustomobject]@{Category='Documents';Path=$root},
    [pscustomobject]@{Category='Pictures';Path=$pictures}
))
if(($usage | Where-Object Category -eq Documents).Bytes -ne 10){throw 'Nested picture counted in Documents'}
if(($usage | Where-Object Category -eq Pictures).Bytes -ne 20){throw 'Picture size incorrect'}
''')

    def test_storage_marks_missing_and_linked_ancestors_partial(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$base=Split-Path $env:OPTIMIZER_RESULTS
$target=Join-Path $base 'target'
$child=Join-Path $target 'child'
$null=New-Item -ItemType Directory $child -Force
[IO.File]::WriteAllBytes((Join-Path $child 'file.bin'),[byte[]]::new(20))
$link=Join-Path $base 'linked'
$null=New-Item -ItemType Junction -Path $link -Target $target
$rows=@(Measure-StorageRoots @(
    [pscustomobject]@{Category='Linked';Path=(Join-Path $link 'child')},
    [pscustomobject]@{Category='Missing';Path=(Join-Path $base 'missing')}
))
if($rows.Count -ne 2 -or @($rows | Where-Object {-not $_.Partial -or $_.Bytes -ne 0}).Count){throw 'Unavailable data claimed as scanned'}
''')

    def test_storage_summary_shows_gb_categories_and_investigation_paths(self):
        _, output = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
function Get-StorageRoots {}
function Measure-StorageRoots {param($Roots)
    [pscustomobject]@{Category='Pictures';Bytes=2GB;Path='C:\Pictures';Partial=$false}
    [pscustomobject]@{Category='Apps';Bytes=5GB;Path='C:\Apps';Partial=$true}
}
Show-StorageSummary
''')
        for expected in ['Free GB', 'Used GB', 'Pictures', 'Apps', 'Partial', 'C:\\Pictures', 'not additive']:
            self.assertIn(expected, output)

    def test_duplicate_downloads_keep_one_copy_and_skip_nested_and_different_content(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'downloads'
$nested=Join-Path $root 'portable'
$null=New-Item -ItemType Directory $nested -Force
foreach($name in @('original.zip','copy.zip','different.zip','different-extension.exe')){[IO.File]::WriteAllText((Join-Path $root $name), $(if($name -eq 'different.zip'){'xyz'}else{'abc'}))}
(Get-Item (Join-Path $root 'original.zip')).CreationTimeUtc=(Get-Date).AddDays(-1)
[IO.File]::WriteAllText((Join-Path $nested 'nested.zip'),'abc')
function Get-DownloadsFolder {$root}
$dupes=@(Get-DuplicateDownloads)
if($dupes.Count -ne 1 -or $dupes[0].Path -ne (Join-Path $root 'copy.zip') -or $dupes[0].KeepPath -ne (Join-Path $root 'original.zip')){throw 'Incorrect duplicate selection'}
$script:moved=0
function Move-CleanupFileToRecycleBin {param($Path)
    $script:moved++
    if($Path -ne (Join-Path $root 'copy.zip')){throw 'Wrong file'}
    $write=$null
    try {$write=[IO.File]::Open((Join-Path $root 'original.zip'),'Open','Write','ReadWrite')} catch {}
    if($write){$write.Dispose(); throw 'Retained copy was not locked against changes'}
}
if(-not (Invoke-RecycleFiles $dupes) -or $script:moved -ne 1){throw 'Duplicate not processed'}
[IO.File]::WriteAllText((Join-Path $root 'original.zip'),'xyz')
if((Invoke-RecycleFiles $dupes) -or $script:moved -ne 1){throw 'Changed retained copy was not protected'}
''')

    def test_duplicate_downloads_do_not_discard_unique_alternate_streams(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'downloads'
$null=New-Item -ItemType Directory $root
foreach($name in @('first.zip','second.zip')) {[IO.File]::WriteAllText((Join-Path $root $name),'same file body')}
Set-Content -LiteralPath (Join-Path $root 'second.zip') -Stream UniqueNotes -Value 'important unique data'
function Get-DownloadsFolder {$root}
if(@(Get-DuplicateDownloads).Count){throw 'Would recycle unique alternate-stream data'}
Set-Content -LiteralPath (Join-Path $root 'first.zip') -Stream UniqueNotes -Value 'important unique data'
if(@(Get-DuplicateDownloads).Count -ne 1){throw 'Matching alternate streams should still deduplicate'}
''')

    def test_locked_file_cannot_reach_shell_recycling(self):
        rows, _ = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$path=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'locked.tmp'
[IO.File]::WriteAllText($path,'preserve me')
$item=Get-Item $path
$candidate=[pscustomobject]@{Path=$path;Bytes=$item.Length;Modified=$item.LastWriteTime}
function Initialize-RecycleApi {throw 'BUG: locked file reached recycling API'}
$handle=[IO.File]::Open($path,'Open','ReadWrite','None')
try {if(Invoke-RecycleFiles @($candidate)){throw 'Locked file reported success'}} finally {$handle.Dispose()}
if([IO.File]::ReadAllText($path) -ne 'preserve me'){throw 'Locked fixture changed'}
''')
        self.assertEqual(rows[0]['Status'], 'Failed')
        self.assertNotIn('BUG:', rows[0]['Detail'])

    @unittest.skipUnless(os.environ.get('OPTIMIZER_TEST_RECYCLE') == '1', 'Opt-in: moves and restores a generated Recycle Bin fixture')
    def test_real_duplicate_recycling_preserves_survivor_and_reaches_recycle_bin(self):
        rows, _ = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'downloads'
$null=New-Item -ItemType Directory $root
$id=[guid]::NewGuid().ToString('N')
$original=Join-Path $root ('optimizer-test-original-'+$id+'.zip')
$copy=Join-Path $root ('optimizer-test-copy-'+$id+'.zip')
[IO.File]::WriteAllText($original,'Generated integration test content')
[IO.File]::WriteAllText($copy,'Generated integration test content')
Set-Content -LiteralPath $original -Stream TestNotes -Value 'fixture metadata'
Set-Content -LiteralPath $copy -Stream TestNotes -Value 'fixture metadata'
(Get-Item $original).CreationTimeUtc=(Get-Date).AddDays(-1)
function Get-DownloadsFolder {$root}
$duplicates=@(Get-DuplicateDownloads)
if($duplicates.Count -ne 1 -or $duplicates[0].Path -ne $copy){throw 'Fixture duplicate discovery failed'}
if(-not (Invoke-RecycleFiles $duplicates)){throw 'Real recycling failed'}
if((Test-Path $copy) -or [IO.File]::ReadAllText($original) -ne 'Generated integration test content'){throw 'Survivor/original path assertion failed'}
$shell=New-Object -ComObject Shell.Application
try {
    $name=[IO.Path]::GetFileName($copy)
    $entry=@($shell.Namespace(10).Items() | Where-Object {$_.Name -in @($name,[IO.Path]::GetFileNameWithoutExtension($name))})
    if($entry.Count -ne 1){throw 'Generated duplicate not found in Recycle Bin'}
    # Restore only this uniquely named fixture; never empty or alter other bin entries.
    $entry[0].InvokeVerb('undelete')
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while(-not (Test-Path $copy) -and $timer.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 100}
    if(-not (Test-Path $copy)){throw 'Fixture restore did not finish'}
    if([IO.File]::ReadAllText($copy) -ne [IO.File]::ReadAllText($original)){throw 'Restored bytes differ'}
    if((Get-Content -LiteralPath $copy -Stream TestNotes -Raw) -ne (Get-Content -LiteralPath $original -Stream TestNotes -Raw)){throw 'Restored alternate stream differs'}
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
''')
        self.assertEqual(rows[0]['Status'], 'Applied')
        self.assertTrue(rows[0]['Verified'])

    def test_report_archive_exception_does_not_allow_report_queue(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$env:ProgramData=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'programdata'
$archive=Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'
$queue=Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'
$null=New-Item -ItemType Directory $archive,$queue -Force
if(-not (Test-CleanupPath $archive)){throw 'Archive should be eligible'}
if(Test-CleanupPath $queue){throw 'Pending queue must remain protected'}
$roots=@(Get-CleanupRoots Deep | Where-Object Category -eq 'Archived crash report - review')
if(-not ($roots.Path -contains $archive) -or @($roots | Where-Object Days -ne 30).Count){throw 'Incorrect archive rules'}
''')

    def test_largest_app_folders_match_installed_names_and_show_gb(self):
        _, output = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'apps'
$fixtureInstallPath=Join-Path $root 'Example'
$null=New-Item -ItemType Directory $fixtureInstallPath -Force
function Get-AppInventory {[pscustomobject]@{App='Example Game';Path=$fixtureInstallPath}}
function Get-StorageRoots {[pscustomobject]@{Category='Apps';Path=$root}}
function Measure-StorageRoots {param($Roots) [pscustomobject]@{Category='Example';Path=$fixtureInstallPath;Bytes=3GB;Partial=$false}}
Show-AppInventory
''')
        self.assertIn('Example Game', output)
        self.assertIn('GB', output)
        self.assertIn('LARGEST APPLICATION FOLDERS', output)

    def test_recycle_api_compiles_without_touching_files(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
Initialize-RecycleApi
if(-not ('OptimizerRecycle' -as [type])){throw 'Recycle API did not compile'}
''')

    def test_windowed_flag_preserves_other_graphics_preferences(self):
        rows, _ = self.run_case(r'''
function Get-ItemPropertyValue {param($Path,$Name,$ErrorAction) '26300'}
function Get-RegistryState {param($Path,$Name) @{Exists=$true;Type='String';Value='AutoHDREnable=1;SwapEffectUpgradeEnable=0;FutureFlag=keep;'}}
function Invoke-RegistryChange {param($Tokens)
    $value=Get-ArgumentValue $Tokens '/d'
    if($value -ne 'AutoHDREnable=1;FutureFlag=keep;SwapEffectUpgradeEnable=1;'){throw "Preferences lost: $value"}
    Write-OperationResult Applied 'Windowed' $value $true
}
$null=Invoke-Operation 'Windowed Enable'
''')
        self.assertEqual(rows[0]['Status'], 'Applied')

    def test_old_windows_skips_windowed_flag_without_writing(self):
        rows, _ = self.run_case(r'''
function Get-ItemPropertyValue {param($Path,$Name,$ErrorAction) '19045'}
function Invoke-RegistryChange {throw 'Unsupported Windows must not be modified'}
$null=Invoke-Operation 'Windowed Enable'
''')
        self.assertEqual(rows[0]['Status'], 'Unsupported')

    def test_integrity_off_does_not_bypass_lock(self):
        rows, _ = self.run_case(r'''
function Get-RegistryState {param($Path,$Name) if($Name -eq 'Locked'){@{Exists=$true;Value=1}}else{@{Exists=$false}}}
function Invoke-RegistryChange {throw 'Locked security must not be modified'}
$null=Invoke-Operation 'Integrity Off'
''')
        self.assertEqual(rows[0]['Status'], 'Unsupported')

    def test_integrity_configuration_and_runtime_are_distinguished(self):
        rows, _ = self.run_case(r'''
$script:enabled=1; $script:running=@(2)
function Get-RegistryState {param($Path,$Name) if($Name -eq 'Enabled'){@{Exists=$true;Value=$script:enabled}}else{@{Exists=$false}}}
function Get-CimInstance {param($Namespace,$ClassName,$ErrorAction) [pscustomobject]@{SecurityServicesRunning=$script:running}}
function Invoke-RegistryChange {param($Tokens) $script:enabled=[int](Get-ArgumentValue $Tokens '/d')}
$null=Invoke-Operation 'Integrity Off'
$null=Invoke-Operation 'Integrity Off'
$script:running=@(0); $null=Invoke-Operation 'Integrity Off'
$null=Invoke-Operation 'Integrity On'
''')
        self.assertEqual([r['Status'] for r in rows], ['RestartRequired','RestartRequired','AlreadyConfigured','RestartRequired'])

    def test_display_check_never_changes_modes_or_gpu_preferences(self):
        rows, output = self.run_case(r'''
function Get-DisplayModes {@(
    [pscustomobject]@{Name='First';Width=2560;Height=1440;CurrentHz=60;HighestHz=144},
    [pscustomobject]@{Name='Second';Width=1920;Height=1080;CurrentHz=144;HighestHz=144}
)}
function Get-CimInstance {param($ClassName,$ErrorAction) [pscustomobject]@{Name='Example GPU'}}
function Test-Path {param($LiteralPath) $false}
function Set-ItemProperty {throw 'Display check must not write'}
function Invoke-NativeOperation {throw 'Display check must not run mutations'}
$null=Invoke-Operation 'Graphics Check'
''')
        self.assertEqual([r['Status'] for r in rows], ['Unverified','AlreadyConfigured','Unverified'])
        self.assertIn('144 Hz', rows[0]['Detail'])
        self.assertIn('Example GPU', output)

if __name__ == '__main__':
    unittest.main(verbosity=2)
