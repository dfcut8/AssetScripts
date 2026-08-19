# AssetScripts

`Extract-ImageArchives.ps1` extracts only selected image assets from ZIP files while preserving a predictable directory layout.

## Usage

Place ZIP files anywhere below `archive/`, then run:

```powershell
pwsh ./Extract-ImageArchives.ps1
```

For example, `archive/Bundle1/2dsprites2.zip` is extracted beneath `extracted/Bundle1/2dsprites2/`. Paths stored inside the ZIP are preserved exactly. An embedded ZIP such as `packs/icons.zip` is recursively extracted beneath `packs/icons/`.

The defaults retain PNG, JPG/JPEG, GIF, BMP, WebP, TIFF, TGA, DDS, SVG, HDR, and EXR files. Matching is case-insensitive. All other entries are ignored, except embedded `.zip` files.

### Options

```powershell
pwsh ./Extract-ImageArchives.ps1 `
    -ArchivePath ./archive `
    -ExtractedPath ./extracted `
    -ThrottleLimit 10 `
    -MaxNestedDepth 5 `
    -Extensions .png,.jpg,.jpeg
```

- `ThrottleLimit` controls the maximum number of disk ZIPs processed concurrently. Nested ZIPs are processed sequentially by their owning worker.
- `MaxNestedDepth` counts embedded ZIP levels; disk ZIPs are depth zero. A ZIP beyond this depth fails and rolls back its owning disk ZIP.
- `Extensions` replaces the default image allowlist. Values may be supplied with or without a leading period.

Each disk ZIP is staged independently. A successful run replaces that ZIP's previous destination folder, removing stale files. If a ZIP is corrupt, encrypted, unsafe, or otherwise unreadable, its prior destination remains untouched while other ZIPs continue. Any failure produces a nonzero process exit code.

The script rejects path traversal, invalid Windows filenames, duplicate outputs, file/directory conflicts, and disk ZIP layouts whose destination folders overlap. It also takes an exclusive lock on the extracted root so two runs cannot modify it simultaneously.

## Tests

The test suite is compatible with the repository's available Pester installation:

```powershell
Invoke-Pester ./tests/Extract-ImageArchives.Tests.ps1
```
