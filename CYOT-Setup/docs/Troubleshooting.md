# Troubleshooting Step 2

## Setup still asks for PackageUrl or PackageSha256

You are running an older launcher or source revision. Download `Setup-Cyot.ps1` again and supply
the intended `-SourceRepository` and `-SourceRef`. The current version asks for **one language**
and reads its package URL and published checksum automatically. Remove old package URL/hash
arguments from saved commands.

## Provider settings are dummy values

This is intentional for deployment testing. Both JSON profiles explicitly use
`deployment.testConfiguration: true`. Zero GUIDs and `example.invalid` URLs are written into the
actual Function App environment, with `EPP_PROVIDER_TEST_CONFIGURATION=true`.
Telesign's supplied channel URLs, timings, and publisher metadata are retained.

The script can deploy code with these values, but they cannot deliver real SMS/voice messages.
Update the provider-owned profile and provision the adapter's credentials in Key Vault before
live use. The API-key sample packages do not turn into outbound Entra-token clients merely because
tenant/scope/app-ID values are present in settings. See [provider ownership](../providers/README.md).

## A checksum or package download fails

Each language entry points to a versioned GitHub ZIP and the same release's `SHA256SUMS.txt`.
The file must contain exactly one valid entry for that asset. Missing, duplicate, malformed, or
mismatched checksums fail closed; there is no manual-hash or skip-verification workaround.
Verify the catalog's links and your access to GitHub/release assets.

Supporting tools, Bicep, catalogs, and provider JSON all come from the commit selected at startup.
For a public-fork branch, pass both source options. A full commit SHA avoids branch-resolution
API rate limits. Private repositories are not supported by these unauthenticated raw downloads.

## .NET build fails

Install the **.NET 8 SDK** and allow NuGet access. Setup selects an installed 8.x SDK, extracts the
verified source into its temporary workspace, runs a Linux-targeted Release publish, checks the
publish output, and creates the ready ZIP. The source ZIP is not uploaded as runnable code.
Build failures occur before Azure resource creation and include the `dotnet` failure output.

Do not manually replace the published source checksum with a hash of the build output. These
represent different artifacts; setup computes the built artifact's hash itself.

## Python remote build fails

Use Azure CLI **2.48.1+** with a user account allowed to publish to the Function App and network
access to its SCM endpoint. Setup enables `SCM_DO_BUILD_DURING_DEPLOYMENT` and `ENABLE_ORYX_BUILD`,
without `WEBSITE_RUN_FROM_PACKAGE` during the build, and requests Azure remote build explicitly.
It never installs Windows Python dependencies for the Linux app.

SCM basic authentication remains disabled. The CLI uses Microsoft Entra authentication. The built
`site/wwwroot` snapshot must include the Python Functions dependency payload; an unbuilt source
archive is rejected even when an upload command returned success. The built output is then stored
in private Blob storage, and temporary remote-build settings are cleared.

If build, snapshot, publication, or startup fails after opening SCM ingress, setup attempts to
disable public ingress again. An inability to close ingress is an explicit error requiring
immediate administrator inspection. Do not bypass certificate errors or enable basic auth.

## Azure CLI warnings break JSON parsing

The current helper separates stdout from stderr. Successful command JSON is parsed independently
of SDK warnings, while stderr warnings are shown and nonzero exit codes still fail. Upgrade an
older downloaded helper by refreshing the launcher/source revision.

## Authentication, permission, or runtime preflight fails

Use PowerShell 7 on Windows, Azure CLI with Bicep, and the documented Graph modules. Sign into the
customer tenant with a user account. ARM requests use the supplied subscription; setup does not
change the CLI's default subscription or adopt unrelated resource groups.

The customer application and enterprise application must already exist from manual Step 1.
Graph needs delegated `Application.ReadWrite.All` for endpoint URI/key configuration. Noninteractive
runs must authenticate both clients first and supply `-ApproveDeployment` separately.
Use a distinct resource prefix for each language; setup rejects changing a previously tagged
app to another runtime with the same prefix.

## Deployment stops after approval

Some resources can remain. No automatic deletion, vault purge/recovery, policy activation, or
rollback occurs. Inspect the named Azure deployment and the reported error, then rerun with the
same tenant, subscription, application, language, and prefix after correcting it.

Recognized storage/Key Vault RBAC propagation errors are retried for at most twelve attempts.
Transient Function startup errors also have bounded retries. A successful upload alone is not
success: `SendOtp` must appear in Azure's function metadata. No success summary is written if
publication or registration fails.

## The endpoint returns 401 or live delivery fails

Keep Easy Auth enabled. Check the trusted tenant, actual token version, audience, HTTPS requirement,
and nonempty Microsoft caller allowlist. Keep `tokenEncryptionKeyId` null on the endpoint app;
payload JWE encryption is separate from signed bearer-token validation.

For live delivery, replace dummy endpoints and configure the provider's exact Key Vault secret
names. Test with synthetic evaluation requests before live messages. CYOT policy remains a
separate, administrator-approved manual operation; no setup code updates it.
