"""Non-admin regression tests. Never execute the optimizer's startup or real tweaks.

Extracted control-flow routines use explicit stubs. Only ClearTemp runs its real
PowerShell, against fixtures under a disposable directory beside the repository.
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
    # This function is deliberately limited to routines tested below. Fail if a
    # test adds an unknown real operation instead of quietly running it.
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

    def test_sequences_stop_before_mutations_on_battery_or_restore_failure(self):
        for name in ['FullOptimization', 'RunRecommended']:
            body = routine(name)
            calls = set(re.findall(r'call :(\w+)', body)) - {'Log'}
            for failure in ['WarnIfOnBattery', 'CreateRestorePoint', None]:
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

    def test_dvr_choice_uses_fresh_exit_code(self):
        body = routine('ApplyGamingTweaks').split('call :Log "Gaming tweaks: power plan"')[0]
        body = mock_commands(body) + '\necho DVR=!DISABLE_DVR!\nexit /b 0\n'
        for selection, seed in [(1, 2), (2, 1)]:
            result, _, _ = self.run_batch(body, 'ApplyGamingTweaks',
                extra=LOG + CHOOSE + stub('BackupRegistryKeys') + stub('Seed', seed),
                prelude='set "DVR_PREF_SET="\ncall :Seed\n', env={'CHOICE_CODE': str(selection)})
            self.assertIn(f'DVR={int(selection == 1)}', result.stdout)

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

    def test_power_guid_parser(self):
        body = routine('ApplyGamingTweaks')
        body = body[body.index('set "UP_GUID="'):body.index('echo [*] Tuning Game Mode')]
        fixture = self.work / 'fake-powercfg.cmd'
        fixture.write_text('@echo off\necho Power Scheme GUID: 11111111-2222-3333-4444-555555555555  (Ultimate Performance)\n')
        body = body.replace('powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61',
                            f'call "{fixture}"')
        body = mock_commands(':TestGuid\n' + body + '\nexit /b 0\n')
        result, trace, _ = self.run_batch(body, 'TestGuid', extra=MOCK)
        self.assertEqual(result.returncode, 0)
        self.assertIn('powercfg -setactive 11111111-2222-3333-4444-555555555555', trace)

    def test_task_names_stay_one_argument(self):
        body = routine('OptimizeServices')
        body = body[body.index('for %%T in ('):body.index('reg add "HKLM')]
        body = body.replace('schtasks ', 'call :Task ')
        task = '\n:Task\n>>"%TRACE%" echo %~3\nif not "%~4"=="/Disable" exit /b 9\nexit /b 0\n'
        result, trace, _ = self.run_batch(':TestTasks\n' + body + '\nexit /b %errorlevel%\n',
                                         'TestTasks', extra=task)
        self.assertEqual(result.returncode, 0)
        self.assertIn(r'\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser', trace)

    def cleanup(self, target, localapp):
        return self.run_batch(routine('ClearTemp'), 'ClearTemp', extra=LOG,
                              args=f'"{target}"', env={'LOCALAPPDATA': str(localapp)})

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
            self.assertIn('Refusing nonstandard', log)
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
        commands = re.findall(r'-Command ((?:"[^"\n]*"\s*)+)', joined)
        scripts = [' '.join(re.findall(r'"([^"]*)"', command)) for command in commands]
        self.assertGreater(len(scripts), 15)
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
