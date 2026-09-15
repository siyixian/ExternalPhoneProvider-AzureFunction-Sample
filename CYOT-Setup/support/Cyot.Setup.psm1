#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:MicrosoftPhoneProviderAppId = '25ec60fa-f18d-41a4-b398-50044c90ce13'

function Read-CyotJson {
    param([string] $Path)

    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($value -isnot [Collections.IDictionary]) { throw "Expected a JSON object in '$Path'." }
    return $value
}

function ConvertTo-CyotGuid {
    param([string] $Value)

    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref] $guid) -or $guid -eq [Guid]::Empty) {
        throw 'Use a nonempty GUID, not an application name or an all-zero placeholder.'
    }
    return $guid.ToString('D')
}

function Assert-CyotHttpsUrl {
    param([string] $Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.IsLoopback -or
        $uri.HostNameType -ne [UriHostNameType]::Dns -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.Host -notmatch '\.' -or $uri.Host -match '(?i)(^|\.)example\.(com|net|org)$') {
        throw 'Use a public HTTPS hostname on port 443, without credentials, a query string, or placeholders.'
    }
}

function Read-CyotInput {
    param(
        [string] $Name, [string] $Value, [string] $Hint,
        [ValidateSet('Text', 'Guid', 'Location', 'Prefix', 'PackageUrl', 'Hash')]
        [string] $Kind = 'Text',
        [switch] $NonInteractive,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample'
    )

    $supplied = -not [string]::IsNullOrWhiteSpace($Value)
    while ($true) {
        if (-not $supplied) {
            if ($NonInteractive) { throw "-$Name is required in noninteractive mode." }
            $Value = [string](Read-Host "$Name - $Hint")
        }
        $Value = $Value.Trim()
        try {
            if (-not $Value -or $Value -match '[\x00-\x1f<>]') { throw 'A nonempty value without placeholders is required.' }
            switch ($Kind) {
                'Guid' { $Value = ConvertTo-CyotGuid $Value }
                'Location' {
                    if ($Value -cnotmatch '^[a-z][a-z0-9]+$') { throw 'Use an Azure region name such as westus2.' }
                }
                'Prefix' {
                    if ($Value -cnotmatch '^[a-z][a-z0-9]{1,9}$') {
                        throw 'Use 2-10 lowercase letters or digits, starting with a letter (for example contoso).'
                    }
                }
                'PackageUrl' {
                    Assert-CyotHttpsUrl $Value
                    $repositories = @('Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample', $SourceRepository)
                    $allowed = @($repositories | Where-Object {
                        $Value -cmatch ('^https://github\.com/' + [regex]::Escape($_) + '/releases/download/[^/]+/[^/]+\.zip$')
                    })
                    if (-not $allowed.Count) {
                        throw 'Use a versioned ZIP release URL from the selected source repository or Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample.'
                    }
                }
                'Hash' {
                    if ($Value -notmatch '^[0-9a-fA-F]{64}$') { throw 'Use the package SHA-256 from its release checksums.' }
                    $Value = $Value.ToLowerInvariant()
                }
            }
            return $Value
        }
        catch {
            if ($supplied) { throw "Invalid -${Name}: $($_.Exception.Message)" }
            Write-Warning "$Name : $($_.Exception.Message)"
        }
    }
}

function Get-CyotProvider {
    param(
        [string] $AssetDirectory, [string] $SourceBaseUri, [string] $Provider, [switch] $NonInteractive,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample'
    )

    $sourcePattern = '^https://raw\.githubusercontent\.com/' + [regex]::Escape($SourceRepository) + '/[0-9a-fA-F]{40}/CYOT-Setup$'
    if ($SourceBaseUri -cnotmatch $sourcePattern) {
        throw 'Provider files must come from the same commit-pinned selected repository as the deployment tools.'
    }
    $catalog = Read-CyotJson (Join-Path $AssetDirectory 'providers/catalog.json')
    if ($catalog['schemaVersion'] -ne 1 -or -not $catalog['providers']) { throw 'Unsupported or empty provider catalog.' }
    $entries = @($catalog['providers'])
    $ids = @{}
    foreach ($entry in $entries) {
        if ($entry -isnot [Collections.IDictionary] -or $entry['id'] -cnotmatch '^[a-z][a-z0-9-]{1,31}$' -or
            $entry['file'] -cnotmatch '^[a-z][a-z0-9-]{1,31}\.json$' -or
            -not $entry['displayName'] -or $entry['displayName'] -match '[\x00-\x1f]' -or $ids.ContainsKey($entry['id'])) {
            throw 'Provider catalog contains an invalid or duplicate entry.'
        }
        $ids[$entry['id']] = $true
    }
    $providerIds = @($entries | ForEach-Object { $_['id'] })

    $selected = $null
    if ($Provider) {
        $selected = $entries | Where-Object { $_['id'] -eq $Provider } | Select-Object -First 1
        if (-not $selected) { throw "Unknown provider '$Provider'. Choose: $($providerIds -join ', ')." }
    }
    else {
        if ($NonInteractive) { throw "-Provider is required. Choose: $($providerIds -join ', ')." }
        Write-Host "`nChoose your provider:" -ForegroundColor Cyan
        for ($index = 0; $index -lt $entries.Count; $index++) {
            Write-Host "  [$($index + 1)] $($entries[$index]['displayName'])"
        }
        while (-not $selected) {
            $answer = ([string](Read-Host 'Provider number or name')).Trim()
            $number = 0
            if ([int]::TryParse($answer, [ref] $number) -and $number -ge 1 -and $number -le $entries.Count) {
                $selected = $entries[$number - 1]
            }
            else { $selected = $entries | Where-Object { $_['id'] -eq $answer } | Select-Object -First 1 }
            if (-not $selected) { Write-Warning 'Choose one of the listed providers.' }
        }
    }

    $path = Join-Path $AssetDirectory "providers/$($selected['file'])"
    Invoke-WebRequest -Uri "$SourceBaseUri/providers/$($selected['file'])" -OutFile $path -TimeoutSec 60 -MaximumRedirection 0
    $profile = Read-CyotJson $path
    return ConvertTo-CyotProviderSettings -Profile $profile -Id $selected['id'] -DisplayName $selected['displayName']
}

function ConvertTo-CyotProviderSettings {
    param([Collections.IDictionary] $Profile, [string] $Id, [string] $DisplayName)

    $issues = [Collections.Generic.List[string]]::new()
    $deployment = $Profile['deployment']
    if ($deployment -isnot [Collections.IDictionary]) { throw "Provider '$DisplayName' has no deployment configuration." }
    if ($deployment['enabled'] -isnot [bool] -or -not $deployment['enabled']) {
        $issues.Add('the provider owner has not enabled this profile')
    }
    if ($deployment['providerName'] -cne $Id) { $issues.Add('deployment.providerName must match the catalog ID') }
    try { $null = ConvertTo-CyotGuid $deployment['providerTenantId'] }
    catch { $issues.Add('deployment.providerTenantId must identify the confirmed provider API token tenant') }
    try { Assert-CyotHttpsUrl $deployment['providerEndpoint'] }
    catch { $issues.Add('deployment.providerEndpoint must be the provider-approved endpoint/base URL for the deployed package') }
    $scope = [string]$deployment['providerScope']
    $resource = $scope -replace '/\.default$', ''
    $resourceUri = $null
    $resourceGuid = [Guid]::Empty
    $validResource = ([Guid]::TryParse($resource, [ref] $resourceGuid) -and $resourceGuid -ne [Guid]::Empty) -or
        ([Uri]::TryCreate($resource, [UriKind]::Absolute, [ref] $resourceUri) -and
            $resourceUri.Scheme -in @('api', 'https') -and $resourceUri.Host -and
            -not $resourceUri.UserInfo -and -not $resourceUri.Query -and -not $resourceUri.Fragment)
    if (-not $validResource -or $scope -notmatch '/\.default$' -or $scope -match '[\s<>]') {
        $issues.Add('deployment.providerScope must be the provider API resource followed by /.default')
    }

    $metadata = $Profile['metadata']
    if ($metadata -isnot [Collections.IDictionary] -or $metadata['endpoints'] -isnot [Collections.IDictionary]) {
        throw "Provider '$DisplayName' is missing metadata.endpoints."
    }
    $timings = @()
    $applicationIds = @()
    foreach ($channel in @('sms', 'voice')) {
        $endpoint = $metadata['endpoints'][$channel]
        if ($endpoint -isnot [Collections.IDictionary]) { $issues.Add("metadata.endpoints.$channel is missing"); continue }
        try { Assert-CyotHttpsUrl $endpoint['url'] }
        catch { $issues.Add("metadata.endpoints.$channel.url must be a public HTTPS endpoint") }
        try { $applicationIds += ConvertTo-CyotGuid $endpoint['appId'] }
        catch { $issues.Add("metadata.endpoints.$channel.appId is missing or invalid") }
        $timeout = $endpoint['timeoutMilliseconds']
        $retry = $endpoint['retryIntervalSeconds']
        if (($timeout -isnot [long] -and $timeout -isnot [int]) -or $timeout -lt 1 -or $timeout -gt 2500) {
            $issues.Add("metadata.endpoints.$channel.timeoutMilliseconds must be an integer from 1 to 2500")
        }
        if (($retry -isnot [long] -and $retry -isnot [int]) -or $retry -lt 0 -or $retry -gt 2147483) {
            $issues.Add("metadata.endpoints.$channel.retryIntervalSeconds must be a nonnegative integer fitting Int32 milliseconds")
        }
        $timings += [pscustomobject]@{ Timeout = $timeout; Retry = $retry }
    }
    if (@($applicationIds | Select-Object -Unique).Count -gt 1) {
        $issues.Add('the current endpoint package requires a shared provider API application/scope for SMS and voice')
    }
    if ($timings.Count -eq 2 -and ($timings[0].Timeout -ne $timings[1].Timeout -or $timings[0].Retry -ne $timings[1].Retry)) {
        $issues.Add('the current endpoint package requires shared SMS/voice timeout and retry settings')
    }
    if ($issues.Count) {
        throw "Provider '$DisplayName' is not deployment-ready:`n - $($issues -join "`n - ")`nAsk the provider owner to complete its GitHub JSON. No Azure resources were changed."
    }
    return [pscustomobject]@{
        Id = $Id
        DisplayName = $DisplayName
        Manifest = $Profile
        Settings = @{
            EPP_PROVIDER_NAME = $Id
            EPP_PROVIDER_ENDPOINT = [string]$deployment['providerEndpoint']
            EPP_PROVIDER_TIMEOUT_MS = [string]$timings[0].Timeout
            EPP_PROVIDER_RETRY_INTERVAL_MS = [string]([long]$timings[0].Retry * 1000)
            EPP_PROVIDER_AUTH_MODE = 'ests'
            EPP_PROVIDER_TENANT_ID = ConvertTo-CyotGuid $deployment['providerTenantId']
            EPP_PROVIDER_SCOPE = $scope
        }
    }
}

function Get-CyotResourceNames {
    param([string] $SubscriptionId, [string] $ApplicationId, [string] $ResourcePrefix)

    if ($ResourcePrefix -cnotmatch '^[a-z][a-z0-9]{1,9}$') { throw 'ResourcePrefix must be 2-10 lowercase letters/digits, starting with a letter.' }
    $seed = "$(ConvertTo-CyotGuid $SubscriptionId)|$(ConvertTo-CyotGuid $ApplicationId)|$ResourcePrefix"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $suffix = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))) -replace '-', '').Substring(0, 8).ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [ordered]@{
        resourceGroup = "$ResourcePrefix-rg-$suffix"
        functionApp = "$ResourcePrefix-func-$suffix"
        storageAccount = "${ResourcePrefix}sa$suffix"
        keyVault = "$ResourcePrefix-kv-$suffix"
        hostingPlan = "$ResourcePrefix-plan-$suffix"
        logAnalytics = "$ResourcePrefix-logs-$suffix"
        applicationInsights = "$ResourcePrefix-insights-$suffix"
        outboundIdentity = "$ResourcePrefix-outbound-$suffix"
    }
}

function Invoke-CyotAz {
    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)

    $PSNativeCommandUseErrorActionPreference = $false
    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output -join "`n") -replace '(?i)([?&](?:sig|token|code|client_secret|password)=)[^&\s]+', '$1[REDACTED]'
        $message = $message -replace '(?i)(Bearer\s+)[^\s,;]+', '$1[REDACTED]'
        throw "Azure CLI operation '$($Arguments[0]) $($Arguments[1])' failed (exit $LASTEXITCODE): $message"
    }
    return $output -join "`n"
}

function Invoke-CyotDataOperation {
    param([scriptblock] $Operation)

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try { return & $Operation }
        catch {
            if ($attempt -eq 12 -or $_.Exception.Message -notmatch 'ForbiddenByRbac|AuthorizationPermissionMismatch|Caller is not authorized to perform action on resource') { throw }
            Write-Warning "Waiting for the new data-plane role assignment ($attempt/12)."
            Start-Sleep -Seconds 10
        }
    }
}

function Connect-CyotContext {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, [switch] $NonInteractive)

    foreach ($command in @('az', 'New-SelfSignedCertificate', 'Export-Certificate')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Missing prerequisite '$command'. Use PowerShell 7 on Windows with Azure CLI; see the setup prerequisites."
        }
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Applications -ErrorAction Stop
    $account = Invoke-CyotAz account show --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json
    if ($account.id -ne $Inputs.SubscriptionId -or $account.tenantId -ne $Inputs.TenantId -or
        $account.state -ne 'Enabled' -or $account.environmentName -ne 'AzureCloud' -or $account.user.type -ne 'user') {
        throw 'Azure CLI must be signed in as a user to the requested enabled subscription and tenant in the public Azure cloud.'
    }
    $operatorId = Invoke-CyotAz rest --method get --url 'https://graph.microsoft.com/v1.0/me' `
        --subscription $Inputs.SubscriptionId --query id --output tsv
    $operatorId = ConvertTo-CyotGuid $operatorId
    $graph = Get-MgContext
    if (-not $graph -or $graph.TenantId -ne $Inputs.TenantId -or $graph.Environment -ne 'Global' -or
        $graph.AuthType -ne 'Delegated' -or $graph.Scopes -notcontains 'Application.ReadWrite.All') {
        if ($NonInteractive) { throw 'Connect-MgGraph to the customer tenant with Application.ReadWrite.All before noninteractive setup.' }
        Connect-MgGraph -TenantId $Inputs.TenantId -Scopes 'Application.ReadWrite.All' -ContextScope Process -NoWelcome
        $graph = Get-MgContext
    }
    if (-not $graph -or $graph.TenantId -ne $Inputs.TenantId -or $graph.Environment -ne 'Global' -or
        $graph.AuthType -ne 'Delegated' -or $graph.Scopes -notcontains 'Application.ReadWrite.All') {
        throw 'Microsoft Graph is not connected to the required customer tenant with delegated application permissions.'
    }
    $applications = @(Get-MgApplication -Filter "appId eq '$($Inputs.ApplicationId)'" -All -ErrorAction Stop)
    if ($applications.Count -ne 1) { throw 'Complete manual Step 1: exactly one existing application with this client ID is required.' }
    $application = Get-MgApplication -ApplicationId $applications[0].Id `
        -Property Id, AppId, DisplayName, SignInAudience, Api, IdentifierUris, KeyCredentials, TokenEncryptionKeyId -ErrorAction Stop
    if ($application.SignInAudience -ne 'AzureADMultipleOrgs') { throw 'The existing CYOT application must be organizational multi-tenant. Complete manual Step 1.' }
    if ($application.TokenEncryptionKeyId) { throw 'Clear tokenEncryptionKeyId manually on the endpoint app. Easy Auth requires signed, not encrypted, bearer access tokens.' }
    $principals = @(Get-MgServicePrincipal -Filter "appId eq '$($Inputs.ApplicationId)'" -All -ErrorAction Stop)
    if ($principals.Count -ne 1 -or $principals[0].AppRoleAssignmentRequired) {
        throw 'Complete manual Step 1: the endpoint enterprise application must exist with assignment required disabled. Setup will not change it.'
    }
    $version = if ($application.Api -and $application.Api.RequestedAccessTokenVersion) { [int]$application.Api.RequestedAccessTokenVersion } else { 1 }
    if ($version -notin @(1, 2)) { throw 'The endpoint application has an unsupported access-token version.' }

    $groupExists = Invoke-CyotAz group exists --name $Names.resourceGroup --subscription $Inputs.SubscriptionId --output tsv
    if ($groupExists -eq 'true') {
        $tags = Invoke-CyotAz group show --name $Names.resourceGroup --subscription $Inputs.SubscriptionId --query tags --output json |
            ConvertFrom-Json -AsHashtable
        if (-not $tags -or $tags['cyotApplicationId'] -ne $Inputs.ApplicationId -or $tags['managedBy'] -ne 'CYOT-Setup') {
            throw "Resource group '$($Names.resourceGroup)' is not owned by this CYOT application. Choose another prefix; existing resources will not be adopted."
        }
    }
    elseif ($groupExists -ne 'false') { throw 'Azure returned an invalid resource-group existence result.' }

    foreach ($provider in @(
        @{ Namespace = 'Microsoft.Web'; Type = 'sites' },
        @{ Namespace = 'Microsoft.Storage'; Type = 'storageAccounts' },
        @{ Namespace = 'Microsoft.KeyVault'; Type = 'vaults' },
        @{ Namespace = 'Microsoft.OperationalInsights'; Type = 'workspaces' },
        @{ Namespace = 'Microsoft.Insights'; Type = 'components' },
        @{ Namespace = 'Microsoft.ManagedIdentity'; Type = 'userAssignedIdentities' }
    )) {
        $registration = Invoke-CyotAz provider show --namespace $provider.Namespace --subscription $Inputs.SubscriptionId --output json |
            ConvertFrom-Json
        if ($registration.registrationState -ne 'Registered') { throw "Register resource provider '$($provider.Namespace)' before setup." }
        $locations = @($registration.resourceTypes | Where-Object resourceType -eq $provider.Type | ForEach-Object locations)
        if (-not @($locations | Where-Object { ($_ -replace '[^a-zA-Z0-9]', '') -ieq $Inputs.Location }).Count) {
            throw "'$($provider.Namespace)/$($provider.Type)' is unavailable in '$($Inputs.Location)'. Choose another location."
        }
    }
    $premiumLocations = Invoke-CyotAz appservice list-locations --sku EP1 --linux-workers-enabled `
        --subscription $Inputs.SubscriptionId --query '[].name' --output json | ConvertFrom-Json
    if (-not @($premiumLocations | Where-Object { ($_ -replace '[^a-zA-Z0-9]', '') -ieq $Inputs.Location }).Count) {
        throw "Linux Premium EP1 is unavailable in '$($Inputs.Location)'."
    }
    return [pscustomobject]@{ OperatorId = $operatorId; GraphAccount = $graph.Account; Application = $application; TokenVersion = $version }
}

function Get-CyotPackage {
    param([string] $Url, [string] $Sha256, [string] $Directory)

    $path = Join-Path $Directory 'endpoint.zip'
    Invoke-WebRequest -Uri $Url -OutFile $path -TimeoutSec 300
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Sha256) {
        throw 'The downloaded Function package does not match PackageSha256. No Azure resources were changed.'
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $names = @($archive.Entries | ForEach-Object FullName)
        if (@($names | Where-Object { $_ -ceq 'host.json' }).Count -ne 1 -or
            @($names | Where-Object { $_ -ceq 'package.json' }).Count -ne 1) {
            throw 'Supply a ready-to-run Node.js Function ZIP with host.json and package.json at its root.'
        }
        if (@($names | Where-Object { $_ -match '\\|(^|/)\.\.?(/|$)|^/|^[a-zA-Z]:' }).Count) {
            throw 'The Function ZIP contains an absolute or traversing archive path.'
        }
        if (@($names | Where-Object { $_ -match '(?i)(^|/)(local\.settings[^/]*\.json|\.env(?:\.[^/]*)?|[^/]+\.(pfx|p12|pem|key))$' }).Count) {
            throw 'The Function ZIP contains local settings or key material. Do not deploy this package.'
        }
    }
    finally { $archive.Dispose() }
    return $path
}

function Show-CyotPlan {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration, $Context, [string] $SourceBaseUri)

    Write-Host "`nDeployment plan (create or update)" -ForegroundColor Cyan
    Write-Host "Tenant:       $($Inputs.TenantId)"
    Write-Host "Subscription: $($Inputs.SubscriptionId)"
    Write-Host "Application:  $($Inputs.ApplicationId)"
    Write-Host "Location:     $($Inputs.Location)"
    Write-Host "Provider:     $($ProviderConfiguration.DisplayName)"
    Write-Host "API endpoint: $($ProviderConfiguration.Settings.EPP_PROVIDER_ENDPOINT)"
    Write-Host "Provider API: $($ProviderConfiguration.Settings.EPP_PROVIDER_TENANT_ID) / $($ProviderConfiguration.Settings.EPP_PROVIDER_SCOPE)"
    Write-Host "Timeout:      $($ProviderConfiguration.Settings.EPP_PROVIDER_TIMEOUT_MS) ms"
    Write-Host "Retry:        $($ProviderConfiguration.Settings.EPP_PROVIDER_RETRY_INTERVAL_MS) ms (package-dependent; not a retry guarantee)"
    Write-Host "Package:      $($Inputs.PackageUrl)"
    Write-Host "SHA-256:      $($Inputs.PackageSha256)"
    Write-Host "Source:       $SourceBaseUri"
    $Names.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Resource = $_.Key; Name = $_.Value } } |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host 'Includes the private packages blob container, Function system identity, Easy Auth, and diagnostic settings.'
    Write-Host 'System identity: Storage Blob Data Owner, Queue/Table Data Contributor, Key Vault Secrets User, Monitoring Metrics Publisher.'
    Write-Host "Azure operator $($Context.OperatorId): Key Vault Secrets Officer and Storage Blob Data Contributor, scoped to these resources."
    Write-Host "Graph operator $($Context.GraphAccount): append the endpoint identifier URI, publish a public encryption certificate,"
    Write-Host 'and add an outbound managed-identity federated credential to the EXISTING application.'
    Write-Host "Create/reuse an RSA certificate in CurrentUser\My; store its private key as phone-provider-decryption-key in the new vault."
    Write-Host 'Deploy the verified package, synchronize triggers, and enable HTTPS ingress guarded by Easy Auth.'
    Write-Host 'Premium EP1, storage, and telemetry incur charges. Reruns can restart the Function. No automatic rollback or deletion.' -ForegroundColor Yellow
    Write-Host 'This does NOT register an application, grant provider API roles, or activate/change CYOT policy.' -ForegroundColor Yellow
}

function Confirm-CyotDeployment {
    param([switch] $NonInteractive, [switch] $ApproveDeployment)

    if ($ApproveDeployment) { return $true }
    if ($NonInteractive) { throw 'Deployment requires -ApproveDeployment in noninteractive mode. No Azure resources were changed.' }
    while ($true) {
        $answer = ([string](Read-Host 'Deploy this complete plan? Type Yes or No [No]')).Trim()
        if ($answer -ieq 'Yes') { return $true }
        if (-not $answer -or $answer -ieq 'No') { return $false }
        Write-Warning 'Type Yes to deploy, or No/Enter to cancel.'
    }
}

function Get-CyotEncryptionCertificate {
    param([hashtable] $Inputs, [string] $OutputDirectory)

    $subject = "CN=CYOT-$($Inputs.ApplicationId)-$($Inputs.ResourcePrefix)"
    $certificate = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $certificate) {
        $certificate = New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy Exportable -KeyUsage KeyEncipherment, DataEncipherment `
            -NotAfter (Get-Date).AddYears(1)
    }
    $publicPath = Join-Path $OutputDirectory "$($certificate.Thumbprint).cer"
    Export-Certificate -Cert $certificate -FilePath $publicPath -Force | Out-Null
    return $certificate
}

function Set-CyotPrivateKey {
    param($Certificate, [string] $KeyId, [string] $VaultName, [string] $SubscriptionId, [string] $Directory)

    $existing = @(Invoke-CyotDataOperation {
        Invoke-CyotAz keyvault secret list --vault-name $VaultName --subscription $SubscriptionId --output json
    } | ConvertFrom-Json -AsHashtable)
    $match = @($existing | Where-Object { $_['name'] -eq 'phone-provider-decryption-key' })
    if ($match.Count -and $match[0]['tags'] -and
        $match[0]['tags']['certificateThumbprint'] -eq $Certificate.Thumbprint -and
        $match[0]['tags']['encryptionKeyId'] -eq $KeyId) {
        if (-not $match[0]['attributes']['enabled'] -or
            ($match[0]['attributes']['expires'] -and [DateTimeOffset]::Parse($match[0]['attributes']['expires']) -le [DateTimeOffset]::UtcNow)) {
            throw 'The existing decryption secret is disabled or expired. Correct its state before rerunning setup.'
        }
        return
    }

    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'The encryption certificate must have an exportable RSA private key.' }
    $privatePath = Join-Path $Directory 'private-key.txt'
    try {
        $pem = "-----BEGIN PRIVATE KEY-----`n$([Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey(), [Base64FormattingOptions]::InsertLineBreaks))`n-----END PRIVATE KEY-----"
        [IO.File]::WriteAllText($privatePath, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pem)), [Text.UTF8Encoding]::new($false))
        Invoke-CyotDataOperation {
            Invoke-CyotAz keyvault secret set --vault-name $VaultName --subscription $SubscriptionId `
                --name phone-provider-decryption-key --file $privatePath --encoding utf-8 `
                --tags "certificateThumbprint=$($Certificate.Thumbprint)" "encryptionKeyId=$KeyId" --output none
        } | Out-Null
    }
    finally {
        $rsa.Dispose()
        if (Test-Path -LiteralPath $privatePath) { Remove-Item -LiteralPath $privatePath -Force }
    }
}

function Set-CyotApplicationEndpoint {
    param([hashtable] $Inputs, $Context, $Outputs, $Certificate, [string] $KeyId)

    $application = Get-MgApplication -ApplicationId $Context.Application.Id `
        -Property Id, AppId, SignInAudience, IdentifierUris, KeyCredentials, TokenEncryptionKeyId -ErrorAction Stop
    if ($application.AppId -ne $Inputs.ApplicationId -or $application.SignInAudience -ne 'AzureADMultipleOrgs' -or $application.TokenEncryptionKeyId) {
        throw 'The application changed after preflight. Its identity, audience, and signed-token configuration must still match.'
    }
    $key = @{
        CustomKeyIdentifier = $Certificate.GetCertHash()
        DisplayName = "CYOT encryption $($Certificate.Thumbprint)"
        Key = $Certificate.GetRawCertData()
        KeyId = $KeyId
        Type = 'AsymmetricX509Cert'
        Usage = 'Encrypt'
        StartDateTime = $Certificate.NotBefore.ToUniversalTime()
        EndDateTime = $Certificate.NotAfter.ToUniversalTime()
    }
    $uris = @($application.IdentifierUris | Where-Object { $_ })
    if ($uris -notcontains $Outputs.identifierUri.value) { $uris += $Outputs.identifierUri.value }
    $keys = @($application.KeyCredentials | Where-Object { $null -ne $_ })
    if (-not @($keys | Where-Object { $_.KeyId -eq $KeyId }).Count) { $keys += $key }
    # Do not set tokenEncryptionKeyId: JWE payload encryption is separate from bearer-token encryption.
    Update-MgApplication -ApplicationId $application.Id -IdentifierUris $uris -KeyCredentials $keys -ErrorAction Stop

    $issuer = "https://login.microsoftonline.com/$($Inputs.TenantId)/v2.0"
    $audience = 'api://AzureADTokenExchange'
    $credentialName = "cyot-$($Outputs.functionAppName.value)-outbound"
    $credentials = @(Get-MgApplicationFederatedIdentityCredential -ApplicationId $application.Id -All -ErrorAction Stop)
    $matching = @($credentials | Where-Object {
        $_.Issuer -ceq $issuer -and $_.Subject -ceq $Outputs.outboundPrincipalId.value -and
        @($_.Audiences).Count -eq 1 -and $_.Audiences[0] -ceq $audience
    })
    if (-not $matching.Count) {
        if (@($credentials | Where-Object Name -eq $credentialName).Count) { throw 'The outbound federated credential name is already used for a different trust. It will not be overwritten.' }
        New-MgApplicationFederatedIdentityCredential -ApplicationId $application.Id -BodyParameter @{
            Name = $credentialName; Issuer = $issuer; Subject = $Outputs.outboundPrincipalId.value; Audiences = @($audience)
        } -ErrorAction Stop | Out-Null
    }
}

function Sync-CyotFunctionTriggers {
    param([string] $SiteId, [string] $SubscriptionId)

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            Invoke-CyotAz rest --method post --url "https://management.azure.com$SiteId/syncfunctiontriggers?api-version=2024-04-01" `
                --subscription $SubscriptionId --output none | Out-Null
            return
        }
        catch {
            if ($attempt -eq 12 -or $_.Exception.Message -notmatch 'BadGateway|ServiceUnavailable|GatewayTimeout') { throw }
            Write-Warning "Waiting for the Function host to load the package ($attempt/12). Ingress remains disabled."
            Start-Sleep -Seconds 10
        }
    }
}

function Invoke-CyotDeployment {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration, $Context,
        [string] $AssetDirectory, [string] $PackagePath, [string] $OutputDirectory, [string] $SourceBaseUri
    )

    $graph = Get-MgContext
    if (-not $graph -or $graph.TenantId -ne $Inputs.TenantId -or $graph.Account -ne $Context.GraphAccount) {
        throw 'The Graph session changed after the plan was reviewed. Rerun setup.'
    }
    # The single setup approval covers these planned writes, including SDK/certificate cmdlets.
    $ConfirmPreference = 'None'
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $certificate = Get-CyotEncryptionCertificate -Inputs $Inputs -OutputDirectory $OutputDirectory
    $existingKeys = @($Context.Application.KeyCredentials | Where-Object {
        $_ -and $_.Usage -eq 'Encrypt' -and $_.CustomKeyIdentifier -and
        -not (Compare-Object $_.CustomKeyIdentifier $certificate.GetCertHash())
    })
    if ($existingKeys.Count -gt 1) { throw 'Multiple encryption credentials match this certificate. Resolve the duplicate credentials manually.' }
    $keyId = if ($existingKeys.Count) { [string]$existingKeys[0].KeyId } else { [Guid]::NewGuid().ToString() }
    $settings = @{} + $ProviderConfiguration.Settings
    $settings.EPP_PROVIDER_ACCOUNT_NAME = $Inputs.ProviderAccountName
    $settings.EPP_ENCRYPTION_KEY_ID = $keyId
    $parameters = @{
        resourceNames = @{ value = $Names }
        location = @{ value = $Inputs.Location }
        tenantId = @{ value = $Inputs.TenantId }
        applicationId = @{ value = $Inputs.ApplicationId }
        tokenVersion = @{ value = $Context.TokenVersion }
        callerApplicationId = @{ value = $script:MicrosoftPhoneProviderAppId }
        deployerObjectId = @{ value = $Context.OperatorId }
        providerSettings = @{ value = $settings }
        packageBlobName = @{ value = "$($Inputs.PackageSha256).zip" }
    }
    $parameterPath = Join-Path $AssetDirectory 'deployment.parameters.json'
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM
    Write-Host 'Deploying Bicep infrastructure...' -ForegroundColor Cyan
    $outputs = Invoke-CyotAz deployment sub create --name "cyot-$($Inputs.ResourcePrefix)-$([Guid]::NewGuid().ToString('N').Substring(0, 8))" `
        --subscription $Inputs.SubscriptionId --location $Inputs.Location --template-file (Join-Path $AssetDirectory 'infra/main.bicep') `
        --parameters "@$parameterPath" --query properties.outputs --output json | ConvertFrom-Json
    foreach ($mapping in @{ functionAppName = 'functionApp'; storageAccountName = 'storageAccount'; keyVaultName = 'keyVault'; resourceGroupName = 'resourceGroup' }.GetEnumerator()) {
        if ($outputs.($mapping.Key).value -cne $Names[$mapping.Value]) { throw 'Bicep outputs do not match the approved resource names. Stop and inspect the deployment.' }
    }
    $null = ConvertTo-CyotGuid $outputs.outboundPrincipalId.value
    Assert-CyotHttpsUrl $outputs.endpointUrl.value
    if ([Text.Encoding]::UTF8.GetByteCount($outputs.endpointUrl.value) -gt 100) { throw 'The deployed endpoint URL exceeds the CYOT 100-byte limit.' }
    Set-CyotPrivateKey -Certificate $certificate -KeyId $keyId -VaultName $Names.keyVault `
        -SubscriptionId $Inputs.SubscriptionId -Directory $AssetDirectory
    Set-CyotApplicationEndpoint -Inputs $Inputs -Context $Context -Outputs $outputs -Certificate $certificate -KeyId $keyId
    Write-Host 'Publishing the verified Function package...' -ForegroundColor Cyan
    Invoke-CyotDataOperation {
        Invoke-CyotAz storage blob upload --account-name $Names.storageAccount --container-name packages `
            --name "$($Inputs.PackageSha256).zip" --file $PackagePath --auth-mode login --overwrite true `
            --subscription $Inputs.SubscriptionId --output none
    } | Out-Null
    Invoke-CyotAz functionapp restart --resource-group $Names.resourceGroup --name $Names.functionApp `
        --subscription $Inputs.SubscriptionId --output none | Out-Null
    $siteId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.Web/sites/$($Names.functionApp)"
    Sync-CyotFunctionTriggers -SiteId $siteId -SubscriptionId $Inputs.SubscriptionId
    Invoke-CyotAz resource update --ids $siteId --api-version 2024-04-01 --set properties.publicNetworkAccess=Enabled `
        --subscription $Inputs.SubscriptionId --output none | Out-Null
    $result = [ordered]@{
        tenantId = $Inputs.TenantId; subscriptionId = $Inputs.SubscriptionId; applicationId = $Inputs.ApplicationId
        provider = $ProviderConfiguration.Id; resourcePrefix = $Inputs.ResourcePrefix; resources = $Names
        endpointUrl = $outputs.endpointUrl.value; identifierUri = $outputs.identifierUri.value
        encryptionKeyId = $keyId; certificateThumbprint = $certificate.Thumbprint
        packageSha256 = $Inputs.PackageSha256; source = $SourceBaseUri
        policyChanged = $false
    }
    $resultPath = Join-Path $OutputDirectory "deployment-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
    Write-Host "Endpoint deployed: $($outputs.endpointUrl.value)" -ForegroundColor Green
    Write-Host "Saved identifiers: $resultPath"
    Write-Host 'CYOT policy was not changed. Validate the endpoint, then complete manual Step 3.' -ForegroundColor Yellow
    return [pscustomobject]$result
}

function Invoke-CyotSetup {
    [CmdletBinding()]
    param(
        [string] $TenantId, [string] $SubscriptionId, [string] $ApplicationId, [string] $Location,
        [string] $Provider, [string] $ProviderAccountName, [string] $ResourcePrefix,
        [string] $PackageUrl, [string] $PackageSha256,
        [string] $OutputDirectory, [string] $AssetDirectory, [string] $SourceBaseUri,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample',
        [switch] $NonInteractive, [switch] $ApproveDeployment
    )

    Write-Host 'Step 2: deploy the External Phone Provider endpoint. Steps 1 and 3 are manual.' -ForegroundColor Cyan
    Write-Host "`nEnter missing customer settings. Supplied values will not be requested again."
    $inputs = @{}
    foreach ($name in @('TenantId', 'SubscriptionId', 'ApplicationId')) {
        $inputs[$name] = Read-CyotInput -Name $name -Value (Get-Variable -Name $name -ValueOnly) -Kind Guid `
            -Hint 'Use the customer tenant/subscription or existing application CLIENT ID' -NonInteractive:$NonInteractive
    }
    $inputs.Location = Read-CyotInput Location $Location -Kind Location -Hint 'Azure region, for example westus2' -NonInteractive:$NonInteractive
    $inputs.ProviderAccountName = Read-CyotInput ProviderAccountName $ProviderAccountName -Hint 'Your provider account/sender name, not a credential' -NonInteractive:$NonInteractive
    $inputs.PackageUrl = Read-CyotInput PackageUrl $PackageUrl -Kind PackageUrl -Hint 'GitHub release ZIP for the Entra-authenticated CYOT endpoint package' -NonInteractive:$NonInteractive -SourceRepository $SourceRepository
    $inputs.PackageSha256 = Read-CyotInput PackageSha256 $PackageSha256 -Kind Hash -Hint 'SHA-256 from the package release' -NonInteractive:$NonInteractive

    $providerConfiguration = Get-CyotProvider -AssetDirectory $AssetDirectory -SourceBaseUri $SourceBaseUri -Provider $Provider `
        -NonInteractive:$NonInteractive -SourceRepository $SourceRepository
    $inputs.ResourcePrefix = Read-CyotInput ResourcePrefix $ResourcePrefix -Kind Prefix -Hint '2-10 lowercase letters/digits; all resource names start with this' -NonInteractive:$NonInteractive
    $names = Get-CyotResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix $inputs.ResourcePrefix

    Write-Host "`nChecking prerequisites and the selected Azure context (no resource changes)..." -ForegroundColor Cyan
    $context = Connect-CyotContext -Inputs $inputs -Names $names -NonInteractive:$NonInteractive
    $packagePath = Get-CyotPackage -Url $inputs.PackageUrl -Sha256 $inputs.PackageSha256 -Directory $AssetDirectory
    Invoke-CyotAz bicep build --file (Join-Path $AssetDirectory 'infra/main.bicep') `
        --outfile (Join-Path $AssetDirectory 'main.json') | Out-Null
    Show-CyotPlan -Inputs $inputs -Names $names -ProviderConfiguration $providerConfiguration -Context $context -SourceBaseUri $SourceBaseUri
    if (-not (Confirm-CyotDeployment -NonInteractive:$NonInteractive -ApproveDeployment:$ApproveDeployment)) {
        Write-Host 'Cancelled. No Azure resources were changed.' -ForegroundColor Yellow
        return
    }
    try {
        Invoke-CyotDeployment -Inputs $inputs -Names $names -ProviderConfiguration $providerConfiguration -Context $context `
            -AssetDirectory $AssetDirectory -PackagePath $packagePath -OutputDirectory $OutputDirectory -SourceBaseUri $SourceBaseUri
    }
    catch {
        Write-Warning 'Deployment did not complete. Previously created resources are left in place; no rollback or policy activation was attempted. Correct the reported failure and rerun with the same inputs and prefix.'
        throw
    }
}

Export-ModuleMember -Function Invoke-CyotSetup
