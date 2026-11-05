"""Batch control-flow tests with stubbed operations; no real optimizations."""
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

    def test_menu_dispatches_only_the_selected_action(self):
        menu = routine('Menu')
        body = ':Dispatch\n' + menu[menu.index('if /I "%choice%"=="1"'):]
        body = body.replace('start "" "%SystemRoot%\\System32\\rstrui.exe"', 'call :OpenRestore')
        targets = set(re.findall(r'call :(\w+)', body)) | {'Menu', 'End'}
        for choice, expected in [('1','FullOptimization'), ('2','RunRecommended'),
                                 ('3','CreateRestorePoint'), ('R','OpenRestore'),
                                 ('G','RunOperation'), ('M','MemoryIntegrityMenu'), ('0','End')]:
            with self.subTest(choice=choice):
                result, trace, _ = self.run_batch(body, 'Dispatch',
                    extra=''.join(stub(target) for target in targets), env={'choice':choice})
                self.assertEqual(result.returncode, 0)
                events = trace.splitlines()
                self.assertEqual(events[0], expected)
                self.assertTrue(set(events) <= {expected, 'PauseReturn', 'Menu'})

    def test_registry_backup_runs_once_and_preserves_mouse_baseline(self):
        body = ':BackupTwice\ncall :BackupRegistryKeys\ncall :BackupRegistryKeys\nexit /b 0\n' + mock_commands(routine('BackupRegistryKeys'))
        for baseline_exists in [False, True]:
            with self.subTest(baseline_exists=baseline_exists):
                prelude = 'set "REGISTRY_BACKUP_DONE="\n'
                if baseline_exists:
                    prelude += 'type nul > "%LOG_DIR%\\mouse_settings_backup.reg"\n'
                result, trace, _ = self.run_batch(body, 'BackupTwice', extra=LOG + MOCK, prelude=prelude)
                self.assertEqual(result.returncode, 0)
                exports = [line for line in trace.splitlines() if 'reg export' in line]
                self.assertEqual(len(exports), 7 if baseline_exists else 8)
                self.assertEqual(sum('mouse_settings_backup.reg' in line for line in exports), int(not baseline_exists))
                self.assertFalse(list(self.work.glob('registry_backup_*.txt')))

    def test_restore_success_and_failures(self):
        body = re.sub(r'^call :RunOperation Restore Create', 'call :Checkpoint',
                      routine('CreateRestorePoint'), flags=re.M)
        for service_code, checkpoint_code in [(0, 0), (1, 0), (0, 1)]:
            with self.subTest(services=service_code, checkpoint=checkpoint_code):
                result, trace, _ = self.run_batch(body, 'CreateRestorePoint', extra=LOG +
                    stub('EnsureShadowServices', service_code) + stub('Checkpoint', checkpoint_code))
                self.assertEqual(result.returncode, int(bool(service_code or checkpoint_code)))
                self.assertEqual('Checkpoint' in trace, service_code == 0)
                self.assertEqual('created and verified' in result.stdout,
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

    def test_gaming_defaults_request_graphics_and_integrity_changes_without_forced_timers(self):
        result, trace, _ = self.run_batch(mock_commands(routine('ApplyGamingTweaks')), 'ApplyGamingTweaks',
            extra=LOG + MOCK + stub('BackupRegistryKeys'),
            env={'DVR_PREF_SET':'1', 'DISABLE_DVR':'0', 'GPU_VENDOR':'NVIDIA'})
        self.assertEqual(result.returncode, 0)
        for operation in ['Windowed Enable', 'Integrity Off', 'Graphics Check',
                          'Native bcdedit /deletevalue useplatformclock',
                          'Native bcdedit /deletevalue disabledynamictick']:
            self.assertIn(operation, trace)
        self.assertNotIn('bcdedit /set', trace)

    def test_capture_opt_out_preserves_settings_and_opt_in_disables_recording(self):
        for disable in ['0', '1']:
            with self.subTest(disable=disable):
                result, trace, _ = self.run_batch(mock_commands(routine('ApplyGamingTweaks')), 'ApplyGamingTweaks',
                    extra=LOG + MOCK + stub('BackupRegistryKeys'),
                    env={'DVR_PREF_SET':'1', 'DISABLE_DVR':disable})
                self.assertEqual(result.returncode, 0)
                writes = [line for line in trace.splitlines() if 'reg add' in line and
                          ('GameDVR' in line or 'GameConfigStore' in line)]
                if disable == '0':
                    self.assertEqual(writes, [])
                else:
                    self.assertEqual(len(writes), 4)
                    self.assertTrue(all('/d 0 /f' in line for line in writes))
                    self.assertTrue(any('HistoricalCaptureEnabled' in line for line in writes))
                self.assertNotIn('FSEBehaviorMode', trace)

    def test_both_network_paths_enable_normal_window_growth(self):
        for name in ['ApplyNetworkTweaksSafe', 'ApplyNetworkTweaks']:
            result, trace, _ = self.run_batch(mock_commands(routine(name)), name, extra=LOG + MOCK)
            self.assertEqual(result.returncode, 0)
            self.assertIn('autotuninglevel=normal', trace)
            self.assertNotIn('autotuninglevel=highlyrestricted', trace)

    def test_memory_and_pagefile_routines_complete_for_all_ram_ranges(self):
        for name in ['OptimizeMemory', 'OptimizePageFile']:
            for ram in (['', '4', '8', '16', '32'] if name == 'OptimizePageFile' else ['4', '8', '32']):
                with self.subTest(routine=name, ram=ram):
                    result, trace, _ = self.run_batch(mock_commands(routine(name)), name,
                        extra=LOG + MOCK, env={'RAM_GB': ram})
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertRegex(trace, r'Memory|Pagefile')
                    if name == 'OptimizePageFile':
                        self.assertIn('Pagefile Auto', trace)
                        self.assertNotIn('Fixed4GB', trace)

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

    def test_cleanup_routes_only_to_recycling_and_app_inventory(self):
        for name, operation in [('FreeDiskSpace','Cleanup Safe'), ('Debloat','Apps Review')]:
            result, trace, _ = self.run_batch(mock_commands(routine(name)), name, extra=LOG + MOCK)
            self.assertEqual(result.returncode, 0)
            self.assertIn(operation, trace)
        engine = (ROOT / 'optimizer-operations.ps1').read_text()
        cleanup = (ROOT / 'optimizer-cleanup.ps1').read_text()
        for text in [SOURCE, engine, cleanup]:
            self.assertNotRegex(text, r'(?i)Remove-Appx|Remove-Item\s|StartComponentCleanup|Clear-RecycleBin')

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
