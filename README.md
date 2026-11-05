# Windows 11 Gaming Optimizer

Windows configuration and recycle-only cleanup. Originally by [Matt Hurley](https://github.com/theantipopau/windows11nontouchgamingoptimizer); maintained in [this fork](https://github.com/apeck14/windows11nontouchgamingoptimizer). [MIT license](LICENSE).

## Run

Extract all three `.bat`/`.ps1` files together and run `win11_nontouch_gaming_optimiser.bat` as administrator. The menu describes individual actions. Close running optimizer windows before editing or updating its files.

- Full optimization defaults to **memory integrity (HVCI) off**, reducing security and potentially affecting anti-cheat compatibility. **M** re-enables it. Game DVR recording defaults off; answer No to preserve capture settings. Installed apps remain installed. Performance gains are not guaranteed.
- Full optimization attempts to enable System Protection and verify a new restore point. Failure defaults to cancelling. **3** creates a checkpoint; **R** opens System Restore. Individual tweaks do not create checkpoints automatically. Restore points can expire; **Undo** is partial, not a substitute for a backup.
- **B** recycles user temp files older than 30 days. **J** shows storage/app-folder estimates in GB and **automatically recycles duplicate loose downloads**, keeping one copy after comparing extensions and all data streams. Other cleanup candidates require selection.
- Files go only to the Recycle Bin; space is not freed until it is emptied. Storage Sense or other software can empty it independently. System/update caches and pending crash reports are excluded.
- Each action ends with a short summary. **P** summarizes the session. Detailed results and selected registry backups are in `logs/`; check failures and restart notices before rerunning.

## Source map

- `win11_nontouch_gaming_optimiser.bat`: menus, elevation, presets and tweak commands.
- `optimizer-operations.ps1`: verified operations, restore points, result journal and summaries. Dot-source with `-NoRun` for tests.
- `optimizer-cleanup.ps1`: storage estimates, candidate selection, duplicate checks and Shell recycling.

## Tests

Windows, Windows PowerShell 5.1, and Python 3.9+; no Python dependencies. Deeper cleanup also requires `Out-GridView`.

```powershell
python -m unittest discover -s tests -p "test_*.py" -q
```

System mutations are mocked; file tests use disposable fixtures. To include the real Recycle Bin round-trip test (generated files only):

```powershell
$env:OPTIMIZER_TEST_RECYCLE = '1'
python -m unittest discover -s tests -p "test_*.py" -q
Remove-Item Env:OPTIMIZER_TEST_RECYCLE
```
