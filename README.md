# Intune Application Assignment and Coverage Analyzer

## Purpose

This sanitized, read-only engineering sample contains no tenant IDs, company prefixes, internal URLs, or organization-specific paths. Graph tools use delegated interactive authentication. The account picker opens in the browser or Windows authentication broker. Device-code authentication is intentionally not used.

## Requirements

- Windows PowerShell 5.1, 64-bit
- Microsoft.Graph.Authentication for Graph-based tools
- An Intune role that permits the requested read operations
- Consent for the delegated scopes listed below
- `IntuneToolkit.Common.psm1` (the shared module), expected at `..\Shared\IntuneToolkit.Common.psm1` relative to this script's own folder. Keep the toolkit's folder structure intact when copying scripts elsewhere.

## Delegated permissions

- `DeviceManagementApps.Read.All`
- `Group.Read.All`

## Usage

```powershell
.\Get-IntuneApplicationAssignmentCoverage.ps1 -IncludeUnassignedApps
```

## Output

Output is written beneath the current user's Documents folder unless `-OutputRoot` is supplied. The Autopilot collector defaults to a folder on the current user's Desktop. No company-specific path is hard coded.

## Authentication behavior

The shared module calls `Connect-MgGraph -Scopes <scopes> -ContextScope Process -NoWelcome`. It disconnects any existing Graph context first and then opens interactive account selection. Do not add `-UseDeviceAuthentication`.

## Important limitations

- Assignment applicability is an engineering inference, not Intune's final policy engine result.
- Filters, exclusions, user-versus-device context, licensing, applicability rules, and service-side processing can change the effective result.
- Large tenants can require substantial time and Graph requests when group membership expansion is enabled.
- This solution uses selected Microsoft Graph beta endpoints. Test before production use and review changes to the API.

## Sanitization

Sample data uses fictional devices, groups, users, IDs, and application names. Do not publish real exports. Review logs and CSVs before sharing them outside your organization.
