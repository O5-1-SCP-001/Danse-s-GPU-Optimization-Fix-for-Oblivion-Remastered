$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path $PSScriptRoot) 'Source\Install-PerformanceFix.ps1'
$work = Join-Path $PSScriptRoot 'installer-test-work'
if (Test-Path -LiteralPath $work) { throw "Refusing to overwrite existing test directory: $work" }
function Get-CimInstance { param($ClassName) if ($ClassName -eq 'Win32_ComputerSystem') { [pscustomobject]@{ TotalPhysicalMemory = 16GB } } else { [pscustomobject]@{ Name = 'Test GPU'; AdapterRAM = 4GB } } }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Invoke-Installer($Dir, [string]$Tier = '4GB', [switch]$Uninstall, [switch]$WhatIf, [switch]$AdoptLegacy) {
	& $installer -ConfigDir $Dir -Tier $Tier -Uninstall:$Uninstall -WhatIf:$WhatIf -AdoptLegacy:$AdoptLegacy
}
function New-AdoptionCase([string]$Name, [string]$Text, [string]$Backup = "[Other]`r`nexisting=1`r`n[SystemSettings]`r`ncustom=original`r`n") {
	$dir = New-Case $Name $Text
	[IO.File]::WriteAllText((Join-Path $dir 'Engine.ini.obr-perffix.bak'), $Backup, [Text.UTF8Encoding]::new($false))
	return $dir
}
function Expect-Failure([scriptblock]$Action, [string]$Message) {
	$failed = $false
	try { & $Action } catch { $failed = $true }
	Assert $failed $Message
}
function New-Case([string]$Name, [string]$Text) {
	$dir = Join-Path $work $Name
	[void](New-Item -ItemType Directory -Path $dir)
	[IO.File]::WriteAllText((Join-Path $dir 'Engine.ini'), $Text, [Text.UTF8Encoding]::new($false))
	return $dir
}
try {
	[void](New-Item -ItemType Directory -Path $work)
	$original = "[Other]`r`nr.Streaming.PoolSize=999`r`n[SystemSettings]`r`n; user comment`r`n  r.Streaming.PoolSize = 333  `r`nuser.Setting=keep`r`n[SystemSettings]`r`nother.Setting=keep2`r`n"
	$dir = New-Case 'rewrite' $original
	$ini = Join-Path $dir 'Engine.ini'; $state = "$ini.obr-perffix.state.json"; $backup = "$ini.obr-perffix.bak"
	[IO.File]::WriteAllText($backup, 'existing backup')
	Invoke-Installer $dir -WhatIf
	Assert ([IO.File]::ReadAllText($ini) -ceq $original) 'WhatIf install changed ini'
	Assert (-not [IO.File]::Exists($state)) 'WhatIf install created state'
	Invoke-Installer $dir
	Assert ([IO.File]::ReadAllText($backup) -ceq 'existing backup') 'existing backup overwritten'
	Assert ([IO.File]::Exists($state)) 'state not created'
	Invoke-Installer $dir -Tier '8GB'
	$installed = [IO.File]::ReadAllText($ini)
	Assert ($installed -match 'r\.Streaming\.PoolSize=1000') 'reinstall tier not applied'
	# Model the game discarding comments and merging duplicate SystemSettings sections.
	$merged = $installed -replace '(?m)^\s*;[^\r\n]*(?:\r?\n|$)', ''
	$first = $true
	$merged = [regex]::Replace($merged, '(?m)^\[SystemSettings\]\r?\n', [Text.RegularExpressions.MatchEvaluator]{ param($m) if ($script:first) { $script:first = $false; return $m.Value } return '' })
	[IO.File]::WriteAllText($ini, $merged, [Text.UTF8Encoding]::new($false))
	$snapshot = [IO.File]::ReadAllText($ini)
	Invoke-Installer $dir -Uninstall -WhatIf
	Assert ([IO.File]::ReadAllText($ini) -ceq $snapshot -and [IO.File]::Exists($state)) 'WhatIf uninstall changed files'
	Invoke-Installer $dir -Uninstall
	$restored = [IO.File]::ReadAllText($ini)
	Assert ($restored.Contains('  r.Streaming.PoolSize = 333  ')) 'original line not restored'
	Assert ($restored.Contains('r.Streaming.PoolSize=999') -and $restored.Contains('user.Setting=keep') -and $restored.Contains('other.Setting=keep2')) 'unrelated content lost'
	Assert (-not $restored.Contains('r.Nanite.Streaming.StreamingPoolSize=')) 'previously absent key remains'
	Assert (-not [IO.File]::Exists($state)) 'state remains after uninstall'
	Invoke-Installer $dir -Uninstall
	$dir2 = New-Case 'conflict' "[SystemSettings]`r`nr.Streaming.PoolSize=55`r`n"
	$ini2 = Join-Path $dir2 'Engine.ini'
	Invoke-Installer $dir2
	$changed = [IO.File]::ReadAllText($ini2).Replace('r.Streaming.PoolSize=700', 'r.Streaming.PoolSize=123')
	[IO.File]::WriteAllText($ini2, $changed)
	Expect-Failure { Invoke-Installer $dir2 -Uninstall } 'changed key uninstall accepted'
	Expect-Failure { Invoke-Installer $dir2 -Tier '6GB' } 'changed key reinstall accepted'
	Assert ([IO.File]::ReadAllText($ini2) -ceq $changed) 'conflict modified ini'
	$dir3 = New-Case 'duplicates' "[SystemSettings]`r`nr.Streaming.PoolSize=3`r`n[SystemSettings]`r`nr.Streaming.PoolSize=4`r`n"
	Expect-Failure { Invoke-Installer $dir3 } 'duplicate keys accepted'
	Assert (-not [IO.File]::Exists((Join-Path $dir3 'Engine.ini.obr-perffix.state.json'))) 'duplicate created state'
	$dir4 = New-Case 'readonly' "[SystemSettings]`r`ncustom=x`r`n"
	$ini4 = Join-Path $dir4 'Engine.ini'
	(Get-Item $ini4).IsReadOnly = $true
	Invoke-Installer $dir4
	Assert ((Get-Item $ini4).IsReadOnly) 'install lost readonly'
	Invoke-Installer $dir4 -Uninstall
	Assert ((Get-Item $ini4).IsReadOnly) 'uninstall lost readonly'
	(Get-Item $ini4).IsReadOnly = $false
	$template = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot) 'Source\PerformanceFix.template.ini'))
	foreach ($pair in @{ VERSION='1.0.0'; TIER='4GB'; STREAMING_POOL='700'; LUMEN_ATLAS='2048'; NANITE_POOL='256'; GC_LOWMEM_MB='3072' }.GetEnumerator()) { $template = $template.Replace("{{$($pair.Key)}}", $pair.Value) }
	$dir5 = New-Case 'legacy' ("[Other]`r`nuntouched=1`r`n[SystemSettings]`r`nr.Streaming.PoolSize=42`r`n" + $template + "`r`n[SystemSettings]`r`ncustom=keep`r`n")
	Expect-Failure { Invoke-Installer $dir5 } 'legacy reinstall accepted'
	Invoke-Installer $dir5 -Uninstall
	$legacy = [IO.File]::ReadAllText((Join-Path $dir5 'Engine.ini'))
	Assert ($legacy.Contains('custom=keep') -and $legacy.Contains('untouched=1') -and $legacy.Contains('r.Streaming.PoolSize=42') -and -not $legacy.Contains('r.Streaming.PoolSize=700')) 'legacy removal incorrect'
	$dir6 = New-Case 'legacy-edited' ($template.Replace('r.Streaming.PoolSize=700', 'r.Streaming.PoolSize=701'))
	Expect-Failure { Invoke-Installer $dir6 -Uninstall } 'edited legacy block accepted'
	$dir7 = New-Case 'stripped-legacy' "[SystemSettings]`r`nr.Streaming.PoolSize=700`r`n"
	Invoke-Installer $dir7 -Uninstall
	Assert ([IO.File]::ReadAllText((Join-Path $dir7 'Engine.ini')).Contains('r.Streaming.PoolSize=700')) 'stripped legacy settings deleted'
	$dir8 = New-Case 'recovery' "[SystemSettings]`r`nr.Streaming.PoolSize=123`r`nother=keep`r`n"
	$ini8 = Join-Path $dir8 'Engine.ini'; $state8 = "$ini8.obr-perffix.state.json"
	Invoke-Installer $dir8
	Assert ([IO.File]::ReadAllText("$ini8.obr-perffix.bak").Contains('r.Streaming.PoolSize=123')) 'new backup missing original'
	$pending = [IO.File]::ReadAllText($state8) | ConvertFrom-Json
	$pending.Phase = 'Installing'
	foreach ($entry in $pending.Entries) { if ($entry.Key -eq 'r.Streaming.PoolSize') { $entry.Target = '1000' } }
	[IO.File]::WriteAllText($state8, ($pending | ConvertTo-Json -Depth 6))
	[IO.File]::WriteAllText($ini8, [IO.File]::ReadAllText($ini8).Replace('r.Streaming.PoolSize=700', 'r.Streaming.PoolSize=1000'))
	Expect-Failure { Invoke-Installer $dir8 } 'interrupted install accepted as normal reinstall'
	Invoke-Installer $dir8 -Uninstall
	Assert ([IO.File]::ReadAllText($ini8).Contains('r.Streaming.PoolSize=123')) 'interrupted install not recovered'
	$dir9 = New-Case 'bad-state' "[SystemSettings]`r`nuser=keep`r`n"
	$ini9 = Join-Path $dir9 'Engine.ini'; Invoke-Installer $dir9
	$before9 = [IO.File]::ReadAllText($ini9)
	[IO.File]::WriteAllText("$ini9.obr-perffix.state.json", '{invalid')
	Expect-Failure { Invoke-Installer $dir9 -Uninstall } 'malformed state accepted'
	Assert ([IO.File]::ReadAllText($ini9) -ceq $before9) 'malformed state changed ini'
	$dir10 = New-Case 'operator' "[SystemSettings]`r`n+r.streaming.poolsize=5`r`n"
	Expect-Failure { Invoke-Installer $dir10 } 'case-insensitive operator accepted'
	$dir11 = Join-Path $work 'missing-ini'; [void](New-Item -ItemType Directory -Path $dir11)
	Invoke-Installer $dir11 -WhatIf
	Assert (-not [IO.File]::Exists((Join-Path $dir11 'Engine.ini'))) 'WhatIf created missing ini'
	Invoke-Installer $dir11
	Invoke-Installer $dir11 -Uninstall
	Assert (-not [IO.File]::ReadAllText((Join-Path $dir11 'Engine.ini')).Contains('r.Streaming.PoolSize=')) 'missing ini uninstall left managed key'
	$dir12 = New-Case 'utf16' ''
	$ini12 = Join-Path $dir12 'Engine.ini'; $unicodeName = 'caf' + [char]0xE9
	[IO.File]::WriteAllText($ini12, "[SystemSettings]`nname=$unicodeName`n", [Text.Encoding]::Unicode)
	Invoke-Installer $dir12
	Invoke-Installer $dir12 -Uninstall
	$bytes12 = [IO.File]::ReadAllBytes($ini12)
	Assert ($bytes12[0] -eq 255 -and $bytes12[1] -eq 254 -and [IO.File]::ReadAllText($ini12).Contains("name=$unicodeName")) 'UTF-16 encoding or content lost'
	$dir13 = New-Case 'missing-key' "[SystemSettings]`r`ncustom=x`r`n"
	$ini13 = Join-Path $dir13 'Engine.ini'; Invoke-Installer $dir13
	$missing = [IO.File]::ReadAllText($ini13) -replace '(?m)^r\.Streaming\.PoolSize=700\r?\n', ''
	[IO.File]::WriteAllText($ini13, $missing)
	Expect-Failure { Invoke-Installer $dir13 -Uninstall } 'missing managed key accepted'
	Assert ([IO.File]::ReadAllText($ini13) -ceq $missing) 'missing key conflict changed ini'
	$dir14 = New-Case 'uninstall-recovery' "[SystemSettings]`r`nr.Streaming.PoolSize=123`r`nother=keep`r`n"
	$ini14 = Join-Path $dir14 'Engine.ini'; $state14 = "$ini14.obr-perffix.state.json"
	Invoke-Installer $dir14
	$pending14 = [IO.File]::ReadAllText($state14) | ConvertFrom-Json; $pending14.Phase = 'Uninstalling'
	[IO.File]::WriteAllText($state14, ($pending14 | ConvertTo-Json -Depth 6))
	[IO.File]::WriteAllText($ini14, [IO.File]::ReadAllText($ini14).Replace('r.Streaming.PoolSize=700', 'r.Streaming.PoolSize=123'))
	Invoke-Installer $dir14 -Uninstall
	Assert ([IO.File]::ReadAllText($ini14).Contains('r.Streaming.PoolSize=123') -and -not [IO.File]::Exists($state14)) 'interrupted uninstall not recovered'
	$template6 = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot) 'Source\PerformanceFix.template.ini'))
	foreach ($pair in @{ VERSION='1.0.0'; TIER='6GB'; STREAMING_POOL='800'; LUMEN_ATLAS='2048'; NANITE_POOL='384'; GC_LOWMEM_MB='3072' }.GetEnumerator()) { $template6 = $template6.Replace("{{$($pair.Key)}}", $pair.Value) }
	$lines6 = @([regex]::Matches($template6, '(?m)^[A-Za-z][\w.]*=[^\r\n]*') | ForEach-Object { $_.Value })
	$managed6 = ($lines6 -join "`r`n") + "`r`n"
	$legacy6 = "[Other]`r`nr.Streaming.PoolSize=777`r`n[SystemSettings]`r`n; current comment`r`ncustom=current`r`n" + $managed6 + "[SystemSettings]`r`n" + $managed6 + "other=preserve`r`n"
	$dir15 = New-AdoptionCase 'adopt-rewrite' $legacy6
	$ini15 = Join-Path $dir15 'Engine.ini'; $state15 = "$ini15.obr-perffix.state.json"; $snapshot15 = "$ini15.obr-perffix.legacy-adoption.bak"
	$backup15 = "$ini15.obr-perffix.bak"; $backupBefore = [IO.File]::ReadAllBytes($backup15)
	Invoke-Installer $dir15 -Tier '6GB' -AdoptLegacy -WhatIf
	Assert ([IO.File]::ReadAllText($ini15) -ceq $legacy6 -and -not [IO.File]::Exists($state15) -and -not [IO.File]::Exists($snapshot15)) 'adoption WhatIf wrote files'
	Invoke-Installer $dir15 -Tier '6GB' -AdoptLegacy
	Assert ([IO.File]::ReadAllText($ini15) -ceq $legacy6) 'adoption changed current ini'
	Assert ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($ini15), [IO.File]::ReadAllBytes($snapshot15))) 'adoption snapshot differs'
	Assert ([Linq.Enumerable]::SequenceEqual([byte[]]$backupBefore, [IO.File]::ReadAllBytes($backup15))) 'adoption modified original backup'
	$adopted = [IO.File]::ReadAllText($state15) | ConvertFrom-Json
	Assert ($adopted.Mode -eq 'AdoptedLegacy' -and @($adopted.Entries).Count -eq $lines6.Count) 'adopted state invalid'
	foreach ($entry in $adopted.Entries) { Assert ($null -eq $entry.OriginalLine -and $null -eq $entry.OriginalValue) 'adoption did not record absent originals' }
	Expect-Failure { Invoke-Installer $dir15 -Tier '6GB' -AdoptLegacy } 'existing state allowed adoption'
	# Model game comment stripping and section merging while retaining both copies.
	$rewritten = $legacy6.Replace('; current comment' + "`r`n", '').Replace("[SystemSettings]`r`n" + $managed6 + 'other=preserve', $managed6 + 'other=preserve')
	[IO.File]::WriteAllText($ini15, $rewritten, [Text.UTF8Encoding]::new($false))
	Invoke-Installer $dir15 -Uninstall -WhatIf
	Assert ([IO.File]::ReadAllText($ini15) -ceq $rewritten -and [IO.File]::Exists($state15)) 'adopted uninstall WhatIf wrote files'
	Invoke-Installer $dir15 -Uninstall
	$after15 = [IO.File]::ReadAllText($ini15)
	Assert ($after15 -ceq "[Other]`r`nr.Streaming.PoolSize=777`r`n[SystemSettings]`r`ncustom=current`r`nother=preserve`r`n") 'adopted uninstall lost unrelated lines or left duplicates'
	Assert ([IO.File]::Exists($snapshot15) -and -not [IO.File]::Exists($state15)) 'adoption snapshot/state retention incorrect'
	$dir16 = New-AdoptionCase 'adopt-direct' $legacy6; $ini16 = Join-Path $dir16 'Engine.ini'
	Invoke-Installer $dir16 -Tier '6GB' -AdoptLegacy
	Invoke-Installer $dir16 -Uninstall
	Assert ([IO.File]::ReadAllText($ini16).Contains('; current comment') -and -not [IO.File]::ReadAllText($ini16).Contains('r.Streaming.PoolSize=800')) 'direct adopted uninstall failed'
	$dir17 = New-AdoptionCase 'adopt-conflict' $legacy6; $ini17 = Join-Path $dir17 'Engine.ini'
	Invoke-Installer $dir17 -Tier '6GB' -AdoptLegacy
	$edited17 = [regex]::new('r\.Streaming\.PoolSize=800').Replace($legacy6, 'r.Streaming.PoolSize=801', 1)
	[IO.File]::WriteAllText($ini17, $edited17)
	Expect-Failure { Invoke-Installer $dir17 -Uninstall } 'changed adopted duplicate was removed'
	Expect-Failure { Invoke-Installer $dir17 -Tier '6GB' } 'changed adopted duplicate was reinstalled'
	Assert ([IO.File]::ReadAllText($ini17) -ceq $edited17) 'adopted conflict changed ini'
	$dir18 = New-AdoptionCase 'adopt-different' $edited17
	Expect-Failure { Invoke-Installer $dir18 -Tier '6GB' -AdoptLegacy } 'different legacy duplicates accepted'
	$dir19 = New-AdoptionCase 'adopt-missing-key' ($legacy6.Replace('r.Streaming.PoolSize=800' + "`r`n", ''))
	Expect-Failure { Invoke-Installer $dir19 -Tier '6GB' -AdoptLegacy } 'missing legacy key accepted'
	$dir20 = New-AdoptionCase 'adopt-mismatch' ($legacy6.Replace('r.Streaming.PoolSize=800', 'r.Streaming.PoolSize=700'))
	Expect-Failure { Invoke-Installer $dir20 -Tier '6GB' -AdoptLegacy } 'mixed legacy preset accepted'
	$dir21 = New-AdoptionCase 'adopt-backup-key' $legacy6 "[SystemSettings]`r`nr.streaming.poolsize=42`r`n"
	Expect-Failure { Invoke-Installer $dir21 -Tier '6GB' -AdoptLegacy } 'backup managed key accepted'
	$dir22 = New-AdoptionCase 'adopt-backup-invalid' $legacy6 'not an ini'
	Expect-Failure { Invoke-Installer $dir22 -Tier '6GB' -AdoptLegacy } 'invalid backup accepted'
	$dir23 = New-AdoptionCase 'adopt-backup-missing' $legacy6; [IO.File]::Delete((Join-Path $dir23 'Engine.ini.obr-perffix.bak'))
	Expect-Failure { Invoke-Installer $dir23 -Tier '6GB' -AdoptLegacy } 'missing backup accepted'
	$dir24 = New-AdoptionCase 'adopt-snapshot-exists' $legacy6
	$snapshot24 = Join-Path $dir24 'Engine.ini.obr-perffix.legacy-adoption.bak'; [IO.File]::WriteAllText($snapshot24, 'do not overwrite')
	Expect-Failure { Invoke-Installer $dir24 -Tier '6GB' -AdoptLegacy } 'existing snapshot accepted'
	Assert ([IO.File]::ReadAllText($snapshot24) -ceq 'do not overwrite') 'existing adoption snapshot overwritten'
	foreach ($dir in @($dir18, $dir19, $dir20, $dir21, $dir22, $dir23)) {
		Assert (-not [IO.File]::Exists((Join-Path $dir 'Engine.ini.obr-perffix.state.json')) -and -not [IO.File]::Exists((Join-Path $dir 'Engine.ini.obr-perffix.legacy-adoption.bak'))) 'rejected adoption created files'
	}
	Assert ([IO.File]::ReadAllText((Join-Path $dir18 'Engine.ini')) -ceq $edited17) 'rejected adoption changed current ini'
	Expect-Failure { Invoke-Installer $dir18 -Tier '6GB' -AdoptLegacy -WhatIf } 'WhatIf skipped adoption validation'
	$dir25 = New-AdoptionCase 'adopt-deduplicated' $legacy6; $ini25 = Join-Path $dir25 'Engine.ini'
	Invoke-Installer $dir25 -Tier 'Auto' -AdoptLegacy
	$deduplicated = "[Other]`r`nr.Streaming.PoolSize=777`r`n[SystemSettings]`r`ncustom=current`r`n" + $managed6 + "other=preserve`r`n"
	[IO.File]::WriteAllText($ini25, $deduplicated)
	Invoke-Installer $dir25 -Uninstall
	Assert ([IO.File]::ReadAllText($ini25) -ceq "[Other]`r`nr.Streaming.PoolSize=777`r`n[SystemSettings]`r`ncustom=current`r`nother=preserve`r`n") 'adopted uninstall failed after game deduplication'
	$dir26 = New-AdoptionCase 'adopt-reinstall' $legacy6; $ini26 = Join-Path $dir26 'Engine.ini'
	(Get-Item $ini26).IsReadOnly = $true
	Invoke-Installer $dir26 -Tier '6GB' -AdoptLegacy
	Invoke-Installer $dir26 -Tier '8GB'
	Assert ((Get-Item $ini26).IsReadOnly -and ([regex]::Matches([IO.File]::ReadAllText($ini26), 'r\.Streaming\.PoolSize=1000').Count -eq 2)) 'adopted reinstall did not update both readonly duplicates'
	Invoke-Installer $dir26 -Uninstall
	Assert ((Get-Item $ini26).IsReadOnly -and -not [IO.File]::ReadAllText($ini26).Contains('r.Streaming.PoolSize=1000')) 'adopted reinstall uninstall failed'
	(Get-Item $ini26).IsReadOnly = $false
	$dir27 = New-AdoptionCase 'adopt-invalid-encoding' $legacy6
	[IO.File]::WriteAllBytes((Join-Path $dir27 'Engine.ini.obr-perffix.bak'), [byte[]](255, 254, 0))
	Expect-Failure { Invoke-Installer $dir27 -Tier '6GB' -AdoptLegacy } 'invalid backup encoding accepted'
	$dir28 = New-AdoptionCase 'adopt-backup-operator' $legacy6 "[SystemSettings]`r`n+r.Streaming.PoolSize=4`r`n"
	Expect-Failure { Invoke-Installer $dir28 -Tier '6GB' -AdoptLegacy } 'backup managed operator accepted'
	$dir29 = New-AdoptionCase 'adopt-wrong-tier' $legacy6
	Expect-Failure { Invoke-Installer $dir29 -Tier '4GB' -AdoptLegacy } 'wrong legacy tier accepted'
	Expect-Failure { Invoke-Installer $dir29 -Tier '6GB' -AdoptLegacy -Uninstall } 'adopt and uninstall accepted together'
	foreach ($case in @(
		@{ Tier='4GB'; Pool='700'; Atlas='2048'; Nanite='256'; GC='1536' },
		@{ Tier='6GB'; Pool='800'; Atlas='2048'; Nanite='384'; GC='4096' },
		@{ Tier='8GB'; Pool='1000'; Atlas='4096'; Nanite='512'; GC='3072' }
	)) {
		$fixture = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot) 'Source\PerformanceFix.template.ini'))
		foreach ($pair in @{ VERSION='1.0.0'; TIER=$case.Tier; STREAMING_POOL=$case.Pool; LUMEN_ATLAS=$case.Atlas; NANITE_POOL=$case.Nanite; GC_LOWMEM_MB=$case.GC }.GetEnumerator()) { $fixture = $fixture.Replace("{{$($pair.Key)}}", $pair.Value) }
		$fixtureLines = @([regex]::Matches($fixture, '(?m)^[A-Za-z][\w.]*=[^\r\n]*') | ForEach-Object { $_.Value })
		$fixtureDir = New-AdoptionCase ("preset-$($case.Tier)") ("[SystemSettings]`r`n" + ($fixtureLines -join "`r`n") + "`r`n")
		Invoke-Installer $fixtureDir -Tier $case.Tier -AdoptLegacy
		Invoke-Installer $fixtureDir -Uninstall
	}
	Write-Host 'PASS: installer synthetic tests'
} finally {
	if (Test-Path -LiteralPath $work) { Get-ChildItem -LiteralPath $work -Recurse -File | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }; Remove-Item -LiteralPath $work -Recurse -Force }
}
