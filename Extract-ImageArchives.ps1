#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter()]
    [string] $ArchivePath = (Join-Path $PSScriptRoot 'archive'),

    [Parameter()]
    [string] $ExtractedPath = (Join-Path $PSScriptRoot 'extracted'),

    [Parameter()]
    [ValidateRange(1, 256)]
    [int] $ThrottleLimit = 10,

    [Parameter()]
    [ValidateRange(0, 100)]
    [int] $MaxNestedDepth = 5,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]] $Extensions = @(
        '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.tif',
        '.tiff', '.tga', '.dds', '.svg', '.hdr', '.exr'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lockStream = $null
$workRoot = $null
$exitCode = 1
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$pathComparison = [System.StringComparison]::OrdinalIgnoreCase
$pathComparer = [System.StringComparer]::OrdinalIgnoreCase
$reservedNames = @('.image-archive-extractor-work', '.image-archive-extractor.lock')

function Get-AbsolutePath {
    param([Parameter(Mandatory)][string] $Path)

    if ([System.IO.Path]::IsPathFullyQualified($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Test-SameOrDescendantPath {
    param(
        [Parameter(Mandatory)][string] $Candidate,
        [Parameter(Mandatory)][string] $Root
    )

    if ($Candidate.Equals($Root, $pathComparison)) {
        return $true
    }

    $rootWithSeparator = $Root.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    return $Candidate.StartsWith($rootWithSeparator, $pathComparison)
}

try {
    $archiveRoot = Get-AbsolutePath -Path $ArchivePath
    $extractedRoot = Get-AbsolutePath -Path $ExtractedPath

    if (-not [System.IO.Directory]::Exists($archiveRoot)) {
        throw "Archive directory does not exist: $archiveRoot"
    }

    if ((Test-SameOrDescendantPath -Candidate $archiveRoot -Root $extractedRoot) -or
        (Test-SameOrDescendantPath -Candidate $extractedRoot -Root $archiveRoot)) {
        throw 'ArchivePath and ExtractedPath must not be the same directory or contain one another.'
    }

    [void][System.IO.Directory]::CreateDirectory($extractedRoot)

    $lockPath = Join-Path $extractedRoot '.image-archive-extractor.lock'
    try {
        $lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        throw "Another extractor is already using '$extractedRoot'."
    }

    $normalizedExtensions = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($extension in $Extensions) {
        $normalized = $extension.Trim()
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            throw 'Extensions cannot contain an empty value.'
        }
        if (-not $normalized.StartsWith('.')) {
            $normalized = ".$normalized"
        }
        if ($normalized.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $normalized.Contains('/') -or $normalized.Contains('\')) {
            throw "Invalid image extension: $extension"
        }
        [void]$normalizedExtensions.Add($normalized)
    }

    $workRoot = Join-Path $extractedRoot '.image-archive-extractor-work'
    if ([System.IO.File]::Exists($workRoot)) {
        throw "The private work path is occupied by a file: $workRoot"
    }
    if ([System.IO.Directory]::Exists($workRoot)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
    [void][System.IO.Directory]::CreateDirectory($workRoot)

    $archives = @(
        Get-ChildItem -LiteralPath $archiveRoot -Recurse -File |
            Where-Object { $_.Extension -ieq '.zip' } |
            Sort-Object FullName
    )

    $destinations = [System.Collections.Generic.Dictionary[string, object]]::new($pathComparer)
    $mappings = [System.Collections.Generic.List[object]]::new()

    foreach ($archive in $archives) {
        $relativeArchive = [System.IO.Path]::GetRelativePath($archiveRoot, $archive.FullName)
        $relativeDestination = $relativeArchive.Substring(
            0,
            $relativeArchive.Length - $archive.Extension.Length
        )
        if ([string]::IsNullOrWhiteSpace($relativeDestination)) {
            throw "Archive has no usable destination name: $relativeArchive"
        }

        $firstSegment = ($relativeDestination -split '[\\/]', 2)[0]
        if ($reservedNames -icontains $firstSegment) {
            throw "Archive destination uses a reserved extractor path: $relativeArchive"
        }

        $destination = [System.IO.Path]::GetFullPath((Join-Path $extractedRoot $relativeDestination))
        if (-not (Test-SameOrDescendantPath -Candidate $destination -Root $extractedRoot) -or
            $destination.Equals($extractedRoot, $pathComparison)) {
            throw "Archive maps outside the extracted directory: $relativeArchive"
        }

        if ($destinations.ContainsKey($destination)) {
            throw "Archives map to the same destination: '$relativeArchive' and '$($destinations[$destination].RelativeArchive)'."
        }

        $mapping = [pscustomobject]@{
            ArchiveFile        = $archive.FullName
            RelativeArchive    = $relativeArchive
            Destination        = $destination
            RelativeDestination = $relativeDestination
        }
        $destinations.Add($destination, $mapping)
        $mappings.Add($mapping)
    }

    foreach ($mapping in $mappings) {
        $parent = [System.IO.Path]::GetDirectoryName($mapping.Destination)
        while ($parent -and -not $parent.Equals($extractedRoot, $pathComparison)) {
            if ($destinations.ContainsKey($parent)) {
                throw "Archive destinations overlap: '$($destinations[$parent].RelativeArchive)' contains '$($mapping.RelativeArchive)'."
            }
            $parent = [System.IO.Path]::GetDirectoryName($parent)
        }
    }

    Write-Host ("Found {0} archive(s). Processing with up to {1} worker(s)." -f $mappings.Count, $ThrottleLimit)

    $workerPath = Join-Path $PSScriptRoot 'src/Invoke-ImageArchiveExtraction.ps1'
    if (-not [System.IO.File]::Exists($workerPath)) {
        throw "Extractor worker is missing: $workerPath"
    }

    $extensionArray = @($normalizedExtensions)
    $results = @(
        $mappings | ForEach-Object -Parallel {
            & $using:workerPath `
                -ArchiveFile $_.ArchiveFile `
                -RelativeArchive $_.RelativeArchive `
                -DestinationPath $_.Destination `
                -WorkRoot $using:workRoot `
                -Extensions $using:extensionArray `
                -MaxNestedDepth $using:MaxNestedDepth
        } -ThrottleLimit $ThrottleLimit
    )

    $validResults = @($results | Where-Object {
        $_ -is [psobject] -and $_.PSObject.Properties.Name -contains 'Success'
    })
    if ($validResults.Count -ne $mappings.Count) {
        throw "Worker pool returned $($validResults.Count) result(s) for $($mappings.Count) archive(s)."
    }

    $successes = @($validResults | Where-Object Success)
    $failures = @($validResults | Where-Object { -not $_.Success })

    foreach ($result in ($validResults | Sort-Object RelativeArchive)) {
        if ($result.Success) {
            Write-Host ("[OK] {0}: {1} image(s), {2:N0} byte(s)" -f
                $result.RelativeArchive, $result.ImageCount, $result.ImageBytes)
        }
        else {
            Write-Host ("[FAILED] {0}: {1}" -f $result.RelativeArchive, $result.ErrorMessage) -ForegroundColor Red
        }
    }

    [long]$totalImages = 0
    [long]$totalBytes = 0
    foreach ($success in $successes) {
        $totalImages += $success.ImageCount
        $totalBytes += $success.ImageBytes
    }

    $stopwatch.Stop()
    Write-Host ("Summary: {0} succeeded, {1} failed, {2} image(s), {3:N0} byte(s), {4:N2}s elapsed." -f
        $successes.Count, $failures.Count, $totalImages, $totalBytes, $stopwatch.Elapsed.TotalSeconds)

    $exitCode = if ($failures.Count -eq 0) { 0 } else { 1 }
}
catch {
    $stopwatch.Stop()
    Write-Host ("Extractor failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $exitCode = 1
}
finally {
    if ($workRoot -and [System.IO.Directory]::Exists($workRoot)) {
        try {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Host ("Warning: could not remove private work directory '{0}': {1}" -f
                $workRoot, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}

exit $exitCode
