param(
    [Parameter(Mandatory = $true)]
    [string]$AddonId,

    [string]$StagingRoot = "C:\GitHub\_release_staging"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

# ------------------------------------------------------------
# Resolve repository / staged release
# ------------------------------------------------------------

$RepoRoot = Split-Path -Parent $PSScriptRoot
$StageDir = Join-Path $StagingRoot $AddonId
$PackageDir = Join-Path $StageDir "package"
$ExportDir = Join-Path $PackageDir $AddonId

if (-not (Test-Path $StageDir -PathType Container)) {
    throw "No staged release found for $AddonId at: $StageDir"
}

if (-not (Test-Path $ExportDir -PathType Container)) {
    throw "Staged package directory missing: $ExportDir"
}

$StagedAddonXmlPath = Join-Path $ExportDir "addon.xml"

if (-not (Test-Path $StagedAddonXmlPath -PathType Leaf)) {
    throw "Staged addon.xml missing: $StagedAddonXmlPath"
}

[xml]$StagedXml = Get-Content $StagedAddonXmlPath -Raw

$StagedId = [string]$StagedXml.addon.id
$Version = [string]$StagedXml.addon.version

if ($StagedId -ne $AddonId) {
    throw "Staged addon ID '$StagedId' does not match requested ID '$AddonId'."
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Staged addon.xml contains no version."
}

$ZipName = "$AddonId-$Version.zip"
$StagedZip = Join-Path $StageDir $ZipName
$RepoAddonDir = Join-Path $RepoRoot $AddonId
$RepoZip = Join-Path $RepoAddonDir $ZipName

if (-not (Test-Path $StagedZip -PathType Leaf)) {
    throw "Staged ZIP missing: $StagedZip"
}

if (-not (Test-Path $RepoAddonDir -PathType Container)) {
    throw "Repository addon directory missing: $RepoAddonDir"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Publish Tested Kodi Add-on Release" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Add-on:  $AddonId"
Write-Host "Version: $Version"
Write-Host "ZIP:     $StagedZip"

# ------------------------------------------------------------
# Validate staged ZIP
# ------------------------------------------------------------

$Archive = [System.IO.Compression.ZipFile]::OpenRead($StagedZip)

try {
    $Entries = @($Archive.Entries)

    $ExpectedAddonXml = "$AddonId/addon.xml"

    $AddonEntries = @(
        $Entries |
            Where-Object { $_.FullName -eq $ExpectedAddonXml }
    )

    if ($AddonEntries.Count -ne 1) {
        throw "Staged ZIP must contain exactly one $ExpectedAddonXml."
    }

    $BadSeparators = @(
        $Entries |
            Where-Object { $_.FullName -match '\\' }
    )

    if ($BadSeparators.Count -gt 0) {
        throw "Staged ZIP contains Windows backslash path separators."
    }

    $Reader = New-Object System.IO.StreamReader($AddonEntries[0].Open())

    try {
        [xml]$ZipXml = $Reader.ReadToEnd()
    }
    finally {
        $Reader.Dispose()
    }

    if ([string]$ZipXml.addon.id -ne $AddonId) {
        throw "addon.xml inside staged ZIP has incorrect addon ID."
    }

    if ([string]$ZipXml.addon.version -ne $Version) {
        throw "addon.xml inside staged ZIP has incorrect version."
    }
}
finally {
    $Archive.Dispose()
}

Write-Host "Validated staged ZIP." -ForegroundColor Green

# ------------------------------------------------------------
# Determine separately hosted artwork from TESTED package
# ------------------------------------------------------------

$AssetPaths = @()

$AssetNodes = $StagedXml.SelectNodes(
    '//extension[@point="xbmc.addon.metadata"]/assets/*'
)

foreach ($AssetNode in @($AssetNodes)) {

    $AssetPath = [string]$AssetNode.InnerText

    if (
        -not [string]::IsNullOrWhiteSpace($AssetPath) -and
        $AssetPath -notmatch '^[a-zA-Z]+://' -and
        $AssetPath -match '^media[\\/]'
    ) {
        $AssetPaths += $AssetPath
    }
}

$AssetPaths = @(
    $AssetPaths |
        Sort-Object -Unique
)

# Validate every asset BEFORE changing the repository.
foreach ($AssetPath in $AssetPaths) {

    $NormalizedAsset = $AssetPath.Replace('/', '\')
    $SourceAsset = Join-Path $ExportDir $NormalizedAsset

    if (-not (Test-Path $SourceAsset -PathType Leaf)) {
        throw "Tested package references missing artwork: $AssetPath"
    }
}

Write-Host "Validated $($AssetPaths.Count) standalone artwork file(s)." -ForegroundColor Green

# ------------------------------------------------------------
# ------------------------------------------------------------
# Refuse to publish an older staged release
# ------------------------------------------------------------

$ExistingVersions = @()

Get-ChildItem $RepoAddonDir -File -Filter "$AddonId-*.zip" |
    ForEach-Object {

        $ExistingArchive = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)

        try {
            $ExistingAddonEntry = @(
                $ExistingArchive.Entries |
                    Where-Object { $_.FullName -eq "$AddonId/addon.xml" }
            )

            if ($ExistingAddonEntry.Count -eq 1) {
                $ExistingReader = New-Object System.IO.StreamReader($ExistingAddonEntry[0].Open())

                try {
                    [xml]$ExistingXml = $ExistingReader.ReadToEnd()
                    $ExistingVersionText = [string]$ExistingXml.addon.version

                    try {
                        $ExistingVersions += [version]$ExistingVersionText
                    }
                    catch {
                        throw "Repository ZIP $($_.Name) contains invalid version: $ExistingVersionText"
                    }
                }
                finally {
                    $ExistingReader.Dispose()
                }
            }
        }
        finally {
            $ExistingArchive.Dispose()
        }
    }

try {
    $StagedVersionObject = [version]$Version
}
catch {
    throw "Staged release contains invalid version: $Version"
}

if ($ExistingVersions.Count -gt 0) {

    $NewestRepositoryVersion = @(
        $ExistingVersions | Sort-Object -Descending
    )[0]

    Write-Host "Newest repository version: $NewestRepositoryVersion"

    if ($StagedVersionObject -lt $NewestRepositoryVersion) {
        throw "Refusing to publish older version $Version over repository version $NewestRepositoryVersion."
    }
}

# ------------------------------------------------------------
# Publish exact tested ZIP
# ------------------------------------------------------------

Copy-Item $StagedZip $RepoZip -Force

$SourceHash = (Get-FileHash $StagedZip -Algorithm SHA256).Hash
$RepoHash = (Get-FileHash $RepoZip -Algorithm SHA256).Hash

if ($SourceHash -ne $RepoHash) {
    throw "Published ZIP hash does not match staged ZIP."
}

Write-Host "Published ZIP: $ZipName" -ForegroundColor Green

# ------------------------------------------------------------
# Publish standalone artwork from exact tested package
# ------------------------------------------------------------

foreach ($AssetPath in $AssetPaths) {

    $NormalizedAsset = $AssetPath.Replace('/', '\')

    $SourceAsset = Join-Path $ExportDir $NormalizedAsset
    $DestinationAsset = Join-Path $RepoAddonDir $NormalizedAsset
    $DestinationDirectory = Split-Path -Parent $DestinationAsset

    if (-not (Test-Path $DestinationDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $DestinationDirectory `
            -Force |
            Out-Null
    }

    Copy-Item $SourceAsset $DestinationAsset -Force

    $SourceAssetHash = (Get-FileHash $SourceAsset -Algorithm SHA256).Hash
    $DestinationAssetHash = (Get-FileHash $DestinationAsset -Algorithm SHA256).Hash

    if ($SourceAssetHash -ne $DestinationAssetHash) {
        throw "Published artwork hash mismatch: $AssetPath"
    }

    Write-Host "Published artwork: $AssetPath" -ForegroundColor Green
}

# ------------------------------------------------------------
# Regenerate repository metadata
# ------------------------------------------------------------

$GenerateRepo = Join-Path $PSScriptRoot "generate_repo.ps1"

if (-not (Test-Path $GenerateRepo -PathType Leaf)) {
    throw "generate_repo.ps1 not found: $GenerateRepo"
}

Write-Host ""
Write-Host "Regenerating repository metadata..." -ForegroundColor Cyan

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $GenerateRepo

if ($LASTEXITCODE -ne 0) {
    throw "Repository metadata generation failed."
}

# ------------------------------------------------------------
# Final report
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " RELEASE PUBLISHED LOCALLY" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Add-on:  $AddonId"
Write-Host "Version: $Version"
Write-Host "SHA256:  $($SourceHash.ToLower())"
Write-Host ""
Write-Host "Nothing has been committed or pushed to GitHub." -ForegroundColor Yellow
Write-Host "Review git status/diff before committing." -ForegroundColor Yellow
