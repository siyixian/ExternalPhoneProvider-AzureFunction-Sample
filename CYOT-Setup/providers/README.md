# Provider-owned configuration

Each provider owns its JSON file. Maintainers review and publish changes; customers select a
provider instead of typing endpoints, API identifiers, scopes, or timing values. `catalog.json`
contains the stable lowercase `id`, `displayName`, and same-directory JSON `file`.

## Test values are real environment settings

Both shipped profiles are enabled for configuration testing and contain
`deployment.testConfiguration: true`. Missing values are filled deliberately:

- All-zero GUIDs for unknown provider/API application IDs.
- `api://00000000-0000-0000-0000-000000000000/.default` for an unknown provider scope.
- Reserved `https://<provider>.example.invalid` URLs where a working endpoint is not known.
- Labelled 1500 ms timeout and 30-second retry defaults for Soprano.

These are **not preview-only values**: after the single approval, setup passes them to Bicep and
writes them into the actual Function App environment. It also writes
`EPP_PROVIDER_TEST_CONFIGURATION=true` and records the test status in the deployment summary.
The flag is a label; it is not a runtime authentication or delivery control.
Malformed values, disabled profiles, and invalid customer IDs are still rejected.

Telesign's supplied publisher tenant, channel URLs, supported-channel metadata, and timing values
remain unchanged. Its publisher tenant is not silently assumed to be its API token tenant.
`placeholderFields` and `note` identify the unconfirmed data. Soprano's values are explicitly test
defaults, not claims about its production API or certifications.

## Environment mapping

| JSON setting | Function App environment setting |
|---|---|
| `deployment.providerName` | `EPP_PROVIDER_NAME` |
| `deployment.providerEndpoint` | `EPP_PROVIDER_ENDPOINT` |
| `deployment.providerTenantId` | `EPP_PROVIDER_TENANT_ID` |
| `deployment.providerScope` | `EPP_PROVIDER_SCOPE` |
| Shared channel `timeoutMilliseconds` | `EPP_PROVIDER_TIMEOUT_MS` |
| Shared channel `retryIntervalSeconds` multiplied by 1000 | `EPP_PROVIDER_RETRY_INTERVAL_MS` |
| `metadata.endpoints.sms.url` / `.voice.url` | `EPP_PROVIDER_SMS_ENDPOINT` / `EPP_PROVIDER_VOICE_ENDPOINT` |
| `metadata.endpoints.sms.appId` / `.voice.appId` | `EPP_PROVIDER_SMS_APP_ID` / `EPP_PROVIDER_VOICE_APP_ID` |
| `deployment.testConfiguration` | `EPP_PROVIDER_TEST_CONFIGURATION` |
| Selected package's authentication contract | `EPP_PROVIDER_AUTH_MODE` |

Customer account/sender names are requested separately and written to `EPP_PROVIDER_ACCOUNT_NAME`.
All environment values are strings. **30 seconds becomes 30000 milliseconds**; it is not a
30-millisecond retry. Timeouts must be integers from 1 to 2500; retry seconds must be nonnegative
integers whose conversion fits Int32 milliseconds. The current shared package settings require
matching SMS/voice timing values.

## Before live delivery

Replace the placeholder data with provider-approved values and set `testConfiguration` to `false`
once the profile is genuinely complete. Do not derive a provider base URL by blindly trimming
`/sms` or `/voice`; the selected adapter must add the correct routes.

The three published sample packages use **API-key authentication**. They do not consume the
tenant/scope/app-ID or separate channel-URL settings for Entra token exchange, nor does the retry
setting make them retry automatically. These values are retained as requested configuration
metadata, not invented runtime capabilities.

Store real provider credentials in Key Vault, never in JSON or application environment values:

| Provider | Required Key Vault secret names |
|---|---|
| Telesign | `telesign-api-key`, `telesign-customer-id` |
| Soprano | `soprano-api-key`, `soprano-api-id` |

The public `$schema` identifies the supplied manifest format. The `deployment` object is this
sample's local extension, not a claim that it belongs to the upstream schema. Additional provider
metadata is preserved; it is not silently translated into unsupported application behavior.
