# Copy saved state from MLFlexer's original resurrect.wezterm into this fork's
# default state directory. Windows only — see migrate-from-mlflexer.sh for macOS/Linux.
#
# Non-destructive: only copies files, never deletes or overwrites. Does not touch
# your wezterm.lua — update the `wezterm.plugin.require(...)` URL yourself.
#
# Always prints a full diagnostic report. If anything looks wrong, paste the whole
# output into a GitHub issue — that's the intent, no need to reproduce locally.

$ErrorActionPreference = "Stop"

$ScriptVersion = "1.0.0"
$Copied = 0
$Skipped = 0
$OldDirsFound = 0
$NewStateDir = $null

function Log-Ok   { param($msg) Write-Host "[OK]   $msg" }
function Log-Skip { param($msg) Write-Host "[SKIP] $msg" }
function Log-Info { param($msg) Write-Host "[INFO] $msg" }
function Log-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red }

function Print-Summary {
    param($Status)
    Write-Host ""
    Write-Host "===== Migration Report ====="
    Write-Host "status:            $Status"
    Write-Host "old plugin dirs:   $OldDirsFound"
    Write-Host "new state dir:     $(if ($NewStateDir) { $NewStateDir } else { '<not resolved>' })"
    Write-Host "files copied:      $Copied"
    Write-Host "files skipped:     $Skipped (already present at destination)"
    Write-Host ""
    Write-Host "next steps:"
    Write-Host "  1. In your wezterm.lua, point require() at this fork:"
    Write-Host '       wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")'
    Write-Host "  2. Restart WezTerm (or run wezterm.reload_configuration())."
    Write-Host "  3. Once you've confirmed your old sessions show up via the fuzzy restore picker,"
    Write-Host "     you can delete the old MLFlexer plugin directory manually."
    Write-Host "============================="
    Write-Host "If something looks wrong, paste this whole output into a GitHub issue."
}

Write-Host "===== resurrect.wezterm migrate-from-mlflexer.ps1 v$ScriptVersion ====="
Write-Host "[INFO] date:        $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
Write-Host "[INFO] OS:          $([System.Environment]::OSVersion.VersionString)"
Write-Host "[INFO] PowerShell:  $($PSVersionTable.PSVersion)"
Write-Host "[INFO] APPDATA:     $(if ($env:APPDATA) { $env:APPDATA } else { '<unset>' })"
$wezVersion = $null
try {
    $wezVersion = (wezterm --version) 2>$null
} catch {
    $wezVersion = $null
}
if ($wezVersion) {
    Write-Host "[INFO] wezterm:     $wezVersion"
} else {
    Write-Host "[INFO] wezterm:     <not found on PATH>"
}
Write-Host ""

try {
    $AppData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME "AppData\Roaming" }
    $PluginsDir = Join-Path $AppData "wezterm\plugins"
    $NewStateDir = Join-Path $AppData "wezterm\resurrect"

    Log-Info "plugins directory:   $PluginsDir"
    Log-Info "new state directory: $NewStateDir"
    Write-Host ""

    if (-not (Test-Path $PluginsDir)) {
        Log-Info "plugins directory does not exist yet - nothing to migrate."
        Print-Summary "NOTHING_TO_MIGRATE"
        exit 0
    }

    # WezTerm encodes the require() URL into the clone directory name (including "."),
    # so match loosely rather than assuming "resurrect.wezterm" appears literally.
    $OldPluginDirs = @(Get-ChildItem -Path $PluginsDir -Directory -Filter "*MLFlexer*resurrect*")

    if ($OldPluginDirs.Count -eq 0) {
        Log-Info "no MLFlexer plugin directory found under $PluginsDir - nothing to migrate."
        Print-Summary "NOTHING_TO_MIGRATE"
        exit 0
    }

    foreach ($oldDir in $OldPluginDirs) {
        Log-Info "found old plugin dir: $($oldDir.FullName)"
        $oldStateDir = Join-Path $oldDir.FullName "state"

        if (-not (Test-Path $oldStateDir)) {
            Log-Info "no state\ subdirectory in $($oldDir.FullName) - skipping."
            continue
        }

        $OldDirsFound++

        foreach ($type in @("workspace", "window", "tab")) {
            $srcDir = Join-Path $oldStateDir $type
            if (-not (Test-Path $srcDir)) {
                Log-Info "no $srcDir, skipping $type"
                continue
            }

            $destDir = Join-Path $NewStateDir $type
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null

            $files = @(Get-ChildItem -Path $srcDir -Filter "*.json" -File)
            if ($files.Count -eq 0) {
                Log-Info "no *.json files in $srcDir"
                continue
            }

            foreach ($f in $files) {
                $dest = Join-Path $destDir $f.Name
                if (Test-Path $dest) {
                    Log-Skip "$type/$($f.Name) (already exists at destination)"
                    $Skipped++
                } else {
                    Copy-Item -Path $f.FullName -Destination $dest
                    Log-Ok "$type/$($f.Name) -> $dest"
                    $Copied++
                }
            }
        }
    }

    Print-Summary "SUCCESS"
}
catch {
    Log-Fail "unexpected error: $($_.Exception.Message)"
    Log-Fail "at: $($_.InvocationInfo.PositionMessage)"
    Print-Summary "FAILED"
    exit 1
}
