# Troubleshooting Step 2

## A provider is not deployment-ready

This is an intentional preflight failure, not an invitation to guess values. Telesign's supplied
manifest has blank API application IDs and no confirmed endpoint-package deployment mapping.
Soprano's settings have not been supplied. The provider owner must complete and enable the JSON
profile upstream. The publisher tenant is not assumed to be the provider API token tenant, and
distinct SMS/voice URLs are not collapsed into an invented base URL.

Check [provider ownership](../providers/README.md). No Azure resources or application properties
are changed when provider validation fails.

## GitHub downloads fail

Use a published `-SourceRef` in the configured `-SourceRepository` (upstream by default). For a
personal public-fork branch, supply **both** options; downloading the launcher from a fork does not
automatically change its default source. The launcher, supporting module, Bicep
templates, catalog, and selected provider JSON must all exist at that revision. GitHub API rate
limits, proxy/network restrictions, and unmerged changes can cause a download to fail.
An incomplete download is never executed. A known full commit SHA avoids the branch-resolution
API call. Do not bypass HTTPS or change execution policy globally to work around a download error.

## A required input or prefix is invalid

Interactive setup asks again for missing/invalid prompted input. An invalid explicitly supplied
parameter fails rather than being silently replaced. Use the application **client** ID and the
customer tenant/subscription GUIDs. The prefix must contain 2-10 lowercase letters/digits and start
with a letter. Supply a different prefix if a globally unique resource name is unavailable.

## Authentication or prerequisites fail

Use PowerShell 7 on Windows, Azure CLI with Bicep, and both documented Graph modules.
Sign Azure CLI into the customer tenant with a user account, then rerun. The script pins ARM
operations to the supplied subscription and rejects tenant mismatches, disabled subscriptions,
nonpublic clouds, and service-principal provisioning. It does not change your default subscription.

For noninteractive Graph operations, connect in the same PowerShell process with delegated
`Application.ReadWrite.All`. The endpoint application and enterprise application must already exist;
complete manual Step 1 rather than adding automated registration back to this workflow.
If an authentication session expires after approval, setup fails instead of repeatedly reopening
sign-in. Reauthenticate, then review a new plan.

## Package validation fails

Use a versioned ZIP URL from this repository's GitHub Releases, or the selected public fork's
releases, and the matching published SHA-256.
The package needs `host.json`, `package.json`, and all production dependencies at their deployment
paths. Local settings and key files are rejected. The current API-key preview packages are not
substitutes for the Entra-authenticated CYOT endpoint package.

The provider owner must approve how `EPP_PROVIDER_ENDPOINT` maps to both channel URLs and confirm
that the package implements the Entra settings and timeout/retry contract. The script does not
rewrite an adapter, flatten URLs, or infer delivery behavior from a successful ZIP upload.

## Confirmation was declined

`No` or Enter exits before resource/certificate creation or application updates. Input collection,
downloads, prerequisite checks, and read-only Azure/Graph checks may already have occurred.
There is no partial deployment to resume in this case.

## Deployment failed after Yes

Some resources may exist. Setup does not delete resources, recover/purge deleted vaults, undo
application changes, or activate policy. Inspect the reported Azure/Graph error and the deployment
in the named resource group. Use the same subscription, application ID, prefix, source revision,
and package checksum when rerunning. The resource plan can be applied again; the certificate store
and existing application credentials are used to avoid minting a new key on every run.

New storage/Key Vault data permissions can take time to propagate. Only recognized data-plane RBAC
propagation errors are retried, for up to twelve attempts. Persistent authorization failures,
wrong scopes, quota errors, and provider/region unavailability need administrator intervention.
Transient gateway/unavailable errors while the Function host loads the package are also retried
for at most twelve attempts, without reopening public ingress during the wait.

The Function's public ingress stays disabled until the final enablement step. A failed rerun can
therefore interrupt an existing test endpoint. After correcting the issue, rerun and repeat the
deployed validation procedure before any manual policy activation. Do not use deletion of a
resource group as rollback unless its exact inventory and ownership have been reviewed.

## Public endpoint is unauthorized or policy is unavailable

Check Easy Auth's trusted tenant, actual token version, audience, HTTPS requirement, and nonempty
Microsoft caller allowlist. Do not disable Easy Auth or set `tokenEncryptionKeyId` on its app to
make a test pass. Key Vault payload decryption and bearer-token authentication are different.

CYOT policy is never changed by this script. Complete the manual contract check and activation
procedure only after endpoint validation; if the supported Graph contract is unavailable, stop.
