# Windows 11 Gaming Optimizer

Windows configuration and recycle-only cleanup. [MIT license](LICENSE).

## Run

Extract all three `.bat`/`.ps1` files together and run `win11_nontouch_gaming_optimiser.bat` as administrator. Use the same Windows account for the desktop and administrator approval; the script stops if they differ. Choose Full optimization, Quick cleanup, Deep cleanup, Recovery, or session Results. Close running optimizer windows before editing or updating its files.

- Full optimization defaults to **memory integrity (HVCI) off**, reducing security and potentially affecting anti-cheat compatibility. **Recovery â†’ Memory integrity** re-enables it. Game DVR recording defaults off; answer No to preserve capture settings. Installed apps remain installed. Performance gains are not guaranteed. Ryzen 9 CPUs that need driver-managed core parking use Balanced with AC Best performance. Other desktop runs reuse one Ultimate Performance/Gaming Optimizer plan and delete extra plans with those names; custom-named plans are preserved.
- Full optimization attempts to enable System Protection and verify a new restore point. Failure defaults to cancelling. **Recovery** also creates checkpoints and opens System Restore. Cleanup does not create checkpoints. Restore points can expire; **Undo** is partial, not a substitute for a backup.
- **2** recycles user temp files older than 30 days. **3** shows storage/app-folder estimates in GB and **automatically recycles duplicate loose downloads**, keeping one copy after comparing extensions and all data streams. Other cleanup candidates require selection.
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
