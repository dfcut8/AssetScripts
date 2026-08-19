@{
    RootModule        = 'AssetScripts.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'e2e79f08-e5de-45a5-afcf-1f7ef523e06a'
    Author            = 'AssetScripts contributors'
    CompanyName       = 'Community'
    Copyright         = '(c) 2026 AssetScripts contributors. All rights reserved.'
    Description       = 'Safely extracts image assets from collections of ZIP archives.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')

    FunctionsToExport = @('Expand-ImageArchive')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Archive', 'Image', 'Extraction', 'Zip')
            ProjectUri = 'https://github.com/dfcut8/AssetScripts'
        }
    }
}
