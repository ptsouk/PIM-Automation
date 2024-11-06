$tenantId = ""
$subscriptionId = ""
$location = ""

Connect-AzAccount -TenantId $tenantId -SubscriptionId $subscriptionId

$subscriptions = Get-AzSubscription -TenantId $tenantId | Where-Object { $_.Name -like "SUB0*" }

# Create Resource Groups
foreach ($subscription in $subscriptions) {
    Set-AzContext -SubscriptionId $subscription.Id | out-null
    $resourceGroups = 1..100 | ForEach-Object { "$($subscription.Name)-RG$($PSItem.ToString().PadLeft(2, '0'))" }
    $resourceGroups | ForEach-Object -Parallel {
        (New-AzResourceGroup -Name $_ -Location $location -ErrorAction SilentlyContinue).ResourceGroupName
    } -ThrottleLimit 10
}