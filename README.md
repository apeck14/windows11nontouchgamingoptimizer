# Windows 11 Gaming Optimizer

Windows configuration and recycle-only cleanup. [MIT license](LICENSE).

## Run

Extract the complete repository ZIP and run `win11_nontouch_gaming_optimiser.bat` as administrator. Keep its `.ps1` and `.cs` files together. Use the same Windows account for the desktop and administrator approval; the script stops if they differ. Close running optimizer windows before editing or updating its files.

- Full optimization defaults to **memory integrity (HVCI) off**, reducing security and potentially affecting anti-cheat compatibility. **Recovery â†’ Memory integrity** re-enables it. Game DVR recording defaults off; answer No to preserve capture settings. Installed apps remain installed. Performance gains are not guaranteed. Ryzen 9 CPUs that need driver-managed core parking use Balanced with AC Best performance. Other desktop runs reuse one Ultimate Performance/Gaming Optimizer plan and delete extra plans with those names; custom-named plans are preserved.
- Full optimization attempts to enable System Protection and verify a new restore point. Failure defaults to cancelling. **Recovery** also creates checkpoints and opens System Restore. Cleanup does not create checkpoints. Restore points can expire; **Undo** is partial, not a substitute for a backup.
- **2** recycles user temp files older than 30 days. **3** shows storage/app-folder estimates in GB and **automatically recycles duplicate loose downloads**, keeping one copy after comparing extensions and all data streams. Other cleanup candidates require selection.
- Files go only to the Recycle Bin; space is not freed until it is emptied. Storage Sense or other software can empty it independently. System/update caches and pending crash reports are excluded.
- Each action ends with a short summary. **P** summarizes the session. Detailed results and selected registry backups are in `logs/`; check failures and restart notices before rerunning.

## MW4 / Warzone

**4** applies the competitive preset with the game closed. It finds retail shared Call of Duty configs in LocalAppData/Activision and Documents, including paired `.txt0`/`.txt1` files. Only existing compatible keys change, without a game-version gate. Unknown keys or incompatible values are preserved. Shared configs/profiles can affect other installed Call of Duty titles.

The preset enables NVIDIA Reflex Boost, disables gameplay V-Sync, frame caps, frame generation and blur/depth-of-field, and lowers ray tracing/shadow/terrain costs. It retains shadows and preserves lower existing quality, textures, upscaling, model detail, FOV and controls. Tearing and greater GPU power draw are possible. NVIDIA application profiles use V-Sync off, no driver frame cap and highest available refresh rate; missing profiles/settings are skipped. Global driver settings stay unchanged.

Backups go to `logs/mw4-backups/`. **Recovery > 5** restores the latest backup, refusing to overwrite subsequent edits. No-op runs keep that backup. File/driver read-back verifies saved values, not FPS or whether the game later rewrites them. Compare the in-game benchmark before/after; keep native or Quality upscaling if lower modes obscure distant targets.

Rationale: [NVIDIA latency guidance](https://www.nvidia.com/en-us/geforce/guides/system-latency-optimization-guide/), [MW4 setting benchmarks](https://www.pcgamer.com/games/call-of-duty/ive-tested-every-graphics-setting-in-call-of-duty-modern-warfare-4-tweak-these-four-options-for-the-best-performance/) and [public NVAPI DRS](https://docs.nvidia.com/nvapi/group__drsapi.html). Config keys/ranges are checked against game-generated files. Avoid guessed worker counts, VRAM budgets, hidden driver flags and shader-cache deletion.

## Source map

- `win11_nontouch_gaming_optimiser.bat`: menus, elevation, presets and tweak commands.
- `optimizer-operations.ps1`: verified operations, restore points, result journal and summaries. Dot-source with `-NoRun` for tests.
- `optimizer-cleanup.ps1`: storage estimates, candidate selection, duplicate checks and Shell recycling.
- `optimizer-mw4.ps1`, `optimizer-nvidia.cs`: game preset, backups/restore, public NVIDIA driver API.

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
