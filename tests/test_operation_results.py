"""Exercise the real result engine with mocked Windows mutations."""
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

    def test_app_enumeration_error_is_not_absence(self):
        rows, _ = self.run_case(r'''
function Get-AppxPackage {param($Name,$ErrorAction) @()}
function Get-AppxProvisionedPackage {param([switch]$Online,$ErrorAction) throw 'Access is denied.'}
if ((Invoke-Operation 'Appx Example.App') -ne 1) {throw 'App removal failure returned success'}
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured','Failed'])
        self.assertIn('provisioning', rows[1]['Operation'])

    def test_app_absence_returns_success_without_removal(self):
        rows, _ = self.run_case(r'''
function Get-AppxPackage {param($Name,$ErrorAction) @()}
function Get-AppxProvisionedPackage {param([switch]$Online,$ErrorAction) @()}
function Remove-AppxPackage {throw 'Absent app must not be removed'}
function Remove-AppxProvisionedPackage {throw 'Absent app must not be removed'}
if ((Invoke-Operation 'Appx Example.App') -ne 0) {throw 'Absent app returned failure'}
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured','AlreadyConfigured'])

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

    def test_power_plan_creation_and_activation_are_read_back(self):
        rows, _ = self.run_case(r'''
$script:active=''
$guid='11111111-2222-3333-4444-555555555555'
function Invoke-NativeOperation {param($Program,$Arguments)
    $output=''
    switch($Arguments[0]) {
        '-duplicatescheme' {$output="Power Scheme GUID: $guid (Ultimate Performance)"}
        '/list' {$output=$guid}
        '/getactivescheme' {$output=$script:active}
        '-setactive' {$script:active=$Arguments[1]}
        default {throw 'Unexpected command'}
    }
    [pscustomobject]@{Code=0;Output=$output}
}
$null=Invoke-Operation 'Plan Ultimate'
''')
        self.assertEqual([r['Status'] for r in rows], ['Applied','Applied'])
        self.assertTrue(all(r['Verified'] for r in rows))

    def test_pending_servicing_defers_dism_without_running_it(self):
        rows, _ = self.run_case(r'''
function Test-Path {param($Path) if($Path -like '*RebootPending'){return $true}; throw 'Unexpected path query'}
function Invoke-NativeOperation {throw 'DISM must not run when servicing is pending'}
$null=Invoke-Operation 'Native dism /Online /Cleanup-Image /StartComponentCleanup'
''')
        self.assertEqual([r['Status'] for r in rows], ['RestartRequired'])
        self.assertIn('Deferred', rows[0]['Detail'])

    def test_pagefile_already_managed_does_not_write(self):
        rows, _ = self.run_case(r'''
function Get-CimInstance {param($ClassName,$ErrorAction) [pscustomobject]@{AutomaticManagedPagefile=$true}}
function Set-CimInstance {throw 'Must not change an already managed page file'}
$null=Invoke-Operation 'Pagefile Auto'
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured'])

    def test_real_read_only_registry_check_does_not_invoke_a_write(self):
        rows, _ = self.run_case(r'''
$path='HKCU\Control Panel\Desktop'
$name='MenuShowDelay'
$before=Get-RegistryState $path $name
if(-not $before.Exists){throw 'Read-only fixture value is unavailable'}
$types=@{String='REG_SZ';DWord='REG_DWORD'}
$type=$types[$before.Type]
function Invoke-NativeOperation {throw 'Read-only smoke test must never write'}
$null=Invoke-Operation ('Registry reg add "'+$path+'" /v '+$name+' /t '+$type+' /d "'+$before.Value+'" /f')
''')
        self.assertEqual([r['Status'] for r in rows], ['AlreadyConfigured'])

if __name__ == '__main__':
    unittest.main(verbosity=2)
