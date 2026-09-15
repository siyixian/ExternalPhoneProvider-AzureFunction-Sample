#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string] $ModulePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path ([IO.Path]::GetTempPath()) "cyot-module-lifecycle-$([Guid]::NewGuid().ToString('N'))"
$originalModulePath = $env:PSModulePath

try {
    $authentication = Join-Path $root 'Microsoft.Graph.Authentication'
    $applications = Join-Path $root 'Microsoft.Graph.Applications'
    New-Item -ItemType Directory -Path $authentication, $applications -Force | Out-Null
    @'
$script:TestSession = [Guid]::NewGuid().ToString()
function Get-CyotGraphTestSession { $script:TestSession }
Export-ModuleMember -Function Get-CyotGraphTestSession
'@ | Set-Content -LiteralPath (Join-Path $authentication 'Microsoft.Graph.Authentication.psm1') -Encoding utf8NoBOM
    @'
function Invoke-CyotGraphTestOperation { Get-CyotGraphTestSession }
Export-ModuleMember -Function Invoke-CyotGraphTestOperation
'@ | Set-Content -LiteralPath (Join-Path $applications 'Microsoft.Graph.Applications.psm1') -Encoding utf8NoBOM
    New-ModuleManifest -Path (Join-Path $authentication 'Microsoft.Graph.Authentication.psd1') `
        -RootModule 'Microsoft.Graph.Authentication.psm1' -ModuleVersion '1.0.0' `
        -FunctionsToExport 'Get-CyotGraphTestSession' -CmdletsToExport @() -AliasesToExport @() -VariablesToExport @()
    New-ModuleManifest -Path (Join-Path $applications 'Microsoft.Graph.Applications.psd1') `
        -RootModule 'Microsoft.Graph.Applications.psm1' -ModuleVersion '1.0.0' `
        -RequiredModules @(@{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '1.0.0' }) `
        -FunctionsToExport 'Invoke-CyotGraphTestOperation' -CmdletsToExport @() -AliasesToExport @() -VariablesToExport @()

    # This script runs in its own pwsh process; real Graph modules cannot be resolved.
    $env:PSModulePath = $root + [IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
    $session = $null
    foreach ($run in 1..2) {
        $cyot = Import-Module -Name $ModulePath -PassThru -Force
        & $cyot {
            Import-CyotGraphModules
            Invoke-CyotGraphTestOperation | Out-Null
        }
        $auth = Get-Module Microsoft.Graph.Authentication
        $apps = Get-Module Microsoft.Graph.Applications
        if (-not $auth -or -not $apps -or
            -not $auth.Path.StartsWith($authentication) -or -not $apps.Path.StartsWith($applications)) {
            throw 'The lifecycle test did not load its isolated fake Graph modules.'
        }
        $current = Get-CyotGraphTestSession
        if ($session -and $current -ne $session) { throw 'Importing the helper again reset the Graph session.' }
        $session = $current
        Remove-Module -ModuleInfo $cyot -ErrorAction Stop
        if (-not (Get-Module Microsoft.Graph.Authentication) -or -not (Get-Module Microsoft.Graph.Applications)) {
            throw 'Unloading the CYOT helper removed a session-owned Graph module.'
        }
        if ((Invoke-CyotGraphTestOperation) -ne $session) {
            throw 'The Graph dependency or session stopped working after helper cleanup.'
        }
    }
    'Graph modules and session survived both helper unloads.'
}
finally {
    $env:PSModulePath = $originalModulePath
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
