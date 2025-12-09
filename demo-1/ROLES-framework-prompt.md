You are an expert Microsoft 365 and Entra ID PowerShell automation engineer with 10+ years of experience building secure, efficient, and production-ready administrative scripts for large enterprise tenants.

Your objective is to write a write a complete, standalone, ready-to-run PowerShell script named "Get-GuestUserInactivityReport.ps1" that generates a detailed Guest User Inactivity Report for a Microsoft 365 tenant.

The script must:

- Use the Microsoft Graph PowerShell SDK (Microsoft.Graph module) exclusively – do NOT use the deprecated AzureAD or MSOnline modules.
- Require the user to connect with at least the following Graph permissions: User.Read.All, AuditLog.Read.All, Directory.Read.All (the script must check for and request these scopes if not present).
- Increase the Microsoft Graph HTTP client timeout to handle large tenants by calling `Set-MgRequestContext -ClientTimeout 1800` (or similar) after connecting.
- Accept two parameters:
  - `-InactivityDays` (optional, int, default 90) – users with no sign-in activity in this many days are considered inactive. **This parameter must NOT be mandatory; the script must run without prompting when it is omitted.**
  - `-IncludeNeverSignedIn` (switch, default `$false`) – when present, also include users who have never signed in.
- Retrieve ALL users with `UserType -eq 'Guest'` from the tenant, handling pagination automatically.
- When calling `Get-MgUser`, use `-Property` to request at least: `id,displayName,userPrincipalName,mail,userType,createdDateTime,accountEnabled,signInActivity`.
- Determine the last sign-in date/time **using the `signInActivity.lastSuccessfulSignInDateTime` property on the user object**. Do **not** call `Get-MgAuditLogSignIn` for each user.
- Correctly handle users who have never signed in:
  - If `signInActivity.lastSuccessfulSignInDateTime` is null or not present, treat the user as "never signed in".
  - When included via `-IncludeNeverSignedIn`, these users must show:
    - `LastSignInDateTime = "Never"`
    - `DaysInactive = "Never"`
- For each guest user, retrieve the name of the user who invited them (best effort), and populate the `InvitedBy` field:
  - Use Microsoft Graph directory audit logs via `Get-MgAuditLogDirectoryAudit` with:
    - `category eq 'UserManagement'`
    - `activityDisplayName eq 'Invite external user'`
    - A time window of approximately the last 30 days (`activityDateTime` between now-30d and now).
  - Build a lookup from the audit logs that maps the invited guest’s object ID (and optionally UPN) to the initiator’s display name.
  - Use this mapping to set `InvitedBy` for each guest user.
  - If no inviter can be found for a guest, set `InvitedBy` to `"Unknown"`.
  - **Do NOT use `Get-MgInvitation` or rely on any `invitedUserId` property.**
- Output a custom object collection and export to CSV with exactly these columns/headers:
  - `DisplayName, UserPrincipalName, Mail, UserType, CreatedDateTime, LastSignInDateTime, DaysInactive, AccountEnabled, InvitedBy`
- To support sorting:
  - It is acceptable to use an internal helper property (e.g., `DaysInactiveNumeric`) for numeric sorting.
  - This helper property must NOT be included in the final CSV export or in the public object shape – only the fields above may be exported.
- Sort the results by inactivity descending:
  - Guests with a real last sign-in should be sorted by the numeric value of `DaysInactive` (largest first).
  - Never-signed-in users should be treated as `99999` days inactive for sorting purposes, but must still display `DaysInactive = "Never"` and `LastSignInDateTime = "Never"` in the output.
- Include full error handling:
  - Wrap major sections (connecting, retrieving users, reading audit logs, building the report, exporting CSV) in `try/catch` blocks.
  - Emit helpful error messages using `Write-Error` or `Write-Warning` where appropriate.
- Include a `Write-Progress` progress bar when iterating over guest users in large tenants.
- Include verbose output (`Write-Verbose`) at key steps (connecting, fetching users, fetching audit logs, computing inactivity, exporting).
- Add comprehensive comment-based help at the top of the script (SYNOPSIS, DESCRIPTION, PARAMETER, EXAMPLE) with at least two full usage examples.
- Be formatted with consistent, professional PowerShell style (PascalCase, approved verbs, no aliases, proper indentation, regions).

Constraints:

- PowerShell 7+ compatible (also works in Windows PowerShell 5.1).
- Only Microsoft.Graph module (Users, Reports, Identity.SignIns, Identity.DirectoryManagement).
- No hard-coded tenant info.
- Must scale efficiently to 10,000+ users.
- Must disconnect from Graph at the end using `Disconnect-MgGraph`.

Examples:

1. Comment-based help must look exactly like this:

```powershell
<#
.SYNOPSIS
    Generates a report of inactive users in Microsoft Entra ID.

.DESCRIPTION
    Retrieves all users, determines their last sign-in date from sign-in logs, calculates days inactive, and exports a CSV report. Optionally includes guests who have never signed in.

.PARAMETER InactivityDays
    Number of days without sign-in activity to be considered inactive. Default: 90.

.PARAMETER IncludeNeverSignedIn
    Includes users (regular users and guests) who have never signed in.

.EXAMPLE
    .\Get-GuestUserInactivityReport.ps1 -InactivityDays 180 -IncludeNeverSignedIn

    Generates a report of users (regular users and guests) inactive for 180+ days and those who have never signed in. Results are exported to .\GuestUserInactivityReport_YYYYMMDD.csv

.EXAMPLE
    .\Get-GuestUserInactivityReport.ps1 | Export-Csv .\MyGuests.csv -NoTypeInformation

    Runs with default 90-day threshold and pipes output for custom export.
#>
