# Windows 11 Non-Touch Gaming Optimizer

Originally by **Matt Hurley**. [Original repository](https://github.com/theantipopau/windows11nontouchgamingoptimizer) · [This fork](https://github.com/apeck14/windows11nontouchgamingoptimizer)

A menu-driven utility for debloating and configuring Windows 11. It changes apps, services, registry values, power settings, networking and storage settings. These changes are not guaranteed FPS or latency improvements; measure performance on your hardware.

## Run

1. Download and extract the complete repository ZIP.
2. Keep `win11_nontouch_gaming_optimiser.bat` and `optimizer-operations.ps1` together.
3. Run the batch file as administrator and choose an action.
4. Review operation results before restarting.

Full and Recommended attempt to create a restore point. If creation fails, they offer an explicit continue/cancel choice, defaulting to cancel. Individual actions do not create restore points. Keep an independent backup: System Restore is not a backup of personal files.

## Actions

| Key | Action |
| --- | --- |
| 1 / F | Full: debloat, touch/pen, gaming, services, aggressive networking, visuals, startup, cleanup, GPU/storage, audio, memory, page file and core parking |
| 2 | Recommended: debloat, gaming, services, safe networking, visuals and core parking |
| 3 | Create a restore point |
| 4 | Remove selected consumer apps |
| 5 | Disable touch/pen components |
| 6 | Apply gaming settings; choose whether to keep Game DVR capture |
| 7 | Configure background services, telemetry and indexing |
| 8 | Apply safe or aggressive networking settings, or revert network settings |
| 9 | Choose balanced/minimal visuals, or skip |
| A | Configure startup-related settings and optional components |
| B | Clean temporary files, Windows Update download cache and superseded components; disable hibernation |
| C | Apply advanced GPU/storage settings |
| D | Apply audio settings |
| E | Optionally disable Xbox services; requires confirmation |
| H | Show brief help |
| P | Show operation results |
| V | Check selected live settings |
| U | Attempt a partial reset of selected settings |
| 0 | Exit |

Spotify is preserved. Xbox/Game Bar components are preserved unless you explicitly disable Xbox services. App removal covers the current user and future-user provisioning, reported separately.

Full uses aggressive TCP settings; Recommended uses the safe option. GPU scheduling, power, timer, scheduler and advanced GPU tweaks remain hardware/workload-dependent. They are settings to evaluate, not benchmark results.

## Results

The batch menu uses `optimizer-operations.ps1` to execute and journal requested operations. Both files are required. The script checks that its log and journal can be written before applying optimizations.

Each operation records one of these outcomes in `logs/operation_results_<timestamp>.jsonl`:

| Outcome | Meaning |
| --- | --- |
| Applied | The change completed and its result was checked. |
| AlreadyConfigured | The requested state was already present; no repeated write was needed. |
| Unsupported | The service, task, feature or removable app is unavailable on this installation. |
| Failed | Execution, enumeration or read-back failed; the diagnostic is preserved. Some changes may already have occurred. |
| RestartRequired | A saved configuration needs activation, or pending Windows servicing prevents completion. Read the detail to distinguish them. |
| Unverified | The command exited successfully, but an independent state check is not implemented. This does not count as verified success. |

Registry changes are compared before and after, including their value types. Services and scheduled tasks are read back. Optional features are checked for availability before changes. Current-user app removal and future-user provisioning have separate results; access denied is never treated as an absent app. Memory-manager and page-file changes are checked through Windows APIs. Boot configuration, selected power settings, TCP settings and TRIM are checked where supported. Other native commands retain their diagnostic output and are explicitly marked unverified.

The final report lists failed, unsupported, restart-required and unverified operations instead of claiming everything succeeded. Results are cumulative for the current script session. The existing **[V]** screen is labelled as limited configuration checks; it is not a performance score or a replacement for the operation report. A matching registry value cannot prove an FPS improvement, hardware support or that a running driver has adopted the setting.

## Cleanup and recovery

- Temporary-file cleanup accepts standard temp folders and your configured `%TEMP%`. It rejects roots and protected locations, skips junctions/symlinks, and reports failures such as locked files.
- Update-cache cleanup waits for the relevant services to stop and attempts to restore only those originally running. Their startup types are not changed by cleanup.
- Scheduled Optimize Drives maintenance is preserved. The script enables TRIM where requested.
- Undo resets selected settings to chosen defaults. It does **not** restore your original configuration, recover deleted files, or reinstall removed apps. It does not enable Remote Registry or Routing/Remote Access.
- Registry exports cover selected keys only. They are stored with logs; they are not a complete system backup.
- If Windows reports pending servicing, restart before retrying the deferred cleanup. Use individual actions instead of repeating the entire run unnecessarily.

## Development

Run `python -m unittest discover -s tests -p "test_*.py" -v` on Windows. Tests mock system mutations; cleanup tests use disposable directories. They check behavior and reporting, not performance gains.

## License

MIT License:

```
Copyright (c) 2025 Matt Hurley

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
