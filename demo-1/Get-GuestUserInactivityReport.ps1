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
start
    Generates a report of users (regular users and guests) inactive for 180+ days and those who have never signed in. Results are exported to .\GuestUserInactivityReport_YYYYMMDD.csv

.EXAMPLE
    .\Get-GuestUserInactivityReport.ps1 | Export-Csv .\MyGuests.csv -NoTypeInformation

    Runs with default 90-day threshold and pipes output for custom export.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [int]$InactivityDays = 90,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeNeverSignedIn
)

#region Modules and Connection
try {
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    Import-Module Microsoft.Graph.Reports -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
}
catch {
    Write-Error "Failed to import Microsoft Graph modules. $_"
    return
}

$requiredScopes = @(
    "User.Read.All",
    "AuditLog.Read.All",
    "Directory.Read.All"
)

try {
    $currentContext = Get-MgContext -ErrorAction SilentlyContinue

    if (-not $currentContext -or -not $currentContext.Scopes) {
        Write-Verbose "No existing Microsoft Graph context found. Connecting with required scopes..."
        Connect-MgGraph -Scopes $requiredScopes -ErrorAction Stop | Out-Null
    }
    else {
        $missingScopes = $requiredScopes | Where-Object { $_ -notin $currentContext.Scopes }

        if ($missingScopes.Count -gt 0) {
            Write-Verbose ("Current Microsoft Graph session is missing required scopes: {0}. Reconnecting..." -f ($missingScopes -join ", "))
            Connect-MgGraph -Scopes $requiredScopes -ErrorAction Stop | Out-Null
        }
        else {
            Write-Verbose "Existing Microsoft Graph session already has required scopes."
        }
    }

    # Increase HTTP client timeout for large tenants / heavy queries
    try {
        # 1800 seconds = 30 minutes
        Set-MgRequestContext -ClientTimeout 1800 | Out-Null
        Write-Verbose "Microsoft Graph HTTP client timeout set to 1800 seconds."
    }
    catch {
        Write-Verbose "Set-MgRequestContext not available or failed. Continuing with default client timeout."
    }
}
catch {
    Write-Error "Failed to establish Microsoft Graph connection. $_"
    return
}
#endregion

try {
    $nowUtc = (Get-Date).ToUniversalTime()

    #region Retrieve Guest Users
    Write-Verbose "Retrieving guest users from Microsoft Entra ID..."

    $userProperties = @(
        "id",
        "displayName",
        "userPrincipalName",
        "mail",
        "userType",
        "createdDateTime",
        "accountEnabled",
        "signInActivity"
    )

    $guestUsers = @()

    try {
        $guestUsers = Get-MgUser `
            -Filter "userType eq 'Guest'" `
            -All `
            -PageSize 999 `
            -Property $userProperties
    }
    catch {
        Write-Error "Failed to retrieve guest users from Microsoft Graph. $_"
        return
    }

    if (-not $guestUsers -or $guestUsers.Count -eq 0) {
        Write-Warning "No guest users found in the tenant."
        return
    }

    Write-Verbose ("Retrieved {0} guest users from Microsoft Graph." -f $guestUsers.Count)
    #endregion

    #region Resolve InvitedBy via Directory Audit logs (best effort)
    $invitedByLookup = @{}

    try {
        Write-Verbose "Retrieving guest invitation audit logs to resolve InvitedBy values (best effort)..."

        # Audit logs retention is limited (typically 30–180 days depending on licensing),
        # so we use a 365-day lookback to catch as much as possible without going overboard.
	# Audit logs retention is typically about 30 days for directoryAudits
	$auditLookbackDays = 30
	$startDateTime = $nowUtc.AddDays(-$auditLookbackDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
	$endDateTime   = $nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")

	$directoryAuditFilter = "category eq 'UserManagement' and activityDisplayName eq 'Invite external user' and activityDateTime ge $startDateTime and activityDateTime le $endDateTime"

        $auditLogs = Get-MgAuditLogDirectoryAudit `
            -Filter $directoryAuditFilter `
            -All `
            -Property "id,activityDateTime,activityDisplayName,category,initiatedBy,targetResources"

        foreach ($log in $auditLogs) {
            if (-not $log.TargetResources) {
                continue
            }

            $initiatedByName = $null

            if ($log.InitiatedBy -and $log.InitiatedBy.User -and $log.InitiatedBy.User.DisplayName) {
                $initiatedByName = $log.InitiatedBy.User.DisplayName
            }
            elseif ($log.InitiatedBy -and $log.InitiatedBy.AdditionalProperties -and $log.InitiatedBy.AdditionalProperties.ContainsKey("user")) {
                $userObject = $log.InitiatedBy.AdditionalProperties["user"]
                if ($userObject -and $userObject.displayName) {
                    $initiatedByName = $userObject.displayName
                }
            }

            if (-not $initiatedByName) {
                continue
            }

            foreach ($target in $log.TargetResources) {
                # Prefer stable objectId when present
                if ($target.Id) {
                    if (-not $invitedByLookup.ContainsKey($target.Id)) {
                        $invitedByLookup[$target.Id] = $initiatedByName
                    }
                }
                elseif ($target.UserPrincipalName) {
                    $upnKey = $target.UserPrincipalName.ToLowerInvariant()
                    if (-not $invitedByLookup.ContainsKey($upnKey)) {
                        $invitedByLookup[$upnKey] = $initiatedByName
                    }
                }
            }
        }

        Write-Verbose ("Resolved InvitedBy information for {0} guest entries based on directory audit logs." -f $invitedByLookup.Count)
    }
    catch {
        Write-Warning ("Failed to retrieve or process directory audit logs for guest invitations. InvitedBy will be 'Unknown' where no mapping exists. Error: {0}" -f $_.Exception.Message)
    }
    #endregion

    #region Build Inactivity Report
    Write-Verbose "Calculating inactivity using signInActivity.lastSuccessfulSignInDateTime (if available)..."

    $reportObjects = @()
    $totalGuests = $guestUsers.Count
    $guestIndex = 0

    foreach ($guest in $guestUsers) {
        $guestIndex++

        $percentComplete = [int](($guestIndex / $totalGuests) * 100)
        Write-Progress -Activity "Processing guest users" -Status ("Processing {0} of {1} guest users..." -f $guestIndex, $totalGuests) -PercentComplete $percentComplete

        $lastSuccessfulSignIn = $null

        if ($guest.SignInActivity -and $guest.SignInActivity.LastSuccessfulSignInDateTime) {
            $lastSuccessfulSignIn = [datetime]$guest.SignInActivity.LastSuccessfulSignInDateTime
        }

        $hasEverSignedIn = $false
        $lastSignInDisplayValue = "Never"
        $daysInactiveDisplayValue = "Never"
        $daysInactiveNumericValue = 99999

        if ($lastSuccessfulSignIn) {
            $hasEverSignedIn = $true
            $daysInactiveNumericValue = [int](($nowUtc - $lastSuccessfulSignIn.ToUniversalTime()).TotalDays)
            if ($daysInactiveNumericValue -lt 0) {
                $daysInactiveNumericValue = 0
            }

            # Use universal sortable format so it’s unambiguous in CSV (UTC)
            $lastSignInDisplayValue = $lastSuccessfulSignIn.ToString("yyyy-MM-ddTHH:mm:ssZ")
            $daysInactiveDisplayValue = $daysInactiveNumericValue
        }
        else {
            # No successful sign-in recorded – treat as "never" unless the caller
            # explicitly asked to include never-signed-in guests.
            if (-not $IncludeNeverSignedIn.IsPresent) {
                continue
            }
        }

        # Apply inactivity threshold only for users who have ever signed in
        if ($hasEverSignedIn -and $daysInactiveNumericValue -lt $InactivityDays) {
            continue
        }

        $accountEnabledValue = $null
        if ($null -ne $guest.AccountEnabled) {
            $accountEnabledValue = [bool]$guest.AccountEnabled
        }

        # Resolve InvitedBy (best effort)
        $invitedByName = "Unknown"
        if ($invitedByLookup.ContainsKey($guest.Id)) {
            $invitedByName = $invitedByLookup[$guest.Id]
        }
        elseif ($guest.UserPrincipalName) {
            $upnKey = $guest.UserPrincipalName.ToLowerInvariant()
            if ($invitedByLookup.ContainsKey($upnKey)) {
                $invitedByName = $invitedByLookup[$upnKey]
            }
        }

        $reportObjects += [PSCustomObject]@{
            DisplayName         = $guest.DisplayName
            UserPrincipalName   = $guest.UserPrincipalName
            Mail                = $guest.Mail
            UserType            = $guest.UserType
            CreatedDateTime     = $guest.CreatedDateTime
            LastSignInDateTime  = $lastSignInDisplayValue
            DaysInactive        = $daysInactiveDisplayValue
            AccountEnabled      = $accountEnabledValue
            InvitedBy           = $invitedByName

            # Internal-only field for numeric sort
            DaysInactiveNumeric = $daysInactiveNumericValue
        }
    }

    Write-Progress -Activity "Processing guest users" -Completed -Status "Processing complete."

    if (-not $reportObjects -or $reportObjects.Count -eq 0) {
        Write-Warning "No guest users matched the specified inactivity criteria."
        return
    }
    #endregion

    #region Sort, Export, and Output
    $sortedResults = $reportObjects | Sort-Object -Property DaysInactiveNumeric -Descending

    # Strip internal sort field before exporting / returning
    $finalResults = $sortedResults | Select-Object `
        DisplayName,
        UserPrincipalName,
        Mail,
        UserType,
        CreatedDateTime,
        LastSignInDateTime,
        DaysInactive,
        AccountEnabled,
        InvitedBy

    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $outputFileName = "GuestUserInactivityReport_{0}.csv" -f $timestamp

    $scriptDirectory = Get-Location
    if ($PSCommandPath) {
        $scriptDirectory = Split-Path -Parent $PSCommandPath
    }

    $outputFilePath = Join-Path -Path $scriptDirectory -ChildPath $outputFileName

    try {
        $finalResults | Export-Csv -Path $outputFilePath -NoTypeInformation -Encoding UTF8
        Write-Verbose ("Report exported to '{0}'." -f $outputFilePath)
    }
    catch {
        Write-Warning ("Failed to export CSV report to '{0}'. Error: {1}" -f $outputFilePath, $_.Exception.Message)
    }

    # Emit objects to the pipeline so caller can re-export or post-process
    $finalResults
    #endregion
}
catch {
    Write-Error "An unexpected error occurred while generating the Guest User Inactivity Report. $_"
}
finally {
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Verbose "Disconnected from Microsoft Graph."
    }
    catch {
        Write-Verbose "Failed to disconnect from Microsoft Graph cleanly. $_"
    }
}
