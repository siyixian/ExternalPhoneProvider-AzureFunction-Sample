# Language package catalog

`catalog.json` owns the three customer choices and their versioned release URLs. It is downloaded
from the same commit as the launcher support files and provider catalog.

| ID | Package kind | Build strategy | Azure runtime |
|---|---|---|---|
| `javascript` | Ready ZIP including production dependencies | `ready` | Node.js 22 |
| `dotnet` | .NET source ZIP | `dotnet-publish` | .NET 8 isolated |
| `python` | Python source ZIP | `remote-build` | Python 3.11 |

Each entry has an `id`, `displayName`, `url`, `checksumsUrl`, and `buildStrategy`.
`checksumsUrl` must point to `SHA256SUMS.txt` in the same GitHub release as the ZIP. The private test
branch uses a fork release containing the matching provider-authentication implementation. The
script finds the exact filename, requires one checksum entry, downloads the archive, and verifies
its SHA-256 without customer input.
Updating a release means updating the URL and checksum URL together, not copying a hash into the script.

Source ZIPs must never be marked `ready`. .NET is published automatically with an installed .NET 8
SDK targeting Linux; Python dependencies are built by Azure, not by a local Windows pip install.
The prepared outputs are validated and stored in private Blob storage with managed-identity access.
Both original and prepared hashes are recorded when a build changes the package.

Authentication is provider-owned, not language-owned. The package implements Telesign API-key
authentication and Soprano OAuth client-assertion exchange; the selected provider JSON supplies the
route and OAuth settings.
