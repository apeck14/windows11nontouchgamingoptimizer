# Windows 11 Non-Touch Gaming Optimizer

Debloating and Windows configuration utility. Originally by [Matt Hurley](https://github.com/theantipopau/windows11nontouchgamingoptimizer); maintained in [this fork](https://github.com/apeck14/windows11nontouchgamingoptimizer). Settings are not guaranteed FPS or latency improvements.

## Run

Extract the repository ZIP, keeping all three `.bat`/`.ps1` files together. Run the batch file as administrator. The menu lists individual actions.

- **1/F Full:** all routines, including aggressive networking and advanced GPU/storage settings; recycles old user temp files.
- **2 Recommended:** app inventory, gaming settings, services, safe networking, visuals and core parking.
- **4:** installed-app inventory; no uninstall. **B:** recycle user temp files older than 30 days.
- **J:** storage/category and largest-app-folder estimates in GB. Automatically recycles SHA-256-identical loose installer/archive downloads with matching extensions and alternate-stream contents, keeping the oldest-created copy. Other old downloads, crash dumps, archived error reports (30+ days) and recordings require selection; nothing is preselected. Changed or unavailable retained copies prevent automatic recycling. Pending error reports are excluded; skipped locations are marked partial.
- **3:** set up System Protection and create a restore point. **R:** open System Restore.
- **G:** display refresh/GPU checks. **M:** memory integrity on/off.
- **P:** session operation results. **V:** limited live configuration checks.

Both presets enable System Protection on the Windows drive and verify a new, named restore point before optimization. The checkpoint frequency override is temporary; existing restore points and storage limits are preserved. If setup or creation fails, a continue/cancel choice defaults to cancel. Individual actions do not create restore points. Apps are preserved; disabling Xbox services requires a separate selection.

Both presets default to disabling Game DVR recording (answer No to preserve existing capture settings; Game Bar stays installed) and restore normal TCP receive-window growth. Both enable windowed-game optimization for compatible DX10/DX11 games, remove forced debug timer overrides, and **disable memory integrity (HVCI) by default**. This reduces security and may block anti-cheat protected games. [M] can re-enable it; restart afterward. Policy/UEFI enforcement is not bypassed. Other virtualization/VBS services are left unchanged.

[G] reports current/highest enumerated refresh rates at the current resolution and saved GPU preferences. It never changes resolution or guesses which GPU a game actually uses. Review Windows Graphics/Advanced display settings for per-game exceptions.

Page files are system-managed at every RAM size. Portable/Modern Standby PCs use the AC Best performance preference while preserving their power plan, battery mode and hibernation. Other desktops retain the Ultimate/High Performance path. Sleep timeouts and hibernation are left unchanged.

Cleanup never permanently deletes files or uninstalls apps. It skips system/application directories, known OneDrive paths, links, cloud placeholders and files that changed after scanning. Failed recycling is not retried as deletion. Files still occupy disk space until you empty the Recycle Bin; Storage Sense or other cleanup tools can empty it independently. Windows update caches, component cleanup and shader caches are excluded.

## Results and recovery

Logs and `operation_results_<timestamp>.jsonl` are saved in `logs/`. Results distinguish **Applied**, **AlreadyConfigured**, **Unsupported**, **Failed**, **RestartRequired**, and **Unverified**. Unverified means the command succeeded without an independent state check. Results cover the current session, not changes made afterward by Windows or other software.

Review failures and restart-required entries before rerunning. Use the individual menu actions when only part of a run needs repeating.

**Recovery:** use **R** (or `rstrui.exe`) and select the logged Gaming Optimizer checkpoint. Restore points can expire and are not full backups. **Undo** restores the saved mouse settings and resets selected settings to defaults; it does not fully reverse optimization. Registry exports cover selected keys only. Full recovery, including deleted files and removed apps, requires an independent backup made beforehand.

## Development

Requires Windows, Windows PowerShell 5.1 (including Out-GridView for deeper cleanup), and Python 3.9+ for tests; no third-party Python packages.

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
```

Tests mock system mutations and use disposable file fixtures. Set `OPTIMIZER_TEST_RECYCLE=1` to also test recycling and restoring a uniquely named generated fixture through the real Recycle Bin. A read-only registry check verifies provider integration. They test behavior and reporting, not gaming performance.

[MIT license](LICENSE).
