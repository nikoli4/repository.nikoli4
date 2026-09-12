$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot

$AddonDirs = @(
    "repository.nikoli4",
    "plugin.program.akl",
    "script.akl.screenscraper",
    "script.akl.defaults",
    "skin.arctic.zephyr.mod"
)

$xmlParts = @()

foreach ($folder in $AddonDirs) {

    if ($folder -eq "repository.nikoli4") {
        $addonXmlPath = Join-Path $Root "$folder\addon.xml"

        if (-not (Test-Path $addonXmlPath)) {
            throw "Missing addon.xml for $folder"
        }

        [xml]$addonXml = Get-Content $addonXmlPath -Raw
    }
    else {
        $folderPath = Join-Path $Root $folder
        $zip = Get-ChildItem $folderPath -Filter *.zip |
               Sort-Object Name |
               Select-Object -Last 1

        if (-not $zip) {
            throw "No ZIP found for $folder"
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)

        try {
		$addonEntries = @(
			$archive.Entries | Where-Object {
				$_.FullName -match '^[^/\\]+[/\\]addon\.xml$'
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

    $id = $addonXml.addon.id
    $version = $addonXml.addon.version

    Write-Host "Adding $id $version"

    $xmlParts += $addonXml.addon.OuterXml
}

$addonsXmlPath = Join-Path $Root "addons.xml"
$md5Path = Join-Path $Root "addons.xml.md5"

$builder = New-Object System.Text.StringBuilder

[void]$builder.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$builder.AppendLine('<addons>')

foreach ($part in $xmlParts) {
    [void]$builder.AppendLine($part)
}

[void]$builder.AppendLine('</addons>')

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