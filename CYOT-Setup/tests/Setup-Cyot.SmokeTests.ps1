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
$source = 'https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/CYOT-Setup'
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
    $profile.deployment.providerTenantId = '44444444-4444-4444-4444-444444444444'
    $profile.deployment.providerScope = 'api://55555555-5555-5555-5555-555555555555/.default'
    $profile.deployment.providerEndpoint = 'https://provider.contoso.com/cyot'
    $profile.metadata.endpoints.sms.appId = '55555555-5555-5555-5555-555555555555'
    $profile.metadata.endpoints.voice.appId = '55555555-5555-5555-5555-555555555555'
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
                @'
function Invoke-CyotSetup {
    param($AssetDirectory, $SourceBaseUri, $SourceRepository, $TenantId, $ResourcePrefix, $OutputDirectory)
    [pscustomobject]@{ Invoked = $true; Source = $SourceBaseUri; Repository = $SourceRepository; Tenant = $TenantId; Prefix = $ResourcePrefix }
}
Export-ModuleMember -Function Invoke-CyotSetup
'@ | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM
            }
            elseif ($scenario.Fault -eq 'empty') { [IO.File]::WriteAllText($OutFile, '') }
            else { '{}' | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM }
        }
        Push-Location $scenario.Directory
        try {
            $scenario.Result = & (Join-Path $scenario.Directory 'Setup-Cyot.ps1') -SourceRef $scenario.SourceRef `
                -SourceRepository $scenario.SourceRepository -TenantId '11111111-1111-1111-1111-111111111111' -ResourcePrefix contoso
        }
        catch { $scenario.Error = $_.Exception.Message }
        finally { Pop-Location }
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
        Location = 'westus2'; Provider = 'telesign'; ProviderAccountName = 'test-sender'; ResourcePrefix = 'contoso'
        Language = 'javascript'
        OutputDirectory = Join-Path $directory 'output'; AssetDirectory = $directory; SourceBaseUri = $source
    }
    foreach ($name in $Omit) { $inputs.Remove($name) }
    foreach ($name in $Overrides.Keys) { $inputs[$name] = $Overrides[$name] }
    $scenario = [pscustomobject]@{
        Inputs = $inputs; Fault = $Fault; ProfileJson = $ProfileJson; Directory = $directory
        Answers = [Collections.Generic.Queue[string]]::new()
        Trace = [Collections.Generic.List[string]]::new()
        Parameters = $null; Context = $null; ResolvedInputs = $null; Result = $null; Error = $null; Text = ''; SyncAttempts = 0
        Access = 'Disabled'; WrittenSettings = $null; Federation = $null
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
            function script:Connect-CyotContext {
                param($Inputs, $Names, [switch] $NonInteractive)
                $script:Fixture.Trace.Add('preflight')
                if ($script:Fixture.Fault -eq 'preflight') { throw 'Simulated preflight failure.' }
                $script:Fixture.ResolvedInputs = $Inputs
                $context = [pscustomobject]@{
                    OperatorId = '66666666-6666-6666-6666-666666666666'; GraphAccount = 'operator@contoso.com'; TokenVersion = 1
                    Application = [pscustomobject]@{ Id = '77777777-7777-7777-7777-777777777777'; KeyCredentials = @() }
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
                if ($Arguments[0] -eq 'deployment') {
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
    param([string] $Fault)

    $scenario = [pscustomobject]@{ Fault = $Fault; Result = $null; Error = $null; Calls = [Collections.Generic.List[string]]::new() }
    $module = Import-Module $modulePath -Force -PassThru
    try {
        $scenario.Result = & $module {
            param($scenario)
            $script:ContextFixture = $scenario
            function script:Get-Command { param($Name, $ErrorAction) return [pscustomobject]@{ Name = $Name } }
            function script:Import-Module { param($Name, $ErrorAction) }
            function script:Get-MgContext {
                return [pscustomobject]@{
                    TenantId = '11111111-1111-1111-1111-111111111111'
                    Environment = 'Global'; AuthType = 'Delegated'; Account = 'operator@contoso.com'
                    Scopes = $(if ($script:ContextFixture.Fault -eq 'scope') { @() } else { @('Application.ReadWrite.All') })
                }
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
                    'rest --method' { return '66666666-6666-6666-6666-666666666666' }
                    'group exists' { return $(if ($script:ContextFixture.Fault -eq 'unowned-group') { 'true' } else { 'false' }) }
                    'group show' { return '{}' }
                    'provider show' {
                        return @{
                            registrationState = $(if ($script:ContextFixture.Fault -eq 'unregistered') { 'NotRegistered' } else { 'Registered' })
                            resourceTypes = @('sites', 'storageAccounts', 'vaults', 'workspaces', 'components', 'userAssignedIdentities') |
                                ForEach-Object { @{ resourceType = $_; locations = @('West US 2') } }
                        } | ConvertTo-Json -Depth 5
                    }
                    'appservice list-locations' { return $(if ($script:ContextFixture.Fault -eq 'region') { '[]' } else { '["West US 2"]' }) }
                    default { throw "Unexpected operation during read-only preflight: $operation" }
                }
            }
            $inputs = @{
                TenantId = '11111111-1111-1111-1111-111111111111'; SubscriptionId = '22222222-2222-2222-2222-222222222222'
                ApplicationId = '33333333-3333-3333-3333-333333333333'; Location = 'westus2'; Language = 'javascript'
            }
            $names = Get-CyotResourceNames $inputs.SubscriptionId $inputs.ApplicationId contoso
            Connect-CyotContext -Inputs $inputs -Names $names -NonInteractive
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
        Assert-True (@($run.Downloads | Where-Object { $_.Uri -notlike "$source/*" }).Count -eq 0) 'Mixed or untrusted source revisions.'
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
        $expected = "https://raw.githubusercontent.com/$repository/$('a' * 40)/CYOT-Setup/"
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

    $module = Import-Module $modulePath -Force -PassThru
    try {
        Test-Case 'Telesign manifest retains exact channel URLs, timings, and publisher tenant' {
            $profile = New-ValidProfile
            Assert-True ($profile.publisher.tenantId -eq 'd818b557-ea1c-4070-a3f1-928330b7a30c') 'Publisher was changed.'
            Assert-True ($profile.metadata.endpoints.sms.url -ceq 'https://rest-ww.telesign.com/integration/microsoft-cyot/sms') 'SMS URL was changed.'
            Assert-True ($profile.metadata.endpoints.voice.url -ceq 'https://rest-ww.telesign.com/integration/microsoft-cyot/voice') 'Voice URL was changed.'
            $result = & $module { param($profile) ConvertTo-CyotProviderSettings $profile telesign Telesign } $profile
            Assert-True ($result.Settings.EPP_PROVIDER_TIMEOUT_MS -ceq '1500' -and $result.Settings.EPP_PROVIDER_RETRY_INTERVAL_MS -ceq '30000') 'Seconds were not converted to milliseconds exactly.'
            Assert-True ($result.Settings.EPP_PROVIDER_ENDPOINT -ceq 'https://provider.contoso.com/cyot') 'A channel URL was guessed instead of the approved mapping.'
        }
        foreach ($provider in @('telesign', 'soprano')) {
            Test-Case "$provider test values are explicit real app-setting strings" {
                $profile = Get-Content (Join-Path $packageRoot "providers/$provider.json") -Raw | ConvertFrom-Json -AsHashtable
                $result = & $module { param($p, $id) ConvertTo-CyotProviderSettings $p $id $id } $profile $provider
                Assert-True ($result.IsTestConfiguration -and $result.Settings.EPP_PROVIDER_TEST_CONFIGURATION -ceq 'true') 'Dummy configuration was not labelled.'
                Assert-True ($result.Settings.EPP_PROVIDER_TENANT_ID -ceq '00000000-0000-0000-0000-000000000000') 'Dummy tenant was discarded.'
                Assert-True ($result.Settings.EPP_PROVIDER_ENDPOINT -ceq "https://$provider.example.invalid") 'Dummy endpoint was discarded.'
                $profile.deployment.testConfiguration = $false
                Assert-Throws { & $module { param($p, $id) ConvertTo-CyotProviderSettings $p $id $id } $profile $provider } 'not deployment-ready'
            }
        }
        foreach ($invalid in @(-1, 2147484, '30', 1.5)) {
            Test-Case "Reject invalid retry seconds '$invalid'" {
                $profile = New-ValidProfile
                $profile.metadata.endpoints.sms.retryIntervalSeconds = $invalid
                Assert-Throws { & $module { param($p) ConvertTo-CyotProviderSettings $p telesign Telesign } $profile } 'retryIntervalSeconds'
            }
        }
        foreach ($invalid in @(0, 2501, '1500')) {
            Test-Case "Reject invalid timeout '$invalid'" {
                $profile = New-ValidProfile
                $profile.metadata.endpoints.sms.timeoutMilliseconds = $invalid
                Assert-Throws { & $module { param($p) ConvertTo-CyotProviderSettings $p telesign Telesign } $profile } 'timeoutMilliseconds'
            }
        }
        Test-Case 'Do not flatten different per-channel timings or audiences' {
            $profile = New-ValidProfile
            $profile.metadata.endpoints.voice.retryIntervalSeconds = 31
            Assert-Throws { & $module { param($p) ConvertTo-CyotProviderSettings $p telesign Telesign } $profile } 'shared SMS/voice'
            $profile.metadata.endpoints.voice.retryIntervalSeconds = 30
            $profile.metadata.endpoints.voice.appId = '99999999-9999-9999-9999-999999999999'
            Assert-Throws { & $module { param($p) ConvertTo-CyotProviderSettings $p telesign Telesign } $profile } 'shared provider API'
        }
        foreach ($url in @('http://provider.contoso.com', 'https://127.0.0.1', 'https://localhost', 'https://provider.contoso.com?token=secret', 'https://user:pass@provider.contoso.com', 'https://provider.example.com')) {
            Test-Case "Reject unsafe or placeholder URL $($url.Split('?')[0])" {
                Assert-Throws { & $module { param($value) Assert-CyotHttpsUrl $value } $url } 'public HTTPS'
            }
        }
        Test-Case 'Resource names are stable, prefix-based, and valid at both length boundaries' {
            foreach ($prefix in @('ab', 'abcdefghij')) {
                $names = & $module { param($p) Get-CyotResourceNames '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222' $p } $prefix
                $again = & $module { param($p) Get-CyotResourceNames '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222' $p } $prefix
                Assert-True (($names | ConvertTo-Json -Compress) -ceq ($again | ConvertTo-Json -Compress)) 'Names changed between runs.'
                Assert-True (@($names.Values | Where-Object { -not $_.StartsWith($prefix) }).Count -eq 0) 'A resource lost its prefix.'
                Assert-True ($names.storageAccount -cmatch '^[a-z0-9]{3,24}$' -and $names.keyVault.Length -le 24 -and $names.functionApp.Length -le 60) 'Invalid Azure name lengths.'
            }
            Assert-Throws { & $module { Get-CyotResourceNames '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222' 'abcdefghijkl' } } 'ResourcePrefix'
        }
        Test-Case 'Source and catalog cannot redirect support execution or traverse directories' {
            Assert-Throws { & $module { param($root) Get-CyotProvider $root 'https://untrusted.contoso.com' telesign } $packageRoot } 'commit-pinned'
            $catalogDirectory = Join-Path $testRoot 'bad-catalog'
            New-Item -ItemType Directory -Path (Join-Path $catalogDirectory 'providers') -Force | Out-Null
            '{"schemaVersion":1,"providers":[{"id":"telesign","displayName":"Telesign","file":"../evil.ps1"}]}' |
                Set-Content (Join-Path $catalogDirectory 'providers/catalog.json')
            Assert-Throws { & $module { param($root, $src) Get-CyotProvider $root $src telesign } $catalogDirectory $source } 'invalid or duplicate'
            Assert-Throws { & $module { param($root, $src) Get-CyotProvider $root $src invalid } $packageRoot $source } 'telesign, soprano'
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
    }
    foreach ($fault in @('tenant', 'scope', 'single-tenant', 'encrypted-token', 'assignment', 'unowned-group', 'unregistered', 'region')) {
        Test-Case "Read-only preflight rejects $fault" {
            $run = Invoke-ContextFixture -Fault $fault
            Assert-True ($null -ne $run.Error -and $null -eq $run.Result) "Unsafe context was accepted: $fault"
            Assert-True ($run.Error -notmatch 'Unexpected operation|cannot be found') "Fixture failed for the wrong reason: $($run.Error)"
        }
    }
    Test-Case 'Only missing inputs prompt, then one language, provider, prefix, and approval' {
        $run = Invoke-FlowFixture -Omit TenantId, Location, Language, Provider, ResourcePrefix `
            -Answers @('', 'not-a-guid', '11111111-1111-1111-1111-111111111111', 'westus2', 'invalid', '1', 'invalid', '1', 'contoso', 'Yes')
        Assert-True (-not $run.Error) "Flow failed: $($run.Error)"
        Assert-True (@($run.Trace | Where-Object { $_ -like 'prompt:SubscriptionId*' -or $_ -like 'prompt:ApplicationId*' }).Count -eq 0) 'Supplied inputs were requested again.'
        Assert-True (@($run.Trace | Where-Object { $_ -like 'prompt:Deploy*' }).Count -eq 1) 'Extra deployment approvals appeared.'
        $trace = $run.Trace -join "`n"
        Assert-True ($trace -match '(?s)prompt:TenantId.*prompt:Location.*prompt:Language.*prompt:Provider.*download:.*prompt:ResourcePrefix.*preflight.*prompt:Deploy.*certificate.*az:deployment sub create') 'Input/approval/deployment order changed.'
        Assert-True ($trace -notmatch 'prompt:PackageUrl|prompt:PackageSha256') 'Customer was asked to find a package link or hash.'
        Assert-True ($run.Text.IndexOf('Deployment plan') -lt $run.Text.IndexOf('Deploying Bicep')) 'Deployment started before the preview.'
    }
    Test-Case 'Selected provider JSON uses the same fork and commit as the downloaded tools' {
        $repository = 'siyixian/ExternalPhoneProvider-AzureFunction-Sample'
        $forkSource = "https://raw.githubusercontent.com/$repository/$('a' * 40)/CYOT-Setup"
        $run = Invoke-FlowFixture -Overrides @{ SourceRepository = $repository; SourceBaseUri = $forkSource } -Answers @('No')
        Assert-True (-not $run.Error -and $run.Trace -contains "download:$forkSource/providers/telesign.json") "Provider did not use the fork: $($run.Error)"
        $mismatch = Invoke-FlowFixture -Overrides @{ SourceRepository = $repository } -Answers @()
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
        foreach ($name in $run.Parameters.resourceNames.value.Values) { Assert-True ($run.Text.Contains($name)) "Unpreviewed resource $name" }
        Assert-True (($run.Trace -join "`n") -match '(?s)az:deployment sub create.*private-key.*application-endpoint.*az:rest --method get.*az:storage blob upload.*public:Enabled.*az:functionapp restart.*az:rest --method post.*az:functionapp function list') 'Authentication/publication ordering changed.'
        Assert-True ($run.Federation -eq $false) 'API-key samples should not create an unnecessary federated application credential.'
        Assert-True ($run.Result.policyChanged -eq $false) 'Setup changed policy.'
        Assert-True (@(Get-ChildItem $run.Inputs.OutputDirectory -Filter 'deployment-*.json').Count -eq 1) 'No persistent summary was written.'
    }
    Test-Case 'Transient Function cold start is retried with Easy Auth enforced' {
        $run = Invoke-FlowFixture -Fault cold-start
        Assert-True (-not $run.Error -and $run.SyncAttempts -eq 3 -and $null -ne $run.Result) "Cold-start recovery failed: $($run.Error)"
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
    foreach ($fault in @('deployment', 'names', 'key', 'auth', 'sync', 'host-unavailable', 'function-missing', 'enable')) {
        Test-Case "$fault failure cannot report success or leave public ingress open" {
            $run = Invoke-FlowFixture -Fault $fault
            Assert-True ($null -ne $run.Error -and $null -eq $run.Result) 'A failed deployment reported success.'
            Assert-True ($run.Access -eq 'Disabled') 'Public ingress remained open after a failure.'
            Assert-True (@(Get-ChildItem $run.Inputs.OutputDirectory -Filter 'deployment-*.json').Count -eq 0) 'A success summary was written on failure.'
            if ($fault -eq 'host-unavailable') { Assert-True ($run.SyncAttempts -eq 12) 'Host readiness retries were not bounded.' }
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
            Assert-True ($run.Parameters.providerSettings.value.EPP_PROVIDER_TENANT_ID -ceq '00000000-0000-0000-0000-000000000000' -and
                $run.Parameters.providerSettings.value.EPP_PROVIDER_ENDPOINT -ceq 'https://telesign.example.invalid') 'Dummy values were not passed to Azure settings.'
            Assert-True ($run.Parameters.providerSettings.value.EPP_PROVIDER_AUTH_MODE -ceq 'apiKey') 'The package authentication contract was misrepresented.'
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
                javascript = 'epp-packages-preview-20260914/epp-javascript.zip'
                dotnet = 'epp-dotnet-source-preview-20260915/epp-dotnet-source.zip'
                python = 'epp-packages-preview-20260914/epp-python-source.zip'
            }
            $catalog = Get-Content (Join-Path $packageRoot 'packages/catalog.json') -Raw | ConvertFrom-Json
            Assert-True ($catalog.packages.Count -eq 3) 'Language menu must contain exactly three choices.'
            foreach ($language in $expected.Keys) {
                $selection = & $packageTests {
                    param($root, $language)
                    Get-CyotLanguage -AssetDirectory $root -Language $language -SourceRepository 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample' -NonInteractive
                } $packageRoot $language
                Assert-True ($selection.Url -ceq "https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/$($expected[$language])") "Wrong release for $language."
            }
            $dotnet = & $packageTests { param($root) Get-CyotLanguage $root '.NET' 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample' -NonInteractive } $packageRoot
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
