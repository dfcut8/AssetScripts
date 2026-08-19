$scriptUnderTest = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extract-ImageArchives.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function New-TestZip {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][object] $Entries
    )

    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    $zip = [System.IO.Compression.ZipArchive]::new(
        $stream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    try {
        $entryItems = if ($Entries -is [System.Collections.IDictionary]) {
            @($Entries.Keys | ForEach-Object {
                [pscustomobject]@{ Name = $_; Value = $Entries[$_] }
            })
        }
        else {
            @($Entries)
        }

        foreach ($item in $entryItems) {
            $name = $item.Name
            $entry = $zip.CreateEntry($name)
            $entryStream = $entry.Open()
            try {
                $value = $item.Value
                $bytes = if ($value -is [byte[]]) {
                    $value
                }
                else {
                    [System.Text.Encoding]::UTF8.GetBytes([string]$value)
                }
                $entryStream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $zip.Dispose()
        $stream.Dispose()
    }
}

function Invoke-Extractor {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $ExtractedPath,
        [int] $ThrottleLimit = 2,
        [int] $MaxNestedDepth = 5
    )

    $output = & $pwsh -NoLogo -NoProfile -File $scriptUnderTest `
        -ArchivePath $ArchivePath `
        -ExtractedPath $ExtractedPath `
        -ThrottleLimit $ThrottleLimit `
        -MaxNestedDepth $MaxNestedDepth 2>&1 | Out-String

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

Describe 'Extract-ImageArchives.ps1' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($caseRoot)
    }

    It 'mirrors disk paths, preserves ZIP paths, and keeps all default image formats case-insensitively' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        $zipPath = Join-Path $archive 'Bundle1/2dsprites2.zip'
        $entries = @{
            '2dsprites2/a.PNG'  = 'png'
            '2dsprites2/b.jpg'  = 'jpg'
            '2dsprites2/c.JPEG' = 'jpeg'
            '2dsprites2/d.gif'  = 'gif'
            '2dsprites2/e.bmp'  = 'bmp'
            '2dsprites2/f.webp' = 'webp'
            '2dsprites2/g.tif'  = 'tif'
            '2dsprites2/h.tiff' = 'tiff'
            '2dsprites2/i.tga'  = 'tga'
            '2dsprites2/j.dds'  = 'dds'
            '2dsprites2/k.svg'  = 'svg'
            '2dsprites2/l.hdr'  = 'hdr'
            '2dsprites2/m.exr'  = 'exr'
            '2dsprites2/no.txt' = 'ignored'
        }
        New-TestZip -Path $zipPath -Entries $entries

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted

        $result.ExitCode | Should Be 0
        (Get-ChildItem -LiteralPath (Join-Path $extracted 'Bundle1/2dsprites2') -Recurse -File).Count | Should Be 13
        (Test-Path -LiteralPath (Join-Path $extracted 'Bundle1/2dsprites2/2dsprites2/a.PNG')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $extracted 'Bundle1/2dsprites2/2dsprites2/no.txt')) | Should Be $false
    }

    It 'extracts embedded ZIPs through five levels into archive-named folders' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        $nestedPath = Join-Path $caseRoot 'level5.zip'
        New-TestZip -Path $nestedPath -Entries @{ 'sprite.png' = 'deep' }

        for ($level = 4; $level -ge 1; $level--) {
            $nextPath = Join-Path $caseRoot ("level$level.zip")
            New-TestZip -Path $nextPath -Entries @{
                ("level{0}.zip" -f ($level + 1)) = [System.IO.File]::ReadAllBytes($nestedPath)
            }
            $nestedPath = $nextPath
        }
        New-TestZip -Path (Join-Path $archive 'outer.zip') -Entries @{
            'level1.zip' = [System.IO.File]::ReadAllBytes($nestedPath)
        }

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted

        $result.ExitCode | Should Be 0
        $expected = Join-Path $extracted 'outer/level1/level2/level3/level4/level5/sprite.png'
        (Get-Content -LiteralPath $expected -Raw) | Should Be 'deep'
    }

    It 'rolls back an archive that exceeds nested depth' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        $destination = Join-Path $extracted 'outer'
        [void][System.IO.Directory]::CreateDirectory($destination)
        Set-Content -LiteralPath (Join-Path $destination 'old.png') -Value 'old' -NoNewline

        $nestedPath = Join-Path $caseRoot 'level6.zip'
        New-TestZip -Path $nestedPath -Entries @{ 'sprite.png' = 'too deep' }
        for ($level = 5; $level -ge 1; $level--) {
            $nextPath = Join-Path $caseRoot ("level$level.zip")
            New-TestZip -Path $nextPath -Entries @{
                ("level{0}.zip" -f ($level + 1)) = [System.IO.File]::ReadAllBytes($nestedPath)
            }
            $nestedPath = $nextPath
        }
        New-TestZip -Path (Join-Path $archive 'outer.zip') -Entries @{
            'level1.zip' = [System.IO.File]::ReadAllBytes($nestedPath)
        }

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted

        $result.ExitCode | Should Be 1
        (Get-Content -LiteralPath (Join-Path $destination 'old.png') -Raw) | Should Be 'old'
        $result.Output | Should Match 'depth exceeds'
    }

    It 'replaces successful output, preserves failed output, and continues other archives' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $extracted 'good'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $extracted 'bad'))
        Set-Content -LiteralPath (Join-Path $extracted 'good/stale.png') -Value 'stale'
        Set-Content -LiteralPath (Join-Path $extracted 'bad/old.png') -Value 'old' -NoNewline
        New-TestZip -Path (Join-Path $archive 'good.zip') -Entries @{ 'new.png' = 'new' }
        [void][System.IO.Directory]::CreateDirectory($archive)
        [System.IO.File]::WriteAllText((Join-Path $archive 'bad.zip'), 'not a zip')

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted

        $result.ExitCode | Should Be 1
        (Test-Path -LiteralPath (Join-Path $extracted 'good/stale.png')) | Should Be $false
        (Get-Content -LiteralPath (Join-Path $extracted 'good/new.png') -Raw) | Should Be 'new'
        (Get-Content -LiteralPath (Join-Path $extracted 'bad/old.png') -Raw) | Should Be 'old'
    }

    It 'rejects traversal and duplicate output names' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        New-TestZip -Path (Join-Path $archive 'traversal.zip') -Entries @{ '../escape.png' = 'escape' }
        New-TestZip -Path (Join-Path $archive 'duplicate.zip') -Entries @(
            [pscustomobject]@{ Name = 'same.png'; Value = 'one' }
            [pscustomobject]@{ Name = 'SAME.PNG'; Value = 'two' }
        )

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted

        $result.ExitCode | Should Be 1
        (Test-Path -LiteralPath (Join-Path $extracted 'traversal')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $caseRoot 'escape.png')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $extracted 'duplicate')) | Should Be $false
    }

    It 'rejects rooted paths and file/directory conflicts' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        New-TestZip -Path (Join-Path $archive 'rooted.zip') -Entries @{ 'C:/escape.png' = 'escape' }
        New-TestZip -Path (Join-Path $archive 'conflict.zip') -Entries @{
            'folder.png'           = 'file'
            'folder.png/child.jpg' = 'child'
        }

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted

        $result.ExitCode | Should Be 1
        (Test-Path -LiteralPath (Join-Path $extracted 'rooted')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $extracted 'conflict')) | Should Be $false
    }

    It 'rejects overlapping disk archive destinations before extracting' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        New-TestZip -Path (Join-Path $archive 'foo.zip') -Entries @{ 'a.png' = 'a' }
        New-TestZip -Path (Join-Path $archive 'foo/bar.zip') -Entries @{ 'b.png' = 'b' }

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'destinations overlap'
        (Test-Path -LiteralPath (Join-Path $extracted 'foo')) | Should Be $false
    }

    It 'creates empty destinations for archives without images and handles multiple workers' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        New-TestZip -Path (Join-Path $archive 'a.zip') -Entries @{ 'readme.txt' = 'a' }
        New-TestZip -Path (Join-Path $archive 'b.zip') -Entries @{ 'data.bin' = 'b' }

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted -ThrottleLimit 10

        $result.ExitCode | Should Be 0
        (Test-Path -LiteralPath (Join-Path $extracted 'a') -PathType Container) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $extracted 'b') -PathType Container) | Should Be $true
        (Get-ChildItem -LiteralPath (Join-Path $extracted 'a')).Count | Should Be 0
        (Get-ChildItem -LiteralPath (Join-Path $extracted 'b')).Count | Should Be 0
    }

    It 'succeeds when the archive directory contains no ZIP files' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        [void][System.IO.Directory]::CreateDirectory($archive)
        Set-Content -LiteralPath (Join-Path $archive 'readme.txt') -Value 'ignored'

        $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'Found 0 archive'
        (Test-Path -LiteralPath $extracted -PathType Container) | Should Be $true
    }

    It 'refuses to run while another process holds the extracted-root lock' {
        $archive = Join-Path $caseRoot 'archive'
        $extracted = Join-Path $caseRoot 'extracted'
        [void][System.IO.Directory]::CreateDirectory($archive)
        [void][System.IO.Directory]::CreateDirectory($extracted)
        $lockPath = Join-Path $extracted '.image-archive-extractor.lock'
        $lock = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $result = Invoke-Extractor -ArchivePath $archive -ExtractedPath $extracted
        }
        finally {
            $lock.Dispose()
        }

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'already using'
    }
}
