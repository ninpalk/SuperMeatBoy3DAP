param([string]$GameDirectory = 'F:\SteamLibrary\steamapps\common\Super Meat Boy 3D')
$ErrorActionPreference = 'Stop'
if (Get-Process -Name 'SMB-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Close Super Meat Boy 3D before installing the mod.'
}
$gameRoot = (Resolve-Path -LiteralPath $GameDirectory).Path
$win64 = Join-Path $gameRoot 'SMB\Binaries\Win64'
if (-not (Test-Path -LiteralPath (Join-Path $win64 'SMB-Win64-Shipping.exe'))) {
    throw 'The expected game executable was not found. Pass the game installation folder as GameDirectory.'
}
if (Test-Path -LiteralPath (Join-Path $win64 'UE4SS.dll')) {
    $modsRoot = Join-Path $win64 'Mods'
} elseif (Test-Path -LiteralPath (Join-Path $win64 'ue4ss\UE4SS.dll')) {
    $modsRoot = Join-Path $win64 'ue4ss\Mods'
} else { throw 'Install a working UE4SS loader first.' }
New-Item -ItemType Directory -Force -Path $modsRoot | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$modsFile = Join-Path $modsRoot 'mods.txt'
$text = if (Test-Path -LiteralPath $modsFile) { Get-Content -LiteralPath $modsFile -Raw } else { '' }
if (Test-Path -LiteralPath $modsFile) {
    Copy-Item -LiteralPath $modsFile -Destination ($modsFile + '.backup-' + $stamp)
}
foreach ($old in @('SMB3DLevelGate', 'SMB3DDiscovery', 'SMB3DDeathDiscovery', 'SMB3DAPlusDiscovery', 'SMB3DSpeedrunDiscovery', 'SMB3DTofuTrap', 'SMB3DTofuDiscovery', 'SMB3DTofuSpawnCapture', 'SMB3DTofuInputCapture')) {
    $enabled = Join-Path $modsRoot ($old + '\enabled.txt')
    if (Test-Path -LiteralPath $enabled) {
        Rename-Item -LiteralPath $enabled -NewName ('disabled-by-bridge-' + $stamp + '.txt')
    }
    $pattern = '(?m)^\s*' + [regex]::Escape($old) + '\s*:\s*[01]\s*$'
    $text = [regex]::Replace($text, $pattern, '')
}
$text = [regex]::Replace($text, '(?m)^\s*SMB3DArchipelago\s*:\s*[01]\s*$', '')
$text = "SMB3DLevelGate : 0`r`nSMB3DDiscovery : 0`r`nSMB3DDeathDiscovery : 0`r`nSMB3DAPlusDiscovery : 0`r`nSMB3DSpeedrunDiscovery : 0`r`nSMB3DTofuTrap : 0`r`nSMB3DTofuDiscovery : 0`r`nSMB3DTofuSpawnCapture : 0`r`nSMB3DTofuInputCapture : 0`r`nSMB3DArchipelago : 1`r`n" + $text
[System.IO.File]::WriteAllText($modsFile, $text, (New-Object System.Text.UTF8Encoding($false)))
$source = Join-Path $PSScriptRoot 'Mods\SMB3DArchipelago'
Copy-Item -LiteralPath $source -Destination $modsRoot -Recurse -Force
Write-Host "Installed SMB3DArchipelago in $modsRoot"
Write-Host 'The earlier test and discovery mods are disabled. Their folders and saved test state were preserved.'
Write-Host 'Start the updated client, connect to your AP room, and then launch the game.'
