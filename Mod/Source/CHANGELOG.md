# Changelog

## 1.1.0
- Add explicit, backup-validated adoption of marker-stripped legacy presets, with a separate non-overwriting current-file snapshot and conflict-checked removal of matching duplicates.
- Store per-install original `SystemSettings` values and installed values in a durable state file, allowing restoration after the game strips comments or merges sections.
- Refuse changed, missing, duplicate or ambiguous managed keys; retain existing backups and read-only attributes. Interrupted changes retain state for recovery.
- Recognize only intact, unmodified legacy preset blocks for cautious removal; marker-stripped or edited legacy installs require manual review.
- Clarify that performance effects have not been established by a controlled before-and-after benchmark.

## 1.0.0
- Initial release. VRAM-tiered (4/6/8 GB) Engine.ini fix: VRAM budget fit, low-memory GC,
  removal of forced GC after cell unload, time-sliced streaming, VSM/Lumen cost reductions.
- Auto-installer with backup, idempotent re-install, Game Pass (WinGDK) support, conflict warnings.
