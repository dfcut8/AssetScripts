function Expand-ImageArchive {
    <#
    .SYNOPSIS
    Extracts image assets from ZIP archives beneath a directory.

    .DESCRIPTION
    Finds ZIP files recursively beneath InputPath and extracts supported image
    files to matching directories beneath OutputPath. Paths stored in each ZIP
    are preserved. Embedded ZIP files are expanded recursively.

    Each top-level ZIP is staged independently. Successful extraction replaces
    that ZIP's existing destination. Failed extraction leaves its previous
    destination unchanged and writes a non-terminating error.

    .PARAMETER InputPath
    The directory to search recursively for ZIP files. Relative paths resolve
    from the caller's current directory.

    .PARAMETER OutputPath
    The directory beneath which extracted image assets are written. The
    directory is created when it does not exist.

    .PARAMETER ThrottleLimit
    The maximum number of top-level ZIP files processed concurrently.

    .PARAMETER MaxNestedDepth
    The maximum number of embedded ZIP levels. Top-level ZIPs are depth zero.

    .PARAMETER Extension
    The image filename extensions to retain. A leading period is optional.

    .EXAMPLE
    Import-Module C:\Tools\AssetScripts\AssetScripts.psd1
    Expand-ImageArchive -InputPath .\archive -OutputPath .\extracted

    Extracts supported image files from ZIP files under .\archive and returns
    one result object for each top-level ZIP.

    .EXAMPLE
    Expand-ImageArchive -InputPath D:\Assets -OutputPath E:\Images -Verbose

    Extracts archives using the default settings and displays progress details.

    .OUTPUTS
    AssetScripts.ImageArchiveExtractionResult

    .NOTES
    Requires PowerShell 7 or later.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('AssetScripts.ImageArchiveExtractionResult')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Alias('ArchivePath')]
        [ValidateNotNullOrEmpty()]
        [string] $InputPath,

        [Parameter(Mandatory, Position = 1)]
        [Alias('ExtractedPath')]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath,

        [Parameter()]
        [ValidateRange(1, 256)]
        [int] $ThrottleLimit = 10,

        [Parameter()]
        [ValidateRange(0, 100)]
        [int] $MaxNestedDepth = 5,

        [Parameter()]
        [Alias('Extensions')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Extension = @(
            '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.tif',
            '.tiff', '.tga', '.dds', '.svg', '.hdr', '.exr'
        )
    )

    $pathComparison = [System.StringComparison]::OrdinalIgnoreCase
    $pathComparer = [System.StringComparer]::OrdinalIgnoreCase
    $reservedNames = @('.image-archive-extractor-work', '.image-archive-extractor.lock')

    function Get-AbsoluteFileSystemPath {
        param(
            [Parameter(Mandatory)]
            [string] $Path
        )

        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw 'InputPath and OutputPath cannot be empty or whitespace.'
        }

        if ([System.IO.Path]::IsPathFullyQualified($Path)) {
            return [System.IO.Path]::GetFullPath($Path)
        }

        return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    }

    function Test-SameOrDescendantPath {
        param(
            [Parameter(Mandatory)]
            [string] $Candidate,

            [Parameter(Mandatory)]
            [string] $Root
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

    $inputRoot = Get-AbsoluteFileSystemPath -Path $InputPath
    $outputRoot = Get-AbsoluteFileSystemPath -Path $OutputPath

    if (-not [System.IO.Directory]::Exists($inputRoot)) {
        throw "Input directory does not exist: $inputRoot"
    }

    if ((Test-SameOrDescendantPath -Candidate $inputRoot -Root $outputRoot) -or
        (Test-SameOrDescendantPath -Candidate $outputRoot -Root $inputRoot)) {
        throw 'InputPath and OutputPath must not be the same directory or contain one another.'
    }

    $normalizedExtensions = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    foreach ($item in $Extension) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            throw 'Extension cannot contain an empty or whitespace value.'
        }

        $normalized = $item.Trim()
        if (-not $normalized.StartsWith('.')) {
            $normalized = ".$normalized"
        }
        if ($normalized.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $normalized.Contains('/') -or $normalized.Contains('\')) {
            throw "Invalid image extension: $item"
        }
        [void] $normalizedExtensions.Add($normalized)
    }

    $archives = @(
        Get-ChildItem -LiteralPath $inputRoot -Recurse -File -ErrorAction Stop |
            Where-Object Extension -IEQ '.zip' |
            Sort-Object FullName
    )

    $destinations = [System.Collections.Generic.Dictionary[string, object]]::new($pathComparer)
    $mappings = [System.Collections.Generic.List[object]]::new()

    foreach ($archive in $archives) {
        $relativeArchive = [System.IO.Path]::GetRelativePath($inputRoot, $archive.FullName)
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

        $destination = [System.IO.Path]::GetFullPath((Join-Path $outputRoot $relativeDestination))
        if (-not (Test-SameOrDescendantPath -Candidate $destination -Root $outputRoot)) {
            throw "Archive maps outside the output directory: $relativeArchive"
        }

        if ($destinations.ContainsKey($destination)) {
            throw "Archives map to the same destination: '$relativeArchive' and '$($destinations[$destination].RelativeArchive)'."
        }

        $mapping = [pscustomobject]@{
            ArchiveFile         = $archive.FullName
            RelativeArchive     = $relativeArchive
            Destination         = $destination
            RelativeDestination = $relativeDestination
        }
        $destinations.Add($destination, $mapping)
        $mappings.Add($mapping)
    }

    foreach ($mapping in $mappings) {
        $parent = [System.IO.Path]::GetDirectoryName($mapping.Destination)
        while ($parent -and -not $parent.Equals($outputRoot, $pathComparison)) {
            if ($destinations.ContainsKey($parent)) {
                throw "Archive destinations overlap: '$($destinations[$parent].RelativeArchive)' contains '$($mapping.RelativeArchive)'."
            }
            $parent = [System.IO.Path]::GetDirectoryName($parent)
        }
    }

    Write-Verbose ("Found {0} archive(s) beneath '{1}'." -f $mappings.Count, $inputRoot)

    $action = 'Extract {0} image archive(s) from {1}' -f $mappings.Count, $inputRoot
    if (-not $PSCmdlet.ShouldProcess($outputRoot, $action)) {
        return
    }

    $lockStream = $null
    $workRoot = Join-Path $outputRoot '.image-archive-extractor-work'
    $results = @()

    try {
        [void] [System.IO.Directory]::CreateDirectory($outputRoot)

        $lockPath = Join-Path $outputRoot '.image-archive-extractor.lock'
        try {
            $lockStream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            throw "Another extractor is already using '$outputRoot'."
        }

        if ([System.IO.File]::Exists($workRoot)) {
            throw "The private work path is occupied by a file: $workRoot"
        }
        if ([System.IO.Directory]::Exists($workRoot)) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
        }
        [void] [System.IO.Directory]::CreateDirectory($workRoot)

        $workerPath = Join-Path $script:ModuleRoot 'src/Invoke-ImageArchiveExtraction.ps1'
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
        $results = $validResults
    }
    finally {
        if ([System.IO.Directory]::Exists($workRoot)) {
            try {
                Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warning ("Could not remove private work directory '{0}': {1}" -f
                    $workRoot, $_.Exception.Message)
            }
        }
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }
    }

    [long] $totalImages = 0
    [long] $totalBytes = 0
    foreach ($result in ($results | Sort-Object RelativeArchive)) {
        $mapping = $mappings |
            Where-Object RelativeArchive -EQ $result.RelativeArchive |
            Select-Object -First 1

        $output = [pscustomobject]@{
            PSTypeName      = 'AssetScripts.ImageArchiveExtractionResult'
            InputPath       = $mapping.ArchiveFile
            RelativePath    = $result.RelativeArchive
            OutputPath      = $mapping.Destination
            Success         = [bool] $result.Success
            ImageCount      = [long] $result.ImageCount
            ImageBytes      = [long] $result.ImageBytes
            ErrorMessage    = $result.ErrorMessage
        }

        if ($result.Success) {
            $totalImages += $result.ImageCount
            $totalBytes += $result.ImageBytes
            Write-Verbose ("Extracted '{0}' ({1} image(s), {2:N0} byte(s))." -f
                $result.RelativeArchive, $result.ImageCount, $result.ImageBytes)
        }

        Write-Output $output

        if (-not $result.Success) {
            $exception = [System.IO.InvalidDataException]::new(
                "Failed to extract '$($result.RelativeArchive)': $($result.ErrorMessage)"
            )
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception,
                'ImageArchiveExtractionFailed',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $mapping.ArchiveFile
            )
            $PSCmdlet.WriteError($errorRecord)
        }
    }

    $successCount = @($results | Where-Object Success).Count
    $failureCount = $results.Count - $successCount
    Write-Information ("Extraction complete: {0} succeeded, {1} failed, {2} image(s), {3:N0} byte(s)." -f
        $successCount, $failureCount, $totalImages, $totalBytes) -Tags 'AssetScripts', 'Summary'
}
