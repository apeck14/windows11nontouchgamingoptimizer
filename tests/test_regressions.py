"""Non-admin regression tests. Never execute the optimizer's startup or real tweaks.

Extracted control-flow routines use explicit stubs. Cleanup runs real file
operations only in a disposable directory; all service operations are mocked.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'win11_nontouch_gaming_optimiser.bat').read_text(encoding='utf-8-sig')
POWERSHELL = str(Path(os.environ.get('SystemRoot', r'C:\Windows')) /
                 'System32/WindowsPowerShell/v1.0/powershell.exe')


def routine(name):
    match = re.search(r'^:' + re.escape(name) + r'\s*\n(.*?)(?=^:\w+\s*$|\Z)',
                      SOURCE, re.M | re.S)
    if not match:
        raise AssertionError(f'Missing routine: {name}')
    return ':' + name + '\n' + match.group(1)


def stub(name, code=0):
    return f'\n:{name}\n>>"%TRACE%" echo {name}\nexit /b {code}\n'


LOG = '\n:Log\nexit /b 0\n'
CHOOSE = '\n:Choose\nexit /b %CHOICE_CODE%\n'
MOCK = '''
:MockCommand
set "MOCK_ARGS=%*"
>>"%TRACE%" echo(!MOCK_ARGS!
exit /b 0
'''


def mock_commands(body):
    # Replace mutations in extracted routines with trace-only stubs.
    body = re.sub(r'(?mi)^(\s*)call :RunOperation ', r'\1call :MockCommand ', body)
    body = re.sub(r'(?mi)^(\s*)(reg|sc|bcdedit|schtasks|powercfg) ',
                  r'\1call :MockCommand \2 ', body)
    body = re.sub(r'(?mi)^\s*"%POWERSHELL%"[^\n]*',
                  'call :MockCommand powershell', body)
    body = re.sub(r'(?mi)^(\s*)choice [^\n]*', r'\1call :Choose', body)
    body = re.sub(r'(?mi)^(\s*)timeout [^\n]*', r'\1rem timeout stubbed', body)
    return body


@unittest.skipUnless(os.name == 'nt', 'Requires Windows cmd.exe and Windows PowerShell')
class Regressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='optimizer-tests-', dir=ROOT.parent)
        self.work = Path(self.temp.name).resolve()
        assert self.work.is_relative_to(ROOT.parent.resolve())
        self.addCleanup(self.temp.cleanup)

    def run_batch(self, body, name, *, extra='', env=None, args='', prelude=''):
        path = self.work / 'harness.bat'
        trace = self.work / 'trace.txt'
        trace.write_text('')
        log = self.work / 'test.log'
        environment = os.environ.copy()
        environment.update(TRACE=str(trace), LOG_FILE=str(log), LOG_DIR=str(self.work),
                           POWERSHELL=POWERSHELL)
        environment.update(env or {})
        script = ('@echo off\nsetlocal EnableExtensions EnableDelayedExpansion\n' +
                  prelude + f'\ncall :{name} {args}\n' +
                  'set "RESULT=%errorlevel%"\necho RESULT=%RESULT%\nexit /b %RESULT%\n' +
                  body + extra)
        path.write_bytes(script.replace('\n', '\r\n').encode('utf-8'))
        result = subprocess.run(['cmd.exe', '/d', '/c', str(path)], env=environment,
                                cwd=self.work, capture_output=True, text=True,
                                errors='replace', timeout=25)
        self.assertIn('RESULT=', result.stdout, result.stdout + result.stderr)
        self.assertNotIn('was unexpected', result.stderr)
        self.assertNotIn('not recognized', result.stderr)
        return result, trace.read_text(), log.read_text(errors='replace') if log.exists() else ''

    def test_unique_labels_and_resolved_calls(self):
        labels = re.findall(r'^:(\w+)\s*$', SOURCE, re.M)
        self.assertEqual(len(labels), len(set(x.lower() for x in labels)))
        targets = re.findall(r'\b(?:call\s+:|goto\s+)(\w+)', SOURCE, re.I)
        self.assertFalse(set(x.lower() for x in targets) - set(x.lower() for x in labels))

    def test_restore_success_and_failures(self):
        body = re.sub(r'^"%POWERSHELL%"[^\n]*', 'call :Checkpoint',
                      routine('CreateRestorePoint'), flags=re.M)
        for service_code, checkpoint_code in [(0, 0), (1, 0), (0, 1)]:
            with self.subTest(services=service_code, checkpoint=checkpoint_code):
                result, trace, _ = self.run_batch(body, 'CreateRestorePoint', extra=LOG +
                    stub('EnsureShadowServices', service_code) + stub('Checkpoint', checkpoint_code))
                self.assertEqual(result.returncode, int(bool(service_code or checkpoint_code)))
                self.assertEqual('Checkpoint' in trace, service_code == 0)
                self.assertEqual('created successfully' in result.stdout,
                                 service_code == checkpoint_code == 0)

    def test_sequences_stop_before_mutations_on_battery_or_cancelled_preparation(self):
        for name in ['FullOptimization', 'RunRecommended']:
            body = routine(name)
            calls = set(re.findall(r'call :(\w+)', body)) - {'Log'}
            for failure in ['WarnIfOnBattery', 'PrepareOptimization', None]:
                with self.subTest(routine=name, failure=failure):
                    extra = LOG + ''.join(stub(n, int(n == failure)) for n in calls)
                    result, trace, _ = self.run_batch(body, name, extra=extra)
                    events = trace.splitlines()
                    self.assertEqual(events[0], 'WarnIfOnBattery')
                    if failure:
                        self.assertEqual(result.returncode, 1)
                        self.assertNotIn('Debloat', events)
                        self.assertEqual(events[-1], failure)
                    else:
                        self.assertEqual(result.returncode, 0)
                        self.assertIn('ApplyGamingTweaks', events)
                        self.assertIn('ShowChangesSummary', events)

    def test_restore_failure_requires_explicit_continue(self):
        body = mock_commands(routine('PrepareOptimization'))
        for restore_code, choice, expected in [(0, '2', 0), (1, '1', 0), (1, '2', 1),
                                                (1, '255', 1)]:
            with self.subTest(restore=restore_code, choice=choice):
                result, _, _ = self.run_batch(body, 'PrepareOptimization',
                    extra=LOG + CHOOSE + stub('CreateRestorePoint', restore_code),
                    env={'CHOICE_CODE': choice})
                self.assertEqual(result.returncode, expected)

    def test_dvr_choice_uses_fresh_exit_code(self):
        body = routine('ApplyGamingTweaks').split('call :Log "Gaming tweaks: power plan"')[0]
        body = mock_commands(body) + '\necho DVR=!DISABLE_DVR!\nexit /b 0\n'
        for selection, seed in [(1, 2), (2, 1)]:
            result, _, _ = self.run_batch(body, 'ApplyGamingTweaks',
                extra=LOG + CHOOSE + stub('BackupRegistryKeys') + stub('Seed', seed),
                prelude='set "DVR_PREF_SET="\ncall :Seed\n', env={'CHOICE_CODE': str(selection)})
            self.assertIn(f'DVR={int(selection == 1)}', result.stdout)

    def test_memory_and_pagefile_routines_complete_for_all_ram_ranges(self):
        for name in ['OptimizeMemory', 'OptimizePageFile']:
            for ram in ['4', '8', '32']:
                with self.subTest(routine=name, ram=ram):
                    result, trace, _ = self.run_batch(mock_commands(routine(name)), name,
                        extra=LOG + MOCK, env={'RAM_GB': ram})
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertRegex(trace, r'Memory|Pagefile')

    def test_laptop_detection_and_cancellation(self):
        body = routine('DetectChassisType')
        body = re.sub(r'^for /f [^\n]+',
                      'for /f "delims=" %%I in (\'echo %CHASSIS_TEST%\') do (', body, flags=re.M)
        body = mock_commands(body)
        for chassis, choice, expected in [('3', '2', 0), ('10', '1', 0), ('10', '2', 1),
                                          ('31', '2', 1)]:
            with self.subTest(chassis=chassis, choice=choice):
                result, _, _ = self.run_batch(body, 'DetectChassisType', extra=LOG + CHOOSE,
                    env={'CHASSIS_TEST': chassis, 'CHOICE_CODE': choice})
                self.assertEqual(result.returncode, expected)
        self.assertRegex(SOURCE, r'call :DetectChassisType\nif errorlevel 1 exit /b 1')

    def test_battery_warning_honors_portable_device_choice(self):
        body = re.sub(r'^for /f [^\n]+', 'set "BAT_STATUS=%BAT_TEST%"',
                      routine('WarnIfOnBattery'), flags=re.M)
        body = mock_commands(body)
        for battery, selection, expected in [('1', '1', 0), ('1', '2', 1), ('2', '2', 0)]:
            result, _, _ = self.run_batch(body, 'WarnIfOnBattery', extra=LOG + CHOOSE,
                env={'IS_LAPTOP': '1', 'CHASSIS_TYPE': 'Convertible',
                     'BAT_TEST': battery, 'CHOICE_CODE': selection})
            self.assertEqual(result.returncode, expected)

    def test_network_menu_routes_all_options(self):
        body = mock_commands(routine('NetworkMenu') + routine('NetworkOptions'))
        choose = '''
:Choose
if defined CHOSEN exit /b 4
set "CHOSEN=1"
exit /b %CHOICE_CODE%
'''
        for selection, target in [(1, 'ApplyNetworkTweaksSafe'), (2, 'ApplyNetworkTweaks'),
                                   (3, 'RevertNetworkTweaks'), (4, None)]:
            result, trace, _ = self.run_batch(body, 'NetworkMenu', extra=choose +
                ''.join(stub(n) for n in ['ApplyNetworkTweaksSafe', 'ApplyNetworkTweaks',
                                          'RevertNetworkTweaks', 'PauseReturn']),
                prelude='set "CHOSEN="\n', env={'CHOICE_CODE': str(selection)})
            self.assertEqual(result.returncode, 0)
            events = trace.splitlines()
            self.assertEqual(events, [target, 'PauseReturn'] if target else [])

    def test_undo_is_opt_in_and_never_enables_remote_services(self):
        body = mock_commands(routine('UndoChanges'))
        for selection in ['1', '2']:
            result, trace, _ = self.run_batch(body, 'UndoChanges', extra=LOG + CHOOSE + MOCK +
                stub('RevertNetworkTweaks'), env={'CHOICE_CODE': selection})
            self.assertEqual(result.returncode, int(selection != '1'))
            self.assertNotRegex(trace, r'(?i)sc (?:start|config) (?:RemoteRegistry|RemoteAccess)\b')
            self.assertEqual(bool(trace), selection == '1')

    def test_task_names_stay_one_argument(self):
        body = routine('OptimizeServices')
        body = body[body.index('for %%T in ('):body.index('call :RunOperation Registry')]
        body = body.replace('call :RunOperation Task schtasks ', 'call :Task ')
        task = '\n:Task\n>>"%TRACE%" echo %~3\nif not "%~4"=="/Disable" exit /b 9\nexit /b 0\n'
        result, trace, _ = self.run_batch(':TestTasks\n' + body + '\nexit /b %errorlevel%\n',
                                         'TestTasks', extra=task)
        self.assertEqual(result.returncode, 0)
        self.assertIn(r'\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser', trace)

    def cleanup(self, target, localapp, temp=None):
        env = {'LOCALAPPDATA': str(localapp)}
        if temp is not None:
            env['TEMP'] = str(temp)
        return self.run_batch(routine('ClearTemp') + routine('ClearDirectory'),
                              'ClearTemp', extra=LOG + stub('RecordOperation'), args=f'"{target}"', env=env)

    def test_cleanup_removes_only_approved_contents(self):
        app = self.work / 'local app'
        target = app / 'Temp'
        nested = target / 'nested'
        nested.mkdir(parents=True)
        (nested / 'square[1].tmp').write_text('temporary')
        (target / 'leaf.tmp').write_text('temporary')
        sentinel = app / 'keep.txt'
        sentinel.write_text('keep')
        result, _, log = self.cleanup(target, app)
        self.assertEqual(result.returncode, 0, log)
        self.assertTrue(target.is_dir())
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(sentinel.read_text(), 'keep')

    def test_cleanup_refuses_unapproved_directories_and_drive_root(self):
        app = self.work / 'local'
        app.mkdir()
        sentinel = app / 'keep.txt'
        sentinel.write_text('keep')
        for target in [app, self.work.anchor]:
            result, _, log = self.cleanup(target, app)
            self.assertEqual(result.returncode, 1, log)
            self.assertIn('Refusing unapproved', log)
            self.assertEqual(sentinel.read_text(), 'keep')

    def test_custom_temp_is_cleaned_but_protected_overrides_are_refused(self):
        app = self.work / 'profile' / 'local'
        custom = self.work / 'custom scratch'
        custom.mkdir()
        (custom / 'discard.tmp').write_text('temporary')
        result, _, log = self.cleanup(custom, app, temp=custom)
        self.assertEqual(result.returncode, 0, log)
        self.assertEqual(list(custom.iterdir()), [])
        app.mkdir(parents=True)
        sentinel = app / 'keep.txt'
        sentinel.write_text('keep')
        for forbidden in [self.work.anchor, app, app.parent]:
            result, _, log = self.cleanup(forbidden, app, temp=forbidden)
            self.assertEqual(result.returncode, 1, log)
            self.assertIn('Refusing', log)
            self.assertEqual(sentinel.read_text(), 'keep')

    def test_update_cache_service_lifecycle(self):
        # Execute the real embedded cleanup code with only service operations
        # mocked. All file targets are in this test's validated sandbox.
        body = routine('ClearDirectory').replace('^\n', '')
        command = re.search(r'-Command\s+((?:"[^"\n]*"\s*)+)', body).group(1)
        script = ' '.join(re.findall(r'"([^"]*)"', command))
        windows = self.work / 'Windows'
        target = windows / 'SoftwareDistribution' / 'Download'
        target.mkdir(parents=True)
        trace = self.work / 'services.txt'
        settings_file = self.work / 'settings.json'
        fixture = self.work / 'cache-test.ps1'
        preamble = r'''
$config = Get-Content -Raw -LiteralPath $env:TEST_SETTINGS | ConvertFrom-Json
$env:SystemRoot = $config.windows
$env:OPTIMIZER_CLEANUP_MODE = 'update'
$env:OPTIMIZER_CLEANUP_TARGET = $config.target
$script:services = @()
foreach($name in @('wuauserv','bits')) {
    $status = if($name -eq 'bits'){$config.bitsStatus}else{'Running'}
    $svc = [pscustomobject]@{Name=$name; Status=$status}
    $svc | Add-Member ScriptMethod WaitForStatus {param($desired,$timeout) $this.Status=$desired}
    $svc | Add-Member ScriptMethod Refresh {}
    $script:services += $svc
}
function Get-Service {param($Name) $script:services}
function Stop-Service {
    param($InputObject,[switch]$NoWait,$ErrorAction)
    Add-Content -LiteralPath $config.trace -Value ('stop:'+$InputObject.Name)
    if($config.stopFailure -and $InputObject.Name -eq 'bits'){throw 'Mock stop failure'}
    $InputObject.Status='Stopped'
}
function Start-Service {
    param($InputObject,$ErrorAction)
    Add-Content -LiteralPath $config.trace -Value ('start:'+$InputObject.Name)
    $InputObject.Status='Running'
}
function Get-ChildItem {
    param($LiteralPath,[switch]$Force)
    if($config.cleanupFailure){throw 'Mock cleanup failure'}
    Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Force:$Force
}
'''
        fixture.write_text(preamble + script, encoding='utf-8')
        for bits_status, stop_failure, cleanup_failure in [('Running', False, False),
                ('Stopped', False, False), ('Running', True, False), ('Running', False, True),
                ('StopPending', False, False)]:
            with self.subTest(bits=bits_status, stop=stop_failure, cleanup=cleanup_failure):
                sentinel = target / 'download.tmp'
                sentinel.write_text('download')
                trace.write_text('')
                settings_file.write_text(json.dumps(dict(windows=str(windows), target=str(target),
                    trace=str(trace), bitsStatus=bits_status, stopFailure=stop_failure,
                    cleanupFailure=cleanup_failure)))
                env = os.environ.copy()
                env['TEST_SETTINGS'] = str(settings_file)
                result = subprocess.run([POWERSHELL, '-NoProfile', '-File', str(fixture)],
                    env=env, capture_output=True, text=True, timeout=25)
                events = trace.read_text().splitlines()
                failed = stop_failure or cleanup_failure or bits_status == 'StopPending'
                self.assertEqual(result.returncode, int(failed), result.stdout + result.stderr)
                self.assertEqual(sentinel.exists(), failed)
                if bits_status == 'StopPending':
                    self.assertEqual(events, [])
                elif bits_status == 'Stopped':
                    self.assertEqual(events, ['stop:wuauserv', 'start:wuauserv'])
                else:
                    self.assertEqual(events, ['stop:wuauserv', 'stop:bits',
                                              'start:wuauserv', 'start:bits'])

    def test_custom_temp_cannot_target_installed_applications(self):
        programs = self.work / 'Program Files'
        target = programs / 'Application'
        target.mkdir(parents=True)
        sentinel = target / 'keep.exe'
        sentinel.write_text('keep')
        body = routine('ClearDirectory').replace('^\n', '')
        command = re.search(r'-Command\s+((?:"[^"\n]*"\s*)+)', body).group(1)
        script = ' '.join(re.findall(r'"([^"]*)"', command))
        # PowerShell resets ProgramFiles on launch; override it after startup.
        fixture = self.work / 'protected-test.ps1'
        fixture.write_text("$env:ProgramFiles=$env:TEST_PROGRAMS; "
            "$env:TEMP=$env:TEST_TARGET; $env:OPTIMIZER_CLEANUP_MODE='temp'; "
            "$env:OPTIMIZER_CLEANUP_TARGET=$env:TEST_TARGET; " + script)
        env = os.environ.copy()
        env.update(TEST_PROGRAMS=str(programs), TEST_TARGET=str(target))
        result = subprocess.run([POWERSHELL, '-NoProfile', '-File', str(fixture)],
                                env=env, capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('Refusing cleanup inside system or application', result.stdout)
        self.assertEqual(sentinel.read_text(), 'keep')

    def test_cleanup_skips_junctions_and_rejects_linked_ancestors(self):
        app = self.work / 'local'
        target = app / 'Temp'
        target.mkdir(parents=True)
        protected = self.work / 'protected'
        protected.mkdir()
        sentinel = protected / 'keep.txt'
        sentinel.write_text('keep')
        link = target / 'link'
        result = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), str(protected)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result, _, log = self.cleanup(target, app)
        self.assertEqual(result.returncode, 0, log)
        self.assertEqual(sentinel.read_text(), 'keep')
        self.assertTrue(link.exists())
        alias = self.work / 'alias'
        result = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(alias), str(app)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result, _, log = self.cleanup(alias / 'Temp', alias)
        self.assertEqual(result.returncode, 1, log)
        self.assertIn('reparse point', log)
        self.assertEqual(sentinel.read_text(), 'keep')

    def test_embedded_powershell_parses(self):
        # Remove batch continuation/pipe escaping, then parse, never invoke.
        joined = SOURCE.replace('^\n', '').replace('^|', '|')
        commands = re.findall(r'-Command\s+((?:"[^"\n]*"\s*)+)', joined)
        scripts = [' '.join(re.findall(r'"([^"]*)"', command)) for command in commands]
        self.assertTrue(scripts, "No embedded PowerShell commands were found")
        script_file = self.work / 'scripts.json'
        script_file.write_text(json.dumps(scripts), encoding='utf-8')
        environment = os.environ.copy()
        environment['TEST_SCRIPTS'] = str(script_file)
        result = subprocess.run([POWERSHELL, '-NoProfile', '-Command',
            "$ErrorActionPreference='Stop'; $scripts=Get-Content -Raw -LiteralPath $env:TEST_SCRIPTS | ConvertFrom-Json; foreach($script in $scripts){[void][scriptblock]::Create($script)}"],
            env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
