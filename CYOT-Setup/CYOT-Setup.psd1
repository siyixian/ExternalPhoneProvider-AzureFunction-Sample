@{
    PackageName = 'CYOT endpoint deployment'
    PackageVersion = '0.2.0'
    EntryPoint = 'Setup-Cyot.ps1'
    MinimumPowerShellVersion = '7.0'
    Support = @('support/Cyot.Setup.psm1')
    Infrastructure = @(
        'infra/main.bicep'
        'infra/resources.bicep'
    )
    ProviderCatalog = 'providers/catalog.json'
    RuntimeDirectories = @('cyot-output')
}
