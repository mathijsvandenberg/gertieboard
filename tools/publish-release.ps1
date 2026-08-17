<#
.SYNOPSIS
    Publishes built Gertie board artifacts as a GitHub release, so GertieBoardLoader
    can offer them to end users under "Firmware from GitHub".

.DESCRIPTION
    The build outputs are deliberately gitignored - they are large and change every
    build, and git would keep every version forever. Releases keep the repository
    lean while still giving users versioned downloads.

    Three artifacts make up a working machine, and all three are published:

        output_files\gertieboard.sof   FPGA bitstream over JTAG, lost on power-off
        output_files\gertieboard.jic   configuration flash image, survives a power cycle
        tools\gertieboard_bios.64k     the 64 KB F-segment BIOS image

    The .jic and the .64k are separate things and both are needed: the .jic is the
    chipset, the .64k is the firmware that runs on it, and updating one does not
    update the other. Which files go out is set by tools\release-files.txt.

    Everything lands in release-staging\<Tag>, which is gitignored.

    This script stages the artifacts, generates SHA256SUMS and manifest.json, and
    then either uploads everything (when a token is available) or leaves the folder
    ready to drag onto the GitHub "Draft a new release" page.

    manifest.json is what makes the loader's picker readable: it gives each file a
    kind (bios / floppy / fpga-sram / fpga-flash) and a human description. Without
    it the loader falls back to guessing from the file extension.

.PARAMETER Tag
    Release tag, e.g. v1.0. Required.

.PARAMETER Notes
    Release description. Defaults to a short generated summary.

.PARAMETER Files
    Explicit list of files to publish. Defaults to the usual build outputs.

.PARAMETER Token
    GitHub personal access token with 'contents: write'. Falls back to $env:GITHUB_TOKEN.
    Omit it entirely to just stage the files locally for a manual upload.

.EXAMPLE
    .\tools\publish-release.ps1 -Tag v1.0
    .\tools\publish-release.ps1 -Tag v1.1 -Notes "CGA fixes" -PreRelease
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Notes = "",
    [string[]]$Files,
    [string]$Token = $env:GITHUB_TOKEN,
    [switch]$PreRelease,
    [switch]$CreateTag,
    [switch]$AllowDirty,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repo = 'mathijsvandenberg/gertieboard'
$root = Split-Path -Parent $PSScriptRoot

# ---- the tag has to be a real thing, on this commit -------------------------
# Without this the release is created from a tag NAME, and GitHub happily
# invents the tag at whatever the default branch happens to be. That is fine
# right up until it is not: publish from a feature branch, or after one more
# commit, and the release points at code nobody built. The artifacts would be
# correct and the source link would be wrong, which is the worst combination
# because only the source link is checkable later.
$gitStatus = & git -C $root status --porcelain
if ($gitStatus -and -not $AllowDirty) {
    throw ("the working tree is dirty:`n  " + (($gitStatus | Select-Object -First 10) -join "`n  ") +
           "`n`nA release built from uncommitted work cannot be reproduced from the tag." +
           " Commit it, or pass -AllowDirty if you genuinely mean to.")
}

$head = (& git -C $root rev-parse HEAD).Trim()

# "does this tag exist" has to tolerate the answer being no, and under
# $ErrorActionPreference = 'Stop' a native command writing to stderr is a
# TERMINATING error in PowerShell -- so the ordinary not-found case would throw
# an unhandled exception instead of being handled. --verify --quiet keeps git
# silent and returns a non-zero exit code, and the preference is relaxed across
# the call so that exit code is a value rather than an exception.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$tagAt = & git -C $root rev-parse --verify --quiet "refs/tags/$Tag^{commit}" 2>$null
$ErrorActionPreference = $prevEAP
if (-not $tagAt) {
    if (-not $CreateTag) {
        throw "tag $Tag does not exist. Create it, or pass -CreateTag to tag HEAD ($($head.Substring(0,7)))."
    }
    Write-Host "creating tag $Tag at $($head.Substring(0,7))" -ForegroundColor Cyan
    if (-not $DryRun) {
        & git -C $root tag -a $Tag -m "Release $Tag"
        & git -C $root push origin $Tag
    }
} elseif ($tagAt.Trim() -ne $head) {
    throw ("tag $Tag points at $($tagAt.Trim().Substring(0,7)) but HEAD is $($head.Substring(0,7)).`n" +
           "Publishing would ship artifacts built from HEAD under a tag naming other code.")
}
$stage = Join-Path $root "release-staging\$Tag"

# ---- descriptions shown in the loader's picker ------------------------------
$descriptions = @{
    'fpga-sram'  = 'FPGA bitstream - configures SRAM, lost on power-off'
    'fpga-flash' = 'Configuration flash image - survives power-cycling'
    'bios'       = 'XT BIOS, 64 KB F-segment image'
    'floppy'     = 'Bootable floppy image'
}

# Which files to publish is deliberately explicit: the build tree is full of
# diagnostic ROMs and stale .jic files that must not end up in a release.
# Preference order: -Files, then tools\release-files.txt, then a narrow default.
$listFile = Join-Path $PSScriptRoot 'release-files.txt'

$patterns = @()
if ($Files) {
    $patterns = $Files
} elseif (Test-Path $listFile) {
    $patterns = Get-Content $listFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
    Write-Host "using file list: $listFile" -ForegroundColor DarkGray
} else {
    $patterns = @('output_files\gertieboard.sof', 'output_files\gertieboard.jic')
    Write-Host "no tools\release-files.txt - defaulting to the main bitstreams only" -ForegroundColor Yellow
}

$selected = @()
$missing = @()
foreach ($pat in $patterns) {
    $p = if ([System.IO.Path]::IsPathRooted($pat)) { $pat } else { Join-Path $root $pat }
    $hits = Get-ChildItem $p -File -ErrorAction SilentlyContinue
    if (-not $hits) {
        # A GLOB matching nothing is a curation choice and stays a warning. A
        # NAMED FILE that is missing is a release quietly going out without it,
        # and that is not a warning-level event.
        if ($pat -match '[\*\?]') {
            Write-Host "  no match (glob): $pat" -ForegroundColor DarkYellow
        } else {
            $missing += $pat
        }
        continue
    }
    $selected += $hits
}
if ($missing) {
    throw ("listed for release but not on disk:`n  " + ($missing -join "`n  ") +
           "`n`nBuild them first - tools\mkfpga.sh for the .sof/.jic, tools\mkbios.sh" +
           " for the .64k - or correct tools\release-files.txt.")
}
$selected = $selected | Sort-Object FullName -Unique
if (-not $selected) { throw "no artifacts found - build first, or pass -Files" }

function Get-Kind($name) {
    switch ([System.IO.Path]::GetExtension($name).ToLower()) {
        '.sof' { 'fpga-sram' }
        '.jic' { 'fpga-flash' }
        '.pof' { 'fpga-flash' }
        '.64k' { 'bios' }
        '.rom' { 'bios' }
        '.ima' { 'floppy' }
        '.img' { 'floppy' }
        default { 'other' }
    }
}
function Get-Desc($name) {
    $kind = Get-Kind $name
    if ($descriptions.ContainsKey($kind)) { $descriptions[$kind] } else { '' }
}

# ---- refuse stale artifacts -------------------------------------------------
# This list named tools\xtbios_claude.64k for a long time after the BIOS build
# started producing gertieboard_bios.64k. The old file still EXISTED, so nothing
# warned and nothing failed - releases simply went out carrying a BIOS from a
# different build than the bitstreams packaged beside it. A missing file is
# loud. A stale one is silent, and the silent one is what reaches users.
#
# So each artifact is checked against the sources that actually produce it,
# which is what mkfpga.sh and mkbios.sh already do for the bench. Deliberately
# narrow: the FPGA does not care about tools\*.asm and the BIOS does not care
# about the VHDL, and checking everything against everything would just train
# people to pass -Force.
function Get-NewestSource($path, $include, $excludes) {
    $items = Get-ChildItem -Path $path -Include $include -File -Recurse -ErrorAction SilentlyContinue
    foreach ($x in $excludes) { $items = $items | Where-Object { $_.FullName -notlike $x } }
    if (-not $items) { return $null }
    return ($items | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

$buildDirs = @("*\db\*", "*\incremental_db\*", "*\release-staging\*", "*\simulation\*", "*\output_files\*")
$newestFor = @{
    'fpga-sram'  = Get-NewestSource $root @('*.vhd','*.vhdl','*.sdc','*.qsf') $buildDirs
    'fpga-flash' = Get-NewestSource $root @('*.vhd','*.vhdl','*.sdc','*.qsf') $buildDirs
    'bios'       = Get-NewestSource (Join-Path $root 'tools') @('xtbios_src.s','*.inc') @()
}

$stale = @()
foreach ($f in $selected) {
    $src = $newestFor[(Get-Kind $f.Name)]
    if ($src -and $f.LastWriteTime -lt $src.LastWriteTime) {
        $stale += "{0}  ({1:yyyy-MM-dd HH:mm}) is older than {2} ({3:yyyy-MM-dd HH:mm})" -f `
                  $f.Name, $f.LastWriteTime, $src.Name, $src.LastWriteTime
    }
}
if ($stale) {
    throw ("these artifacts are older than the sources that produce them:`n  " +
           ($stale -join "`n  ") +
           "`n`nRebuild - tools\mkfpga.sh for the .sof/.jic, tools\mkbios.sh for the" +
           " .64k - then publish. Shipping a mismatched set is how a release ends up" +
           " with a BIOS and a bitstream from different builds.")
}

# ---- the BIOS must agree with the tag ---------------------------------------
# The staleness check above catches a BIOS older than its source. It does NOT
# catch a BIOS that was rebuilt correctly and still says the previous version,
# because forgetting to bump the string is not a timestamp problem. That is a
# release which is internally consistent, freshly built, and lies to the user
# on the POST screen -- and the POST screen is the ONLY place a user can see
# which firmware they are running.
#
# The version lives in three .asciz strings in xtbios_src.s. This checks the
# built image rather than the source, because what ships is the image.
$verWanted = "Release " + ($Tag -replace '^[vV]', '')
foreach ($b in ($selected | Where-Object { (Get-Kind $_.Name) -eq 'bios' })) {
    $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($b.FullName))
    if ($text -notlike "*$verWanted*") {
        throw ("$($b.Name) does not contain `"$verWanted`".`n`n" +
               "Bump the version strings in tools\xtbios_src.s and rebuild with" +
               " tools\mkbios.sh. Publishing $Tag with a BIOS that reports a" +
               " different release is not something anyone finds later.")
    }
}
Write-Host "  BIOS reports $verWanted" -ForegroundColor DarkGray

# ---- stage ------------------------------------------------------------------
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Force $stage | Out-Null

Write-Host "staging $($selected.Count) file(s) for $Tag" -ForegroundColor Cyan
$manifestAssets = @()
$sumLines = @()
foreach ($f in $selected) {
    Copy-Item $f.FullName (Join-Path $stage $f.Name) -Force
    $hash = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()
    $sumLines += "$hash  $($f.Name)"
    $manifestAssets += [ordered]@{
        file        = $f.Name
        kind        = Get-Kind $f.Name
        description = Get-Desc $f.Name
        size        = $f.Length
    }
    "  {0,-28} {1,10:N0} B  {2}" -f $f.Name, $f.Length, (Get-Kind $f.Name) | Write-Host
}

# SHA256SUMS must use LF and no BOM so sha256sum -c works on Linux/macOS too
[System.IO.File]::WriteAllText((Join-Path $stage 'SHA256SUMS'),
    (($sumLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$manifest = [ordered]@{
    board   = 'gertieboard'
    version = $Tag
    built   = (Get-Date).ToString('yyyy-MM-dd')
    assets  = $manifestAssets
}
[System.IO.File]::WriteAllText((Join-Path $stage 'manifest.json'),
    ($manifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "  SHA256SUMS + manifest.json written" -ForegroundColor DarkGray
Write-Host "staged in: $stage"

if ($DryRun) { Write-Host "`n-DryRun: stopping before upload." -ForegroundColor Yellow; return }

# ---- upload (only if a token is available) ----------------------------------
if (-not $Token) {
    Write-Host ""
    Write-Host "No token given, so nothing was uploaded." -ForegroundColor Yellow
    Write-Host "Either set `$env:GITHUB_TOKEN and re-run, or upload by hand:"
    Write-Host "  1. https://github.com/$repo/releases/new?tag=$Tag"
    Write-Host "  2. drag in every file from $stage"
    Write-Host "  3. publish"
    return
}

if (-not $Notes) {
    $Notes = "Gertie board $Tag`n`nBuilt $(Get-Date -Format 'yyyy-MM-dd'). Verify downloads against SHA256SUMS."
}

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'gertieboard-publish'
}

Write-Host "`ncreating release $Tag on $repo" -ForegroundColor Cyan
try {
    $body = @{ tag_name = $Tag; name = $Tag; body = $Notes; prerelease = [bool]$PreRelease } | ConvertTo-Json
    $release = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$repo/releases" `
        -Headers $headers -Body $body -ContentType 'application/json'
} catch {
    # already exists -> reuse it so re-running the script updates the assets
    Write-Host "  release exists, reusing it" -ForegroundColor DarkGray
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/$Tag" -Headers $headers
}

$uploadBase = ($release.upload_url -replace '\{.*\}$', '')
foreach ($f in Get-ChildItem $stage -File) {
    # replace an existing asset of the same name, otherwise GitHub rejects it
    $existing = $release.assets | Where-Object { $_.name -eq $f.Name }
    if ($existing) {
        Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$repo/releases/assets/$($existing.id)" -Headers $headers | Out-Null
    }
    Write-Host "  uploading $($f.Name) ($('{0:N0}' -f $f.Length) B)"
    Invoke-RestMethod -Method Post -Uri "$uploadBase`?name=$($f.Name)" `
        -Headers $headers -InFile $f.FullName -ContentType 'application/octet-stream' | Out-Null
}

Write-Host "`ndone: $($release.html_url)" -ForegroundColor Green
Write-Host "GertieBoardLoader will show this under 'Firmware from GitHub'."
