# CYOT endpoint setup

**Only Step 2 is scripted.** Register the customer application manually, run one downloaded
PowerShell script to deploy the endpoint, and activate policy manually after validation.

The customer does not clone this repository or download Bicep/support scripts separately.
`Setup-Cyot.ps1` retrieves those files and the selected provider's JSON from GitHub.

## Availability

The catalog lists **Telesign** and **Soprano**, but neither is deployment-ready yet.
Telesign's supplied manifest is preserved, including its distinct SMS/voice URLs, publisher tenant,
1500 ms timeout, and 30-second retry interval. Its API application IDs and confirmed deployment
mapping are missing. Soprano's provider-owned settings are still pending. Selecting an incomplete
profile produces an actionable error **before Azure sign-in, resource creation, or application updates**.
Do not fill these gaps with guessed values; see [provider ownership](../providers/README.md).

The default download URLs below become usable when this change is published upstream. Before merging,
test from a published public fork using `-SourceRepository <owner/repository>` and
`-SourceRef <branch-or-full-commit-sha>`. Both options must identify the same source as the downloaded
launcher. Unpublished worktree changes are not downloadable from GitHub.

## Step 1 - manually register and onboard the application

Use a dedicated nonproduction tenant/subscription for the first deployment.

1. In the customer tenant's **Microsoft Entra admin center > App registrations**, register a
   dedicated application. Select **Accounts in any organizational directory**; do not enable
   personal Microsoft accounts. No redirect URI or client secret is needed for this endpoint.
2. Record the **Directory (tenant) ID** and **Application (client) ID**. The script requires the
   client ID, not the application's object ID, and will not create a replacement registration.
3. Verify the application's enterprise application exists in the same tenant. In **Enterprise
   applications > Properties**, set **Assignment required?** to **No** as required by CYOT onboarding.
   Easy Auth will still pin inbound calls to the Microsoft phone-provider application
   `25ec60fa-f18d-41a4-b398-50044c90ce13`; this is not permission to accept arbitrary callers.
4. Verify the app's access-token version in its manifest. Setup reads `api.requestedAccessTokenVersion`
   and configures the corresponding v1 or v2 issuer/audience. Leave **`tokenEncryptionKeyId` null**:
   Easy Auth expects a signed bearer JWT. Payload JWE encryption is separate.
5. Give the same customer application client ID to the chosen provider and complete purchase,
   account/sender registration, and provider-side authorization. The provider owns its API app,
   token-issuing tenant, API scope, channel endpoints, and API role assignments. Setup does not
   grant provider API permissions.

Step 2 still configures endpoint-specific properties on this **existing** application: its
hostname-based identifier URI, public JWE encryption certificate, and outbound managed-identity
federated credential. Those changes are included in the single deployment approval.

## Prerequisites for Step 2

- **Windows with PowerShell 7+**. Certificate generation/reuse uses the current user's Windows
  certificate store; this is not an Azure Cloud Shell or Linux customer deployment script.
- Azure CLI and its Bicep compiler, with access to GitHub, Azure, Microsoft Graph, and Key Vault.
- Microsoft Graph PowerShell modules `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications`.
- An Azure **user** account permitted to deploy at subscription scope, create the listed resources,
  and create the scoped role assignments. Service-principal provisioning is not supported.
- Application-management permission in the customer tenant and delegated Graph
  `Application.ReadWrite.All` for endpoint-specific application configuration.
- The required resource providers registered and **Linux Premium EP1** available in the chosen region.
- A **ready-to-run Node.js 24 CYOT endpoint ZIP** published in this repository's GitHub Releases
  or the explicitly selected public fork's releases,
  plus its SHA-256 checksum. It must implement the existing Entra token-exchange `EPP_*` contract
  and the provider-approved endpoint mapping. Source ZIPs requiring a build are not supported here.

**Package compatibility matters:** the repository's JavaScript/Python/.NET API-key samples and their
current preview downloads do not implement the Entra outbound settings used by this deployment.
Do not substitute those ZIPs. A checksum and `host.json` prove neither provider compatibility nor
OTP delivery. Obtain the compatible package from the CYOT owner before proceeding; the script has
no private-blob/SAS fallback and will not guess a package.

Install prerequisites once, if missing:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Repository PSGallery
az bicep install
```

Install Azure CLI through its official installation instructions if necessary. Sign in before
running setup; Azure CLI and Microsoft Graph have separate authentication sessions:

```powershell
az login --tenant <customer-tenant-id>
```

Setup checks the explicitly supplied subscription and tenant without changing the CLI's selected
subscription. It requests Graph sign-in before displaying the plan if a suitable delegated
session is not already available. Authentication/MFA prompts are not resource-creation approvals.

## Step 2 - download and run one script

Download and inspect [Setup-Cyot.ps1](../Setup-Cyot.ps1), or save it from the upstream raw URL:

```powershell
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/main/CYOT-Setup/Setup-Cyot.ps1' `
    -OutFile .\Setup-Cyot.ps1
.\Setup-Cyot.ps1
```

The flow is:

1. **Collect missing customer inputs:** tenant, subscription, existing application client ID, Azure
   region, provider account/sender name, compatible package URL, and package SHA-256. Supplied values
   are reused without prompts. Credentials are never requested as ordinary string parameters.
2. **Choose a provider** from the GitHub catalog. Setup downloads only that provider's JSON, validates
   it, and reads its endpoint, token tenant/scope, timeout, and retry interval. Incomplete or
   incompatible profiles stop here; customers are not asked to invent provider settings.
3. **Enter a resource prefix**, such as `contoso`: 2-10 lowercase letters/digits, starting with a
   letter. Every top-level resource name starts with it. A deterministic suffix derived from the
   subscription, application ID, and prefix reduces global-name collisions. Reruns use the same names.
4. **Review the complete plan**, including resource names, tenant/subscription, package/hash, provider
   settings, scoped roles, certificate creation, and application configuration. Bicep receives these
   exact names; it does not independently calculate a different naming scheme.
5. **Type `Yes` once to deploy.** `No` or Enter cancels without Azure changes. Invalid answers prompt
   again; individual resources do not request additional approvals.

Supply known values to shorten the prompts:

```powershell
.\Setup-Cyot.ps1 `
    -TenantId <customer-tenant-id> `
    -SubscriptionId <subscription-id> `
    -ApplicationId <existing-client-id> `
    -Location westus2 `
    -Provider telesign `
    -ResourcePrefix contoso
```

The plan creates or updates a dedicated resource group, Linux Premium EP1 hosting plan, Function App,
storage account/private package container, Key Vault, Log Analytics workspace, Application Insights,
outbound managed identity, diagnostics, Easy Auth, and scoped role assignments. Storage/package
access uses managed identity, not account keys or SAS. Telemetry uses the system identity; the
outbound identity is selected explicitly, not through a global `AZURE_CLIENT_ID`.

The Function starts with public ingress disabled. Setup stores the private key in Key Vault,
configures application trust, uploads the hash-verified package, synchronizes triggers, and only then
opens ingress protected by HTTPS and Easy Auth. The public certificate and a timestamped identifier
summary are saved to `cyot-output` beside the downloaded script, or to `-OutputDirectory`.
Private keys remain in the user's certificate store and Key Vault, not in that summary.

For unattended runs, supply every input, authenticate both clients first, and explicitly authorize
the whole displayed plan with **both** `-NonInteractive -ApproveDeployment`. `-NonInteractive`
alone never approves changes. There is no `-Stage`, `-Resume`, `-ConfigPath`, or policy-approval switch.

### Test a published public fork

Open PowerShell 7 on Windows in an empty test folder. Replace the owner below with your GitHub login:

```powershell
$repository = '<your-GitHub-login>/ExternalPhoneProvider-AzureFunction-Sample'
$ref = 'test/cyot-single-script'
Invoke-WebRequest `
    -Uri "https://raw.githubusercontent.com/$repository/$ref/CYOT-Setup/Setup-Cyot.ps1" `
    -OutFile .\Setup-Cyot.ps1
.\Setup-Cyot.ps1 -SourceRepository $repository -SourceRef $ref
```

This downloads the module, Bicep, catalog, and selected provider JSON from **your fork**, without
changing the upstream PR branch. A full commit SHA can replace `$ref` for repeatable tests.
Choosing a fork does not bypass missing provider settings, package validation, or deployment approval.
With the currently incomplete profiles, expect provider validation to stop before Azure changes.

Fork downloads must be publicly readable. A branch in a public fork is not private; repository
visibility applies to every branch. Do not put a GitHub token in the script, URLs, or provider files.

### Source versioning

`-SourceRepository` defaults to `Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample`.
The small entry point resolves `-SourceRef` (default `main`) to a single commit in that repository. All supporting
PowerShell, Bicep, the catalog, and the selected provider profile are downloaded from that commit.
Use a reviewed full commit SHA for repeatable deployments. Provider JSON selects data only; it
cannot redirect execution to another script. Download failures stop setup, and temporary downloads
are removed on completion or failure. Select only a repository whose code you trust: its supporting
PowerShell is executed locally.

## Step 3 - manually validate and activate policy

1. Save the Step 2 summary and confirm its tenant, application client ID, endpoint URL, encryption
   key ID, and certificate with the CYOT onboarding owner. Finish provider-side role assignments
   and verify the package's channel routing and retry behavior.
2. Validate the deployed endpoint with synthetic, non-delivering evaluation requests first.
   Missing/invalid credentials and unauthorized callers must be rejected by Easy Auth. An admitted
   caller's valid encrypted request must return the matching nonce. Then verify live SMS/voice
   provider acceptance and handset delivery through the supported test procedure. Never put
   phone numbers, messages, tokens, private keys, or nonce values in shared logs.
3. An **Authentication Policy Administrator**, using the approved Microsoft Graph tool and delegated
   `Policy.ReadWrite.AuthenticationMethod`, must verify that the tenant's currently supported CYOT
   contract is available. For the preview contract formerly handled by Step 3, inspect
   `https://graph.microsoft.com/beta/$metadata` for `authenticationMethodsPolicy.cyot` and its
   `endpoint`, `appId`, and `migrated` fields. **If absent or different, stop and obtain the supported
   onboarding procedure from Microsoft; do not send a guessed PATCH or enable a different method.**
4. Read `https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy` using that supported
   contract, save the existing `cyot` value with tenant ID and timestamp, and independently approve
   the migration choice. `migrated` is a routing decision, not a script default.
5. Re-read immediately before a manual change, stop if the policy changed, and use `If-Match` when
   an ETag is available. Patch **only** the `cyot` property with the tested endpoint, the same
   application client ID, and the deliberately chosen migration Boolean. Read it back and compare
   before considering activation complete.

Policy activation, policy backups, and policy rollback are administrator-owned manual operations.
No policy API is called by the setup package. For rollback, restore only the reviewed prior CYOT
value through the still-supported contract; resource deletion is not a policy rollback.

## Development checks

These checks are offline and do not sign in, deploy Azure resources, or call providers:

```powershell
pwsh -NoProfile -File .\CYOT-Setup\tests\Setup-Cyot.SmokeTests.ps1
az bicep build --file .\CYOT-Setup\infra\main.bicep --outfile "$env:TEMP\cyot-main.json"
```

The smoke suite substitutes GitHub downloads, input prompts, and Azure/Graph boundaries, including
running the launcher from a directory containing only that one file. It is not live deployment or
provider certification. See [Troubleshooting.md](Troubleshooting.md) for failure recovery.
