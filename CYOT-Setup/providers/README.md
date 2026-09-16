# Provider-owned configuration

Each provider owns its complete JSON file. Maintainers review and publish changes; customers select a
provider, channel, and endpoint region instead of typing endpoints, API identifiers, scopes, timing
values, or authentication mode. `catalog.json` contains the stable lowercase `id`, `displayName`,
and same-directory JSON `file`.

## Test values are real environment settings

Both shipped profiles are enabled for configuration testing and contain
`deployment.testConfiguration: true`. Every `sms`/`voice` and `global`/`eu` route is structurally
complete. Unknown values are explicit dummy values:

- All-zero GUIDs for unknown provider/API application IDs.
- `api://00000000-0000-0000-0000-000000000000/.default` for an unknown provider scope.
- Reserved `https://<provider>.example.invalid` URLs where a working endpoint is not known.
- Labelled 1500 ms timeout and 30-second retry defaults for Soprano.

These are **not preview-only values**: after the single approval, setup passes them to Bicep and
writes them into the actual Function App environment. It also writes
`EPP_PROVIDER_TEST_CONFIGURATION=true` and records the test status in the deployment summary.
The flag is a label; it is not a runtime authentication or delivery control.
Malformed values, disabled profiles, and invalid customer IDs are still rejected.

Telesign's supplied publisher tenant, global channel URLs, supported-channel metadata, and timing
values remain unchanged. Its EU routes and application IDs are explicit test values. Soprano's
tenant, scopes, application IDs, endpoints, and timings are explicit test values, not production
claims. There is no separate `placeholderFields` list; the complete route objects are authoritative.

## Environment mapping

| JSON setting | Function App environment setting |
|---|---|
| `deployment.providerName` | `EPP_PROVIDER_NAME` |
| Selected `deployment.routes.<channel>.<region>.endpoint` | `EPP_PROVIDER_ENDPOINT` |
| Selected channel | `EPP_PROVIDER_CHANNEL` |
| Selected endpoint region | `EPP_PROVIDER_ENDPOINT_REGION` |
| `deployment.authentication.mode` | `EPP_PROVIDER_AUTH_MODE` |
| OAuth `deployment.authentication.tenantId` | `EPP_PROVIDER_TENANT_ID` |
| Selected OAuth route `scope` / `appId` | `EPP_PROVIDER_SCOPE` / `EPP_PROVIDER_APP_ID` |
| Selected route `timeoutMilliseconds` | `EPP_PROVIDER_TIMEOUT_MS` |
| Selected route `retryIntervalSeconds` multiplied by 1000 | `EPP_PROVIDER_RETRY_INTERVAL_MS` |
| `deployment.testConfiguration` | `EPP_PROVIDER_TEST_CONFIGURATION` |

Customer account/sender names are requested separately and written to `EPP_PROVIDER_ACCOUNT_NAME`.
All environment values are strings. **30 seconds becomes 30000 milliseconds**; it is not a
30-millisecond retry. Timeouts must be integers from 1 to 2500; retry seconds must be nonnegative
integers whose conversion fits Int32 milliseconds. Different channel/region routes may use different
values; setup writes only the selected route.

## Before live delivery

Replace every dummy route value with provider-approved values and set `testConfiguration` to `false`
once the profile is genuinely complete. Route endpoints are complete request URLs and are used
exactly; adapters do not derive them by trimming or appending channel paths.

Telesign uses API-key authentication through its two named Key Vault secrets. Soprano uses OAuth:
the Function's outbound user-assigned managed identity supplies a client assertion, the existing
multitenant application receives a federated identity credential, and the runtime requests the
selected route's provider scope. Setup does not grant provider API consent or application roles.

Store real provider credentials in Key Vault, never in JSON or application environment values:

| Provider | Required Key Vault secret names |
|---|---|
| Telesign | `telesign-api-key`, `telesign-customer-id` |
| Soprano | None; OAuth tenant/scope/app IDs come from the provider profile |

The public `$schema` identifies the supplied manifest format. The `deployment` object is this
sample's local extension, not a claim that it belongs to the upstream schema. Additional provider
metadata is preserved; it is not silently translated into unsupported application behavior.
