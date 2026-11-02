<#
.SYNOPSIS
	Installs / uninstalls the Oblivion Remastered Low/Mid-End Performance & Stutter Fix.

.DESCRIPTION
	Detects GPU VRAM and system RAM, picks a tier, and records original settings in
	per-install state so uninstall works even if the game rewrites Engine.ini.

.PARAMETER Tier
	Auto (default), 4GB, 6GB or 8GB. Overrides VRAM auto-detection.

.PARAMETER Uninstall
	Restores the settings recorded by the installer, unless they have changed.

.PARAMETER AdoptLegacy
	Explicitly adopt an unmarked legacy preset after validating the original backup.
	Requires -ConfigDir. Creates state and a separate snapshot without changing Engine.ini.

.PARAMETER ConfigDir
	Optional explicit config folder (the folder that contains Engine.ini).

.EXAMPLE
	.\Install-PerformanceFix.ps1
	.\Install-PerformanceFix.ps1 -Tier 4GB
	.\Install-PerformanceFix.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess)]
param(
	[ValidateSet('Auto', '4GB', '6GB', '8GB')]
	[string]$Tier = 'Auto',
	[switch]$Uninstall,
	[switch]$AdoptLegacy,
	[string]$ConfigDir
)

$ErrorActionPreference = 'Stop'
$Version = '1.1.0'
$BeginMarker = '; ==== BEGIN OBR-LowEndPerformanceFix ===='
$EndMarker = '; ==== END OBR-LowEndPerformanceFix ===='
$TemplatePath = Join-Path $PSScriptRoot 'PerformanceFix.template.ini'

function Get-GpuInfo {
	# Win32_VideoController.AdapterRAM is a uint32 and caps at 4 GB, so prefer the 64-bit registry value.
	$gpus = @()
	$classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
	Get-ChildItem $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
		$p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
		$bytes = $p.'HardwareInformation.qwMemorySize'
		if (-not $bytes) { $bytes = $p.'HardwareInformation.MemorySize' }
		if ($bytes -is [byte[]]) { $bytes = if ($bytes.Length -ge 8) { [BitConverter]::ToUInt64($bytes, 0) } else { [BitConverter]::ToUInt32($bytes, 0) } }
		if ($p.DriverDesc -and $bytes) {
			$gpus += [pscustomobject]@{ Name = $p.DriverDesc; VramGB = [math]::Round([double]$bytes / 1GB, 1) }
		}
	}
	if (-not $gpus) {
		$gpus = Get-CimInstance Win32_VideoController | ForEach-Object {
			[pscustomobject]@{ Name = $_.Name; VramGB = [math]::Round([double]$_.AdapterRAM / 1GB, 1) }
		}
	}
	# The game runs on the discrete GPU; the one with the most VRAM is the best proxy.
	$gpus | Sort-Object VramGB -Descending | Select-Object -First 1
}

function Get-TierSettings([string]$TierName, [double]$RamGB) {
	$t = switch ($TierName) {
		'4GB' { @{ STREAMING_POOL = 700;  LUMEN_ATLAS = 2048; NANITE_POOL = 256 } }
		'6GB' { @{ STREAMING_POOL = 800;  LUMEN_ATLAS = 2048; NANITE_POOL = 384 } }
		'8GB' { @{ STREAMING_POOL = 1000; LUMEN_ATLAS = 4096; NANITE_POOL = 512 } }
	}
	# Enter low-memory GC mode before Windows starts paging the game out.
	$t.GC_LOWMEM_MB = if ($RamGB -le 9) { 1536 } elseif ($RamGB -le 17) { 3072 } else { 4096 }
	$t.TIER = $TierName
	$t.VERSION = $Version
	$t
}

function Get-ConfigDirs {
	if ($ConfigDir) { return , (Resolve-Path $ConfigDir).Path }
	$docs = [Environment]::GetFolderPath('MyDocuments')
	$base = Join-Path $docs 'My Games\Oblivion Remastered\Saved\Config'
	@('Windows', 'WinGDK') | ForEach-Object { Join-Path $base $_ } | Where-Object { Test-Path $_ }
}

function Get-Settings([string]$TierName, [double]$RamGB) {
	$block = [IO.File]::ReadAllText($TemplatePath)
	$parameters = Get-TierSettings $TierName $RamGB
	foreach ($key in $parameters.Keys) { $block = $block.Replace("{{$key}}", [string]$parameters[$key]) }
	if ($block -match '\{\{\w+\}\}') { throw "Unfilled template placeholder: $($Matches[0])" }
	$result = [ordered]@{}
	foreach ($match in [regex]::Matches($block, '(?m)^([A-Za-z][\w.]+)=([^\r\n]*)')) {
		if ($result.Contains($match.Groups[1].Value)) { throw 'Duplicate template key.' }
		$result[$match.Groups[1].Value] = $match.Groups[2].Value.Trim()
	}
	return $result
}

function Get-LegacySettings([string]$TierName, [double]$RamGB) {
	$pool = switch ($TierName) { '4GB' { '700' } '6GB' { '800' } '8GB' { '1000' } }
	$atlas = if ($TierName -eq '8GB') { '4096' } else { '2048' }
	$nanite = switch ($TierName) { '4GB' { '256' } '6GB' { '384' } '8GB' { '512' } }
	$gc = if ($RamGB -le 9) { '1536' } elseif ($RamGB -le 17) { '3072' } else { '4096' }
	return [ordered]@{
		'r.Streaming.LimitPoolSizeToVRAM' = '1'
		'r.Streaming.PoolSize' = $pool
		'r.LumenScene.SurfaceCache.AtlasSize' = $atlas
		'r.Nanite.Streaming.StreamingPoolSize' = $nanite
		'gc.LowMemory.MemoryThresholdMB' = $gc
		'gc.LowMemory.TimeBetweenPurgingPendingKillObjects' = '30'
		's.ForceGCAfterLevelStreamedOut' = '0'
		's.ContinuouslyIncrementalGCWhileLevelsPendingPurge' = '1'
		's.PriorityAsyncLoadingExtraTime' = '4'
		's.LevelStreamingActorsUpdateTimeLimit' = '4'
		's.PriorityLevelStreamingActorsUpdateExtraTime' = '2'
		's.UnregisterComponentsTimeLimit' = '1'
		'r.Shadow.Virtual.ResolutionLodBiasDirectional' = '0.5'
		'r.Shadow.Virtual.ResolutionLodBiasLocal' = '0.5'
		'r.Shadow.Virtual.Clipmap.LastLevel' = '19'
		'r.LumenScene.DirectLighting.UpdateFactor' = '64'
		'r.LumenScene.Radiosity.UpdateFactor' = '128'
		'r.LumenScene.SurfaceCache.CardCaptureRefreshFraction' = '0.0625'
	}
}

function Read-Ini([string]$Path) {
	if (-not [IO.File]::Exists($Path)) { return @{ Text = ''; Encoding = [Text.UTF8Encoding]::new($false); Bytes = $null } }
	$bytes = [IO.File]::ReadAllBytes($Path)
	$reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes), [Text.UTF8Encoding]::new($false, $true), $true)
	try { $text = $reader.ReadToEnd(); $encoding = $reader.CurrentEncoding } finally { $reader.Dispose() }
	$strict = [Text.Encoding]::GetEncoding($encoding.CodePage, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
	[void]$strict.GetString($bytes)
	return @{ Text = $text; Encoding = $encoding; Bytes = $bytes }
}

function Assert-IniUnchanged([string]$Path, $Ini) {
	if ($null -eq $Ini.Bytes) {
		if ([IO.File]::Exists($Path)) { throw 'Engine.ini appeared during the operation; no INI changes made.' }
		return
	}
	if (-not [IO.File]::Exists($Path)) { throw 'Engine.ini disappeared during the operation; no INI changes made.' }
	$current = [IO.File]::ReadAllBytes($Path)
	if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$Ini.Bytes, [byte[]]$current)) { throw 'Engine.ini changed during the operation; no INI changes made.' }
}

function Parse-Ini([string]$Text, $Keys, [bool]$AllowDuplicates = $false) {
	$lines = [Collections.Generic.List[object]]::new()
	$found = @{}
	$occurrences = @{}
	$section = ''
	$sectionIndex = -1
	foreach ($match in [regex]::Matches($Text, '[^\r\n]+(?:\r\n|\r|\n)?|\r\n|\r|\n')) {
		$raw = $match.Value
		$content = $raw.TrimEnd("`r", "`n")
		$ending = $raw.Substring($content.Length)
		$index = $lines.Count
		$lines.Add([pscustomobject]@{ Content = $content; Ending = $ending })
		if ($content -match '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$') {
			$section = $Matches[1].Trim()
			if ($section -ieq 'SystemSettings' -and $sectionIndex -lt 0) { $sectionIndex = $index }
			continue
		}
		if ($content -match '^\s*\[') { throw "Ambiguous section header: $content" }
		if ($section -ine 'SystemSettings' -or $content -match '^\s*[;#]') { continue }
		if ($content -match '^\s*([+\-.!]?)([A-Za-z][\w.]*)\s*=\s*(.*?)\s*$') {
			$operator = $Matches[1]; $key = $Matches[2]; $value = $Matches[3]
			if ($Keys.Contains($key)) {
				if ($operator -or ($found.ContainsKey($key) -and -not $AllowDuplicates)) { throw "Ambiguous or duplicate SystemSettings key: $key" }
				$found[$key] = [pscustomobject]@{ Index = $index; Value = $value; Line = $content }
				if (-not $occurrences.ContainsKey($key)) { $occurrences[$key] = [Collections.Generic.List[object]]::new() }
				$occurrences[$key].Add($found[$key])
			}
		} elseif ($content -match '^\s*[+\-.!]?([A-Za-z][\w.]*)\b' -and $Keys.Contains($Matches[1])) {
			throw "Ambiguous SystemSettings line: $content"
		}
	}
	return @{ Lines = $lines; Found = $found; Occurrences = $occurrences; SectionIndex = $sectionIndex }
}

function Save-Atomic([string]$Path, [string]$Text, [Text.Encoding]$Encoding) {
	$temp = "$Path.obr-$([guid]::NewGuid().ToString('N')).tmp"
	$existed = [IO.File]::Exists($Path)
	$attributes = if ($existed) { [IO.File]::GetAttributes($Path) } else { $null }
	try {
		[IO.File]::WriteAllText($temp, $Text, $Encoding)
		if ($existed) {
			if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing to replace a reparse point: $Path" }
			if ($attributes -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($Path, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly))) }
			[IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value)
		} else { [IO.File]::Move($temp, $Path) }
	} finally {
		if ($existed -and [IO.File]::Exists($Path)) { [IO.File]::SetAttributes($Path, $attributes) }
		if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
	}
}

function Save-State([string]$Path, $State) {
	Save-Atomic $Path ($State | ConvertTo-Json -Depth 6) ([Text.UTF8Encoding]::new($false))
}

function Render-Ini($Parsed, $Entries, [bool]$Restore, [string]$OriginalText) {
	$newline = if ($OriginalText -match '\r\n') { "`r`n" } elseif ($OriginalText -match '\n') { "`n" } elseif ($OriginalText -match '\r') { "`r" } else { "`r`n" }
	$insert = [Collections.Generic.List[string]]::new()
	foreach ($entry in $Entries) {
		$line = if ($Restore) { $entry.OriginalLine } else { "$($entry.Key)=$($entry.Target)" }
		if ($Parsed.Found.ContainsKey($entry.Key)) {
			foreach ($occurrence in $Parsed.Occurrences[$entry.Key]) {
				$index = $occurrence.Index
				if ($null -eq $line) { $Parsed.Lines[$index].Content = $null; $Parsed.Lines[$index].Ending = '' }
				else { $Parsed.Lines[$index].Content = $line }
			}
		} elseif ($null -ne $line) { $insert.Add($line) }
	}
	if ($insert.Count -gt 0) {
		if ($Parsed.SectionIndex -lt 0) {
			if ($Parsed.Lines.Count -gt 0 -and -not $Parsed.Lines[$Parsed.Lines.Count - 1].Ending) { $Parsed.Lines[$Parsed.Lines.Count - 1].Ending = $newline }
			$Parsed.Lines.Add([pscustomobject]@{ Content = '[SystemSettings]'; Ending = $newline })
			$Parsed.SectionIndex = $Parsed.Lines.Count - 1
		}
		$header = $Parsed.Lines[$Parsed.SectionIndex]
		if (-not $header.Ending) { $header.Ending = $newline }
		for ($i = $insert.Count - 1; $i -ge 0; $i--) {
			$Parsed.Lines.Insert($Parsed.SectionIndex + 1, [pscustomobject]@{ Content = $insert[$i]; Ending = $newline })
		}
	}
	return (($Parsed.Lines | ForEach-Object { $_.Content + $_.Ending }) -join '')
}

function Assert-State($State, $Keys) {
	if ($State.Format -ne 1 -or $State.Phase -notin @('Installed', 'Installing', 'Uninstalling') -or @($State.Entries).Count -ne $Keys.Count) { throw 'Invalid or unsupported installer state; no changes made.' }
	if ($null -ne $State.Mode -and $State.Mode -ne 'AdoptedLegacy') { throw 'Invalid installer state mode.' }
	$seen = @{}
	foreach ($entry in $State.Entries) {
		if (-not $entry.Key -or -not $Keys.Contains($entry.Key) -or $seen.ContainsKey($entry.Key)) { throw 'Invalid keys in installer state.' }
		$seen[$entry.Key] = $true
		foreach ($value in @($entry.OriginalLine, $entry.OriginalValue, $entry.Applied, $entry.Target)) {
			if ($null -ne $value -and ($value -isnot [string] -or $value -match '[\r\n]')) { throw 'Invalid value in installer state.' }
		}
		if ($null -ne $entry.OriginalLine) {
			if ($entry.OriginalLine -notmatch '^\s*([A-Za-z][\w.]*)\s*=\s*(.*?)\s*$' -or $Matches[1] -ine $entry.Key -or $Matches[2] -cne $entry.OriginalValue) { throw 'Invalid original value in installer state.' }
		} elseif ($null -ne $entry.OriginalValue) { throw 'Invalid original value in installer state.' }
		if ($State.Mode -eq 'AdoptedLegacy' -and ($null -ne $entry.OriginalLine -or $null -ne $entry.OriginalValue)) { throw 'Invalid adopted legacy original value.' }
		if ($null -eq $entry.Target -or ($State.Phase -eq 'Installed' -and $null -eq $entry.Applied)) { throw 'Invalid installed value in installer state.' }
	}
}

function Test-Value($Actual, $Expected) {
	return ($null -eq $Actual -and $null -eq $Expected) -or ($null -ne $Actual -and $null -ne $Expected -and [string]$Actual -ceq [string]$Expected)
}

function Assert-Current($Parsed, $State) {
	foreach ($entry in $State.Entries) {
		$actual = if ($Parsed.Found.ContainsKey($entry.Key)) { $Parsed.Found[$entry.Key].Value } else { $null }
		if ($Parsed.Occurrences.ContainsKey($entry.Key)) {
			foreach ($occurrence in $Parsed.Occurrences[$entry.Key]) {
				if (-not (Test-Value $occurrence.Value $actual)) { throw "Conflicting duplicates for '$($entry.Key)'; no changes made." }
			}
		}
		$ok = Test-Value $actual $entry.Applied
		if ($State.Phase -eq 'Installing') { $ok = $ok -or (Test-Value $actual $entry.Target) }
		if ($State.Phase -eq 'Uninstalling') { $ok = $ok -or (Test-Value $actual $entry.OriginalValue) }
		if (-not $ok) { throw "Conflict on SystemSettings key '$($entry.Key)': value changed since install. No changes made; resolve it manually." }
	}
}

function Assert-AdoptionIniSyntax($Ini, [string]$Label) {
	if ($null -eq $Ini.Bytes -or $Ini.Bytes.Length -eq 0) { throw "$Label is missing or empty; legacy adoption refused." }
	if ($Ini.Text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]' -or $Ini.Text.Contains($BeginMarker) -or $Ini.Text.Contains($EndMarker)) { throw "$Label is invalid or contains legacy markers; adoption refused." }
	$hasSection = $false
	foreach ($line in [regex]::Split($Ini.Text, '\r\n|\r|\n')) {
		if ($line -match '^\s*(?:[;#]|$)') { continue }
		if ($line -match '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$') {
			if (-not $Matches[1].Trim()) { throw "$Label contains an empty section; adoption refused." }
			$hasSection = $true; continue
		}
		if (-not $hasSection -or $line -notmatch '^\s*[+\-.!]?[A-Za-z_][^\s=]*\s*=.*$') { throw "$Label is not a recognizable INI; adoption refused." }
	}
	if (-not $hasSection) { throw "$Label has no INI sections; adoption refused." }
}

function Assert-LegacyBackup($Ini, $Keys) {
	Assert-AdoptionIniSyntax $Ini 'Original backup'
	$parsedBackup = Parse-Ini $Ini.Text $Keys $true
	if ($parsedBackup.Found.Count -ne 0) { throw 'Original backup contains managed SystemSettings keys; adoption refused.' }
}

function Get-LegacyPreset($Parsed, [string]$RequestedTier) {
	$matches = [Collections.Generic.List[object]]::new()
	foreach ($tierName in @('4GB', '6GB', '8GB')) {
		if ($RequestedTier -ne 'Auto' -and $RequestedTier -ne $tierName) { continue }
		foreach ($ram in @(8, 16, 32)) {
			$preset = Get-LegacySettings $tierName $ram
			$equal = $Parsed.Found.Count -eq $preset.Count
			foreach ($key in $preset.Keys) {
				if (-not $Parsed.Occurrences.ContainsKey($key)) { $equal = $false; continue }
				foreach ($occurrence in $Parsed.Occurrences[$key]) {
					if ($occurrence.Value -cne $preset[$key]) { $equal = $false }
				}
			}
			if ($equal) { $matches.Add([pscustomobject]@{ Tier = $tierName; Settings = $preset }) }
		}
	}
	if ($matches.Count -ne 1) { throw 'Managed settings do not all match exactly one recognized legacy preset; adoption refused.' }
	return $matches[0]
}

function Save-NewState([string]$Path, $State) {
	$temp = "$Path.obr-$([guid]::NewGuid().ToString('N')).tmp"
	try {
		[IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
		[IO.File]::Move($temp, $Path)
	} finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Remove-Legacy($Parsed, $Keys) {
	$begin = @(); $end = @()
	for ($i = 0; $i -lt $Parsed.Lines.Count; $i++) {
		if ($Parsed.Lines[$i].Content.Trim() -eq $BeginMarker) { $begin += $i }
		if ($Parsed.Lines[$i].Content.Trim() -eq $EndMarker) { $end += $i }
	}
	if ($begin.Count -ne 1 -or $end.Count -ne 1 -or $begin[0] -ge $end[0]) { throw 'Ambiguous legacy markers; no changes made.' }
	$legacy = @{}; $sections = 0
	for ($i = $begin[0] + 1; $i -lt $end[0]; $i++) {
		$line = $Parsed.Lines[$i].Content
		if ($line -match '^\s*(?:[;#]|$)') { continue }
		if ($line -match '^\s*\[SystemSettings\]\s*$') { $sections++; continue }
		if ($sections -ne 1 -or $line -notmatch '^\s*([A-Za-z][\w.]*)\s*=\s*(.*?)\s*$') { throw 'Legacy block contains unexpected content; no changes made.' }
		$key = $Matches[1]; $value = $Matches[2]
		if (-not $Keys.Contains($key) -or $legacy.ContainsKey($key)) { throw 'Legacy block contains unexpected or duplicate keys; no changes made.' }
		$legacy[$key] = $value
	}
	$matchesPreset = $false
	foreach ($tierName in @('4GB', '6GB', '8GB')) {
		foreach ($ram in @(8, 16, 32)) {
			$preset = Get-LegacySettings $tierName $ram
			$equal = $legacy.Count -eq $preset.Count -and $sections -eq 1
			foreach ($key in $preset.Keys) { if (-not $legacy.ContainsKey($key) -or $legacy[$key] -cne $preset[$key]) { $equal = $false } }
			if ($equal) { $matchesPreset = $true }
		}
	}
	if (-not $matchesPreset) { throw 'Legacy block differs from a known preset; no changes made.' }
	for ($i = $begin[0]; $i -le $end[0]; $i++) {
		$line = $Parsed.Lines[$i].Content
		if ($i -eq $begin[0] -or $i -eq $end[0] -or $line -match '^\s*[A-Za-z][\w.]*\s*=') { $Parsed.Lines[$i].Content = $null; $Parsed.Lines[$i].Ending = '' }
	}
	return (($Parsed.Lines | ForEach-Object { $_.Content + $_.Ending }) -join '')
}

if ($AdoptLegacy -and ($Uninstall -or -not $ConfigDir)) { throw '-AdoptLegacy requires an explicit -ConfigDir and cannot be combined with -Uninstall.' }
$dirs = @(Get-ConfigDirs)
if (-not $dirs) { throw 'Config folder not found. Specify an existing folder with -ConfigDir.' }
$keys = Get-Settings '4GB' 16
foreach ($dir in $dirs) {
	$engineIni = Join-Path $dir 'Engine.ini'
	$backup = "$engineIni.obr-perffix.bak"
	$statePath = "$engineIni.obr-perffix.state.json"
	$snapshotPath = "$engineIni.obr-perffix.legacy-adoption.bak"
	$paths = @($engineIni, $statePath, $backup)
	if ($AdoptLegacy) { $paths += $snapshotPath }
	foreach ($path in $paths) {
		if (Test-Path -LiteralPath $path) {
			$item = Get-Item -LiteralPath $path -Force
			if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsafe path: $path" }
		}
	}
	$ini = Read-Ini $engineIni
	$hasMarker = $ini.Text.Contains($BeginMarker) -or $ini.Text.Contains($EndMarker)
	$hasState = [IO.File]::Exists($statePath)
	if ($hasState -and $hasMarker) { throw 'Both installer state and legacy markers exist; resolve manually.' }
	$state = $null
	if ($hasState) {
		try { $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json; Assert-State $state $keys } catch { throw "Cannot use installer state '$statePath': $_" }
	}
	if ($AdoptLegacy -and ($hasMarker -or $hasState)) { throw 'Legacy adoption requires no markers and no existing installer state.' }
	$allowDuplicates = $AdoptLegacy -or ($hasMarker -and -not $hasState) -or ($state -and $state.Mode -eq 'AdoptedLegacy')
	$parsed = Parse-Ini $ini.Text $keys $allowDuplicates
	if ($AdoptLegacy) {
		Assert-AdoptionIniSyntax $ini 'Engine.ini'
		if ([IO.File]::Exists($snapshotPath)) { throw "Legacy adoption snapshot already exists: $snapshotPath. It will not be overwritten." }
		$originalBackup = Read-Ini $backup
		Assert-LegacyBackup $originalBackup $keys
		$preset = Get-LegacyPreset $parsed $Tier
		if ($preset.Settings.Count -ne $keys.Count) { throw 'Current template has incompatible keys; legacy adoption refused.' }
		foreach ($key in $preset.Settings.Keys) { if (-not $keys.Contains($key)) { throw 'Current template has incompatible keys; legacy adoption refused.' } }
		$entries = foreach ($key in $preset.Settings.Keys) {
			[pscustomobject]@{ Key = $key; OriginalLine = $null; OriginalValue = $null; Applied = $preset.Settings[$key]; Target = $preset.Settings[$key] }
		}
		$adoptedState = [pscustomobject]@{ Format = 1; Mode = 'AdoptedLegacy'; Phase = 'Installed'; Entries = @($entries) }
		if ($PSCmdlet.ShouldProcess($engineIni, "Adopt verified legacy $($preset.Tier) settings and create snapshot and state")) {
			Assert-IniUnchanged $engineIni $ini
			Assert-IniUnchanged $backup $originalBackup
			$stream = [IO.File]::Open($snapshotPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
			try { $stream.Write($ini.Bytes, 0, $ini.Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
			Assert-IniUnchanged $engineIni $ini
			Assert-IniUnchanged $backup $originalBackup
			Save-NewState $statePath $adoptedState
			Write-Host "[$dir] Adopted legacy $($preset.Tier) settings without modifying Engine.ini. Snapshot: $snapshotPath"
		}
		continue
	}
	if ($hasMarker) {
		if (-not $Uninstall) { throw 'Legacy marked installation detected. Uninstall it first or resolve manually.' }
		$legacyOutput = Remove-Legacy $parsed $keys
		if ($PSCmdlet.ShouldProcess($engineIni, 'Remove verified legacy settings')) { Assert-IniUnchanged $engineIni $ini; Save-Atomic $engineIni $legacyOutput $ini.Encoding; Write-Warning 'Legacy uninstall cannot restore values overridden by the old installer. Review your backup and settings.' }
		continue
	}
	if ($hasState) {
		Assert-Current $parsed $state
	}
	if ($Uninstall -and -not $state) { Write-Warning "[$dir] No installer state or intact legacy markers. Nothing removed; marker-stripped legacy settings require manual review."; continue }
	if (-not $Uninstall) {
		if ($state -and $state.Phase -ne 'Installed') { throw "Interrupted $($state.Phase) operation detected. Run -Uninstall to recover before reinstalling." }
		$gpu = Get-GpuInfo
		$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
		$tierName = if ($Tier -ne 'Auto') { $Tier } elseif ($gpu.VramGB -lt 5) { '4GB' } elseif ($gpu.VramGB -lt 7.5) { '6GB' } else { '8GB' }
		$settings = Get-Settings $tierName $ramGB
		if (-not $state) {
			$entries = foreach ($key in $settings.Keys) {
				$prior = $parsed.Found[$key]
				[pscustomobject]@{ Key = $key; OriginalLine = if ($prior) { $prior.Line } else { $null }; OriginalValue = if ($prior) { $prior.Value } else { $null }; Applied = if ($prior) { $prior.Value } else { $null }; Target = $settings[$key] }
			}
			$state = [pscustomobject]@{ Format = 1; Phase = 'Installing'; Entries = @($entries) }
			if ($parsed.Found.Count) { Write-Warning "Overriding existing SystemSettings keys (their original lines will be saved): $(@($parsed.Found.Keys) -join ', ')" }
		} else {
			foreach ($entry in $state.Entries) { $entry.Target = $settings[$entry.Key] }
			$state.Phase = 'Installing'
		}
		$output = Render-Ini $parsed $state.Entries $false $ini.Text
		if ($PSCmdlet.ShouldProcess($engineIni, "Install performance fix ($tierName) and save recovery state")) {
			Assert-IniUnchanged $engineIni $ini
			if ([IO.File]::Exists($engineIni) -and -not [IO.File]::Exists($backup)) {
				try { $source = [IO.File]::OpenRead($engineIni); $destination = [IO.File]::Open($backup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); try { $source.CopyTo($destination) } finally { $destination.Dispose() } } finally { if ($source) { $source.Dispose() } }
			}
			Save-State $statePath $state
			Assert-IniUnchanged $engineIni $ini
			Save-Atomic $engineIni $output $ini.Encoding
			foreach ($entry in $state.Entries) { $entry.Applied = $entry.Target }
			$state.Phase = 'Installed'
			Save-State $statePath $state
			Write-Host "[$dir] Installed v$Version ($tierName). State: $statePath"
		}
	} else {
		$output = Render-Ini $parsed $state.Entries $true $ini.Text
		if ($PSCmdlet.ShouldProcess($engineIni, 'Restore recorded settings and remove recovery state')) {
			Assert-IniUnchanged $engineIni $ini
			# During interrupted installation either value can be present; retain that fact until restored.
			if ($state.Phase -eq 'Installing') {
				foreach ($entry in $state.Entries) { if ($parsed.Found.ContainsKey($entry.Key)) { $entry.Applied = $parsed.Found[$entry.Key].Value } else { $entry.Applied = $null } }
			}
			$state.Phase = 'Uninstalling'
			Save-State $statePath $state
			Assert-IniUnchanged $engineIni $ini
			Save-Atomic $engineIni $output $ini.Encoding
			[IO.File]::Delete($statePath)
			Write-Host "[$dir] Restored recorded settings. Existing backup was retained."
		}
	}
}
