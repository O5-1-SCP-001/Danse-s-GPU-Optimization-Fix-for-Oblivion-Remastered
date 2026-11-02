# Oblivion Remastered – Low/Mid-End Performance & Stutter Fix

An experimental `Engine.ini` configuration for **4–8 GB GPUs** and **8–16 GB RAM** systems. It was
informed by one baseline profile, not a controlled before-and-after benchmark. Performance, stability,
and visual changes vary; improvement is not guaranteed.

* No .pak, DLL, UE4SS, or OBSE required. The installer targets Steam's Windows and Game Pass WinGDK config folders; only the Steam setup was tested.
* Doesn't change your in-game settings (resolution, upscaler, VSync, frame cap).
* The installer attempts to detect your GPU's VRAM and picks a tier (4 GB / 6 GB / 8 GB+); verify its selection on multi-GPU and integrated-GPU systems.
* The installer saves prior values in a per-folder state file and uses them to restore its keys. It stops on conflicts rather than overwriting later edits.

---

## Installation

### Automatic (recommended)
1. Launch the game once to the main menu, then quit (this creates the config folder). Keep the game and other config editors closed while installing or uninstalling.
2. Extract the archive anywhere.
3. Double-click **`Install.bat`**.
   * To choose a tier, open PowerShell in the extracted folder and run `powershell.exe -ExecutionPolicy Bypass -File Install-PerformanceFix.ps1 -Tier 4GB` (or `6GB`, `8GB`).
   * Auto-detection chooses the 6GB tier on a 6GB RTX 3050. The smaller 4GB tier was the configuration used in the recent outdoor experiment on that GPU; results are not guaranteed and may include texture pop-in.
4. Play.

If both `Windows` and `WinGDK` config folders exist, the installer acts on both. To target just one, run `powershell.exe -ExecutionPolicy Bypass -File Install-PerformanceFix.ps1 -ConfigDir "<folder containing Engine.ini>"` in PowerShell.

To remove the mod, double-click **`Uninstall.bat`**.

For each config folder the installer creates `Engine.ini.obr-perffix.state.json` alongside `Engine.ini`.
Keep this state file: it records the original `SystemSettings` lines, including absent keys, and the
installed values, even if the game removes comments or merges sections. Reinstalling updates the tier
without replacing the original values. An existing `Engine.ini.obr-perffix.bak` is never overwritten;
the backup is a snapshot, not a record of later edits. Read-only `Engine.ini` files retain that attribute.

If an installed key has changed or is missing, install/uninstall refuses to edit the file. Duplicate
managed keys are refused except for validated legacy adoption described below. Review conflicts and state
and resolve them deliberately. The installer
also refuses malformed state and ambiguous legacy blocks. Interrupted operations retain recovery state;
run uninstall after checking the files. Preview with `Install.bat -WhatIf` or run the PowerShell script
with `-Uninstall -WhatIf`; previews do not write files. If state is missing, the installer cannot safely
identify marker-stripped settings: it will not remove them automatically. Restore or compare a backup
manually, taking care not to overwrite unrelated later changes. Conflict detection compares values; it
cannot identify a third-party edit that happens to use the same value as the installer.

Old marker-based installs: with intact markers, uninstall removes only an unmodified, recognized legacy
preset's settings and markers, leaving comments and other content. It cannot reconstruct values the old
installer overrode. If the block was edited, inspect the settings and backup manually. Normal installation
over a marker-stripped legacy install with unique keys treats their current values as pre-existing, not as
removable mod values; duplicate managed keys are refused. Intact legacy installs must be uninstalled or
resolved before reinstalling.

### Opt-in recovery for marker-stripped legacy installs

Only use adoption if you intend **all** matching managed `SystemSettings` entries to be removed later.
The original backup proves those keys were absent at backup time; it cannot prove that identical values
were not added later by another tweak. Adoption is therefore an explicit judgment, not automatic detection.
Close the game and config editors, then from PowerShell in the extracted mod folder preview (replace the
folder with the one containing your `Engine.ini`):

```powershell
.\Install-PerformanceFix.ps1 -ConfigDir "<config folder>" -AdoptLegacy -Tier 6GB -WhatIf
```

If the preview validates and you accept that judgment, repeat without `-WhatIf`. Omit `-Tier` only if you
want the installer to infer which single legacy preset matches; a supplied tier must match. Adoption requires
an existing `Engine.ini.obr-perffix.bak` with recognizable INI syntax and **no managed keys in any
`SystemSettings` section**. Every managed key must be present in the current file, and every occurrence
must match the same known legacy preset exactly. Missing keys, differing duplicates, invalid or missing
backup, markers, or existing state cause refusal; unrelated keys and other sections are preserved.

Adoption does not change `Engine.ini`. It writes a byte-for-byte snapshot to the new, distinct
`Engine.ini.obr-perffix.legacy-adoption.bak` and creates state recording all managed originals as absent.
Neither the original backup nor an existing adoption snapshot is overwritten. If an interruption leaves
the new snapshot but no state, inspect and move the snapshot elsewhere before retrying; do not discard it
without reviewing it. Later uninstall removes all matching managed occurrences, even if the game merges
sections or deduplicates entries, while keeping unrelated content and the snapshot. A changed value, a
missing key, or differing duplicates causes a conflict instead. Keep both backups and the state file until
recovery is complete.

### Manual
1. Open `Presets\<your VRAM>GB\Engine.ini` and copy **everything** in it.
2. Paste it at the **end** of:
   * Steam: `Documents\My Games\Oblivion Remastered\Saved\Config\Windows\Engine.ini`
   * Game Pass: `Documents\My Games\Oblivion Remastered\Saved\Config\WinGDK\Engine.ini`
3. Before saving, record any pre-existing values for these keys. Manual installation does not create installer state. To undo, restore those values and remove only keys you added. The game may strip markers and merge sections, so deleting a marked block later is not reliable.

The manual presets assume 16 GB RAM. With 8 GB RAM, change `gc.LowMemory.MemoryThresholdMB` to `1536`. The installer sets it automatically.

### Mod managers (Vortex / MO2)
These don't manage files in `Documents\My Games`. Use the installer or the manual method above.

---

## What it changes and why

These numbers come from Nsight Systems captures on an RTX 3050 6 GB, i7-8700 and 16 GB RAM, with all settings on Low at 1080p and 50% resolution scale:

| Problem measured (vanilla) | Value |
|---|---|
| Average FPS / 1% low | 27.7 / **3.2** |
| Frames > 50 ms in 95 s | **73** (incl. 1.2 s, 1.4 s and 2.1 s freezes) |
| Game VRAM vs. Windows budget | 3.8 GB used of a **~4.0 GB budget**, so it was already at the ceiling |
| VRAM demoted to system RAM | **up to 415 MB** (read over PCIe, which stalls the GPU) |
| GPU busy vs. actually issuing work | 88% busy, **7% SM issue**, so the GPU mostly waits on memory |
| Game RAM commit / free system RAM | 11.3 GB / **< 300 MB** |

| Area | Settings | Effect |
|---|---|---|
| VRAM | `r.LumenScene.SurfaceCache.AtlasSize`, `r.Nanite.Streaming.StreamingPoolSize`, `r.Streaming.PoolSize` (per tier) | Adjusts pool sizes; total VRAM use and demotion depend on the workload. |
| RAM | `gc.LowMemory.MemoryThresholdMB` (scaled to your RAM) | Changes the low-memory threshold; it cannot guarantee paging will be avoided. |
| Cell-transition hitches | `s.ForceGCAfterLevelStreamedOut=0` | Disables the forced full garbage collection after level streaming; incremental collection remains enabled. |
| Streaming spikes | `s.PriorityAsyncLoadingExtraTime`, `s.LevelStreamingActorsUpdateTimeLimit`, … | Adjusts streaming work time limits; the resulting frame pacing has not been validated. |
| Shadows (GPU) | VSM LOD bias 0.5 and clipmap last level 19 | Uses the **game's own High-preset values**. Vanilla Low renders *sharper*, farther shadows than High, which is a quirk of the shipped config. |
| Lumen (GPU) | Scene lighting/radiosity update factors, card refresh | Adjusts GI update rates; lighting responsiveness may change. |

**Visual impact:** these settings can affect shadow detail, texture quality, and lighting responsiveness; actual impact varies.

---

## Other considerations

On the test PC, **background apps held ~2 GB of the 6 GB card**, leaving the game only a ~4 GB budget.
Before playing:
1. **Close GPU-accelerated apps**: browsers, Discord, Spotify, Teams, Visual Studio/IDEs, overlays (Overwolf, Razer Axon wallpapers, GameAssist), launchers you don't need.
   You can check usage in Task Manager → Details → right-click a column header → *Select columns* → **Dedicated GPU memory**.
2. If your PC has an integrated GPU (Intel UHD/AMD APU), set browsers, Discord and Spotify to **Power saving** in
	  *Settings → System → Display → Graphics*. Whether an app uses the selected GPU varies.
3. Check your GPU driver's shader cache settings; results vary by driver and game.
4. **Page file:** leave it *System managed*, ideally on an SSD. With 16 GB RAM the game commits ~11 GB.
   Keep **at least 15–20 GB free on drive C:**. If Windows can't grow the page file, you get hard freezes or crashes.
5. **Upscaler:** compare available DLSS, FSR or XeSS modes with your preferred resolution scale.
6. **VSync at 60 Hz below 60 FPS** alternates 33/50 ms frames, which feels like stutter. Use a VRR display, or set the in-game frame limit to 30/40 for steadier pacing.

---

## Compatibility

* The baseline profile was captured on one Steam setup with OBSE64 installed. Cvar names were checked against that executable; this does not establish effectiveness or compatibility with every version.
* WinGDK, AMD, Intel GPUs, other game versions and other mod combinations have not been independently tested. Existing matching `SystemSettings` values are recorded and temporarily overridden; later changes to those keys cause a conflict rather than being overwritten.
* Auto-detection selects the adapter with the most reported VRAM, which might not be the GPU running the game. Select a tier manually if the reported adapter or tier is incorrect.
* Close the game and config editors before changes; restart the game afterwards. Outside the explicit validated legacy-adoption path, duplicate managed keys and unsupported INI syntax require manual review.

## Troubleshooting

* *"Config folder not found"*: launch the game once to the main menu first, or run `Install.bat -ConfigDir "<folder with Engine.ini>"`.
* To undo, run `Uninstall.bat`. A backup can help with manual recovery, but restoring it wholesale also discards subsequent unrelated changes.

## Changelog
See `CHANGELOG.md`.
