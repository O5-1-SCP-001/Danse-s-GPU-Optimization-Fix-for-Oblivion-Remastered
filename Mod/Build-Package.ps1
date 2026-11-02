<#
.SYNOPSIS
	Builds the release zip: installer + rendered manual presets + docs  ->  dist\OBR-LowEndPerformanceFix-v<ver>.zip
#>
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'Source'
$root = Split-Path $PSScriptRoot
$installer = Join-Path $src 'Install-PerformanceFix.ps1'
$version = [regex]::Match([IO.File]::ReadAllText($installer), "\`$Version\s*=\s*'([^']+)'").Groups[1].Value
if (-not $version) { throw 'Could not read $Version from installer' }

$stage = Join-Path $root "dist\stage\OBR-LowEndPerformanceFix"
if (Test-Path (Split-Path $stage)) { Remove-Item (Split-Path $stage) -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item (Join-Path $src '*') $stage -Include *.ps1, *.bat, *.ini, *.md

# Manual presets. Keep in sync with Get-TierSettings in the installer; GC threshold assumes 16 GB RAM.
$tiers = @{
	'4GB' = @{ STREAMING_POOL = 700;  LUMEN_ATLAS = 2048; NANITE_POOL = 256 }
	'6GB' = @{ STREAMING_POOL = 800;  LUMEN_ATLAS = 2048; NANITE_POOL = 384 }
	'8GB' = @{ STREAMING_POOL = 1000; LUMEN_ATLAS = 4096; NANITE_POOL = 512 }
}
$template = [IO.File]::ReadAllText((Join-Path $src 'PerformanceFix.template.ini'))
foreach ($name in $tiers.Keys) {
	$s = $tiers[$name] + @{ TIER = $name; VERSION = $version; GC_LOWMEM_MB = 3072 }
	$text = $template
	foreach ($k in $s.Keys) { $text = $text.Replace("{{$k}}", [string]$s[$k]) }
	if ($text -match '\{\{\w+\}\}') { throw "Unfilled placeholder $($Matches[0]) in $name preset" }
	$dir = Join-Path $stage "Presets\$name"
	New-Item -ItemType Directory -Force $dir | Out-Null
	[IO.File]::WriteAllText((Join-Path $dir 'Engine.ini'), $text, [Text.UTF8Encoding]::new($false))
}

$zip = Join-Path $root "dist\OBR-LowEndPerformanceFix-v$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip
Remove-Item (Split-Path $stage) -Recurse -Force
Write-Host "Built $zip"
