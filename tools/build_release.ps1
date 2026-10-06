param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRepo,

    [string]$OutputRoot = "C:\GitHub\_release_staging"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ------------------------------------------------------------
# Resolve source repository
# ------------------------------------------------------------

$SourceRepo = (Resolve-Path $SourceRepo).Path

$AddonXmlPath = Join-Path $SourceRepo "addon.xml"

if (-not (Test-Path $AddonXmlPath)) {
    throw "addon.xml not found: $AddonXmlPath"
}

[xml]$AddonXml = Get-Content $AddonXmlPath -Raw

$AddonId = [string]$AddonXml.addon.id
$Version = [string]$AddonXml.addon.version

if ([string]::IsNullOrWhiteSpace($AddonId)) {
    throw "addon.xml contains no addon ID."
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "addon.xml contains no addon version."
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Kodi Add-on Release Builder" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Source:  $SourceRepo"
Write-Host "ID:      $AddonId"
Write-Host "Version: $Version"

# ------------------------------------------------------------
# Verify Git repository and clean working tree
# ------------------------------------------------------------

Push-Location $SourceRepo

try {
    git rev-parse --is-inside-work-tree 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Source directory is not a Git repository."
    }

    $Status = @(git status --porcelain)

    if ($Status.Count -ne 0) {
        Write-Host ""
        Write-Host "Working tree is NOT clean:" -ForegroundColor Red
        $Status | ForEach-Object { Write-Host "  $_" }

        throw "Refusing to build from a dirty working tree."
    }

    $Head = (git rev-parse HEAD).Trim()

    $TagsAtHead = @(git tag --points-at HEAD)

    if ($TagsAtHead -notcontains $Version) {
        Write-Host ""
        Write-Host "Tags at HEAD:" -ForegroundColor Yellow

        if ($TagsAtHead.Count -eq 0) {
            Write-Host "  (none)"
        }
        else {
            $TagsAtHead | ForEach-Object { Write-Host "  $_" }
        }

        throw "Version $Version is not tagged at HEAD."
    }

    $TagCommit = (git rev-list -n 1 $Version).Trim()

    if ($TagCommit -ne $Head) {
        throw "Tag $Version does not point to HEAD."
    }
}
finally {
    Pop-Location
}

Write-Host "HEAD:    $Head"
Write-Host "Tag:     $Version" -ForegroundColor Green

# ------------------------------------------------------------
# Prepare clean staging area
# ------------------------------------------------------------

$AddonOutputRoot = Join-Path $OutputRoot $AddonId
$PackageRoot = Join-Path $AddonOutputRoot "package"
$ExportRoot = Join-Path $PackageRoot $AddonId

if (Test-Path $AddonOutputRoot) {
    Remove-Item $AddonOutputRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $ExportRoot -Force | Out-Null

# ------------------------------------------------------------
# Export ONLY files tracked by the release tag
#
# git archive ensures:
#   - no .git directory
#   - no untracked files
#   - no working-tree junk
#   - exact tagged release contents
# ------------------------------------------------------------

$TempTar = Join-Path $AddonOutputRoot "$AddonId-$Version.tar"

Push-Location $SourceRepo

try {
    git archive --format=tar --output="$TempTar" $Version

    if ($LASTEXITCODE -ne 0) {
        throw "git archive failed."
    }
}
finally {
    Pop-Location
}

tar -xf $TempTar -C $ExportRoot

if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract Git archive."
}

Remove-Item $TempTar -Force

# ------------------------------------------------------------
# Validate exported addon.xml
# ------------------------------------------------------------

$ExportedAddonXml = Join-Path $ExportRoot "addon.xml"

if (-not (Test-Path $ExportedAddonXml)) {
    throw "Export does not contain addon.xml."
}

[xml]$ExportXml = Get-Content $ExportedAddonXml -Raw

if ([string]$ExportXml.addon.id -ne $AddonId) {
    throw "Exported addon ID does not match expected ID."
}

if ([string]$ExportXml.addon.version -ne $Version) {
    throw "Exported addon version does not match expected version."
}

# ------------------------------------------------------------
# Reject development junk
# ------------------------------------------------------------

$ForbiddenNames = @(
    ".git",
    ".github",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".idea",
    ".vscode"
)

$BadFiles = @(
    Get-ChildItem $ExportRoot -Recurse -Force |
        Where-Object {
            $_.Name -in $ForbiddenNames -or
            $_.Extension -in @(".pyc", ".pyo")
        }
)

if ($BadFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "Forbidden files/directories found:" -ForegroundColor Red

    $BadFiles |
        ForEach-Object { Write-Host "  $($_.FullName)" }

    throw "Release contains forbidden development files."
}

# ------------------------------------------------------------
# Build ZIP using .NET
#
# PackageRoot contains:
#
#   addon.id\
#       addon.xml
#       ...
#
# Therefore the ZIP root is always addon.id/
# ------------------------------------------------------------

$ZipPath = Join-Path $AddonOutputRoot "$AddonId-$Version.zip"

if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
}

# Create ZIP entries manually instead of using CreateFromDirectory().
# On Windows, CreateFromDirectory() can store "\" in entry names.
# Kodi release packages should use portable "/" ZIP path separators.

$Archive = [System.IO.Compression.ZipFile]::Open(
    $ZipPath,
    [System.IO.Compression.ZipArchiveMode]::Create
)

try {
    $Files = @(
        Get-ChildItem $PackageRoot -Recurse -File -Force
    )

    foreach ($File in $Files) {
        $RelativePath = $File.FullName.Substring(
            $PackageRoot.Length
        ).TrimStart('\', '/')

        $EntryName = $RelativePath.Replace('\', '/')

        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Archive,
            $File.FullName,
            $EntryName,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
}
finally {
    $Archive.Dispose()
}

# ------------------------------------------------------------
# Inspect resulting ZIP
# ------------------------------------------------------------

$Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

try {
    $Entries = @($Archive.Entries)

    if ($Entries.Count -eq 0) {
        throw "ZIP is empty."
    }

    $BackslashEntries = @(
        $Entries | Where-Object { $_.FullName -match '\\' }
    )

    if ($BackslashEntries.Count -gt 0) {
        throw "ZIP contains Windows backslash path separators."
    }

    $ExpectedAddonXml = "$AddonId/addon.xml"

    $AddonEntries = @(
        $Entries |
            Where-Object { $_.FullName -eq $ExpectedAddonXml }
    )

    if ($AddonEntries.Count -ne 1) {
        throw "ZIP must contain exactly one $ExpectedAddonXml."
    }

    $WrongRoots = @(
        $Entries |
            Where-Object {
                $_.FullName -and
                -not $_.FullName.StartsWith("$AddonId/")
            }
    )

    if ($WrongRoots.Count -gt 0) {
        Write-Host ""
        Write-Host "Entries outside expected root:" -ForegroundColor Red

        $WrongRoots |
            Select-Object -First 20 |
            ForEach-Object { Write-Host "  $($_.FullName)" }

        throw "ZIP contains entries outside $AddonId/."
    }

    $ForbiddenZipEntries = @(
        $Entries |
            Where-Object {
                $_.FullName -match '(^|/)\.git(/|$)' -or
                $_.FullName -match '(^|/)__pycache__(/|$)' -or
                $_.FullName -match '\.py[co]$'
            }
    )

    if ($ForbiddenZipEntries.Count -gt 0) {
        throw "ZIP contains forbidden development files."
    }

    # Read addon.xml directly FROM THE ZIP.
    $Reader = New-Object System.IO.StreamReader($AddonEntries[0].Open())

    try {
        [xml]$ZipXml = $Reader.ReadToEnd()
    }
    finally {
        $Reader.Dispose()
    }

    if ([string]$ZipXml.addon.id -ne $AddonId) {
        throw "addon.xml inside ZIP has incorrect addon ID."
    }

    if ([string]$ZipXml.addon.version -ne $Version) {
        throw "addon.xml inside ZIP has incorrect version."
    }

    $FileEntries = @(
        $Entries |
            Where-Object { -not [string]::IsNullOrEmpty($_.Name) }
    )
}
finally {
    $Archive.Dispose()
}

# ------------------------------------------------------------
# Hash final package
# ------------------------------------------------------------

$Sha256 = Get-FileHash $ZipPath -Algorithm SHA256
$ZipItem = Get-Item $ZipPath

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " RELEASE PACKAGE BUILT SUCCESSFULLY" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Add-on:      $AddonId"
Write-Host "Version:     $Version"
Write-Host "Git commit:  $Head"
Write-Host "Files:       $($FileEntries.Count)"
Write-Host "ZIP size:    $([math]::Round($ZipItem.Length / 1MB, 2)) MB"
Write-Host "SHA256:      $($Sha256.Hash.ToLower())"
Write-Host ""
Write-Host "ZIP:"
Write-Host "  $ZipPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "This ZIP has NOT been copied into repository.nikoli4." -ForegroundColor Yellow
Write-Host "Install and test it in Kodi first." -ForegroundColor Yellow
Write-Host ""