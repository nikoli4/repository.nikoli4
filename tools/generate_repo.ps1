function Get-LatestAddonZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [Parameter(Mandatory = $true)]
        [string]$AddonId
    )

    $files = @(Get-ChildItem -LiteralPath $FolderPath -File -Filter "*.zip")
    $candidates = @()

    foreach ($file in $files) {
        $pattern = '^' + [regex]::Escape($AddonId) + '-(\d+\.\d+\.\d+)\.zip$'

        if ($file.Name -notmatch $pattern) {
            throw "Unexpected ZIP filename in ${AddonId}: $($file.Name)"
        }

        $candidates += [pscustomobject]@{
            File = $file
            Version = [version]$Matches[1]
        }
    }

    if ($candidates.Count -eq 0) {
        throw "No ZIP found for $AddonId"
    }

    return ($candidates |
        Sort-Object Version |
        Select-Object -Last 1).File
}

$ErrorActionPreference = "Stop"

function Test-KodiZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedAddonId
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

    try {
        $badEntries = @(
            $archive.Entries | Where-Object {
                $_.FullName -match '\\'
            }
        )

        if ($badEntries.Count -gt 0) {
            Write-Host ""
            Write-Host "ERROR: Kodi-incompatible ZIP paths found in:"
            Write-Host "  $ZipPath"
            Write-Host ""

            foreach ($entry in $badEntries | Select-Object -First 10) {
                Write-Host "  $($entry.FullName)"
            }

            if ($badEntries.Count -gt 10) {
                Write-Host "  ...and $($badEntries.Count - 10) more"
            }

            throw "ZIP contains backslash path separators."
        }

        $expectedAddonXml = "$ExpectedAddonId/addon.xml"

        $addonEntry = $archive.Entries | Where-Object {
            $_.FullName -eq $expectedAddonXml
        }

        if (-not $addonEntry) {
            Write-Host ""
            Write-Host "ERROR: ZIP does not contain expected addon.xml path:"
            Write-Host "  $expectedAddonXml"
            Write-Host ""
            Write-Host "ZIP:"
            Write-Host "  $ZipPath"

            throw "Missing expected addon.xml path."
        }

        Write-Host "Validated ZIP: $ExpectedAddonId"
    }
    finally {
        $archive.Dispose()
    }
}


$Root = Split-Path -Parent $PSScriptRoot

$AddonDirs = @(
    "repository.nikoli4",
    "plugin.program.akl",
    "script.module.akl",
    "script.akl.defaults",
    "script.akl.screenscraper",
    "script.akl.tgdbscraper",
    "script.akl.arcadedb",
    "skin.arctic.zephyr.akl"
)

$xmlParts = @()

foreach ($folder in $AddonDirs) {

    if ($folder -eq "repository.nikoli4") {
        $folderPath = Join-Path $Root $folder

        $repoZip = Get-LatestAddonZip -FolderPath $folderPath -AddonId $folder

        if (-not $repoZip) {
            throw "No repository ZIP found for $folder"
        }

        Test-KodiZip -ZipPath $repoZip.FullName -ExpectedAddonId $folder

        $addonXmlPath = Join-Path $Root "$folder\addon.xml"

        if (-not (Test-Path $addonXmlPath)) {
            throw "Missing addon.xml for $folder"
        }

        [xml]$addonXml = Get-Content $addonXmlPath -Raw
    }
    else {
        $folderPath = Join-Path $Root $folder

        $zip = Get-LatestAddonZip -FolderPath $folderPath -AddonId $folder

        if (-not $zip) {
            throw "No ZIP found for $folder"
        }

        Test-KodiZip -ZipPath $zip.FullName -ExpectedAddonId $folder

        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)

        try {
            $addonEntries = @(
                $archive.Entries | Where-Object {
                    $_.FullName -match '^[^/]+/addon\.xml$'
                }
            )

            if ($addonEntries.Count -ne 1) {
                throw "$($zip.FullName): expected exactly one top-level addon.xml"
            }

            $reader = New-Object System.IO.StreamReader($addonEntries[0].Open())

            try {
                $xmlText = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }

            [xml]$addonXml = $xmlText
        }
        finally {
            $archive.Dispose()
        }
    }

    # ------------------------------------------------------------
    # Validate separately hosted repository artwork
    #
    # Kodi repository metadata references icon/fanart/screenshots
    # as files beside the release ZIP. Verify every local media/*
    # reference in addon.xml actually exists in the repository.
    # ------------------------------------------------------------

    $assetPaths = @()

    $assetNodes = $addonXml.SelectNodes(
        '//extension[@point="xbmc.addon.metadata"]/assets/*'
    )

    foreach ($assetNode in @($assetNodes)) {

        $assetPath = [string]$assetNode.InnerText

        if (
            -not [string]::IsNullOrWhiteSpace($assetPath) -and
            $assetPath -notmatch '^[a-zA-Z]+://' -and
            $assetPath -match '^media[\\/]'
        ) {
            $assetPaths += $assetPath
        }
    }

    $assetPaths = @(
        $assetPaths |
            Sort-Object -Unique
    )

    foreach ($assetPath in $assetPaths) {

        $normalizedAssetPath = $assetPath.Replace('/', '\')
        $repositoryAssetPath = Join-Path $folderPath $normalizedAssetPath

        if (-not (Test-Path $repositoryAssetPath -PathType Leaf)) {

            Write-Host ""
            Write-Host "ERROR: Repository artwork is missing." -ForegroundColor Red
            Write-Host "Add-on:   $($addonXml.addon.id)"
            Write-Host "Version:  $($addonXml.addon.version)"
            Write-Host "Metadata: $assetPath"
            Write-Host "Expected: $repositoryAssetPath"
            Write-Host ""

            throw "Missing repository artwork for $($addonXml.addon.id)."
        }

        Write-Host "Validated artwork: $($addonXml.addon.id)/$($assetPath.Replace('\','/'))"
    }

    $id = $addonXml.addon.id
    $version = $addonXml.addon.version

    Write-Host "Adding $id $version"

    $xmlParts += $addonXml.addon.OuterXml
}


$addonsXmlPath = Join-Path $Root "addons.xml"
$md5Path = Join-Path $Root "addons.xml.md5"

$builder = New-Object System.Text.StringBuilder

[void]$builder.Append('<?xml version="1.0" encoding="UTF-8"?>' + "`n")
[void]$builder.Append('<addons>' + "`n")

foreach ($part in $xmlParts) {
    [void]$builder.Append($part + "`n")
}

[void]$builder.Append('</addons>' + "`n")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $addonsXmlPath,
    $builder.ToString(),
    $utf8NoBom
)

$md5 = Get-FileHash $addonsXmlPath -Algorithm MD5

[System.IO.File]::WriteAllText(
    $md5Path,
    $md5.Hash.ToLower(),
    $utf8NoBom
)

Write-Host ""
Write-Host "Wrote: $addonsXmlPath"
Write-Host "Wrote: $md5Path"
Write-Host "MD5:   $($md5.Hash.ToLower())"
