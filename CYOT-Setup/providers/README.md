# Provider-owned configuration

Each provider owns its JSON file. The repository maintainers review and publish updates; customers
select a provider rather than type API endpoints, token tenants/scopes, or timing values.
`catalog.json` is the menu index: a stable lowercase `id`, customer-facing `displayName`, and a
same-directory JSON `file`. Additions to the catalog do not require changing the downloaded launcher.

## Supplied data and intentional gaps

`telesign.json` preserves the supplied CYOT package manifest. SMS and voice have distinct URLs and
blank API `appId` values; the publisher tenant is recorded without assuming it is the API's token
issuer. Both channels specify 1500 milliseconds and a 30-second retry interval.

`soprano.json` is an unavailable template, not a fabricated provider configuration.
Both profiles have `deployment.enabled: false`. They remain visible in the menu, but selection
fails before any Azure changes until the owner completes and enables the profile.

## Deployment mapping

The provider-supplied `$schema` identifies the manifest format. The additional `deployment` object
is this sample's local configuration extension, not a claim that it is part of the upstream schema:

| Field | Required value |
|---|---|
| `enabled` | JSON Boolean `true` only after provider review; not the string `"true"` |
| `providerName` | Exact adapter ID matching the catalog entry |
| `providerTenantId` | Confirmed provider API token-issuing tenant GUID; not inferred from `publisher.tenantId` |
| `providerScope` | Confirmed provider API application ID or App ID URI followed by `/.default` |
| `providerEndpoint` | Provider-approved HTTPS endpoint/base URL expected by the compatible Function package |

The existing endpoint package contract accepts one `EPP_PROVIDER_ENDPOINT`, one API scope, and
shared timing values. A manifest with different channel URLs does **not** identify that base URL
or prove the package appends the correct routes. The provider/package owners must validate and
fill `deployment.providerEndpoint`; setup deliberately does not trim `/sms`, append a guessed path,
or substitute the first channel's URL.

Each `metadata.endpoints.sms` and `.voice` must provide:

- `url`: absolute public HTTPS URL on port 443, without credentials, query strings, or fragments.
- `appId`: the provider API's nonempty application GUID. The current package requires the same
  provider API application for both channels.
- `timeoutMilliseconds`: integer from 1 through 2500, shared between the channels.
- `retryIntervalSeconds`: nonnegative integer, shared between the channels, whose conversion fits
  a signed 32-bit millisecond value.

Setup maps the shared timeout directly to `EPP_PROVIDER_TIMEOUT_MS` and explicitly multiplies
seconds by 1000 for `EPP_PROVIDER_RETRY_INTERVAL_MS`: **30 seconds becomes 30000 milliseconds**.
This is configuration, not a claim that the runtime performs retries. The repository's API-key
sample ignores the retry and Entra settings; use the approved compatible endpoint package.
Other manifest fields (certification endpoints, EU routing, supported regions, fraud protection,
rate limits, sender requirements, and support links) remain metadata and are not silently converted
into Azure resources or promises about runtime behavior.

Never commit provider secrets, customer credentials, access tokens, private keys, or signed URLs.
Customer-specific account/sender names are collected by setup; provider-owned settings are not.
Use the offline smoke suite after every profile or catalog change, then validate the complete
package/profile combination with the provider before enabling it.
