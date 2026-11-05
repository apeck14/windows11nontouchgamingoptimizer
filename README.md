# Windows 11 Gaming Optimizer

Windows gaming tweaks and recycle-only cleanup. [MIT license](LICENSE).

## Development

Target **Windows PowerShell 5.1**. Preserve **CRLF**, especially in the batch file. Close optimizer windows before editing executable files. Dot-source `optimizer-operations.ps1 -NoRun` to load functions without applying changes.

| Source | Purpose | Tests |
| --- | --- | --- |
| `win11_nontouch_gaming_optimiser.bat` | Menus, elevation, Windows presets | `tests/test_regressions.py` |
| `optimizer-operations.ps1` | Verified operations, restore points, reporting | `tests/test_operation_results.py` |
| `optimizer-cleanup.ps1` | Storage scans, recycling | `tests/test_operation_results.py` |
| `optimizer-mw4.ps1`, `optimizer-nvidia.cs` | Game configs, NVIDIA profiles, backup/restore | `tests/test_mw4.py` |

Run from the repository root on Windows with Python 3.9+; no Python dependencies:

```powershell
python -m unittest discover -s tests -p "test_*.py" -q
```

System/driver changes are mocked; files use disposable fixtures. Set `$env:OPTIMIZER_TEST_RECYCLE = '1'` to include a real recycle/restore test using generated files; unset afterward with `Remove-Item Env:OPTIMIZER_TEST_RECYCLE`.

## Use

Extract the complete ZIP and run `win11_nontouch_gaming_optimiser.bat` as administrator under the desktop user's account. Keep companion `.ps1` and `.cs` files together.

- **1 Full optimization:** Windows tweaks plus Quick cleanup. Defaults to memory integrity (HVCI) off and Game DVR recording off; recording has an opt-out prompt. HVCI off reduces security and may affect anti-cheat compatibility.
- **2 Quick cleanup:** recycle temp files, supported app logs and crash reports older than 30 days.
- **3 Deep cleanup:** everything in Quick, plus old web caches, partial downloads, duplicate installer/archive downloads (one retained), and recognized driver extractions (newest retained). Shows storage estimates and the largest folders with no detected content changes for 180 days, using timestamps rather than game names. Empty folders under Downloads and user Temp are recycled after seven days; other old folders are review-only; other downloads/recordings require selection via `Out-GridView`.
- **4 MW4 / Warzone:** compatible existing config keys and NVIDIA application profiles. Shared configs may affect other Call of Duty titles. Tearing and higher GPU power use are possible.

Age-based automatic cleanup checks creation and modification dates; app-specific cleanup skips running apps. Cleanup can discard download resume progress and diagnostic history; web caches may need downloading again. Files occupy space in the Recycle Bin until emptied; Storage Sense can empty it independently.

Full optimization attempts a verified restore point; failure defaults to cancellation. **R Recovery** offers System Restore, checkpoints and partial undo. Restore points can expire; partial undo is not a full backup. Standalone cleanup creates no checkpoint.

**Recovery > 5** restores the latest game backup while preserving subsequent edits. Close the game before apply/restore; no-op runs retain the previous backup.

**P** shows session results. Diagnostics and backups live in `logs/`. Read-back verifies settings, not FPS gains; benchmark in-game.
