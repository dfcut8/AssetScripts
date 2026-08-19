#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'src/Expand-ImageArchive.ps1')

Export-ModuleMember -Function 'Expand-ImageArchive'
