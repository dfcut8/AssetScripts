# AssetScripts

AssetScripts is a PowerShell module for safely extracting selected image assets
from collections of ZIP files. It exports one cmdlet-style advanced function:
`Expand-ImageArchive`.

## Requirements

- PowerShell 7.0 or later
- Windows, Linux, or macOS

## Import the module

Import the manifest directly from any location:

```powershell
Import-Module C:\Tools\AssetScripts\AssetScripts.psd1
```

For name-based imports, copy the project directory to an `AssetScripts\1.0.0`
directory beneath one of the paths in `$env:PSModulePath`, then run:

```powershell
Import-Module AssetScripts
```

Confirm the exported command and view its full help:

```powershell
Get-Command -Module AssetScripts
Get-Help Expand-ImageArchive -Full
```

## Usage

Both paths are required and may be absolute or relative to the current directory:

```powershell
Expand-ImageArchive `
    -InputPath .\archive `
    -OutputPath .\extracted
```

For example, `archive/Bundle1/2dsprites2.zip` is extracted beneath
`extracted/Bundle1/2dsprites2/`. Paths stored inside the ZIP are preserved. An
embedded ZIP such as `packs/icons.zip` is recursively extracted beneath
`packs/icons/`.

The command returns one `AssetScripts.ImageArchiveExtractionResult` object for
each top-level ZIP. This makes results easy to filter, format, or export:

```powershell
$results = Expand-ImageArchive -InputPath .\archive -OutputPath .\extracted
$results | Where-Object Success
$results | Format-Table RelativePath, Success, ImageCount, ImageBytes
```

Use the standard common parameters to preview changes or display operational
details:

```powershell
Expand-ImageArchive -InputPath .\archive -OutputPath .\extracted -WhatIf
Expand-ImageArchive -InputPath .\archive -OutputPath .\extracted -Verbose
```

### Options

```powershell
Expand-ImageArchive `
    -InputPath .\archive `
    -OutputPath .\extracted `
    -ThrottleLimit 10 `
    -MaxNestedDepth 5 `
    -Extension .png, .jpg, .jpeg
```

- `ThrottleLimit` controls how many disk ZIPs are processed concurrently.
- `MaxNestedDepth` limits embedded ZIP recursion; disk ZIPs are depth zero.
- `Extension` replaces the default image allowlist. Values may include or omit
  the leading period.

The defaults retain PNG, JPG/JPEG, GIF, BMP, WebP, TIFF, TGA, DDS, SVG, HDR,
and EXR files. Matching is case-insensitive. Other entries are ignored, except
embedded ZIP files.

Each disk ZIP is staged independently. A successful extraction replaces that
ZIP's prior destination, removing stale files. If a ZIP is corrupt, encrypted,
unsafe, or otherwise unreadable, its prior destination remains untouched while
other ZIPs continue. Failures produce non-terminating PowerShell errors and
result objects whose `Success` property is `$false`.

The module rejects path traversal, invalid Windows filenames, duplicate outputs,
file/directory conflicts, and ZIP layouts whose destination folders overlap. It
also takes an exclusive lock on the output root so two runs cannot modify it at
the same time.

## Tests

The test suite supports the repository's installed Pester version:

```powershell
Invoke-Pester .\tests\Extract-ImageArchives.Tests.ps1
```
