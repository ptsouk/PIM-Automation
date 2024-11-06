$tenantId = ""
$subscriptionId = ""

Connect-AzAccount -TenantId $tenantId -SubscriptionId $subscriptionId
Connect-MgGraph -TenantId $tenantId -Scopes "Group.ReadWrite.All" -NoWelcome

$groups = Get-MgGroup -All
$groups | ForEach-Object -Parallel { Remove-MgGroup -GroupId $_.Id | out-null } -ThrottleLimit 10

# Get Resource Groups
function searchAzGraph {
    param (
        $kqlQuery,
        $batchSize
    )

    $skipResult = 0 
    $kqlResult = @()
    
    while ($true) {
        if ($skipResult -gt 0) {
            $graphResult = Search-AzGraph -Query $kqlQuery -First $batchSize -SkipToken $graphResult.SkipToken -UseTenantScope
        }
        else {
            $graphResult = Search-AzGraph -Query $kqlQuery -First $batchSize -UseTenantScope
        }
    
        $kqlResult += $graphResult.data
    
        if ($graphResult.data.Count -lt $batchSize) {
            break;
        }
        $skipResult += $skipResult + $batchSize
    }
    return $kqlResult
}

$subscriptions = Get-AzSubscription -TenantId $tenantId
foreach ($subscription in $subscriptions) {
    $kqlQuery = @"
    resourcecontainers 
    | where type =~ 'microsoft.resources/subscriptions/resourcegroups' 
    | where tolower(name) matches regex @"^sub\d+-rg\d+$"
    | where subscriptionId == '$($subscription.Id)'
    | project name, subscriptionId
"@
    $resourceGroups = searchAzGraph -kqlQuery $kqlQuery -batchSize 100
    Set-AzContext -SubscriptionId $subscription.Id | out-null
    $resourceGroups | ForEach-Object -Parallel {
        Remove-AzResourceGroup -Name $_.name -Force | out-null  
    } -ThrottleLimit 10
}