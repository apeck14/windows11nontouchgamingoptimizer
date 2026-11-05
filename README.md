# Windows 11 Gaming Optimizer

Windows gaming tweaks and recycle-only cleanup. [MIT license](LICENSE).

## Run and recover

Extract the complete ZIP; run `win11_nontouch_gaming_optimiser.bat` as administrator using the desktop user's account. Keep all `.ps1` and `.cs` files together.

- **1 Full optimization:** Windows tweaks plus quick cleanup. Defaults to memory integrity (HVCI) off and Game DVR recording off; the latter has an opt-out prompt. Disabling HVCI reduces security and can affect anti-cheat compatibility. Recovery can re-enable it.
- **2 Quick cleanup:** recycle user temp files older than 30 days.
- **3 Deep cleanup:** storage estimates in GB; automatically recycle identical loose installer/archive downloads, retaining one copy. Other candidates require selection. Installed apps remain installed. Requires `Out-GridView`.
- **4 MW4 / Warzone:** separate competitive preset for compatible keys in current and older configs, plus NVIDIA application profiles. Shared configs/profiles may affect other Call of Duty titles. Prioritizes latency and lower effects costs; preserves textures, upscaling, FOV and controls. Tearing and higher GPU power use are possible.

Full optimization attempts a verified restore point; failure defaults to cancellation. **R Recovery** opens System Restore, creates checkpoints and provides partial undo. Restore points can expire; partial undo is not a full backup. Standalone cleanup creates no checkpoint. Recycled files occupy space until the bin is emptied; Storage Sense can empty it independently.

**Recovery > 5** restores the latest game backup from `logs/mw4-backups/`, preserving subsequent edits. Game apply/restore requires the game closed. No-op runs keep the previous backup.

The game preset preserves GPU upload heaps and enables in-game Anti-Lag 2 only for identified RDNA Radeon hardware with a compatible existing setting. Runtime support still depends on the game and driver.

Each action shows results; **P** summarizes the session. Diagnostics and selected registry backups live in `logs/`. Read-back verifies settings, not FPS gains; benchmark in-game.

## Editing

Close running optimizer windows before editing or updating files. Target Windows PowerShell **5.1** and preserve **CRLF**, especially in the batch file. Dot-source `optimizer-operations.ps1 -NoRun` to load functions without running an operation.

| Source | Responsibility | Tests |
| --- | --- | --- |
| `win11_nontouch_gaming_optimiser.bat` | Menus, elevation, Windows presets | `tests/test_regressions.py` |
| `optimizer-operations.ps1` | Verified operations, restore points, reporting | `tests/test_operation_results.py` |
| `optimizer-cleanup.ps1` | Storage, duplicate detection, recycling | `tests/test_operation_results.py` |
| `optimizer-mw4.ps1`, `optimizer-nvidia.cs` | Game preset, backup/restore, NVIDIA API | `tests/test_mw4.py` |

## Tests

Windows, Windows PowerShell 5.1, Python 3.9+; no Python dependencies. Run from the repository root:

```powershell
python -m unittest discover -s tests -p "test_*.py" -q
```

System/driver mutations are mocked; file tests use disposable fixtures. To also test actual recycling and restoration of generated files, set `$env:OPTIMIZER_TEST_RECYCLE = '1'` before running; unset it afterward with `Remove-Item Env:OPTIMIZER_TEST_RECYCLE`.
