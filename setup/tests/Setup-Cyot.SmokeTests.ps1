#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$packageRoot = Split-Path -Parent $PSScriptRoot
$entryPoint = Join-Path $packageRoot 'Setup-Cyot.ps1'
$modulePath = Join-Path $packageRoot 'support/Cyot.Setup.psm1'
$packageHelperPath = Join-Path $packageRoot 'support/Cyot.Packages.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "cyot-tests-$([Guid]::NewGuid().ToString('N'))"
$source = 'https://raw.githubusercontent.com/siyixian/ExternalPhoneProvider-AzureFunction-Sample/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/setup'
$failures = [Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    $message = $null
    try { & $Action | Out-Null }
    catch { $message = $_.Exception.Message }
    Assert-True ($null -ne $message -and $message -match $Pattern) "Expected error matching '$Pattern'; got '$message'."
}

function Test-Case {
    param([string] $Name, [scriptblock] $Action)
    try {
        & $Action
        $script:passed++
        Write-Host "PASS: $Name" -ForegroundColor Green
    }
    catch {
        $failures.Add("${Name}: $($_.Exception.Message)`n$($_.ScriptStackTrace)")
        Write-Host "FAIL: $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-ValidProfile {
    $profile = Get-Content (Join-Path $packageRoot 'providers/telesign.json') -Raw | ConvertFrom-Json -AsHashtable
    $profile.deployment.enabled = $true
    $profile.deployment.testConfiguration = $false
    foreach ($channel in @('sms', 'voice')) {
        foreach ($region in @('global', 'eu')) {
            $profile.deployment.routes[$channel][$region].endpoint = "https://provider.contoso.com/$channel/$region"
        }
    }
    return $profile
}

function New-ArchiveFixture {
    param([string] $Path, [string[]] $Entries, [hashtable] $Contents = @{})

    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries) {
            $writer = [IO.StreamWriter]::new($archive.CreateEntry($name).Open())
            try { $writer.Write($(if ($Contents.ContainsKey($name)) { $Contents[$name] } else { '{}' })) }
            finally { $writer.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Invoke-LauncherFixture {
    param(
        [string] $Fault, [string] $SourceRef = 'main',
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample'
    )

    $directory = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    Copy-Item -LiteralPath $entryPoint -Destination (Join-Path $directory 'Setup-Cyot.ps1')
    $scenario = [pscustomobject]@{
        Fault = $Fault; SourceRef = $SourceRef; SourceRepository = $SourceRepository; ApiCalls = 0; ApiUri = $null
        Downloads = [Collections.Generic.List[object]]::new()
        Directory = $directory; Result = $null; Error = $null
    }
    & {
        param($scenario)
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $scenario.ApiCalls++
            $scenario.ApiUri = $Uri
            if ($scenario.Fault -eq 'commit') { return @{ sha = 'not-a-commit' } }
            return @{ sha = ('a' * 40) }
        }
        function Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec, $MaximumRedirection)
            $scenario.Downloads.Add([pscustomobject]@{ Uri = $Uri; Path = $OutFile })
            if ($scenario.Fault -eq 'download' -and $scenario.Downloads.Count -eq 2) { throw 'Simulated download failure.' }
            if ($Uri.EndsWith('Cyot.Setup.psm1')) {
                $content = @'
function Invoke-CyotSetup {
    param($AssetDirectory, $SourceBaseUri, $SourceRepository, $TenantId, $ResourcePrefix, $OutputDirectory)
    [pscustomobject]@{ Invoked = $true; Source = $SourceBaseUri; Repository = $SourceRepository; Tenant = $TenantId; Prefix = $ResourcePrefix }
}
Export-ModuleMember -Function Invoke-CyotSetup
'@
                if ($scenario.Fault -eq 'operation-and-cleanup') {
                    $content = $content.Replace('[pscustomobject]@{ Invoked', "throw 'Simulated primary setup failure.'; [pscustomobject]@{ Invoked")
                }
                $content | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM
            }
            elseif ($scenario.Fault -eq 'empty') { [IO.File]::WriteAllText($OutFile, '') }
            else { '{}' | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM }
        }
        function Remove-Module {
            param($ModuleInfo, $ErrorAction)
            if ($scenario.Fault -in @('cleanup', 'operation-and-cleanup')) { throw 'Simulated helper cleanup failure.' }
            Microsoft.PowerShell.Core\Remove-Module -ModuleInfo $ModuleInfo -ErrorAction Stop
        }
        Push-Location $scenario.Directory
        try {
            $scenario.Result = & (Join-Path $scenario.Directory 'Setup-Cyot.ps1') -SourceRef $scenario.SourceRef `
                -SourceRepository $scenario.SourceRepository -TenantId '11111111-1111-1111-1111-111111111111' -ResourcePrefix contoso
        }
        catch { $scenario.Error = $_.Exception.Message }
        finally {
            Pop-Location
            $paths = @($scenario.Downloads | ForEach-Object Path)
            $remaining = @(Get-Module -All | Where-Object { $paths -contains $_.Path })
            if ($remaining.Count) { Microsoft.PowerShell.Core\Remove-Module -ModuleInfo $remaining -ErrorAction Stop }
        }
    } $scenario
    return $scenario
}

function Invoke-FlowFixture {
    param(
        [string[]] $Answers = @('Yes'),
        [hashtable] $Overrides = @{},
        [string[]] $Omit = @(),
        [string] $Fault,
        [string] $ProfileJson = ((New-ValidProfile) | ConvertTo-Json -Depth 15)
    )

    $directory = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $directory 'providers') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $directory 'packages') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $packageRoot 'providers/catalog.json') -Destination (Join-Path $directory 'providers/catalog.json')
    Copy-Item -LiteralPath (Join-Path $packageRoot 'packages/catalog.json') -Destination (Join-Path $directory 'packages/catalog.json')
    $inputs = @{
        TenantId = '11111111-1111-1111-1111-111111111111'
        SubscriptionId = '22222222-2222-2222-2222-222222222222'
        ApplicationId = '33333333-3333-3333-3333-333333333333'
        Location = 'westus2'; Provider = 'telesign'; Channel = 'sms'; EndpointRegion = 'global'
        ProviderAccountName = 'test-sender'; ResourcePrefix = 'contoso'
        Language = 'javascript'
        OutputDirectory = Join-Path $directory 'output'; AssetDirectory = $directory; SourceBaseUri = $source
        SourceRepository = 'siyixian/ExternalPhoneProvider-AzureFunction-Sample'
    }
    foreach ($name in $Omit) { $inputs.Remove($name) }
    foreach ($name in $Overrides.Keys) { $inputs[$name] = $Overrides[$name] }
    $scenario = [pscustomobject]@{
        Inputs = $inputs; Fault = $Fault; ProfileJson = $ProfileJson; Directory = $directory
        Answers = [Collections.Generic.Queue[string]]::new()
        Trace = [Collections.Generic.List[string]]::new()
        Parameters = $null; Context = $null; ResolvedInputs = $null; Result = $null; Error = $null; Text = ''; SyncAttempts = 0
        Access = 'Disabled'; WrittenSettings = $null; Federation = $null
        ProviderRegistrations = [Collections.Generic.List[string]]::new()
        DeploymentNames = [Collections.Generic.List[string]]::new()
        PremiumChecks = 0
        Certificate = $script:testCertificate
    }
    foreach ($answer in $Answers) { $scenario.Answers.Enqueue($answer) }
    $module = Import-Module $modulePath -Force -PassThru
    $records = [Collections.Generic.List[object]]::new()
    try {
        & $module {
            param($scenario)
            $script:Fixture = $scenario
            function script:Read-Host {
                param([string] $Prompt)
                $script:Fixture.Trace.Add("prompt:$Prompt")
                if (-not $script:Fixture.Answers.Count) { throw "Unexpected prompt: $Prompt" }
                return $script:Fixture.Answers.Dequeue()
            }
            function script:Invoke-WebRequest {
                param($Uri, $OutFile, $TimeoutSec, $MaximumRedirection)
                $script:Fixture.Trace.Add("download:$Uri")
                if ($script:Fixture.Fault -eq 'profile-download') { throw 'Simulated provider download failure.' }
                $script:Fixture.ProfileJson | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM
            }
            function script:Get-FixtureProviderState {
                param([string] $Namespace)
                if ($Namespace -eq 'Microsoft.Web') {
                    if ($script:Fixture.Fault -eq 'provider-unregistering') { return 'Unregistering' }
                    if ($script:Fixture.Fault -eq 'provider-registering') { return 'Registering' }
                    if ($script:Fixture.Fault -in @('provider-missing', 'provider-denied', 'provider-stuck')) {
                        if ($script:Fixture.Fault -ne 'provider-stuck' -and $script:Fixture.ProviderRegistrations.Contains($Namespace)) {
                            return 'Registering'
                        }
                        return 'NotRegistered'
                    }
                }
                return 'Registered'
            }
            function script:Connect-CyotContext {
                param($Inputs, $Names, [switch] $NonInteractive)
                $script:Fixture.Trace.Add('preflight')
                if ($script:Fixture.Fault -eq 'preflight') { throw 'Simulated preflight failure.' }
                $script:Fixture.ResolvedInputs = $Inputs
                $context = [pscustomobject]@{
                    OperatorId = '66666666-6666-6666-6666-666666666666'; GraphAccount = 'operator@contoso.com'; TokenVersion = 1
                    Application = [pscustomobject]@{ Id = '77777777-7777-7777-7777-777777777777'; KeyCredentials = @() }
                    ResourceProviders = @(Get-CyotResourceProviderRequirements | ForEach-Object {
                        [pscustomobject]@{
                            Namespace = $_.Namespace; Type = $_.Type
                            RegistrationState = Get-FixtureProviderState $_.Namespace
                            Locations = @('West US 2')
                        }
                    })
                }
                if ($script:Fixture.Fault -eq 'existing-key') {
                    $context.Application.KeyCredentials = @([pscustomobject]@{
                        Usage = 'Encrypt'; CustomKeyIdentifier = $script:Fixture.Certificate.GetCertHash()
                        KeyId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    })
                }
                $script:Fixture.Context = $context
                return $context
            }
            function script:Get-CyotPackage {
                param($Selection, $Directory)
                $script:Fixture.Trace.Add('package')
                if ($script:Fixture.Fault -eq 'package') { throw 'Simulated package validation failure.' }
                return [pscustomobject]@{
                    Path = Join-Path $Directory "$($Selection.Id).zip"; SourceSha256 = ('b' * 64)
                    Sha256 = $(if ($Selection.Id -eq 'dotnet') { 'c' * 64 } else { 'b' * 64 })
                    RequiresRemoteBuild = $Selection.BuildStrategy -eq 'remote-build'
                }
            }
            function script:Get-MgContext {
                return [pscustomobject]@{ TenantId = $script:Fixture.ResolvedInputs.TenantId; Account = 'operator@contoso.com' }
            }
            function script:Start-Sleep {
                param($Seconds)
                $script:Fixture.Trace.Add("wait:$Seconds")
            }
            function script:Get-CyotEncryptionCertificate {
                param($Inputs, $OutputDirectory)
                $script:Fixture.Trace.Add('certificate')
                return $script:Fixture.Certificate
            }
            function script:Set-CyotPrivateKey {
                param($Certificate, $KeyId, $VaultName, $SubscriptionId, $Directory)
                $script:Fixture.Trace.Add('private-key')
                if ($script:Fixture.Fault -eq 'key') { throw 'Simulated Key Vault failure.' }
            }
            function script:Set-CyotApplicationEndpoint {
                param($Inputs, $Context, $Outputs, $Certificate, $KeyId, [bool] $ConfigureFederation)
                $script:Fixture.Trace.Add('application-endpoint')
                $script:Fixture.Federation = $ConfigureFederation
            }
            function script:Build-CyotPythonPackage {
                param($Inputs, $Names, $SiteId, $SourcePath, $Directory)
                $script:Fixture.Trace.Add('python-remote-build')
                if ($script:Fixture.Fault -eq 'python-build') { throw 'Simulated Python remote-build failure.' }
                $path = Join-Path $Directory 'python-built.zip'
                [IO.File]::WriteAllText($path, 'synthetic built Python package')
                return $path
            }
            function script:Invoke-CyotAz {
                param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
                $operation = $Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' '
                $script:Fixture.Trace.Add("az:$operation")
                if ($Arguments[0] -eq 'bicep') {
                    if ($script:Fixture.Fault -eq 'build') { throw 'Simulated Bicep build failure.' }
                    return ''
                }
                if ($Arguments[0] -eq 'provider') {
                    $subscription = $Arguments[([Array]::IndexOf($Arguments, '--subscription') + 1)]
                    if ($subscription -ne $script:Fixture.ResolvedInputs.SubscriptionId) { throw 'Provider operation used the wrong subscription.' }
                    $namespace = $Arguments[([Array]::IndexOf($Arguments, '--namespace') + 1)]
                    if ($Arguments[1] -eq 'register') {
                        $script:Fixture.ProviderRegistrations.Add($namespace)
                        $script:Fixture.Trace.Add("register:$namespace")
                        if ($script:Fixture.Fault -eq 'provider-denied') { throw 'AuthorizationFailed: provider registration denied.' }
                        return ''
                    }
                    if ($Arguments[1] -eq 'show') {
                        return @{
                            registrationState = Get-FixtureProviderState $namespace
                            resourceTypes = @(Get-CyotResourceProviderRequirements | ForEach-Object {
                                @{ resourceType = $_.Type; locations = @('West US 2') }
                            })
                        } | ConvertTo-Json -Depth 5
                    }
                    throw 'Unexpected resource-provider operation.'
                }
                if ($Arguments[0] -eq 'appservice') {
                    throw 'Do not use appservice list-locations for the EP1 Functions SKU.'
                }
                if ($Arguments[0] -eq 'deployment') {
                    $script:Fixture.DeploymentNames.Add($Arguments[([Array]::IndexOf($Arguments, '--name') + 1)])
                    if ($script:Fixture.Fault -eq 'deployment-registration-delay' -and $script:Fixture.DeploymentNames.Count -lt 3) {
                        throw "MissingSubscriptionRegistration: namespace 'Microsoft.Web' is still registering."
                    }
                    if ($script:Fixture.Fault -eq 'deployment') { throw 'Simulated ARM failure.' }
                    $parameterFile = $Arguments[([Array]::IndexOf($Arguments, '--parameters') + 1)].Substring(1)
                    $script:Fixture.Parameters = (Read-CyotJson $parameterFile).parameters
                    $names = $script:Fixture.Parameters.resourceNames.value
                    $outputs = @{
                        resourceGroupName = @{ value = $names.resourceGroup }
                        functionAppName = @{ value = $names.functionApp }
                        storageAccountName = @{ value = $names.storageAccount }
                        keyVaultName = @{ value = $names.keyVault }
                        outboundPrincipalId = @{ value = '88888888-8888-8888-8888-888888888888' }
                        endpointUrl = @{ value = "https://$($names.functionApp).azurewebsites.net/api/SendOtp" }
                        identifierUri = @{ value = "api://$($names.functionApp).azurewebsites.net/$($script:Fixture.ResolvedInputs.ApplicationId)" }
                        packageContainerUrl = @{ value = "https://$($names.storageAccount).blob.core.windows.net/packages/" }
                    }
                    if ($script:Fixture.Fault -eq 'names') { $outputs.functionAppName.value = 'not-approved' }
                    return $outputs | ConvertTo-Json -Depth 5
                }
                if ($Arguments[0] -eq 'rest') {
                    $uri = $Arguments[([Array]::IndexOf($Arguments, '--url') + 1)]
                    if ($uri -match '/providers/Microsoft\.Web/geoRegions$') {
                        $script:Fixture.PremiumChecks++
                        $queryFile = $Arguments[([Array]::IndexOf($Arguments, '--url-parameters') + 1)].Substring(1)
                        $query = Read-CyotJson $queryFile
                        if ($query.sku -cne 'ElasticPremium' -or $query.linuxWorkersEnabled -cne 'true' -or $query.'api-version' -cne '2024-04-01') {
                            throw 'Incorrect Functions Premium region filter.'
                        }
                        if ($script:Fixture.Fault -eq 'provider-region-delay' -and $script:Fixture.PremiumChecks -lt 3) {
                            throw "MissingSubscriptionRegistration: namespace 'Microsoft.Web' is still registering."
                        }
                        return '{"value":[{"name":"West US 2"}]}'
                    }
                    if ($uri -match '/authsettingsV2\?') {
                        $inputs = $script:Fixture.ResolvedInputs
                        $names = $script:Fixture.Parameters.resourceNames.value
                        return @{ properties = @{
                            platform = @{ enabled = $true }
                            globalValidation = @{ requireAuthentication = $true; unauthenticatedClientAction = 'Return401'; excludedPaths = @() }
                            httpSettings = @{ requireHttps = $true }
                            identityProviders = @{ azureActiveDirectory = @{
                                enabled = $true
                                registration = @{ clientId = $inputs.ApplicationId; openIdIssuer = "https://sts.windows.net/$($inputs.TenantId)/" }
                                validation = @{
                                    allowedAudiences = @("api://$($names.functionApp).azurewebsites.net/$($inputs.ApplicationId)")
                                    defaultAuthorizationPolicy = @{
                                        allowedApplications = $(if ($script:Fixture.Fault -eq 'auth') { @() } else { @('25ec60fa-f18d-41a4-b398-50044c90ce13') })
                                    }
                                }
                            } }
                        } } | ConvertTo-Json -Depth 12
                    }
                    if ($uri -match '/appsettings/list\?') {
                        return @{ properties = @{ ExistingSetting = 'preserve-me'; SCM_RUN_FROM_PACKAGE = 'old-build' } } | ConvertTo-Json
                    }
                    if ($uri -match '/appsettings\?') {
                        $path = $Arguments[([Array]::IndexOf($Arguments, '--body') + 1)].Substring(1)
                        $script:Fixture.WrittenSettings = (Read-CyotJson $path).properties
                        return ''
                    }
                    if ($uri -match '/syncfunctiontriggers\?') {
                        $script:Fixture.SyncAttempts++
                        if ($script:Fixture.Fault -in @('sync', 'cleanup')) { throw 'Simulated trigger synchronization failure.' }
                        if ($script:Fixture.Fault -eq 'unrelated-internal-error') {
                            throw 'InternalServerError from an unrelated deployment proxy.'
                        }
                        if ($script:Fixture.Fault -eq 'host-runtime-internal-persistent' -or
                            ($script:Fixture.Fault -eq 'host-runtime-internal' -and $script:Fixture.SyncAttempts -lt 3)) {
                            throw 'Bad Request: Encountered an error (InternalServerError) from host runtime.'
                        }
                        if ($script:Fixture.Fault -eq 'host-unavailable' -or
                            ($script:Fixture.Fault -eq 'cold-start' -and $script:Fixture.SyncAttempts -lt 3)) {
                            throw 'ServiceUnavailable from host runtime.'
                        }
                    }
                }
                if ($operation -eq 'functionapp function list') {
                    if ($script:Fixture.Fault -eq 'function-missing') { return '[]' }
                    return '[{"name":"fixture/SendOtp"}]'
                }
                if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'update') {
                    $access = ($Arguments[([Array]::IndexOf($Arguments, '--set') + 1)] -split '=', 2)[1]
                    if ($access -eq 'Disabled' -and $script:Fixture.Fault -eq 'cleanup') { throw 'Simulated ingress cleanup failure.' }
                    $script:Fixture.Access = $access
                    $script:Fixture.Trace.Add("public:$access")
                    if ($access -eq 'Enabled' -and $script:Fixture.Fault -eq 'enable') { throw 'Simulated lost response after opening ingress.' }
                }
                return ''
            }
            $setupArguments = $scenario.Inputs
            Invoke-CyotSetup @setupArguments
        } $scenario *>&1 | ForEach-Object { $records.Add($_) }
    }
    catch { $scenario.Error = $_.Exception.Message }
    finally { Remove-Module -ModuleInfo $module }
    $scenario.Text = $records | Out-String -Width 240
    $scenario.Result = $records | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['policyChanged'] } | Select-Object -Last 1
    return $scenario
}

function Invoke-ContextFixture {
    param([string] $Fault, [switch] $Interactive)

    $scenario = [pscustomobject]@{
        Fault = $Fault; Interactive = [bool]$Interactive; Result = $null; Error = $null
        Calls = [Collections.Generic.List[string]]::new()
        ContextReads = 0; Reloads = 0; Connections = 0; Connected = $false
    }
    $module = Import-Module $modulePath -Force -PassThru
    try {
        $scenario.Result = & $module {
            param($scenario)
            $script:ContextFixture = $scenario
            function script:Get-Command { param($Name, $ErrorAction) return [pscustomobject]@{ Name = $Name } }
            function script:Get-Module {
                param($Name)
                if ($Name -ne 'Microsoft.Graph.Authentication') { throw 'Unexpected module lookup.' }
                if ($script:ContextFixture.Fault -eq 'ambiguous-session') {
                    return @([pscustomobject]@{ Version = [Version]'2.38.0' }, [pscustomobject]@{ Version = [Version]'2.39.0' })
                }
                return [pscustomobject]@{ Version = [Version]'2.39.0' }
            }
            function script:Import-Module {
                param($Name, $ErrorAction, $RequiredVersion, [switch] $Global, [switch] $Force)
                if ($Force) {
                    if ($Name -ne 'Microsoft.Graph.Authentication' -or $RequiredVersion -ne [Version]'2.39.0' -or -not $Global) {
                        throw 'SDK recovery changed module/version or import scope.'
                    }
                    $script:ContextFixture.Reloads++
                }
            }
            function script:Get-MgContext {
                param($ErrorAction)
                $script:ContextFixture.ContextReads++
                if ($script:ContextFixture.Fault -eq 'sdk-error') { throw [InvalidOperationException]::new('Unrelated Graph SDK failure.') }
                if ($script:ContextFixture.Fault -in @('persistent-session', 'ambiguous-session') -or
                    ($script:ContextFixture.Fault -eq 'reset-session' -and $script:ContextFixture.ContextReads -eq 1)) {
                    throw [InvalidOperationException]::new('SessionNotInitialized')
                }
                if ($script:ContextFixture.Fault -in @('reset-session', 'not-signed-in') -and -not $script:ContextFixture.Connected) {
                    return $null
                }
                return [pscustomobject]@{
                    TenantId = '11111111-1111-1111-1111-111111111111'
                    Environment = 'Global'; AuthType = 'Delegated'; Account = 'operator@contoso.com'
                    Scopes = $(if ($script:ContextFixture.Fault -eq 'scope') { @() } else { @('Application.ReadWrite.All') })
                }
            }
            function script:Connect-MgGraph {
                param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome, $ErrorAction)
                if (-not $script:ContextFixture.Interactive) { throw 'Noninteractive setup attempted a sign-in.' }
                if ($TenantId -ne '11111111-1111-1111-1111-111111111111' -or
                    $Scopes -ne 'Application.ReadWrite.All' -or $ContextScope -ne 'Process') {
                    throw 'Graph sign-in changed its tenant or permission scope.'
                }
                $script:ContextFixture.Connections++
                $script:ContextFixture.Connected = $true
            }
            function script:Get-MgApplication {
                param($ApplicationId, $Property, $Filter, [switch] $All, $ErrorAction)
                return [pscustomobject]@{
                    Id = 'application-object-id'; AppId = '33333333-3333-3333-3333-333333333333'
                    SignInAudience = $(if ($script:ContextFixture.Fault -eq 'single-tenant') { 'AzureADMyOrg' } else { 'AzureADMultipleOrgs' })
                    TokenEncryptionKeyId = $(if ($script:ContextFixture.Fault -eq 'encrypted-token') { 'existing-key-id' } else { $null })
                    Api = $null; IdentifierUris = @(); KeyCredentials = @()
                }
            }
            function script:Get-MgServicePrincipal {
                param($Filter, [switch] $All, $ErrorAction)
                return [pscustomobject]@{ AppRoleAssignmentRequired = ($script:ContextFixture.Fault -eq 'assignment') }
            }
            function script:Invoke-CyotAz {
                param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
                $operation = $Arguments[0..1] -join ' '
                $script:ContextFixture.Calls.Add($operation)
                switch ($operation) {
                    'version --output' { return '{"azure-cli":"2.62.0"}' }
                    'account show' {
                        return @{
                            id = '22222222-2222-2222-2222-222222222222'
                            tenantId = $(if ($script:ContextFixture.Fault -eq 'tenant') { 'wrong-tenant' } else { '11111111-1111-1111-1111-111111111111' })
                            state = 'Enabled'; environmentName = 'AzureCloud'; user = @{ type = 'user' }
                        } | ConvertTo-Json
                    }
                    'rest --method' {
                        $uri = $Arguments[([Array]::IndexOf($Arguments, '--url') + 1)]
                        if ($uri -match '/geoRegions$') {
                            $script:ContextFixture.Calls.Add('geoRegions')
                            return $(if ($script:ContextFixture.Fault -eq 'region') { '{"value":[]}' } else { '{"value":[{"name":"West US 2"}]}' })
                        }
                        return '66666666-6666-6666-6666-666666666666'
                    }
                    'group exists' { return $(if ($script:ContextFixture.Fault -eq 'unowned-group') { 'true' } else { 'false' }) }
                    'group show' { return '{}' }
                    'provider show' {
                        return @{
                            registrationState = $(switch ($script:ContextFixture.Fault) {
                                'unregistered' { 'NotRegistered' }
                                'registering' { 'Registering' }
                                'unregistering' { 'Unregistering' }
                                'unknown-provider-state' { 'UnknownState' }
                                default { 'Registered' }
                            })
                            resourceTypes = $(if ($script:ContextFixture.Fault -eq 'unregistered') { @() } else {
                                @('sites', 'storageAccounts', 'vaults', 'workspaces', 'components', 'userAssignedIdentities') |
                                    ForEach-Object { @{ resourceType = $_; locations = @('West US 2') } }
                            })
                        } | ConvertTo-Json -Depth 5
                    }
                    'appservice list-locations' { throw 'EP1 is not accepted by this CLI command.' }
                    default { throw "Unexpected operation during read-only preflight: $operation" }
                }
            }
            $inputs = @{
                TenantId = '11111111-1111-1111-1111-111111111111'; SubscriptionId = '22222222-2222-2222-2222-222222222222'
                ApplicationId = '33333333-3333-3333-3333-333333333333'; Location = 'westus2'; Language = 'javascript'
            }
            $names = Get-CyotResourceNames $inputs.SubscriptionId $inputs.ApplicationId contoso
            Connect-CyotContext -Inputs $inputs -Names $names -NonInteractive:(-not $script:ContextFixture.Interactive)
        } $scenario
    }
    catch { $scenario.Error = $_.Exception.Message }
    finally { Remove-Module -ModuleInfo $module }
    return $scenario
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
$rsa = [Security.Cryptography.RSA]::Create(2048)
$request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=CYOT offline fixture', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
$script:testCertificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(365))
try {
    Test-Case 'All shipped PowerShell files parse' {
        foreach ($file in @($entryPoint, $modulePath, $packageHelperPath, $PSCommandPath)) {
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) ($errors | Out-String)
        }
    }
    Test-Case 'Customer entry point stays under 100 lines with no stage switches' {
        $lines = @(Get-Content -LiteralPath $entryPoint)
        Assert-True ($lines.Count -le 100) "Launcher has $($lines.Count) lines."
        Assert-True (($lines -join "`n") -notmatch '\$(Stage|Resume|ConfigPath|ApprovePolicyActivation)\b') 'Legacy stage controls remain.'
        Assert-True (($lines -join "`n") -notmatch '\$(PackageUrl|PackageSha256)\b') 'Customers are still asked for a package URL or checksum.'
    }
    Test-Case 'One-file download resolves GitHub once and pins every support download' {
        $run = Invoke-LauncherFixture
        Assert-True (-not $run.Error -and $run.Result.Invoked) "Launcher failed: $($run.Error)"
        Assert-True ($run.ApiCalls -eq 1 -and $run.Downloads.Count -eq 6) 'Unexpected bootstrap requests.'
        $expected = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup/"
        Assert-True (@($run.Downloads | Where-Object { -not $_.Uri.StartsWith($expected) }).Count -eq 0) 'Mixed or untrusted source revisions.'
        Assert-True ($run.Result.Prefix -eq 'contoso' -and $run.Result.Tenant -like '11111111-*') 'Parameters were not forwarded.'
        Assert-True (@($run.Downloads | Where-Object { Test-Path -LiteralPath $_.Path }).Count -eq 0) 'Temporary downloads survived completion.'
    }
    Test-Case 'Explicit commit avoids the GitHub API' {
        $run = Invoke-LauncherFixture -SourceRef ('a' * 40)
        Assert-True (-not $run.Error -and $run.ApiCalls -eq 0 -and $run.Result.Invoked) 'Commit-pinned launch failed.'
    }
    Test-Case 'Public fork and slash-containing branch control every bootstrap download' {
        $repository = 'siyixian/ExternalPhoneProvider-AzureFunction-Sample'
        $run = Invoke-LauncherFixture -SourceRepository $repository -SourceRef 'test/cyot-single-script'
        Assert-True (-not $run.Error -and $run.Result.Repository -ceq $repository) "Fork launch failed: $($run.Error)"
        Assert-True ($run.ApiUri -ceq "https://api.github.com/repos/$repository/commits/test%2Fcyot-single-script") 'The selected fork/ref was not resolved correctly.'
        $expected = "https://raw.githubusercontent.com/$repository/$('a' * 40)/setup/"
        Assert-True ($run.Downloads.Count -eq 6 -and @($run.Downloads | Where-Object { -not $_.Uri.StartsWith($expected) }).Count -eq 0) 'A support file came from upstream instead of the fork.'
    }
    foreach ($repository in @('https://github.com/owner/repo', 'owner/repo/extra', 'owner/repo?token=value', '../repo')) {
        Test-Case "Invalid source repository '$repository' is rejected before network access" {
            $run = Invoke-LauncherFixture -SourceRepository $repository
            Assert-True ($run.Error -match 'SourceRepository' -and $run.ApiCalls -eq 0 -and $run.Downloads.Count -eq 0) 'Invalid repository reached GitHub downloads.'
        }
    }
    foreach ($fault in @('commit', 'download', 'empty')) {
        Test-Case "Launcher stops and cleans up after $fault failure" {
            $run = Invoke-LauncherFixture -Fault $fault
            Assert-True ($null -ne $run.Error -and $null -eq $run.Result) 'Partial tools were executed.'
            Assert-True (@($run.Downloads | Where-Object { Test-Path -LiteralPath $_.Path }).Count -eq 0) 'Failure left downloaded files behind.'
        }
    }
    Test-Case 'Cleanup failure preserves the original setup error and still deletes downloads' {
        $run = Invoke-LauncherFixture -Fault operation-and-cleanup
        Assert-True ($run.Error -eq 'Simulated primary setup failure.') "Cleanup replaced the primary error: $($run.Error)"
        Assert-True (@($run.Downloads | Where-Object { Test-Path -LiteralPath $_.Path }).Count -eq 0) 'Module cleanup failure skipped file cleanup.'
    }
    Test-Case 'Cleanup failure is a warning rather than a false deployment failure' {
        $run = Invoke-LauncherFixture -Fault cleanup
        Assert-True (-not $run.Error -and $run.Result.Invoked) "Successful setup was replaced by a cleanup failure: $($run.Error)"
        Assert-True (@($run.Downloads | Where-Object { Test-Path -LiteralPath $_.Path }).Count -eq 0) 'Temporary downloads survived a cleanup warning.'
    }
    Test-Case 'Session-global Graph dependencies survive helper unload and rerun' {
        $path = Join-Path $PSScriptRoot 'ModuleLifecycle.Tests.ps1'
        $output = & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -File $path -ModulePath $modulePath 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0 -and $output -match 'survived both helper unloads') $output
    }

    $module = Import-Module $modulePath -Force -PassThru
    try {
        Test-Case 'Simplified Telesign profile retains exact channel URLs and timings' {
            $profile = Get-Content (Join-Path $packageRoot 'providers/telesign.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert-True (@($profile.Keys).Count -eq 1 -and $profile.Contains('deployment')) 'Non-deployment provider metadata returned.'
            Assert-True ($profile.deployment.routes.sms.global.endpoint -ceq 'https://rest-ww.telesign.com/integration/microsoft-cyot/sms') 'SMS URL was changed.'
            Assert-True ($profile.deployment.routes.voice.global.endpoint -ceq 'https://rest-ww.telesign.com/integration/microsoft-cyot/voice') 'Voice URL was changed.'
            $result = & $module { param($profile) ConvertTo-CyotProviderSettings $profile telesign Telesign sms global -NonInteractive } $profile
            Assert-True ($result.Settings.EPP_PROVIDER_TIMEOUT_MS -ceq '1500' -and $result.Settings.EPP_PROVIDER_RETRY_INTERVAL_MS -ceq '30000') 'Seconds were not converted to milliseconds exactly.'
            Assert-True ($result.Settings.EPP_PROVIDER_ENDPOINT -ceq 'https://rest-ww.telesign.com/integration/microsoft-cyot/sms') 'The selected channel/region endpoint was not used exactly.'
        }
        foreach ($provider in @('telesign', 'soprano')) {
            Test-Case "$provider test values are explicit real app-setting strings" {
                $profile = Get-Content (Join-Path $packageRoot "providers/$provider.json") -Raw | ConvertFrom-Json -AsHashtable
                $result = & $module { param($p, $id) ConvertTo-CyotProviderSettings $p $id $id sms global -NonInteractive } $profile $provider
                Assert-True ($result.IsTestConfiguration -and $result.Settings.EPP_PROVIDER_TEST_CONFIGURATION -ceq 'true') 'Dummy configuration was not labelled.'
                Assert-True ($result.Settings.EPP_PROVIDER_CHANNEL -ceq 'sms' -and $result.Settings.EPP_PROVIDER_ENDPOINT_REGION -ceq 'global') 'Selected route labels were not written.'
                $expectedAuth = if ($provider -eq 'soprano') { 'oauth' } else { 'apiKey' }
                Assert-True ($result.AuthenticationMode -ceq $expectedAuth -and $result.Settings.EPP_PROVIDER_AUTH_MODE -ceq $expectedAuth) 'Provider authentication was not profile-owned.'
                Assert-True (-not $profile.deployment.Contains('placeholderFields')) 'The provider profile still contains placeholderFields.'
                $profile.deployment.testConfiguration = $false
                if ($provider -eq 'soprano') {
                    Assert-Throws { & $module { param($p, $id) ConvertTo-CyotProviderSettings $p $id $id sms global -NonInteractive } $profile $provider } 'not deployment-ready'
                }
                else {
                    $live = & $module { param($p, $id) ConvertTo-CyotProviderSettings $p $id $id sms global -NonInteractive } $profile $provider
                    Assert-True (-not $live.IsTestConfiguration) 'A complete Telesign profile could not disable its test label.'
                }
            }
        }
        foreach ($invalid in @(-1, 2147484, '30', 1.5)) {
            Test-Case "Reject invalid retry seconds '$invalid'" {
                $profile = New-ValidProfile
                $profile.deployment.routes.sms.global.retryIntervalSeconds = $invalid
                Assert-Throws { & $module { param($p) ConvertTo-CyotProviderSettings $p telesign Telesign sms global -NonInteractive } $profile } 'retryIntervalSeconds'
            }
        }
        foreach ($invalid in @(0, 2501, '1500')) {
            Test-Case "Reject invalid timeout '$invalid'" {
                $profile = New-ValidProfile
                $profile.deployment.routes.sms.global.timeoutMilliseconds = $invalid
                Assert-Throws { & $module { param($p) ConvertTo-CyotProviderSettings $p telesign Telesign sms global -NonInteractive } $profile } 'timeoutMilliseconds'
            }
        }
        Test-Case 'Channel and endpoint-region selections resolve independently' {
            $profile = New-ValidProfile
            $profile.deployment.routes.voice.eu.retryIntervalSeconds = 31
            $result = & $module { param($p) ConvertTo-CyotProviderSettings $p telesign Telesign voice eu -NonInteractive } $profile
            Assert-True ($result.Settings.EPP_PROVIDER_ENDPOINT -ceq 'https://provider.contoso.com/voice/eu' -and
                $result.Settings.EPP_PROVIDER_RETRY_INTERVAL_MS -ceq '31000') 'The selected route was flattened with another channel or region.'
        }
        foreach ($url in @('http://provider.contoso.com', 'https://127.0.0.1', 'https://localhost', 'https://provider.contoso.com?token=secret', 'https://user:pass@provider.contoso.com', 'https://provider.example.com')) {
            Test-Case "Reject unsafe or placeholder URL $($url.Split('?')[0])" {
                Assert-Throws { & $module { param($value) Assert-CyotHttpsUrl $value } $url } 'public HTTPS'
            }
        }
        Test-Case 'Resource names are stable, prefix-based, and valid at both length boundaries' {
            foreach ($prefix in @('ab', 'abcdefgh')) {
                $names = & $module { param($p) Get-CyotResourceNames '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222' $p } $prefix
                $again = & $module { param($p) Get-CyotResourceNames '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222' $p } $prefix
                Assert-True (($names | ConvertTo-Json -Compress) -ceq ($again | ConvertTo-Json -Compress)) 'Names changed between runs.'
                Assert-True (@($names.Values | Where-Object { -not $_.StartsWith($prefix) }).Count -eq 0) 'A resource lost its prefix.'
                Assert-True (@($names.Values | Where-Object { $_ -notmatch "^$prefix-?epp" }).Count -eq 0) 'A resource name did not add the epp marker after the customer prefix.'
                Assert-True ($names.storageAccount -cmatch '^[a-z0-9]{3,24}$' -and $names.keyVault.Length -le 24 -and $names.functionApp.Length -le 60) 'Invalid Azure name lengths.'
            }
            Assert-Throws { & $module { Get-CyotResourceNames '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222' 'abcdefghi' } } 'ResourcePrefix'
        }
        Test-Case 'Source and catalog cannot redirect support execution or traverse directories' {
            Assert-Throws { & $module { param($root) Get-CyotProvider $root 'https://untrusted.contoso.com' telesign } $packageRoot } 'commit-pinned'
            $catalogDirectory = Join-Path $testRoot 'bad-catalog'
            New-Item -ItemType Directory -Path (Join-Path $catalogDirectory 'providers') -Force | Out-Null
            '{"schemaVersion":1,"providers":[{"id":"telesign","displayName":"Telesign","file":"../evil.ps1"}]}' |
                Set-Content (Join-Path $catalogDirectory 'providers/catalog.json')
            Assert-Throws {
                & $module {
                    param($root, $src)
                    Get-CyotProvider $root $src telesign -SourceRepository 'siyixian/ExternalPhoneProvider-AzureFunction-Sample'
                } $catalogDirectory $source
            } 'invalid or duplicate'
            Assert-Throws {
                & $module {
                    param($root, $src)
                    Get-CyotProvider $root $src invalid -SourceRepository 'siyixian/ExternalPhoneProvider-AzureFunction-Sample'
                } $packageRoot $source
            } 'telesign, soprano'
        }
        Test-Case 'Fork release URLs are accepted only for an explicitly selected fork' {
            $repository = 'siyixian/ExternalPhoneProvider-AzureFunction-Sample'
            $url = "https://github.com/$repository/releases/download/test/cyot.zip"
            $value = & $module { param($url, $repo) Read-CyotInput -Name PackageUrl -Value $url -Kind PackageUrl -SourceRepository $repo -NonInteractive } $url $repository
            Assert-True ($value -ceq $url) 'Selected-fork package URL was rejected.'
            Assert-Throws { & $module { param($url) Read-CyotInput -Name PackageUrl -Value $url -Kind PackageUrl -NonInteractive } $url } 'versioned ZIP'
        }
        Test-Case 'Package download verifies its hash, root layout, and excluded content' {
            $zipDirectory = Join-Path $testRoot 'zip-fixtures'
            New-Item -ItemType Directory -Path $zipDirectory | Out-Null
            & $module {
                function script:Invoke-WebRequest {
                    param($Uri, $OutFile, $TimeoutSec)
                    if ($Uri.EndsWith('SHA256SUMS.txt')) { "$script:ZipChecksum  endpoint.zip" | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM }
                    else { Copy-Item -LiteralPath $script:ZipFixture -Destination $OutFile }
                }
            }
            foreach ($kind in @('valid', 'wrong-hash', 'nested', 'secret', 'traversal')) {
                $zipPath = Join-Path $zipDirectory "$kind.zip"
                $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
                try {
                    $entries = if ($kind -eq 'nested') { @('folder/host.json', 'folder/package.json') } else { @('host.json', 'package.json') }
                    if ($kind -eq 'secret') { $entries += 'local.settings.json' }
                    if ($kind -eq 'traversal') { $entries += '../outside.txt' }
                    foreach ($entryName in $entries) {
                        $writer = [IO.StreamWriter]::new($archive.CreateEntry($entryName).Open())
                        try { $writer.Write('{}') }
                        finally { $writer.Dispose() }
                    }
                }
                finally { $archive.Dispose() }
                & $module { param($path) $script:ZipFixture = $path } $zipPath
                $hash = (Get-FileHash $zipPath).Hash
                if ($kind -eq 'wrong-hash') { $hash = '0' * 64 }
                & $module { param($hash) $script:ZipChecksum = $hash } $hash
                $selection = [pscustomobject]@{
                    Id = 'javascript'; DisplayName = 'JavaScript'; BuildStrategy = 'ready'
                    Url = 'https://github.com/offline/fixture/releases/download/test/endpoint.zip'
                    ChecksumsUrl = 'https://github.com/offline/fixture/releases/download/test/SHA256SUMS.txt'
                }
                if ($kind -eq 'valid') {
                    $download = & $module { param($selection, $dir) Get-CyotPackage $selection $dir } $selection $zipDirectory
                    Assert-True ((Get-FileHash $download.Path).Hash -eq $hash -and $download.SourceSha256 -ieq $hash) 'Valid package was not retained.'
                }
                else {
                    $pattern = switch ($kind) { 'wrong-hash' { 'does not match' } 'nested' { 'required deployment path' } 'secret' { 'local settings' } 'traversal' { 'traversing' } }
                    Assert-Throws { & $module { param($selection, $dir) Get-CyotPackage $selection $dir } $selection $zipDirectory } $pattern
                }
            }
        }
        Test-Case 'Application endpoint updates preserve existing URIs/keys without enabling token encryption' {
            $record = [pscustomobject]@{
                Application = [pscustomobject]@{
                    Id = 'application-object-id'; AppId = '33333333-3333-3333-3333-333333333333'
                    SignInAudience = 'AzureADMultipleOrgs'; TokenEncryptionKeyId = $null
                    IdentifierUris = @('api://existing')
                    KeyCredentials = @([pscustomobject]@{ KeyId = '99999999-9999-9999-9999-999999999999'; Usage = 'Verify' })
                }
                Update = $null; Credential = $null; Credentials = @()
            }
            & $module {
                param($record, $certificate)
                $script:RegistrationFixture = $record
                function script:Get-MgApplication { param($ApplicationId, $Property, $ErrorAction) return $script:RegistrationFixture.Application }
                function script:Update-MgApplication {
                    param($ApplicationId, $IdentifierUris, $KeyCredentials, $ErrorAction)
                    $script:RegistrationFixture.Update = @{ Id = $ApplicationId; Uris = $IdentifierUris; Keys = $KeyCredentials }
                }
                function script:Get-MgApplicationFederatedIdentityCredential {
                    param($ApplicationId, [switch]$All, $ErrorAction)
                    return $script:RegistrationFixture.Credentials
                }
                function script:New-MgApplicationFederatedIdentityCredential {
                    param($ApplicationId, $BodyParameter, $ErrorAction)
                    $script:RegistrationFixture.Credential = $BodyParameter
                }
                $inputs = @{ TenantId = '11111111-1111-1111-1111-111111111111'; ApplicationId = $record.Application.AppId }
                $context = [pscustomobject]@{ Application = $record.Application }
                $outputs = [pscustomobject]@{
                    identifierUri = @{ value = 'api://cyot.contoso.com/app' }
                    functionAppName = @{ value = 'contoso-function' }
                    outboundPrincipalId = @{ value = '88888888-8888-8888-8888-888888888888' }
                }
                Set-CyotApplicationEndpoint $inputs $context $outputs $certificate 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                $record.Credentials = @([pscustomobject]$record.Credential)
                $record.Credential = $null
                Set-CyotApplicationEndpoint $inputs $context $outputs $certificate 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                if ($record.Credential) { throw 'Identical federation was created twice.' }
            } $record $script:testCertificate
            Assert-True ($record.Update.Uris -contains 'api://existing' -and $record.Update.Uris -contains 'api://cyot.contoso.com/app') 'An existing identifier URI was lost.'
            Assert-True ($record.Update.Keys.Count -eq 2 -and @($record.Update.Keys | Where-Object Usage -eq 'Encrypt').Count -eq 1) 'An existing key was lost or the new key is not Encrypt.'
            Assert-True ($null -eq $record.Application.TokenEncryptionKeyId) 'Payload encryption enabled access-token encryption.'
        }
        Test-Case 'Private-key upload uses a temporary file, reuses matching secrets, and rejects disabled secrets' {
            $record = [pscustomobject]@{
                Secrets = @(); Uploads = 0; PrivatePath = $null; Value = $null
            }
            & $module {
                param($record, $certificate, $directory)
                $script:SecretFixture = $record
                function script:Invoke-CyotAz {
                    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
                    if ($Arguments[0..2] -join ' ' -eq 'keyvault secret list') {
                        return ConvertTo-Json -InputObject $script:SecretFixture.Secrets -Depth 5
                    }
                    if ($Arguments[0..2] -join ' ' -ne 'keyvault secret set') { throw 'Unexpected operation in private-key test.' }
                    $script:SecretFixture.Uploads++
                    if ($Arguments -contains '--value') { throw 'Private key was put on the command line.' }
                    $path = $Arguments[([Array]::IndexOf($Arguments, '--file') + 1)]
                    $script:SecretFixture.PrivatePath = $path
                    $script:SecretFixture.Value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Get-Content $path -Raw)))
                    return ''
                }
                Set-CyotPrivateKey $certificate 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' 'test-vault' '22222222-2222-2222-2222-222222222222' $directory
                $record.Secrets = @(@{
                    name = 'phone-provider-decryption-key'
                    tags = @{ certificateThumbprint = $certificate.Thumbprint; encryptionKeyId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                    attributes = @{ enabled = $true; expires = $null }
                })
                Set-CyotPrivateKey $certificate 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' 'test-vault' '22222222-2222-2222-2222-222222222222' $directory
            } $record $script:testCertificate $testRoot
            Assert-True ($record.Uploads -eq 1 -and $record.Value -match 'BEGIN PRIVATE KEY') 'Private-key export or idempotent reuse failed.'
            Assert-True (-not (Test-Path -LiteralPath $record.PrivatePath)) 'Temporary private key survived upload.'
            $record.Secrets[0].attributes.enabled = $false
            Assert-Throws {
                & $module { param($cert, $dir) Set-CyotPrivateKey $cert 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' 'test-vault' '22222222-2222-2222-2222-222222222222' $dir } $script:testCertificate $testRoot
            } 'disabled or expired'
        }
        Test-Case 'CLI wrapper preserves arguments and rejects/redacts native failures' {
            $nativeModule = Import-Module $modulePath -Force -PassThru
            try {
            & $nativeModule {
                function script:az { $global:LASTEXITCODE = 0; $args -join '|' }
                $result = Invoke-CyotAz account show --subscription '11111111-1111-1111-1111-111111111111' --output json
                if ($result -notmatch 'account\|show\|--subscription\|11111111') { throw 'CLI arguments changed.' }
                function script:az { $global:LASTEXITCODE = 1; 'Bearer private-token https://blob.contoso.com/?sig=private-signature' }
                try { Invoke-CyotAz rest --method post; throw 'Expected native failure.' }
                catch {
                    if ($_.Exception.Message -notmatch 'Azure CLI operation' -or $_.Exception.Message -match 'private-token|private-signature') { throw }
                }
                finally { $global:LASTEXITCODE = 0 }
            }
            }
            finally { Remove-Module -ModuleInfo $nativeModule }
        }
    }
    finally { Remove-Module -ModuleInfo $module }

    Test-Case 'Read-only preflight validates context and accepts a default-v1 existing application' {
        $run = Invoke-ContextFixture
        Assert-True (-not $run.Error -and $run.Result.TokenVersion -eq 1) "Context preflight failed: $($run.Error)"
        Assert-True ($run.Result.OperatorId -eq '66666666-6666-6666-6666-666666666666') 'Wrong scoped role principal.'
        Assert-True ($run.Reloads -eq 0 -and $run.Connections -eq 0) 'A healthy Graph session was reset.'
    }
    Test-Case 'An uninitialized SDK is reloaded once before normal interactive sign-in' {
        $run = Invoke-ContextFixture -Fault reset-session -Interactive
        Assert-True (-not $run.Error -and $run.Reloads -eq 1 -and $run.Connections -eq 1) "SDK recovery failed: $($run.Error)"
    }
    Test-Case 'An initialized SDK without sign-in connects without reloading modules' {
        $run = Invoke-ContextFixture -Fault not-signed-in -Interactive
        Assert-True (-not $run.Error -and $run.Reloads -eq 0 -and $run.Connections -eq 1) "Normal sign-in failed: $($run.Error)"
    }
    Test-Case 'Noninteractive SDK recovery never initiates sign-in' {
        $run = Invoke-ContextFixture -Fault reset-session
        Assert-True ($run.Error -match 'Connect-MgGraph' -and $run.Reloads -eq 1 -and $run.Connections -eq 0) 'SDK recovery bypassed noninteractive sign-in requirements.'
    }
    Test-Case 'Unrelated SDK failures are not swallowed or retried' {
        $run = Invoke-ContextFixture -Fault sdk-error -Interactive
        Assert-True ($run.Error -eq 'Unrelated Graph SDK failure.' -and $run.Reloads -eq 0 -and $run.Connections -eq 0) 'An unrelated error was treated as an uninitialized session.'
    }
    Test-Case 'Persistent or ambiguous SDK state requires a fresh process without looping' {
        $persistent = Invoke-ContextFixture -Fault persistent-session -Interactive
        Assert-True ($persistent.Error -match 'pwsh -NoProfile' -and $persistent.Reloads -eq 1 -and $persistent.Connections -eq 0) 'Persistent initialization failure was not bounded.'
        $ambiguous = Invoke-ContextFixture -Fault ambiguous-session -Interactive
        Assert-True ($ambiguous.Error -match 'ambiguous' -and $ambiguous.Reloads -eq 0 -and $ambiguous.Connections -eq 0) 'Recovery guessed a Graph module version.'
    }
    foreach ($fault in @('tenant', 'scope', 'single-tenant', 'encrypted-token', 'assignment', 'unowned-group', 'unregistering', 'unknown-provider-state', 'region')) {
        Test-Case "Read-only preflight rejects $fault" {
            $run = Invoke-ContextFixture -Fault $fault
            Assert-True ($null -ne $run.Error -and $null -eq $run.Result) "Unsafe context was accepted: $fault"
            Assert-True ($run.Error -notmatch 'Unexpected operation|cannot be found') "Fixture failed for the wrong reason: $($run.Error)"
        }
    }
    foreach ($state in @('unregistered', 'registering')) {
        Test-Case "Preflight records $state resource providers without writes or early SKU checks" {
            $run = Invoke-ContextFixture -Fault $state
            Assert-True (-not $run.Error -and $run.Result.ResourceProviders.Count -eq 6) "Pending registration blocked preflight: $($run.Error)"
            Assert-True ($run.Calls -notcontains 'provider register' -and $run.Calls -notcontains 'geoRegions') 'Preflight mutated registration or required a registered Web provider.'
        }
    }
    Test-Case 'Only missing inputs prompt, then language, provider, channel, endpoint region, prefix, and approval' {
        $run = Invoke-FlowFixture -Omit TenantId, Location, Language, Provider, Channel, EndpointRegion, ResourcePrefix `
            -Answers @('', 'not-a-guid', '11111111-1111-1111-1111-111111111111', 'westus2',
                'invalid', '1', 'invalid', '1', 'invalid', '1', 'invalid', '1', 'contoso', 'Yes')
        Assert-True (-not $run.Error) "Flow failed: $($run.Error)"
        Assert-True (@($run.Trace | Where-Object { $_ -like 'prompt:SubscriptionId*' -or $_ -like 'prompt:ApplicationId*' }).Count -eq 0) 'Supplied inputs were requested again.'
        Assert-True (@($run.Trace | Where-Object { $_ -like 'prompt:Deploy*' }).Count -eq 1) 'Extra deployment approvals appeared.'
        $trace = $run.Trace -join "`n"
        Assert-True ($trace -match '(?s)prompt:TenantId.*prompt:Location.*prompt:Language.*prompt:Provider.*download:.*prompt:Channel.*prompt:EndpointRegion.*prompt:ResourcePrefix.*preflight.*prompt:Deploy.*certificate.*az:deployment sub create') 'Input/approval/deployment order changed.'
        Assert-True ($trace -notmatch 'prompt:PackageUrl|prompt:PackageSha256') 'Customer was asked to find a package link or hash.'
        Assert-True ($run.Text.IndexOf('Deployment plan') -lt $run.Text.IndexOf('Deploying Bicep')) 'Deployment started before the preview.'
    }
    Test-Case 'Selected provider JSON uses the same fork and commit as the downloaded tools' {
        $repository = 'siyixian/ExternalPhoneProvider-AzureFunction-Sample'
        $forkSource = "https://raw.githubusercontent.com/$repository/$('a' * 40)/setup"
        $run = Invoke-FlowFixture -Overrides @{ SourceRepository = $repository; SourceBaseUri = $forkSource } -Answers @('No')
        Assert-True (-not $run.Error -and $run.Trace -contains "download:$forkSource/providers/telesign.json") "Provider did not use the fork: $($run.Error)"
        $mismatch = Invoke-FlowFixture -Overrides @{
            SourceRepository = $repository
            SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
        } -Answers @()
        Assert-True ($mismatch.Error -match 'commit-pinned selected repository' -and $mismatch.Trace -notcontains 'preflight') 'Cross-repository provider content was accepted.'
    }
    foreach ($answer in @('No', '')) {
        Test-Case "Cancellation '$answer' creates no resources, certificate, or output directory" {
            $run = Invoke-FlowFixture -Answers @($answer)
            Assert-True (-not $run.Error -and $null -eq $run.Result) "Cancellation failed: $($run.Error)"
            Assert-True ($run.Trace -notcontains 'certificate' -and -not (Test-Path $run.Inputs.OutputDirectory)) 'Cancellation caused mutations.'
            Assert-True ($run.Text -match 'Cancelled. No Azure resources') 'Cancellation was not explicit.'
        }
    }
    Test-Case 'An ambiguous answer cannot approve deployment' {
        $run = Invoke-FlowFixture -Answers @('y', 'maybe', 'No')
        Assert-True (-not $run.Error -and $run.Trace -notcontains 'certificate') 'A non-Yes answer approved deployment.'
    }
    Test-Case 'Yes deploys the previewed names and settings with one guarded publication' {
        $run = Invoke-FlowFixture
        Assert-True (-not $run.Error -and $null -ne $run.Result) "Deployment fixture failed: $($run.Error)"
        Assert-True (@($run.Trace | Where-Object { $_ -eq 'az:deployment sub create' }).Count -eq 1) 'Expected one Bicep deployment.'
        Assert-True ($run.Parameters.providerSettings.value.EPP_PROVIDER_RETRY_INTERVAL_MS -ceq '30000') 'Provider configuration was not passed to Bicep.'
        Assert-True ($run.Parameters.providerSettings.value.EPP_PROVIDER_CHANNEL -ceq 'sms' -and
            $run.Parameters.providerSettings.value.EPP_PROVIDER_ENDPOINT_REGION -ceq 'global') 'The selected provider route was not passed to Bicep.'
        foreach ($name in $run.Parameters.resourceNames.value.Values) { Assert-True ($run.Text.Contains($name)) "Unpreviewed resource $name" }
        Assert-True (($run.Trace -join "`n") -match '(?s)az:deployment sub create.*private-key.*application-endpoint.*az:rest --method get.*az:storage blob upload.*public:Enabled.*az:functionapp restart.*az:rest --method post.*az:functionapp function list') 'Authentication/publication ordering changed.'
        Assert-True ($run.Federation -eq $false) 'API-key samples should not create an unnecessary federated application credential.'
        Assert-True ($run.Result.policyChanged -eq $false) 'Setup changed policy.'
        Assert-True ($run.ProviderRegistrations.Count -eq 0) 'Already registered providers were registered again.'
        Assert-True (@(Get-ChildItem $run.Inputs.OutputDirectory -Filter 'deployment-*.json').Count -eq 1) 'No persistent summary was written.'
    }
    Test-Case 'Soprano selects OAuth route settings and creates outbound federation' {
        $profile = Get-Content (Join-Path $packageRoot 'providers/soprano.json') -Raw
        $run = Invoke-FlowFixture -ProfileJson $profile -Overrides @{
            Provider = 'soprano'; Channel = 'voice'; EndpointRegion = 'eu'
        }
        Assert-True (-not $run.Error -and $run.Federation -eq $true) "Soprano OAuth deployment failed: $($run.Error)"
        Assert-True ($run.Parameters.providerSettings.value.EPP_PROVIDER_AUTH_MODE -ceq 'oauth' -and
            $run.Parameters.providerSettings.value.EPP_PROVIDER_CHANNEL -ceq 'voice' -and
            $run.Parameters.providerSettings.value.EPP_PROVIDER_ENDPOINT_REGION -ceq 'eu') 'Soprano route/auth settings were not passed to Azure.'
        Assert-True ($run.Parameters.providerSettings.value.EPP_PROVIDER_ENDPOINT -ceq 'https://soprano-eu.example.invalid/voice' -and
            $run.Parameters.providerSettings.value.EPP_PROVIDER_SCOPE -ceq 'api://00000000-0000-0000-0000-000000000000/.default') 'Soprano OAuth endpoint or scope was not selected from its profile.'
        Assert-True ($run.Result.providerAuthentication -ceq 'oauth' -and $run.Result.channel -ceq 'voice' -and
            $run.Result.endpointRegion -ceq 'eu') 'The deployment summary omitted the selected Soprano route.'
    }
    Test-Case 'Missing Microsoft.Web is registered once after approval and before certificate/resource creation' {
        $run = Invoke-FlowFixture -Fault provider-missing
        Assert-True (-not $run.Error -and $null -ne $run.Result) "Automatic provider registration failed: $($run.Error)"
        Assert-True ($run.ProviderRegistrations.Count -eq 1 -and $run.ProviderRegistrations[0] -eq 'Microsoft.Web') 'Registered unrelated providers or repeated registration.'
        Assert-True (($run.Trace -join "`n") -match '(?s)prompt:Deploy.*register:Microsoft.Web.*certificate.*az:deployment sub create') 'Registration was outside the approved deployment phase.'
        Assert-True ($run.Text -match 'subscription-wide' -and $run.Text -match 'NotRegistered') 'The registration change was not disclosed in the plan.'
    }
    Test-Case 'Declining or withholding approval performs no resource-provider registration' {
        $declined = Invoke-FlowFixture -Fault provider-missing -Answers @('No')
        Assert-True (-not $declined.Error -and $declined.ProviderRegistrations.Count -eq 0) 'Declining approval still registered a provider.'
        $unapproved = Invoke-FlowFixture -Fault provider-missing -Overrides @{ NonInteractive = $true } -Answers @()
        Assert-True ($unapproved.Error -match 'ApproveDeployment' -and $unapproved.ProviderRegistrations.Count -eq 0) 'Noninteractive mode silently registered a provider.'
    }
    Test-Case 'Already-registering providers do not block regional deployment or get re-registered' {
        $run = Invoke-FlowFixture -Fault provider-registering
        Assert-True (-not $run.Error -and $null -ne $run.Result -and $run.ProviderRegistrations.Count -eq 0) "In-progress registration was mishandled: $($run.Error)"
    }
    foreach ($fault in @('provider-denied', 'provider-stuck', 'provider-unregistering')) {
        Test-Case "$fault stops before certificate or Azure resource creation" {
            $run = Invoke-FlowFixture -Fault $fault
            Assert-True ($null -ne $run.Error -and $null -eq $run.Result -and $run.Trace -notcontains 'certificate') 'Provider failure did not stop resource creation.'
            Assert-True ($run.DeploymentNames.Count -eq 0 -and -not (Test-Path $run.Inputs.OutputDirectory)) 'Provider failure created deployment resources.'
            if ($fault -eq 'provider-denied') { Assert-True ($run.Error -match 'AuthorizationFailed' -and $run.Error -match '/register/action') 'Registration permission failure lost its cause or required permission.' }
            if ($fault -eq 'provider-stuck') { Assert-True ($run.Error -match '60 checks' -and $run.ProviderRegistrations.Count -eq 1) 'Registration did not have bounded polling/idempotent requests.' }
        }
    }
    Test-Case 'Regional registration propagation is retried without another approval or registration' {
        $run = Invoke-FlowFixture -Fault provider-region-delay
        Assert-True (-not $run.Error -and $run.PremiumChecks -eq 3 -and $run.ProviderRegistrations.Count -eq 0) "Regional provider readiness failed: $($run.Error)"
        $deployment = Invoke-FlowFixture -Fault deployment-registration-delay
        Assert-True (-not $deployment.Error -and $deployment.DeploymentNames.Count -eq 3) "Regional deployment retry failed: $($deployment.Error)"
        Assert-True (@($deployment.DeploymentNames | Select-Object -Unique).Count -eq 1) 'Registration retries changed deployment identity.'
        Assert-True (@($deployment.Trace | Where-Object { $_ -like 'prompt:Deploy*' }).Count -eq 1) 'Registration retry prompted again.'
    }
    Test-Case 'Registration retries are bounded and reject unrelated errors or namespaces' {
        $registrationTests = Import-Module $modulePath -Force -PassThru
        try {
            & $registrationTests {
                $script:RegistrationAttempts = 0
                function script:Start-Sleep { param($Seconds) }
                try {
                    Invoke-CyotRegistrationRetry -MaxAttempts 2 -Operation {
                        $script:RegistrationAttempts++
                        throw "MissingSubscriptionRegistration: namespace 'Microsoft.Web'."
                    }
                    throw 'Expected the registration retry limit.'
                }
                catch {
                    if ($_.Exception.Message -notmatch 'MissingSubscriptionRegistration' -or $script:RegistrationAttempts -ne 2) { throw }
                }
                foreach ($message in @(
                    "AuthorizationFailed: namespace 'Microsoft.Web'.",
                    "MissingSubscriptionRegistration: namespace 'Microsoft.Compute'.",
                    "MissingSubscriptionRegistration: namespace 'Microsoft.Web.Other'."
                )) {
                    if (Test-CyotRegistrationDelay $message) { throw "Unrelated error was considered registration propagation: $message" }
                }
            }
        }
        finally { Remove-Module -ModuleInfo $registrationTests }
    }
    Test-Case 'Elastic Premium region lookup uses the ARM tier/Linux filters and safe pagination' {
        $regionTests = Import-Module $modulePath -Force -PassThru
        $record = [pscustomobject]@{
            Scenario = 'paged'; Calls = 0; QueryPath = $null
            Queries = [Collections.Generic.List[object]]::new()
        }
        try {
            & $regionTests {
                param($record)
                $script:RegionFixture = $record
                function script:Invoke-CyotAz {
                    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
                    if ($Arguments[0] -ne 'rest') { throw 'Elastic Premium must not use the App Service CLI SKU enum.' }
                    $endpoint = 'https://management.azure.com/subscriptions/22222222-2222-2222-2222-222222222222/providers/Microsoft.Web/geoRegions'
                    if ($Arguments[([Array]::IndexOf($Arguments, '--url') + 1)] -cne $endpoint -or
                        $Arguments[([Array]::IndexOf($Arguments, '--subscription') + 1)] -ne '22222222-2222-2222-2222-222222222222') {
                        throw 'Region lookup changed its subscription or endpoint.'
                    }
                    $path = $Arguments[([Array]::IndexOf($Arguments, '--url-parameters') + 1)].Substring(1)
                    $query = Read-CyotJson $path
                    if ($query.sku -cne 'ElasticPremium' -or $query.linuxWorkersEnabled -cne 'true' -or $query.'api-version' -cne '2024-04-01') {
                        throw 'Region lookup substituted another plan tier or lost Linux filtering.'
                    }
                    $script:RegionFixture.QueryPath = $path
                    $script:RegionFixture.Queries.Add($query)
                    $script:RegionFixture.Calls++
                    $next = $endpoint + '?api-version=2024-04-01&sku=ElasticPremium&linuxWorkersEnabled=true&%24skipToken=next%26page%2Btoken'
                    switch ($script:RegionFixture.Scenario) {
                        'paged' {
                            if ($script:RegionFixture.Calls -eq 1) {
                                return @{ value = @(@{ name = 'East US' }); nextLink = $next } | ConvertTo-Json -Depth 4
                            }
                            return '{"value":[{"name":"West US 2"}]}'
                        }
                        'unavailable' { return '{"value":[]}' }
                        'malformed' { return '{"value":null}' }
                        'wrong-host' { return @{ value = @(); nextLink = 'https://untrusted.contoso.com/geoRegions' } | ConvertTo-Json }
                        'wrong-filter' { return @{ value = @(); nextLink = ($endpoint + '?sku=Premium') } | ConvertTo-Json }
                        'cycle' { return @{ value = @(); nextLink = $next } | ConvertTo-Json }
                        default { throw 'Unknown region fixture.' }
                    }
                }
                Assert-CyotPremiumLocation @{ SubscriptionId = '22222222-2222-2222-2222-222222222222'; Location = 'westus2' }
            } $record
            Assert-True ($record.Calls -eq 2 -and $record.Queries[1]['$skipToken'] -ceq 'next&page+token') 'Region pagination or query escaping failed.'
            Assert-True (-not (Test-Path -LiteralPath $record.QueryPath)) 'Temporary region-query file was not removed.'
            foreach ($case in @{
                unavailable = 'Linux Premium EP1 is unavailable'
                malformed = 'invalid Elastic Premium region response'
                'wrong-host' = 'invalid or repeated'
                'wrong-filter' = 'changed the approved'
                cycle = 'invalid or repeated'
            }.GetEnumerator()) {
                $record.Scenario = $case.Key
                $record.Calls = 0
                Assert-Throws {
                    & $regionTests { Assert-CyotPremiumLocation @{ SubscriptionId = '22222222-2222-2222-2222-222222222222'; Location = 'westus2' } }
                } $case.Value
                Assert-True (-not (Test-Path -LiteralPath $record.QueryPath)) 'A failed region lookup left its query file behind.'
            }
        }
        finally { Remove-Module -ModuleInfo $regionTests }
        $bicep = Get-Content (Join-Path $packageRoot 'infra/resources.bicep') -Raw
        Assert-True ($bicep -match "name: 'EP1'" -and $bicep -match "tier: 'ElasticPremium'") 'The region fix changed the deployed hosting plan.'
    }
    Test-Case 'Transient Function cold start is retried with Easy Auth enforced' {
        $run = Invoke-FlowFixture -Fault cold-start
        Assert-True (-not $run.Error -and $run.SyncAttempts -eq 3 -and $null -ne $run.Result) "Cold-start recovery failed: $($run.Error)"
    }
    Test-Case 'Transient host-runtime InternalServerError is retried' {
        $run = Invoke-FlowFixture -Fault host-runtime-internal
        Assert-True (-not $run.Error -and $run.SyncAttempts -eq 3 -and $null -ne $run.Result) "Host-runtime recovery failed: $($run.Error)"
    }
    Test-Case 'Unrelated InternalServerError is not retried' {
        $run = Invoke-FlowFixture -Fault unrelated-internal-error
        Assert-True ($null -ne $run.Error -and $run.SyncAttempts -eq 1 -and $null -eq $run.Result) 'An unrelated InternalServerError was treated as a transient host-startup response.'
    }
    Test-Case 'Rerun reuses the existing certificate encryption-key ID' {
        $run = Invoke-FlowFixture -Fault existing-key
        Assert-True (-not $run.Error -and $run.Result.encryptionKeyId -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') "Rerun rotated the key unexpectedly: $($run.Error)"
    }
    Test-Case 'Noninteractive setup requires all inputs and a separate explicit approval' {
        $missing = Invoke-FlowFixture -Overrides @{ NonInteractive = $true } -Omit ApplicationId -Answers @()
        Assert-True ($missing.Error -match 'ApplicationId is required' -and $missing.Trace.Count -eq 0) 'Missing input was defaulted or prompted.'
        $unapproved = Invoke-FlowFixture -Overrides @{ NonInteractive = $true } -Answers @()
        Assert-True ($unapproved.Error -match 'requires -ApproveDeployment' -and $unapproved.Trace -notcontains 'certificate') 'Noninteractive mode implicitly approved.'
        $approved = Invoke-FlowFixture -Overrides @{ NonInteractive = $true; ApproveDeployment = $true } -Answers @()
        Assert-True (-not $approved.Error -and $null -ne $approved.Result) "Explicit unattended deployment failed: $($approved.Error)"
        Assert-True (@($approved.Trace | Where-Object { $_ -like 'prompt:*' }).Count -eq 0) 'Unattended deployment prompted.'
    }
    Test-Case 'Disabled and malformed profiles still fail before Azure calls' {
        $disabled = New-ValidProfile
        $disabled.deployment.enabled = $false
        foreach ($json in @(($disabled | ConvertTo-Json -Depth 15), '{ broken json')) {
            $run = Invoke-FlowFixture -ProfileJson $json -Overrides @{ NonInteractive = $true; ApproveDeployment = $true } -Answers @()
            Assert-True ($null -ne $run.Error -and $run.Trace -notcontains 'preflight' -and $run.Trace -notcontains 'certificate') 'Bad profile reached Azure.'
        }
    }
    foreach ($fault in @('profile-download', 'preflight', 'package', 'build')) {
        Test-Case "$fault failure occurs before approval and mutations" {
            $run = Invoke-FlowFixture -Fault $fault -Answers @()
            Assert-True ($null -ne $run.Error -and $run.Trace -notcontains 'certificate') 'Failed preflight reached mutation.'
            Assert-True (@($run.Trace | Where-Object { $_ -like 'prompt:*' }).Count -eq 0) 'Failure requested approval anyway.'
        }
    }
    foreach ($fault in @('deployment', 'names', 'key', 'auth', 'sync', 'host-unavailable', 'host-runtime-internal-persistent', 'function-missing', 'enable')) {
        Test-Case "$fault failure cannot report success or leave public ingress open" {
            $run = Invoke-FlowFixture -Fault $fault
            Assert-True ($null -ne $run.Error -and $null -eq $run.Result) 'A failed deployment reported success.'
            Assert-True ($run.Access -eq 'Disabled') 'Public ingress remained open after a failure.'
            Assert-True (@(Get-ChildItem $run.Inputs.OutputDirectory -Filter 'deployment-*.json').Count -eq 0) 'A success summary was written on failure.'
            if ($fault -in @('host-unavailable', 'host-runtime-internal-persistent')) {
                Assert-True ($run.SyncAttempts -eq 12) 'Host readiness retries were not bounded.'
            }
        }
    }
    Test-Case 'Failure to close ingress is reported explicitly alongside the deployment error' {
        $run = Invoke-FlowFixture -Fault cleanup
        Assert-True ($run.Error -match 'public ingress could not be disabled' -and $null -eq $run.Result) 'Cleanup failure was hidden.'
    }
    foreach ($language in @('javascript', 'dotnet', 'python')) {
        Test-Case "$language automatically deploys code and actual dummy environment settings" {
            $profile = Get-Content (Join-Path $packageRoot 'providers/telesign.json') -Raw
            $run = Invoke-FlowFixture -ProfileJson $profile -Overrides @{ Language = $language }
            Assert-True (-not $run.Error -and $run.Result.language -eq $language) "Language deployment failed: $($run.Error)"
            Assert-True ($run.Parameters.language.value -eq $language) 'Bicep did not receive the selected runtime.'
            Assert-True ($run.Result.testConfiguration -and $run.Parameters.providerSettings.value.EPP_PROVIDER_TEST_CONFIGURATION -ceq 'true') 'Test configuration was not labelled in actual app settings.'
            Assert-True ($run.Parameters.providerSettings.value.EPP_PROVIDER_ENDPOINT -ceq 'https://rest-ww.telesign.com/integration/microsoft-cyot/sms') 'The selected provider route was not passed to Azure settings.'
            Assert-True ($run.Parameters.providerSettings.value.EPP_PROVIDER_AUTH_MODE -ceq 'apiKey') 'The provider authentication contract was misrepresented.'
            if ($language -eq 'dotnet') {
                Assert-True ($run.Result.sourcePackageSha256 -cne $run.Result.packageSha256) '.NET source was treated as compiled output.'
            }
            if ($language -eq 'python') {
                Assert-True ($run.Trace -contains 'python-remote-build' -and $run.Result.sourcePackageSha256 -cne $run.Result.packageSha256) 'Python source was not built remotely.'
                Assert-True ($run.WrittenSettings.ExistingSetting -ceq 'preserve-me' -and $run.WrittenSettings.WEBSITE_RUN_FROM_PACKAGE -like '*.blob.core.windows.net/packages/*.zip') 'Built Python output was not wired to managed-identity package storage.'
                Assert-True (-not $run.WrittenSettings.Contains('SCM_RUN_FROM_PACKAGE') -and $run.WrittenSettings.SCM_DO_BUILD_DURING_DEPLOYMENT -ceq 'false') 'Stale remote-build settings survived final publication.'
            }
        }
    }
    Test-Case 'Python remote build failure cannot mount a source archive or leave ingress open' {
        $run = Invoke-FlowFixture -Overrides @{ Language = 'python' } -Fault python-build
        Assert-True ($run.Error -match 'Python remote-build failure' -and $run.Access -eq 'Disabled' -and $null -eq $run.Result) 'Python build failure reported success or left ingress open.'
        Assert-True ($run.Trace -notcontains 'az:storage blob upload' -and $null -eq $run.WrittenSettings) 'A failed Python source build was published anyway.'
    }
    $packageTests = Import-Module $modulePath -Force -PassThru
    try {
        Test-Case 'Language catalog exactly matches the three documented release choices' {
            $expected = @{
                javascript = 'epp-provider-auth-preview-20260915/epp-javascript.zip'
                dotnet = 'epp-provider-auth-preview-20260915/epp-dotnet-source.zip'
                python = 'epp-provider-auth-preview-20260915/epp-python-source.zip'
            }
            $catalog = Get-Content (Join-Path $packageRoot 'packages/catalog.json') -Raw | ConvertFrom-Json
            Assert-True ($catalog.packages.Count -eq 3) 'Language menu must contain exactly three choices.'
            foreach ($language in $expected.Keys) {
                $selection = & $packageTests {
                    param($root, $language)
                    Get-CyotLanguage -AssetDirectory $root -Language $language -SourceRepository 'siyixian/ExternalPhoneProvider-AzureFunction-Sample' -NonInteractive
                } $packageRoot $language
                Assert-True ($selection.Url -ceq "https://github.com/siyixian/ExternalPhoneProvider-AzureFunction-Sample/releases/download/$($expected[$language])") "Wrong release for $language."
            }
            $dotnet = & $packageTests { param($root) Get-CyotLanguage $root '.NET' 'siyixian/ExternalPhoneProvider-AzureFunction-Sample' -NonInteractive } $packageRoot
            Assert-True ($dotnet.Id -eq 'dotnet') '.NET display-name selection failed.'
        }
        Test-Case 'Published checksums require one exact filename and cannot fall back to another asset' {
            $hash = 'a' * 64
            $text = "$hash  different.zip`r`n$hash *endpoint.zip`r`n"
            $result = & $packageTests { param($text) Get-CyotPublishedChecksum $text endpoint.zip } $text
            Assert-True ($result -ceq $hash) 'Valid release checksum was not parsed.'
            Assert-Throws { & $packageTests { param($text) Get-CyotPublishedChecksum $text missing.zip } $text } 'exactly one'
            Assert-Throws { & $packageTests { param($text) Get-CyotPublishedChecksum ($text + $text) endpoint.zip } $text } 'exactly one'
            Assert-Throws { & $packageTests { Get-CyotPublishedChecksum 'not-a-hash endpoint.zip' endpoint.zip } } 'exactly one'
        }
        Test-Case 'Source .NET/Python archives cannot pass as runnable deployment packages' {
            foreach ($language in @('dotnet', 'python')) {
                $path = Join-Path $testRoot "$language-source-only.zip"
                $entries = if ($language -eq 'dotnet') { @('host.json', 'dotnet.csproj') } else { @('host.json', 'function_app.py', 'requirements.txt') }
                New-ArchiveFixture -Path $path -Entries $entries
                & $packageTests { param($path, $language) Assert-CyotArchive $path $language source } $path $language
                Assert-Throws { & $packageTests { param($path, $language) Assert-CyotArchive $path $language ready } $path $language } 'required deployment path'
            }
        }
        Test-Case '.NET publishing invokes the Linux build automatically and repackages publish output' {
            $directory = Join-Path $testRoot 'dotnet-build'
            New-Item -ItemType Directory -Path $directory | Out-Null
            $sourceZip = Join-Path $directory 'source.zip'
            New-ArchiveFixture -Path $sourceZip -Entries @('host.json', 'dotnet.csproj')
            $record = [pscustomobject]@{ Arguments = $null; MissingSdk = $false }
            $path = & $packageTests {
                param($record, $source, $directory)
                $script:BuildFixture = $record
                function script:Get-Command { param($Name, $ErrorAction) return [pscustomobject]@{ Name = $Name } }
                function script:Invoke-CyotDotNet {
                    param([string[]] $Arguments)
                    if ($Arguments[0] -eq '--list-sdks') {
                        if ($script:BuildFixture.MissingSdk) { return '9.0.100 [sdk]' }
                        return "8.0.100 [sdk]`n9.0.100 [sdk]"
                    }
                    $script:BuildFixture.Arguments = $Arguments
                    $directory = $Arguments[([Array]::IndexOf($Arguments, '--output') + 1)]
                    New-Item -ItemType Directory -Path $directory | Out-Null
                    foreach ($name in @('host.json', 'worker.config.json', 'functions.metadata', 'app.dll')) {
                        '{}' | Set-Content -LiteralPath (Join-Path $directory $name)
                    }
                    return ''
                }
                Build-CyotDotNetPackage -SourcePath $source -Directory $directory
            } $record $sourceZip $directory
            Assert-True ($record.Arguments -contains '-p:UseAppHost=false' -and $record.Arguments -contains 'linux-x64') 'Linux build flags were lost or interpreted as PowerShell parameters.'
            & $packageTests { param($path) Assert-CyotArchive $path dotnet ready } $path
            $record.MissingSdk = $true
            Assert-Throws { & $packageTests { param($source, $dir) Build-CyotDotNetPackage $source $dir } $sourceZip $directory } '.NET 8 SDK'
        }
    }
    finally { Remove-Module -ModuleInfo $packageTests }
    Test-Case 'Python remote build uses Entra SCM access and validates the built dependency payload' {
        $directory = Join-Path $testRoot 'python-build'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $builtZip = Join-Path $directory 'built-fixture.zip'
        $entries = @('host.json', 'function_app.py', 'requirements.txt',
            '.python_packages/lib/site-packages/azure/functions/__init__.py',
            '.python_packages/lib/site-packages/certifi/cacert.pem')
        New-ArchiveFixture -Path $builtZip -Entries $entries
        $record = [pscustomobject]@{ Calls = [Collections.Generic.List[object]]::new(); Uri = $null; Auth = $null; FixtureZip = $builtZip }
        $pythonTests = Import-Module $modulePath -Force -PassThru
        try {
            $path = & $pythonTests {
                param($record, $directory)
                $script:PythonFixture = $record
                function script:Invoke-CyotAz {
                    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
                    $script:PythonFixture.Calls.Add($Arguments)
                    if ($Arguments[0] -eq 'functionapp') { return '' }
                    if ($Arguments[0] -eq 'rest') {
                        return '{"properties":{"enabledHostNames":["fixture.azurewebsites.net","fixture.scm.azurewebsites.net"]}}'
                    }
                    if ($Arguments[0] -eq 'account') { return 'synthetic-access-token' }
                    throw 'Unexpected Azure operation.'
                }
                function script:Invoke-WebRequest {
                    param($Uri, $Authentication, [Security.SecureString] $Token, $OutFile, $TimeoutSec, $MaximumRedirection)
                    if (-not $Token -or $MaximumRedirection -ne 0) { throw 'SCM token handling is not constrained.' }
                    $script:PythonFixture.Uri = $Uri
                    $script:PythonFixture.Auth = $Authentication
                    Copy-Item -LiteralPath $script:PythonFixture.FixtureZip -Destination $OutFile -Force
                }
                $inputs = @{ SubscriptionId = '22222222-2222-2222-2222-222222222222' }
                $names = @{ resourceGroup = 'fixture-rg'; functionApp = 'fixture' }
                Build-CyotPythonPackage $inputs $names '/subscriptions/fixture/sites/fixture' 'source.zip' $directory
            } $record $directory
            Assert-True ($record.Calls[0] -contains '--build-remote' -and $record.Calls[0] -contains 'true') 'Remote build was not requested.'
            Assert-True ($record.Auth -eq 'Bearer' -and $record.Uri -ceq 'https://fixture.scm.azurewebsites.net/api/zip/site/wwwroot/') 'SCM used the wrong authentication or download path.'
            Assert-True ((Get-FileHash $path).Hash -eq (Get-FileHash $builtZip).Hash) 'Built payload changed during download.'
            $sourceOnly = Join-Path $directory 'source-fixture.zip'
            New-ArchiveFixture -Path $sourceOnly -Entries @('host.json', 'function_app.py', 'requirements.txt')
            $record.FixtureZip = $sourceOnly
            Assert-Throws {
                & $pythonTests {
                    param($directory)
                    Build-CyotPythonPackage @{ SubscriptionId = '22222222-2222-2222-2222-222222222222' } `
                        @{ resourceGroup = 'fixture-rg'; functionApp = 'fixture' } '/subscriptions/fixture/sites/fixture' 'source.zip' $directory
                } $directory
            } 'azure/functions'
        }
        finally { Remove-Module -ModuleInfo $pythonTests }
    }
    Test-Case 'Azure CLI stderr warnings cannot corrupt a successful JSON response' {
        $cliTests = Import-Module $modulePath -Force -PassThru
        try {
            & $cliTests {
                $WarningPreference = 'SilentlyContinue'
                function script:az {
                    Write-Error 'Synthetic SDK warning on stderr.' -ErrorAction Continue
                    $global:LASTEXITCODE = 0
                    '{"id":"expected"}'
                }
                $value = Invoke-CyotAz account show --output json | ConvertFrom-Json
                if ($value.id -cne 'expected') { throw 'CLI stderr polluted JSON.' }
            }
        }
        finally { Remove-Module -ModuleInfo $cliTests }
    }
    Test-Case 'No registration, policy, or legacy CLI provisioning scripts remain' {
        $manifest = Import-PowerShellDataFile (Join-Path $packageRoot 'CYOT-Setup.psd1')
        Assert-True ($manifest.Support.Count -eq 2 -and -not $manifest.ContainsKey('Stages')) 'Old stage manifest remains.'
        $support = Get-Content $modulePath -Raw
        Assert-True ($support -notmatch '\bNew-MgApplication\b|authenticationMethodsPolicy|Policy\.ReadWrite|ApprovePolicyActivation') 'Automated registration/policy calls remain.'
        Assert-True ($support -notmatch 'functionapp create|keyvault create|group create') 'A second CLI resource-provisioning path remains.'
        $bicep = Get-Content (Join-Path $packageRoot 'infra/resources.bicep') -Raw
        Assert-True ($bicep -match "publicNetworkAccess: 'Disabled'" -and $bicep -match 'allowedApplications: \[callerApplicationId\]' -and $bicep -match "unauthenticatedClientAction: 'Return401'") 'Platform authentication gates regressed.'
        Assert-True ($bicep -notmatch 'uniqueString\(|var namePrefix') 'Bicep independently recomputes the approved names.'
    }
}
finally {
    $script:testCertificate.Dispose()
    $rsa.Dispose()
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

if ($failures.Count) { throw "CYOT smoke tests failed:`n$($failures -join "`n")" }
Write-Host "All $passed CYOT setup smoke tests passed." -ForegroundColor Green
