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


    def test_activity_indicator_ticks_preserves_output_and_failure_code(self):
        rows, output = self.run_case(r'''
$fixture=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'worker fixture.ps1'
@'
param([switch]$NoRun)
function Invoke-Operation($Text) {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Cleanup UI requires STA' }
    Write-Host 'Visible operation message'
    Start-Sleep -Milliseconds 850
    return [int]$Text
}
'@ | Set-Content -LiteralPath $fixture
$script:updates=@()
function Write-Progress {param($Id,$Activity,$Status,$PercentComplete,[switch]$Completed)
    $script:updates+=@{Status=$Status;Completed=[bool]$Completed}
}
if ((Invoke-OperationWithProgress '1' $fixture) -ne 1) {throw 'Failure code was lost'}
$active=@($script:updates | Where-Object {-not $_.Completed})
if($active.Count -lt 2 -or $active[0].Status -eq $active[1].Status){throw 'Indicator did not animate'}
if(-not $script:updates[-1].Completed){throw 'Indicator not cleared'}
'param([switch]$NoRun); function Invoke-Operation($Text) {throw "Worker failed"}' | Set-Content -LiteralPath $fixture
$threw=$false
try {$null=Invoke-OperationWithProgress '0' $fixture} catch {$threw=$true}
if(-not $threw -or -not $script:updates[-1].Completed){throw 'Worker error was swallowed or indicator remained'}
if ((Invoke-OperationWithProgress 'Unknown Test') -ne 1) {throw 'Default worker path lost failure code'}
''')
        self.assertIn('Visible operation message', output)
        self.assertEqual([r['Status'] for r in rows], ['Failed'])

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

    def test_denied_widgets_button_is_skipped_without_hiding_registry_failures(self):
        rows, output = self.run_case(r'''
function Get-RegistryState {param($Path,$Name) @{Exists=$false}}
$script:diagnostic='ERROR: Access is denied.'
function Invoke-NativeOperation {param($Program,$Arguments) [pscustomobject]@{Code=1;Output=$script:diagnostic}}
$prefix='Registry reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v '
$null=Invoke-Operation ($prefix+'TaskbarDa /t REG_DWORD /d 0 /f')
$null=Invoke-Operation ($prefix+'TaskbarAnimations /t REG_DWORD /d 0 /f')
$script:diagnostic='ERROR: Invalid syntax.'
$null=Invoke-Operation ($prefix+'TaskbarDa /t REG_DWORD /d 0 /f')
''')
        self.assertEqual([r['Status'] for r in rows], ['Unsupported', 'Failed', 'Failed'])
        self.assertFalse(rows[0]['Verified'])
        self.assertIn('Access is denied', rows[0]['Detail'])
        self.assertNotIn('[ERROR] Widgets taskbar button', output)
        self.assertEqual(output.count('[ERROR]'), 2)

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
        self.assertIn('FINISHED WITH ISSUES', stdout)
        self.assertNotIn('All supported, attempted operations have verified', stdout)
        self.assertEqual(len(rows), 3)

    def test_summary_marks_unverified_run_incomplete(self):
        _, stdout = self.run_case(r'''
Write-OperationResult Unverified 'Command' 'unknown'
if((Show-OperationSummary) -ne 2){throw 'Unverified was counted as success'}
''')
        self.assertIn('FINISHED - REVIEW NEEDED', stdout)

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
        self.assertIn('2 files moved to Recycle Bin (5.00 GB)', summary)
        self.assertIn('Gaming, graphics & input', summary)
        self.assertIn('Restart        Needed', summary)
        self.assertIn('Not applied    1 change.', summary)
        self.assertNotIn('DO_NOT_REPEAT_RAW_ERROR', summary)
        self.assertNotIn('C:\\first.zip', summary)
        self.assertLess(len(summary.splitlines()), 18)
        self.assertIn('Duplicate downloads: 1', summary)
        self.assertIn('Log: logs\\log.txt', summary)
        self.assertIn('    - Gaming, graphics & input', summary)

    def test_cleanup_summary_uses_readable_units_for_small_amounts(self):
        _, output = self.run_case(r'''
foreach($bytes in @(0,1,512,1KB,1MB,3MB,1GB)) {
    $env:OPTIMIZER_ACTION_ID=[string]$bytes
    Write-OperationResult Applied 'Recycle C:\small.zip' 'recycled' $true $bytes
    $null=Show-OperationSummary
}
''')
        for size in ('0 B', '1 B', '512 B', '1.00 KB', '1.00 MB', '3.00 MB', '1.00 GB'):
            self.assertIn(f'1 file moved to Recycle Bin ({size})', output)
        self.assertNotIn('0.00 GB', output)

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
        self.assertIn('1 file moved to Recycle Bin (1.00 GB)', current)
        self.assertIn('Memory & security', session)
        self.assertIn('1 file moved to Recycle Bin (1.00 GB)', session)

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

    def test_failed_plan_creation_returns_failure_even_when_fallback_succeeds(self):
        rows, _ = self.run_case(r'''
function Test-ManagedCoreParking {$false}
function Get-PowerCapabilities {@{ModernStandby=$false;Portable=$false}}
function Get-PerformancePlans {}
$script:active=[guid]'381b4222-f694-41f0-9685-ff5bb260df2e'
function Get-ActivePowerScheme {$script:active}
function Invoke-NativeOperation {param($Program,$Arguments)
    if($Arguments[0] -eq '-duplicatescheme'){return [pscustomobject]@{Code=5;Output='Creation denied'}}
    if($Arguments[0] -ne '-setactive' -or $Arguments[1] -ne 'SCHEME_MIN'){throw 'Unexpected mutation'}
    $script:active=[guid]'8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    [pscustomobject]@{Code=0;Output=''}
}
if((Invoke-Operation 'Plan Ultimate') -ne 1){throw 'Recorded failure incorrectly returned success'}
if($script:active -ne [guid]'8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'){throw 'Fallback did not apply'}
if((Invoke-Operation 'Native powercfg -setactive SCHEME_MIN') -ne 0){throw 'Previous failure leaked into next operation'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Failed', 'Applied', 'AlreadyConfigured'])

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
$files=@(Get-CleanupFiles @([pscustomobject]@{Path=$root;Category='Fixture';Days=30;Extensions=@('.tmp')}))
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
function Show-PossibleLeftoverFolders {}
function Get-DuplicateDownloads {}
function Get-AutomaticCleanupFiles {}
function Show-StorageSummary {}
function Out-GridView {param($Title,[switch]$PassThru)}
function Move-CleanupFileToRecycleBin {throw 'Cancellation must not recycle'}
Invoke-RecycleCleanup Deep
if(-not $script:inventoryShown){throw 'App inventory was not shown'}
''')
        self.assertEqual(rows[0]['Status'], 'AlreadyConfigured')

    def test_automatic_downloads_require_both_dates_and_skip_nested_files_and_active_apps(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$env:ProgramData=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'programdata'
$env:APPDATA=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'roaming'
$env:LOCALAPPDATA=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'local'
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'downloads'
$null=New-Item -ItemType Directory (Join-Path $root 'nested') -Force
foreach($name in @('old.part','old.crdownload','new.part','copied.part','old.zip','nested\old.part')) {
    $p=Join-Path $root $name
    [IO.File]::WriteAllText($p,'fixture')
    (Get-Item $p).CreationTime=(Get-Date).AddDays(-40)
    (Get-Item $p).LastWriteTime=(Get-Date).AddDays(-40)
}
(Get-Item (Join-Path $root 'new.part')).LastWriteTime=Get-Date
(Get-Item (Join-Path $root 'copied.part')).CreationTime=Get-Date
$script:fixtureDownloads=$root
function Get-DownloadsFolder {$script:fixtureDownloads}
function Get-Process {}
function Get-OldDriverExtractionFiles {}
$files=@(Get-AutomaticCleanupFiles)
if($files.Count -ne 2){throw ('Age, extension or loose-download boundary failed: '+($files | ConvertTo-Json -Depth 4))}
function Get-Process {[pscustomobject]@{ProcessName='chrome';Path=''}}
if(@(Get-AutomaticCleanupFiles).Count){throw 'Active browser files selected'}
''')

    def test_automatic_crash_reports_use_known_paths_and_preserve_recent_reports(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$env:ProgramData=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'programdata'
$env:APPDATA=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'roaming'
$env:LOCALAPPDATA=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'local'
function Get-DownloadsFolder {''}
function Get-Process {}
function Get-OldDriverExtractionFiles {}
$report=Join-Path $env:APPDATA 'discord\Crashpad\reports'
$other=Join-Path $env:APPDATA 'discord\userdata'
$null=New-Item -ItemType Directory $report,$other -Force
foreach($p in @((Join-Path $report 'old.dmp'),(Join-Path $report 'recent.dmp'),(Join-Path $report 'keep.json'),(Join-Path $other 'old.dmp'))) {
    [IO.File]::WriteAllText($p,'fixture')
    (Get-Item $p).CreationTime=(Get-Date).AddDays(-40)
    (Get-Item $p).LastWriteTime=(Get-Date).AddDays(-40)
}
(Get-Item (Join-Path $report 'recent.dmp')).LastWriteTime=Get-Date
$files=@(Get-AutomaticCleanupFiles)
if($files.Count -ne 1 -or $files[0].Path -ne (Join-Path $report 'old.dmp')){throw 'Crash report boundary failed'}
function Get-Process {[pscustomobject]@{ProcessName='Discord';Path=''}}
if(@(Get-AutomaticCleanupFiles).Count){throw 'Active Discord selected'}
''')

    def test_automatic_web_cache_and_logs_preserve_user_data_and_skip_running_apps(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$base=Split-Path $env:OPTIMIZER_RESULTS
$env:ProgramData=Join-Path $base 'programdata'
$env:APPDATA=Join-Path $base 'roaming'
$env:LOCALAPPDATA=Join-Path $base 'local'
function Get-DownloadsFolder {''}
function Get-Process {}
function Get-OldDriverExtractionFiles {}
$eligible=@(
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache\Cache_Data\entry'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Profile 2\Cache\Cache_Data\entry'),
    (Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles\example.default\cache2\entries\entry'),
    (Join-Path $env:APPDATA 'Code\logs\session\main.log'),
    (Join-Path $env:APPDATA 'Slack\logs\app.log'),
    (Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved\Logs\launcher.log'))
$protected=@(
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cookies'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Sessions\tabs'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\GPUCache\entry'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Custom\Cache\Cache_Data\entry'),
    (Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles\example.default\OfflineCache\entry'),
    (Join-Path $env:APPDATA 'Code\User\History\backup.log'),
    (Join-Path $env:APPDATA 'Code\logs\settings.json'),
    (Join-Path $env:APPDATA 'Slack\Local Storage\data'),
    (Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved\Config\settings.ini'))
foreach($p in @($eligible)+@($protected)) {
    $null=New-Item -ItemType Directory (Split-Path $p) -Force
    [IO.File]::WriteAllText($p,'fixture')
    (Get-Item $p).CreationTime=(Get-Date).AddDays(-40)
    (Get-Item $p).LastWriteTime=(Get-Date).AddDays(-40)
}
$files=@(Get-AutomaticCleanupFiles)
if($files.Count -ne $eligible.Count -or @($files | Where-Object Path -in $protected).Count){throw 'Cache/log scan included saved data or missed targets'}
foreach($p in $eligible){if($p -notin $files.Path){throw "Missed $p"}}
(Get-Item $eligible[0]).LastWriteTime=Get-Date
if(@(Get-AutomaticCleanupFiles).Count -ne ($eligible.Count-1)){throw 'Recent cache selected'}
function Get-Process {
    foreach($name in @('chrome','msedge','firefox','Code','slack','EpicGamesLauncher')) {
        [pscustomobject]@{ProcessName=$name;Path=''}
    }
}
if(@(Get-AutomaticCleanupFiles).Count){throw 'Running application files selected'}
if(@(Get-CleanupCandidates Safe).Count){throw 'Quick selected running application files'}
function Move-CleanupFileToRecycleBin {throw 'Running application files must never reach recycling'}
Invoke-RecycleCleanup Safe
if($script:OperationFailed){throw 'Skipping running applications was reported as a failure'}
''')

    def test_deep_cleanup_automates_old_temp_and_archived_reports_only(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$base=Split-Path $env:OPTIMIZER_RESULTS
$env:ProgramData=Join-Path $base 'programdata'
$env:APPDATA=Join-Path $base 'roaming'
$env:LOCALAPPDATA=Join-Path $base 'local'
function Get-DownloadsFolder {''}
function Get-Process {}
function Get-OldDriverExtractionFiles {}
$eligible=@(
    (Join-Path $env:LOCALAPPDATA 'Temp\old.tmp'),
    (Join-Path $env:LOCALAPPDATA 'CrashDumps\app.dmp'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive\report\Report.wer'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive\report\Report.wer'))
$queue=Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue\pending\Report.wer'
foreach($p in @($eligible)+@($queue)) {
    $null=New-Item -ItemType Directory (Split-Path $p) -Force
    [IO.File]::WriteAllText($p,'fixture')
    (Get-Item $p).CreationTime=(Get-Date).AddDays(-40)
    (Get-Item $p).LastWriteTime=(Get-Date).AddDays(-40)
}
$files=@(Get-AutomaticCleanupFiles)
if($files.Count -ne 4 -or $queue -in $files.Path){throw 'Automatic system cleanup boundary failed'}
if(@(Get-CleanupCandidates Deep).Count){throw 'Automatic files offered twice'}
if(@(Get-CleanupCandidates Safe).Count -ne 4){throw 'Quick cleanup missed shared temp/crash targets'}
(Get-Item $eligible[0]).CreationTime=Get-Date
if(@(Get-AutomaticCleanupFiles).Count -ne 3){throw 'Recently created temp file selected'}
''')

    def test_deep_includes_every_quick_rule_once_and_keeps_expensive_scans_separate(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$base=Split-Path $env:OPTIMIZER_RESULTS
$env:ProgramData=Join-Path $base 'programdata'
$env:APPDATA=Join-Path $base 'roaming'
$env:LOCALAPPDATA=Join-Path $base 'local'
function Get-DownloadsFolder {throw 'Quick must not inspect Downloads'}
$quickRoots=@(Get-AutomaticCleanupRoots 'Safe')
if(-not @($quickRoots | Where-Object Category -eq 'Old application log').Count){throw 'Quick missed app logs'}
if(-not @($quickRoots | Where-Object Category -eq 'Old application crash report').Count){throw 'Quick missed app crashes'}
function Get-DownloadsFolder {Join-Path $base 'downloads'}
$deepRoots=@(Get-AutomaticCleanupRoots)
foreach($root in $quickRoots) {
    $matches=@($deepRoots | Where-Object Path -eq $root.Path)
    if($matches.Count -ne 1 -or $matches[0].Days -ne $root.Days -or $matches[0].Automatic -ne $root.Automatic){throw 'Deep differs from Quick or duplicates a shared rule'}
}
$log=Join-Path $env:APPDATA 'Code\logs\old.log'
$null=New-Item -ItemType Directory (Split-Path $log) -Force
[IO.File]::WriteAllText($log,'fixture')
(Get-Item $log).LastWriteTime=(Get-Date).AddDays(-40)
if(@(Get-CleanupCandidates Safe).Count){throw 'Quick accepted recently created old-dated file'}
(Get-Item $log).CreationTime=(Get-Date).AddDays(-40)
function Get-Process {}
function Get-OldDriverExtractionFiles {}
$quick=@(Get-CleanupCandidates Safe)
$deep=@(Get-AutomaticCleanupFiles)
if($quick.Count -ne 1 -or $deep.Count -ne 1 -or $quick[0].Path -ne $deep[0].Path){throw 'Deep did not include Quick candidate exactly once'}
''')

    def test_driver_extractions_require_signed_layout_keep_newest_and_skip_recent_or_running(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'drivers'
function Get-DriverExtractionRoots {[pscustomobject]@{Path=$root;Vendor='NVIDIA'}}
function Get-Process {}
function Get-AuthenticodeSignature {param($LiteralPath)
    [pscustomobject]@{Status=$(if($LiteralPath -like '*unsigned*'){'NotSigned'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='CN=NVIDIA Corporation'}}
}
foreach($name in @('old','newest','recent','unsigned','unrecognized')) {
    $p=Join-Path $root $name
    $null=New-Item -ItemType Directory (Join-Path $p 'Display.Driver') -Force
    [IO.File]::WriteAllText((Join-Path $p 'Setup.exe'),'fixture')
    if($name -ne 'unrecognized'){[IO.File]::WriteAllText((Join-Path $p 'Display.Driver\nv.inf'),'fixture')}
    foreach($file in Get-ChildItem $p -Recurse -File) {
        $file.CreationTime=(Get-Date).AddDays(-60)
        $file.LastWriteTime=(Get-Date).AddDays(-60)
    }
}
(Get-Item (Join-Path $root 'newest\Setup.exe')).LastWriteTime=(Get-Date).AddDays(-40)
(Get-Item (Join-Path $root 'recent\Setup.exe')).CreationTime=Get-Date
$files=@(Get-OldDriverExtractionFiles)
# The recent package is retained as newest; both older signed packages are eligible.
if($files.Count -ne 4 -or @($files | Where-Object {$_.Path -match 'unsigned|unrecognized|recent'}).Count){throw 'Driver recognition or age boundary failed'}
# Removing the recent recognized package leaves the newest old one protected.
function Get-AuthenticodeSignature {param($LiteralPath)
    [pscustomobject]@{Status=$(if($LiteralPath -match 'unsigned|recent'){'NotSigned'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='CN=NVIDIA Corporation'}}
}
$files=@(Get-OldDriverExtractionFiles)
if($files.Count -ne 2 -or @($files | Where-Object {$_.Path -notlike '*\old\*'}).Count){throw 'Newest old package was not retained'}
function Get-Process {[pscustomobject]@{ProcessName='setup';Path=''}}
if(@(Get-OldDriverExtractionFiles).Count){throw 'Running installer was ignored'}
''')

    def test_amd_driver_extractions_preserve_incomplete_and_wrong_publisher_packages(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'drivers'
function Get-DriverExtractionRoots {[pscustomobject]@{Path=$root;Vendor='AMD'}}
function Get-Process {}
function Get-AuthenticodeSignature {param($LiteralPath)
    [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject=$(if($LiteralPath -like '*wrong*'){'CN=Other Company'}else{'CN=Advanced Micro Devices, Inc.'})}}
}
foreach($name in @('old','newest','wrong','incomplete')) {
    $p=Join-Path $root $name
    $null=New-Item -ItemType Directory (Join-Path $p 'Packages\Drivers\Display') -Force
    [IO.File]::WriteAllText((Join-Path $p 'Setup.exe'),'fixture')
    [IO.File]::WriteAllText((Join-Path $p 'Packages\Drivers\Display\amd.inf'),'fixture')
    foreach($file in Get-ChildItem $p -Recurse -File) {
        $file.CreationTime=(Get-Date).AddDays(-60)
        $file.LastWriteTime=(Get-Date).AddDays(-60)
    }
}
(Get-Item (Join-Path $root 'newest\Setup.exe')).LastWriteTime=(Get-Date).AddDays(-40)
$originalPathCheck=${function:Test-CleanupPath}
function Test-CleanupPath {param($Path)
    if($Path -like '*\incomplete\Packages\Drivers\Display\amd.inf'){return $false}
    & $originalPathCheck $Path
}
$files=@(Get-OldDriverExtractionFiles)
if($files.Count -ne 2 -or @($files | Where-Object {$_.Path -notlike '*\old\*'}).Count){throw 'Unsafe AMD package selection'}
''')

    def test_automatic_cleanup_runs_before_optional_selection_and_rechecks_processes(self):
        rows, _ = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$p=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'old.part'
[IO.File]::WriteAllText($p,'fixture')
$file=[pscustomobject]@{Path=$p;Bytes=7;Modified=(Get-Item $p).LastWriteTime;Processes=@('chrome')}
function Show-StorageSummary {}
function Show-AppInventory {}
function Show-PossibleLeftoverFolders {}
function Get-DuplicateDownloads {}
function Get-AutomaticCleanupFiles {$file}
function Get-CleanupCandidates {}
function Get-Process {}
function Out-GridView {throw 'No review candidates'}
function Move-CleanupFileToRecycleBin {param($Path) [IO.File]::Delete($Path)}
Invoke-RecycleCleanup Deep
if(Test-Path $p){throw 'Automatic cleanup did not recycle'}
[IO.File]::WriteAllText($p,'fixture')
$file.Modified=(Get-Item $p).LastWriteTime
function Get-Process {[pscustomobject]@{ProcessName='chrome';Path=''}}
if(Invoke-RecycleFiles @($file)){throw 'Running app must block recycling'}
if(-not (Test-Path $p)){throw 'Running app file removed'}
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied', 'AlreadyConfigured', 'Failed'])

    def test_additional_package_extensions_deduplicate_by_content(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$root=Join-Path (Split-Path $env:OPTIMIZER_RESULTS) 'downloads'
$null=New-Item -ItemType Directory $root
function Get-DownloadsFolder {$root}
foreach($extension in @('.msixbundle','.appx','.appxbundle','.cab','.msp')) {
    [IO.File]::WriteAllText((Join-Path $root ('first'+$extension)),'same')
    [IO.File]::WriteAllText((Join-Path $root ('copy'+$extension)),'same')
    [IO.File]::WriteAllText((Join-Path $root ('unique'+$extension)),'diff')
}
if(@(Get-DuplicateDownloads).Count -ne 5){throw 'New package types not deduplicated correctly'}
''')

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
$roots=@(Get-AutomaticCleanupRoots | Where-Object Category -eq 'Archived crash report')
if(-not ($roots.Path -contains $archive) -or @($roots | Where-Object Days -ne 30).Count){throw 'Incorrect archive rules'}
''')

    def test_installed_names_include_steam_secondary_libraries_and_epic(self):
        self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$base=Split-Path $env:OPTIMIZER_RESULTS
$script:steamRoot=Join-Path $base 'steam'
$secondary=Join-Path $base 'secondary'
$env:ProgramData=Join-Path $base 'programdata'
$epic=Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
foreach($p in @((Join-Path $script:steamRoot 'steamapps'),(Join-Path $secondary 'steamapps'),$epic)) {
    $null=New-Item -ItemType Directory $p -Force
}
[IO.File]::WriteAllText((Join-Path $script:steamRoot 'steamapps\libraryfolders.vdf'),('"path" "'+$secondary.Replace('\','\\')+'"'))
[IO.File]::WriteAllText((Join-Path $secondary 'steamapps\appmanifest_252950.acf'),'"AppState" { "name" "Rocket League" }')
[IO.File]::WriteAllText((Join-Path $epic 'fortnite.item'),'{"DisplayName":"Fortnite"}')
[IO.File]::WriteAllText((Join-Path $epic 'invalid.item'),'invalid JSON')
function Get-AppInventory {[pscustomobject]@{App='Call of Duty: Vanguard';Path='ignored'}}
function Get-ItemPropertyValue {$script:steamRoot}
$names=@(Get-CleanupInstalledNames)
foreach($name in @('Call of Duty: Vanguard','Rocket League','Fortnite')) {
    if($name -notin $names){throw "Missing installation record: $name"}
}
if($names.Count -ne 3){throw 'Malformed record was accepted'}
''')

    def test_leftover_report_excludes_installed_and_running_games_without_changes(self):
        _, output = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$base=Split-Path $env:OPTIMIZER_RESULTS
foreach($name in @('Vanguard','Fortnite','Rocket')) {
    $p=Join-Path $base $name
    $null=New-Item -ItemType Directory $p
    [IO.File]::WriteAllText((Join-Path $p 'save.dat'),'keep me')
}
function Get-KnownGameFolders {
    [pscustomobject]@{Game='Call of Duty Vanguard';Path=(Join-Path $base 'Vanguard');Processes=@('Vanguard')}
    [pscustomobject]@{Game='Fortnite';Path=(Join-Path $base 'Fortnite');Processes=@('Fortnite')}
    [pscustomobject]@{Game='Rocket League';Path=(Join-Path $base 'Rocket');Processes=@('RocketLeague')}
}
function Get-CleanupInstalledNames {'Call of Duty: Vanguard'}
function Get-Process {[pscustomobject]@{ProcessName='RocketLeague';Path=''}}
Show-PossibleLeftoverFolders
foreach($name in @('Vanguard','Fortnite','Rocket')) {
    if([IO.File]::ReadAllText((Join-Path $base "$name\save.dat")) -ne 'keep me'){throw 'Report changed saved data'}
}
''')
        self.assertIn('Fortnite', output)
        self.assertIn('Remaining GB', output)
        self.assertNotIn('Vanguard', output)
        self.assertNotIn('Rocket League', output)
        self.assertIn('may contain saves', output)

    def test_game_diagnostics_recycle_before_remaining_size_is_measured(self):
        rows, output = self.run_case(r'''
. (Join-Path (Split-Path $env:TEST_ENGINE) 'optimizer-cleanup.ps1')
$base=Split-Path $env:OPTIMIZER_RESULTS
$env:LOCALAPPDATA=Join-Path $base 'local'
$env:APPDATA=Join-Path $base 'roaming'
$env:ProgramData=Join-Path $base 'programdata'
$script:gamePath=Join-Path $env:LOCALAPPDATA 'FortniteGame'
$logs=Join-Path $script:gamePath 'Saved\Logs'
$null=New-Item -ItemType Directory $logs -Force
[IO.File]::WriteAllText((Join-Path $logs 'old.log'),'old log')
[IO.File]::WriteAllText((Join-Path $logs 'recent.log'),'recent log')
[IO.File]::WriteAllText((Join-Path $script:gamePath 'save.dat'),'saved progress')
[IO.File]::WriteAllText((Join-Path $logs 'preferences.json'),'saved settings')
foreach($p in Get-ChildItem $script:gamePath -File -Recurse) {
    $p.CreationTime=(Get-Date).AddDays(-40)
    $p.LastWriteTime=(Get-Date).AddDays(-40)
}
(Get-Item (Join-Path $logs 'recent.log')).LastWriteTime=Get-Date
$script:knownFolders=@(Get-KnownGameFolders | Where-Object Path -eq $script:gamePath)
if($script:knownFolders.Count -ne 1){throw 'Built-in Fortnite folder detection failed'}
function Get-KnownGameFolders {
    $script:knownFolders
}
function Get-CleanupInstalledNames {}
function Get-Process {}
function Get-DownloadsFolder {''}
function Get-OldDriverExtractionFiles {}
function Get-DuplicateDownloads {}
function Get-CleanupCandidates {}
function Show-StorageSummary {}
function Show-AppInventory {}
function Move-CleanupFileToRecycleBin {param($Path) [IO.File]::Delete($Path)}
function Out-GridView {throw 'Unexpected selection dialog'}
$realMeasure=${function:Measure-StorageRoots}
function Measure-StorageRoots {param($Roots)
    if(Test-Path (Join-Path $script:gamePath 'Saved\Logs\old.log')){throw 'Measured before automatic cleanup'}
    $usage=@(& $realMeasure $Roots)
    if(($usage | Measure-Object Bytes -Sum).Sum -ne 38){throw 'Remaining size does not match surviving files'}
    $usage
}
Invoke-RecycleCleanup Deep
if(Test-Path (Join-Path $logs 'old.log')){throw 'Old diagnostic was not recycled'}
if([IO.File]::ReadAllText((Join-Path $script:gamePath 'save.dat')) -ne 'saved progress'){throw 'Save was changed'}
if(-not (Test-Path (Join-Path $logs 'preferences.json')) -or -not (Test-Path (Join-Path $logs 'recent.log'))){throw 'Unrelated or recent file changed'}
''')
        self.assertEqual(sum(r['Status'] == 'Applied' for r in rows), 1)
        self.assertIn('POSSIBLE LEFTOVER', output)
        self.assertIn('Remaining GB', output)

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
        rows, _ = self.run_case(r'''
function Get-DisplayModes {@(
    [pscustomobject]@{Name='First';Width=2560;Height=1440;CurrentHz=60;HighestHz=144},
    [pscustomobject]@{Name='Second';Width=1920;Height=1080;CurrentHz=144;HighestHz=144}
)}
function Get-CimInstance {throw 'Unused graphics inventory must not run'}
function Get-ItemProperty {throw 'Unused graphics inventory must not run'}
function Set-ItemProperty {throw 'Display check must not write'}
function Invoke-NativeOperation {throw 'Display check must not run mutations'}
$null=Invoke-Operation 'Graphics Check'
''')
        self.assertEqual([r['Status'] for r in rows], ['Unverified','AlreadyConfigured','Unverified'])
        self.assertIn('144 Hz', rows[0]['Detail'])

if __name__ == '__main__':
    unittest.main(verbosity=2)
