[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ArchiveFile,
    [Parameter(Mandatory)][string] $RelativeArchive,
    [Parameter(Mandatory)][string] $DestinationPath,
    [Parameter(Mandatory)][string] $WorkRoot,
    [Parameter(Mandatory)][string[]] $Extensions,
    [Parameter(Mandatory)][ValidateRange(0, 100)][int] $MaxNestedDepth
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:imageCount = 0L
$script:imageBytes = 0L
$script:stageRoot = $null
$script:nestedTempRoot = $null
$pathComparison = [System.StringComparison]::OrdinalIgnoreCase
$pathComparer = [System.StringComparer]::OrdinalIgnoreCase
$imageExtensions = [System.Collections.Generic.HashSet[string]]::new($Extensions, $pathComparer)
$writtenFiles = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
$knownDirectories = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
$invalidFileNameChars = [System.IO.Path]::GetInvalidFileNameChars()

function Test-WithinPath {
    param(
        [Parameter(Mandatory)][string] $Candidate,
        [Parameter(Mandatory)][string] $Root
    )

    if ($Candidate.Equals($Root, $pathComparison)) {
        return $true
    }
    $prefix = $Root.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    return $Candidate.StartsWith($prefix, $pathComparison)
}

function Assert-ValidPathSegment {
    param([Parameter(Mandatory)][string] $Segment)

    if ([string]::IsNullOrWhiteSpace($Segment) -or $Segment -eq '.' -or $Segment -eq '..') {
        throw "Archive entry contains an invalid path segment: '$Segment'."
    }
    if ($Segment.IndexOfAny($invalidFileNameChars) -ge 0 -or $Segment.EndsWith('.') -or $Segment.EndsWith(' ')) {
        throw "Archive entry contains an invalid Windows filename: '$Segment'."
    }
    if ($Segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        throw "Archive entry contains a reserved Windows filename: '$Segment'."
    }
}

function Get-SafeOutputPath {
    param(
        [Parameter(Mandatory)][string] $BasePath,
        [Parameter(Mandatory)][string] $EntryPath
    )

    if ([string]::IsNullOrWhiteSpace($EntryPath) -or
        [System.IO.Path]::IsPathRooted($EntryPath) -or
        $EntryPath.StartsWith('/') -or $EntryPath.StartsWith('\') -or
        $EntryPath -match '^[A-Za-z]:') {
        throw "Archive entry has a rooted or empty path: '$EntryPath'."
    }

    $normalized = $EntryPath.Replace('\', '/')
    $segments = @($normalized.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($segments.Count -eq 0) {
        throw "Archive entry has no usable path: '$EntryPath'."
    }
    foreach ($segment in $segments) {
        Assert-ValidPathSegment -Segment $segment
    }

    $relativePath = [string]::Join([System.IO.Path]::DirectorySeparatorChar, $segments)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $BasePath $relativePath))
    if (-not (Test-WithinPath -Candidate $candidate -Root $BasePath)) {
        throw "Archive entry escapes its output directory: '$EntryPath'."
    }
    return $candidate
}

function Register-Directory {
    param([Parameter(Mandatory)][string] $DirectoryPath)

    if (-not (Test-WithinPath -Candidate $DirectoryPath -Root $script:stageRoot)) {
        throw "Directory maps outside the staging root: '$DirectoryPath'."
    }

    $current = $DirectoryPath
    while ($current -and (Test-WithinPath -Candidate $current -Root $script:stageRoot)) {
        if ($writtenFiles.Contains($current)) {
            throw "Archive entries create a file/directory conflict at '$current'."
        }
        [void]$knownDirectories.Add($current)
        if ($current.Equals($script:stageRoot, $pathComparison)) {
            break
        }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
}

function Register-File {
    param([Parameter(Mandatory)][string] $FilePath)

    if (-not (Test-WithinPath -Candidate $FilePath -Root $script:stageRoot)) {
        throw "File maps outside the staging root: '$FilePath'."
    }
    if ($knownDirectories.Contains($FilePath)) {
        throw "Archive entries create a file/directory conflict at '$FilePath'."
    }
    if (-not $writtenFiles.Add($FilePath)) {
        throw "Archive contains duplicate image output '$FilePath'."
    }
    Register-Directory -DirectoryPath ([System.IO.Path]::GetDirectoryName($FilePath))
}

function Copy-ZipEntryToFile {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchiveEntry] $Entry,
        [Parameter(Mandatory)][string] $TargetPath
    )

    $source = $null
    $target = $null
    try {
        $source = $Entry.Open()
        $target = [System.IO.File]::Open(
            $TargetPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $source.CopyTo($target)
    }
    finally {
        if ($null -ne $target) { $target.Dispose() }
        if ($null -ne $source) { $source.Dispose() }
    }
}

function Expand-ImageZip {
    param(
        [Parameter(Mandatory)][string] $ZipPath,
        [Parameter(Mandatory)][string] $OutputBase,
        [Parameter(Mandatory)][int] $Depth
    )

    $fileStream = $null
    $zipArchive = $null
    try {
        $fileStream = [System.IO.File]::Open(
            $ZipPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $zipArchive = [System.IO.Compression.ZipArchive]::new(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false
        )

        foreach ($entry in $zipArchive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name) -or $entry.FullName.EndsWith('/')) {
                continue
            }

            $extension = [System.IO.Path]::GetExtension($entry.FullName)
            if ($extension -ieq '.zip') {
                if ($Depth -ge $MaxNestedDepth) {
                    throw "Nested ZIP depth exceeds the configured maximum of $MaxNestedDepth at '$($entry.FullName)'."
                }

                $nestedRelativePath = $entry.FullName.Substring(
                    0,
                    $entry.FullName.Length - $extension.Length
                )
                $nestedOutputBase = Get-SafeOutputPath -BasePath $OutputBase -EntryPath $nestedRelativePath
                Register-Directory -DirectoryPath $nestedOutputBase
                [void][System.IO.Directory]::CreateDirectory($nestedOutputBase)

                $nestedTempPath = Join-Path $script:nestedTempRoot ("{0}.zip" -f [System.Guid]::NewGuid().ToString('N'))
                try {
                    Copy-ZipEntryToFile -Entry $entry -TargetPath $nestedTempPath
                    Expand-ImageZip -ZipPath $nestedTempPath -OutputBase $nestedOutputBase -Depth ($Depth + 1)
                }
                finally {
                    if ([System.IO.File]::Exists($nestedTempPath)) {
                        [System.IO.File]::Delete($nestedTempPath)
                    }
                }
                continue
            }

            if (-not $imageExtensions.Contains($extension)) {
                continue
            }

            $targetPath = Get-SafeOutputPath -BasePath $OutputBase -EntryPath $entry.FullName
            Register-File -FilePath $targetPath
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($targetPath))
            Copy-ZipEntryToFile -Entry $entry -TargetPath $targetPath
            $script:imageCount++
            $script:imageBytes += $entry.Length
        }
    }
    finally {
        if ($null -ne $zipArchive) { $zipArchive.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
    }
}

$jobRoot = Join-Path $WorkRoot ([System.Guid]::NewGuid().ToString('N'))
$script:stageRoot = Join-Path $jobRoot 'output'
$script:nestedTempRoot = Join-Path $jobRoot 'nested'
$previousPath = Join-Path $jobRoot 'previous'
$previousMoved = $false

try {
    [void][System.IO.Directory]::CreateDirectory($script:stageRoot)
    [void][System.IO.Directory]::CreateDirectory($script:nestedTempRoot)
    Register-Directory -DirectoryPath $script:stageRoot

    Expand-ImageZip -ZipPath $ArchiveFile -OutputBase $script:stageRoot -Depth 0

    $destinationParent = [System.IO.Path]::GetDirectoryName($DestinationPath)
    [void][System.IO.Directory]::CreateDirectory($destinationParent)

    if ([System.IO.File]::Exists($DestinationPath)) {
        throw "Destination is occupied by a file: '$DestinationPath'."
    }
    if ([System.IO.Directory]::Exists($DestinationPath)) {
        [System.IO.Directory]::Move($DestinationPath, $previousPath)
        $previousMoved = $true
    }

    try {
        [System.IO.Directory]::Move($script:stageRoot, $DestinationPath)
    }
    catch {
        if ($previousMoved -and -not [System.IO.Directory]::Exists($DestinationPath)) {
            [System.IO.Directory]::Move($previousPath, $DestinationPath)
            $previousMoved = $false
        }
        throw
    }

    [pscustomobject]@{
        RelativeArchive = $RelativeArchive
        Success         = $true
        ImageCount      = $script:imageCount
        ImageBytes      = $script:imageBytes
        ErrorMessage    = $null
    }
}
catch {
    [pscustomobject]@{
        RelativeArchive = $RelativeArchive
        Success         = $false
        ImageCount      = 0L
        ImageBytes      = 0L
        ErrorMessage    = $_.Exception.Message
    }
}
finally {
    if ([System.IO.Directory]::Exists($jobRoot)) {
        try {
            Remove-Item -LiteralPath $jobRoot -Recurse -Force -ErrorAction Stop
        }
        catch {
            # The main process makes a final cleanup attempt after all workers finish.
        }
    }
}
