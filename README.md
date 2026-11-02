# Oblivion Remastered Low/Mid-End Performance Fix - v1.1.0 source

This folder contains the source for the v1.1.0 Nexus package. The installer is a PowerShell script; the batch files launch it. No compiled application, DLL, game assets, profiling captures, or nested archives are included.

## Build the distribution ZIP

On Windows with Windows PowerShell 5.1 or later, from the repository root:

```powershell
powershell.exe -NoProfile -File .\Mod\Build-Package.ps1
```

This produces `dist\OBR-LowEndPerformanceFix-v1.1.0.zip`. The script deletes its `dist\stage` staging directory and overwrites an existing ZIP with that name; use a clean checkout and keep any files you need elsewhere. ZIP metadata and compression can differ, so the rebuilt archive may not have the same hash as the distributed archive.

## Run installer tests

```powershell
powershell.exe -NoProfile -File .\Mod\Tests\Test-Installer.ps1
```

The tests use temporary fixture files in `Mod\Tests\installer-test-work` and refuse to overwrite an existing test directory. They do not modify the game's configuration.

## Source layout

- `Mod\Source`: installer and uninstaller, config template, readme and changelog.
- `Mod\Build-Package.ps1`: renders three manual presets and builds the distribution ZIP.
- `Mod\Tests\Test-Installer.ps1`: installer and recovery regression tests.

The executable `.bat` wrappers run PowerShell using `-ExecutionPolicy Bypass` for that process; this does not change the machine-wide PowerShell execution policy. The installer edits user game configuration, maintains a recovery-state file and backup, and attempts to preserve unrelated settings. Consult `Mod\Source\README.md` for compatibility, recovery and uninstall details.

The published v1.1.0 archive inspected for the Nexus review has SHA-256 `83CADAADFEDEB409B351DF5AFC579FB0B867FBD2B68185F2AC0A1C61B7C503DE`. Verify that this hash matches the actual file submitted to Nexus before using it as an identifier.
