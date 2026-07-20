#requires -Version 5.1
<#
.SYNOPSIS
    Exports Intune app assignments and flags potentially conflicting assignment intents.
.DESCRIPTION
    Read-only reporting script. Connects to Microsoft Graph via the shared IntuneToolkit module,
    inventories every app in Intune's app catalog, records each app's assignments (intent, target
    group/filter), and flags any app/group/target combination assigned with conflicting intents
    (e.g. both "required" and "uninstall", or both "available" and "uninstall" for the same group).
.PARAMETER IncludeUnassignedApps
    Include a row for apps that have no assignments at all (Intent = 'Unassigned'). Without this
    switch, unassigned apps are simply omitted from the report.
.PARAMETER OutputRoot
    Root folder under which the ApplicationAssignmentAnalyzer report folder is created.
    Defaults to <MyDocuments>\IntuneToolkitReports.
.NOTES
    Script version: 1.0.0
    Read-only: makes no changes to Intune or Entra ID.
#>
[CmdletBinding()]
param(
    [switch]$IncludeUnassignedApps,
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'IntuneToolkitReports')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\Shared\IntuneToolkit.Common.psm1') -Force
Connect-ToolkitGraph @('DeviceManagementApps.Read.All', 'Group.Read.All') | Out-Null
$outputFolder = New-ToolkitFolder 'ApplicationAssignmentAnalyzer' $OutputRoot

# Get-ToolkitCollection returns the raw OData response object for a URL (a hashtable/object with
# '@odata.context' and 'value' keys, plus '@odata.nextLink' when more pages remain) rather than a
# flattened array of items. This helper unwraps 'value' and follows nextLink until exhausted, so
# every call site below gets a plain array of item objects, regardless of that internal shape.
function Get-ToolkitGraphItems {
    param([Parameter(Mandatory)][string]$Uri)

    $items   = New-Object System.Collections.Generic.List[object]
    $nextUri = $Uri

    while ($nextUri) {
        $response = Get-ToolkitCollection $nextUri
        $nextUri  = $null

        if ($response -is [System.Collections.IDictionary]) {
            if ($response.ContainsKey('value')) {
                foreach ($item in $response['value']) { $items.Add($item) }
            }
            if ($response.ContainsKey('@odata.nextLink')) {
                $nextUri = [string]$response['@odata.nextLink']
            }
        }
        elseif ($response.PSObject.Properties.Name -contains 'value') {
            foreach ($item in $response.value) { $items.Add($item) }
            if ($response.PSObject.Properties.Name -contains '@odata.nextLink') {
                $nextUri = [string]$response.'@odata.nextLink'
            }
        }
        else {
            foreach ($item in @($response)) { $items.Add($item) }
        }
    }

    return $items
}

# Graph items unwrapped above are Hashtables. For a Hashtable, .PSObject.Properties.Name only
# lists the Hashtable CLASS's own real members (Count, Keys, Values, etc.) - it does NOT list the
# dictionary's own keys, even though dot-notation access (e.g. $item.foo) resolves those keys via
# a separate PowerShell language fallback. That mismatch makes property-existence checks against
# these items silently always false. This helper checks the right way for either shape.
function Get-ToolkitValue {
    param($InputObject, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.ContainsKey($Name)) { return $InputObject[$Name] }
        return $null
    }
    if ($InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $null
}

# Graph omits assignment-target fields entirely when they don't apply (e.g. no assignment filter
# is set on that assignment), rather than including them as null. Resolve-ToolkitTarget (in the
# shared module) reads some of these unconditionally, so a genuinely-missing key crashes it. Note
# that this script's Set-StrictMode setting does not reach into the module's functions either way
# - functions imported from a module run in the module's own scope chain, not as a child of this
# script's scope - so the fix has to be on the data we hand it: pad it with $null defaults for the
# standard assignmentTarget schema fields so every key the module might read is guaranteed to
# exist.
function ConvertTo-ToolkitAssignmentTarget {
    param($RawTarget)

    if ($null -eq $RawTarget) { return $RawTarget }
    if ($RawTarget -isnot [System.Collections.IDictionary]) { return $RawTarget }

    $padded = @{}
    foreach ($key in $RawTarget.Keys) { $padded[$key] = $RawTarget[$key] }
    foreach ($defaultKey in @(
        'groupId',
        'deviceAndAppManagementAssignmentFilterId',
        'deviceAndAppManagementAssignmentFilterType'
    )) {
        if (-not $padded.ContainsKey($defaultKey)) { $padded[$defaultKey] = $null }
    }
    return $padded
}

$groupMemberCache = @{}
$assignmentRows   = New-Object System.Collections.Generic.List[object]

# Retrieve every app in the tenant's Intune app catalog.
$apps = @(Get-ToolkitGraphItems 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps')

foreach ($app in $apps) {
    $appName = [string](Get-ToolkitValue $app 'displayName')
    $appId   = [string](Get-ToolkitValue $app 'id')
    Write-Host "Processing: $appName"

    try {
        $assignments = @(Get-ToolkitGraphItems "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/assignments")
    } catch {
        Write-Warning "Skipping '$appName' - failed to retrieve assignments: $_"
        continue
    }

    if ($assignments.Count -eq 0 -and $IncludeUnassignedApps) {
        $assignmentRows.Add([pscustomobject]@{
            AppName    = $appName
            Publisher  = Get-ToolkitValue $app 'publisher'
            AppType    = Get-ToolkitValue $app '@odata.type'
            AppId      = $appId
            Intent     = 'Unassigned'
            TargetType = ''
            GroupName  = ''
            GroupId    = ''
            FilterType = ''
            FilterId   = ''
        })
    }

    foreach ($assignment in $assignments) {
        $assignmentTarget = ConvertTo-ToolkitAssignmentTarget (Get-ToolkitValue $assignment 'target')
        $target = Resolve-ToolkitTarget $assignmentTarget $groupMemberCache

        $assignmentRows.Add([pscustomobject]@{
            AppName    = $appName
            Publisher  = Get-ToolkitValue $app 'publisher'
            AppType    = Get-ToolkitValue $app '@odata.type'
            AppId      = $appId
            Intent     = Get-ToolkitValue $assignment 'intent'
            TargetType = $target.TargetType
            GroupName  = $target.GroupName
            GroupId    = $target.GroupId
            FilterType = $target.FilterType
            FilterId   = $target.FilterId
        })
    }
}

# Flag app/group/target combinations assigned with conflicting intents - e.g. the same group
# assigned both "required" and "uninstall", or both "available" and "uninstall", for one app.
$conflictRows = New-Object System.Collections.Generic.List[object]

foreach ($group in ($assignmentRows | Group-Object AppId, GroupId, TargetType)) {
    $intents = @($group.Group.Intent | Sort-Object -Unique)
    $hasConflict = (($intents -contains 'required' -and $intents -contains 'uninstall')) -or
                   (($intents -contains 'available' -and $intents -contains 'uninstall'))

    if ($hasConflict) {
        $first = $group.Group[0]
        $conflictRows.Add([pscustomobject]@{
            AppName   = $first.AppName
            AppId     = $first.AppId
            TargetType = $first.TargetType
            GroupName = $first.GroupName
            Intents   = ($intents -join '; ')
            Finding   = 'Potential conflicting application intent'
        })
    }
}

$assignmentSummary = $assignmentRows | Group-Object Intent | Select-Object `
    @{Name = 'Intent'; Expression = { $_.Name } }, `
    @{Name = 'AssignmentCount'; Expression = { $_.Count } }

$assignmentRows | Sort-Object AppName, Intent, GroupName |
    Export-Csv (Join-Path $outputFolder 'ApplicationAssignments.csv') -NoTypeInformation -Encoding ASCII
$conflictRows |
    Export-Csv (Join-Path $outputFolder 'PotentialIntentConflicts.csv') -NoTypeInformation -Encoding ASCII
$assignmentSummary |
    Export-Csv (Join-Path $outputFolder 'AssignmentSummary.csv') -NoTypeInformation -Encoding ASCII

Write-Host "Complete. Apps: $($apps.Count); assignments: $($assignmentRows.Count); conflicts: $($conflictRows.Count)" -ForegroundColor Green
Write-Host "Output: $outputFolder"
