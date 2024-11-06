# https://techcommunity.microsoft.com/t5/azure-integration-services-blog/grant-graph-api-permission-to-managed-identity-object/ba-p/2792127
# https://learn.microsoft.com/en-us/graph/permissions-reference
# https://learn.microsoft.com/en-us/powershell/module/az.resources/?view=azps-12.4.0

$tenantId = ""
$subscriptionId = ""
$GraphAppId = "00000003-0000-0000-c000-000000000000"
$DisplayNameOfMSI = "pim-automation-aa"

Connect-AzAccount -TenantID $tenantId -SubscriptionId $subscriptionId

#$PermissionNames = "PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup", "PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup", "Group.ReadWrite.All", "User.ReadWrite.All", "PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup", "Domain.Read.All", "RoleManagementPolicy.ReadWrite.AzureADGroup"
$PermissionNames = "PrivilegedAccess.Read.AzureADGroup", "PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup", "RoleManagementPolicy.ReadWrite.AzureADGroup", "Group.ReadWrite.All", "Domain.Read.All"


$MSI = Get-AzADServicePrincipal -DisplayName $DisplayNameOfMSI
Start-Sleep -Seconds 10
$GraphServicePrincipal = Get-AzADServicePrincipal -ApplicationId $GraphAppId
foreach ($PermissionName in $PermissionNames)
{
    $AppRole = $GraphServicePrincipal.AppRole | Where-Object {$_.Value -eq $PermissionName -and $_.AllowedMemberType -contains "Application"}
    New-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $MSI.Id -ResourceId $GraphServicePrincipal.Id -AppRoleId $AppRole.Id
}
Start-Sleep -Seconds 10
$roleAssignments = Get-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $MSI.Id
# Verify
foreach ($roleAssignment in $roleAssignments)
{
    ($GraphServicePrincipal.AppRole | Where-Object {$_.Id -eq $roleAssignment.AppRoleId}).Value
}
<# Remove
foreach ($roleAssignment in $roleAssignments)
{
    Remove-AzADServicePrincipalAppRoleAssignment -AppRoleAssignmentId $roleAssignment.Id -ServicePrincipalId $MSI.Id
}
#> 