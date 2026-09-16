@{
    PackageName = 'CYOT endpoint deployment'
    PackageVersion = '0.3.0'
    EntryPoint = 'Setup-Cyot.ps1'
    MinimumPowerShellVersion = '7.0'
    Support = @('support/Cyot.Setup.psm1', 'support/Cyot.Packages.ps1')
    Infrastructure = @(
        'infra/main.bicep'
        'infra/resources.bicep'
    )
    ProviderCatalog = 'providers/catalog.json'
    PackageCatalog = 'packages/catalog.json'
    RuntimeDirectories = @('cyot-output')
}
