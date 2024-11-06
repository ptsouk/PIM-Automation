$VerbosePreference = "SilentlyContinue"
# START
# Login to Azure and Microsoft Graph
try {
    Write-Output "Logging in to Azure..."
    Connect-AzAccount -Identity -SubscriptionId "6568220f-c927-40c3-9ab9-e681106aec28" | out-null
    Write-Output "Connecting to Microsoft Graph..."
    Connect-MgGraph -Identity -NoWelcome
    Write-Output "Details of current session:"
    Get-MgContext

    $endDateTime = $((Get-date).AddDays(7))
    
    # Function to get Resource Groups
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
    # Get Resource Groups
    
    $kqlQuery = @"
    resourcecontainers 
    | where type =~ 'microsoft.resources/subscriptions/resourcegroups' 
    | where tolower(name) matches regex @"^sub\d+-rg\d+$"
    | project name, subscriptionId
    | sort by name asc
"@
    $resourceGroups = searchAzGraph -kqlQuery $kqlQuery -batchSize 100
    # Process
    Write-Output "Processing $($resourceGroups.count) Resource Groups"
    $resourceGroups | ForEach-Object -Parallel {
        $VerbosePreference = $using:VerbosePreference
        # Function to get Authorization Token
        function Get-Token {
            param (
                $resourceUrl
            )
            $token = ConvertFrom-SecureString -SecureString (Get-AzAccessToken -ResourceUrl $resourceUrl -AsSecureString -WarningAction SilentlyContinue).Token -AsPlainText
            return $token
        }
        # Function to Invoke Rest API
        function Invoke-RestAPI {
            param (
                $token,
                $uri,
                $method,
                $body,
                $successStatusCode,
                [int]$maxRetries = 5
            )

            # Create a hashtable with parameters for splatting
            if ($body) {
                $params = @{
                    Uri                     = $uri
                    Headers                 = @{"Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
                    Method                  = $method
                    Body                    = $body
                    StatusCodeVariable      = "scv"
                    ResponseHeadersVariable = "responseHeaders"
                }
            }
            else {
                $params = @{
                    Uri                     = $uri
                    Headers                 = @{"Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
                    Method                  = $method
                    StatusCodeVariable      = "scv"
                    ResponseHeadersVariable = "responseHeaders"
                }
            }
            $retryCount = 1
            $success = $false
            $scv = $null
            :apiLoop while (-not $success -and $retryCount -le $maxRetries) {
                try {                    
                    $response = Invoke-RestMethod @params -SkipHttpErrorCheck                    
                    #Write-Warning "ResponseHeaders: $($responseHeaders | ConvertTo-Json -Depth 10)"
                    switch ($scv) {
                        $successStatusCode { $success = $true }
                        404 { Write-Verbose "Invoke-RestMethod -Uri $uri returned 404 Not Found."; $response = $null; break apiLoop }
                        504 { Write-Verbose "Invoke-RestMethod -Uri $uri returned 504 TimeOut - Assuming Not Found."; $response = $null; break apiLoop }
                        Default { throw "Invoke-RestMethod -Uri $uri status code: $scv." }
                    }
                }
                catch {
                    if ($scv -ne 404 -and $scv -ne 504 -and $retryCount -lt $maxRetries) {
                        $delaySeconds = ([math]::Pow(2, $retryCount) * 5 + 1) # ResponseHeaders: "Retry-After": ["10"]
                        Write-Warning "Attempt $retryCount failed with error: $_ - Retrying in $delaySeconds seconds..."                
                        Start-Sleep -Seconds $delaySeconds
                    }
                    elseif ($scv -ne 404 -and $scv -ne 504 -and $retryCount -eq $maxRetries) {
                        Write-Warning "Attempt $retryCount failed with error: $_ - Max Retries reached."
                    }
                    $retryCount++
                }
            }
            if (-not $success -and $scv -ne 404 -and $scv -ne 504) {
                throw "Invoke-RestMethod -Uri $uri failed after $maxRetries attempts."
            }        
            return $response    
        }
        # Function to Invoke MgGraph API
        function Invoke-MgGraphAPI {
            param (
                $uri,
                $method,
                $body,
                $successStatusCode,
                [int]$maxRetries = 5
            )
        
            # Create a hashtable with parameters for splatting
            if ($body) {
                $params = @{
                    Uri                = $uri
                    ContentType        = "application/json"
                    Method             = $method
                    Body               = $body
                    StatusCodeVariable = "scv"
															   
                }
            }
            else {
                $params = @{
                    Uri                = $uri
                    ContentType        = "application/json"
                    Method             = $method
                    StatusCodeVariable = "scv"
															   
                }
            }
            $retryCount = 1
            $success = $false
            $scv = $null
            :apiLoop while (-not $success -and $retryCount -le $maxRetries) {
                try {                    
                    $response = Invoke-MgGraphRequest @params -SkipHttpErrorCheck -OutputType PSObject                    
																																		 
                    switch ($scv) {
                        $successStatusCode { $success = $true }
                        404 { Write-Verbose "Invoke-MgGraphRequest -Uri $uri returned 404 Not Found."; $response = $null; break apiLoop }
                        504 { Write-Verbose "Invoke-MgGraphRequest -Uri $uri returned 504 TimeOut - Assuming Not Found."; $response = $null; break apiLoop }
                        Default { throw "Invoke-MgGraphRequest -Uri $uri status code: $scv." }
                    }
                }
                catch {
                    if ($scv -ne 404 -and $scv -ne 504 -and $retryCount -lt $maxRetries) {
                        $delaySeconds = ([math]::Pow(2, $retryCount) * 3)
                        Write-Warning "Attempt $retryCount failed with error: $_ - Retrying in $delaySeconds seconds..."                
                        Start-Sleep -Seconds $delaySeconds
                    }
                    elseif ($scv -ne 404 -and $scv -ne 504 -and $retryCount -eq $maxRetries) {
                        Write-Warning "Attempt $retryCount failed with error: $_ - Max Retries reached."
                    }
                    $retryCount++
                }
            }
            if (-not $success -and $scv -ne 404 -and $scv -ne 504) {
                throw "Invoke-MgGraphRequest -Uri $uri failed after $maxRetries attempts."
            }        
            return $response    
        }
        # Function to get eligibilityScheduleInstance for a principal at a pim managed group
        function Get-EligibilityScheduleInstance {
            param (
                $principalId,
                $groupId,
                $method = "GET",
                $successStatusCode = 200,
                $token
            )     
        
            $privilegedAccessGroupEligibilityScheduleInstanceId = $groupId + "_member_" + $principalId
            $uri = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances/$privilegedAccessGroupEligibilityScheduleInstanceId"      
            $response = Invoke-RestAPI -token $token -uri $uri -method $method -successStatusCode $successStatusCode
            return $response
        }
        function Get-EligibilityScheduleInstanceWithMgGraph {
            param (
                $principalId,
                $groupId,
                $method = "GET",
                $successStatusCode = 200
            )     
        
            $privilegedAccessGroupEligibilityScheduleInstanceId = $groupId + "_member_" + $principalId
            $uri = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances/$privilegedAccessGroupEligibilityScheduleInstanceId"      
            $response = Invoke-MgGraphAPI -uri $uri -method $method -successStatusCode $successStatusCode
            return $response
        }
        # Function to create eligibilityScheduleRequest if not exists
        function New-EligibilityScheduleRequest {
            param (
                $uri = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleRequests",
                $method = "POST",
                $successStatusCode = 201,
                $accessId,
                $principalId,
                $principalDisplayName,
                $groupId,
                $groupDisplayName,
                $action,
                $scheduleInfo,
                $justification
            )
            $token = Get-Token -ResourceUrl "https://graph.microsoft.com/.default"
            $exists = Get-EligibilityScheduleInstance -principalId $principalId -groupId $groupId -token $token
            if (-not $exists) {
                $body = @{
                    accessId      = $accessId
                    principalId   = $principalId
                    groupId       = $groupId
                    action        = $action
                    scheduleInfo  = $scheduleInfo
                    justification = $justification
                } | ConvertTo-Json -Depth 10
                $response = Invoke-RestAPI -token $token -uri $uri -method $method -body $body -successStatusCode $successStatusCode
            }
            else {
                Write-Verbose "Eligibility Schedule Request already exists: Security Group: $principalDisplayName, PIM Group: $groupDisplayName"
            }

            return $response
        }
        # Function to create Security Group if it doesn't exist
        function New-SecurityGroup {
            param (
                $securityGroupName,
                $securityGroupDescription
            )
           
            $securityGroup = Get-MgGroup -Filter ("DisplayName eq '$securityGroupName'") -Property DisplayName, Id -ErrorAction Stop
            if ($null -eq $securityGroup) {
                $params = @{
                    DisplayName     = $($securityGroupName)
                    MailEnabled     = $false
                    MailNickName    = $($securityGroupName)
                    SecurityEnabled = $true
                    Description     = $securityGroupDescription
                }
                $securityGroup = New-MgGroup @params -ErrorAction Stop
                Write-Verbose "Security Group created: $($securityGroup.DisplayName)"
            }
            else {
                Write-Verbose "Security Group already exists: $($securityGroup.DisplayName)"
            }

            return $securityGroup
        }        
        # Function to check Role Assignment existence at Resource Group (Role Assignments - List For Resource Group)
        function Get-RoleAssignment {
            param (
                $resourceGroup,
                $securityGroup,
                $builtinRoleDefinitionId,
                $token
            )
            $uri = "https://management.azure.com/subscriptions/$($resourceGroup.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$($securityGroup.Id)'"
            $method = "GET"
            $successStatusCode = 200
            $response = Invoke-RestAPI -token $token -uri $uri -method $method -successStatusCode $successStatusCode
            if ($response.value.properties.roleDefinitionId) {
                $roleDefinitionId = ($response.value.properties.roleDefinitionId).split("/")[-1]
                if ($roleDefinitionId -eq $builtinRoleDefinitionId) {
                    $exists = $true
                }
            }    
            else {
                $exists = $false
            }
            return $exists
        }
        # Function to create Role Assignment if it doesn't exist
        function New-RoleAssignment {
            param (
                $resourceGroup,
                $securityGroup,
                $roleDefinitionName
            )
            # Azure built-in roles Ids
            switch ($roleDefinitionName) {
                "Reader" { $builtinRoleDefinitionId = "acdd72a7-3385-48ef-bd42-f606fba81ae7" }
                "Contributor" { $builtinRoleDefinitionId = "b24988ac-6180-42a0-ab88-20f7382dd24c" }
            }
            $token = Get-Token -ResourceUrl "https://management.azure.com"
            $exists = Get-RoleAssignment -resourceGroup $resourceGroup -securityGroup $securityGroup -builtinRoleDefinitionId $builtinRoleDefinitionId -token $token
            if (-not $exists) {
                Write-Verbose "Assigning Role: $roleDefinitionName, Security Group: $($securityGroup.DisplayName), Resource Group: $($resourceGroup.name)"
                
                $uri = "https://management.azure.com/subscriptions/$($resourceGroup.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/Microsoft.Authorization/roleAssignments/$((New-Guid).Guid)?api-version=2022-04-01"
                $method = "PUT"
                $successStatusCode = 201
                $body = @{
                    properties = @{
                        roleDefinitionId = "/subscriptions/$($resourceGroup.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$builtinRoleDefinitionId"
                        principalId      = $securityGroup.Id
                        principalType    = "Group"
                    }
                } | ConvertTo-Json -Depth 10
                $response = Invoke-RestAPI -token $token -uri $uri -method $method -body $body -successStatusCode $successStatusCode                
            }
            else {
                Write-Verbose "Assignment already exists: $roleDefinitionName, Security Group: $($securityGroup.DisplayName), Resource Group: $($resourceGroup.name)"
            }

            return $response
        }

        ### Create Security Groups Start ###
        # Create the Default Security Group if it doesn't exist
        $securityGroupName = $PSItem.name
        Write-Output "Creating Security Group: $securityGroupName"
        $securityGroupDescription = "Members of Security Group: $securityGroupName, are eligible for PIM Group Access to Resource Group: $($PSItem.name)"
        $defaultSecurityGroup = New-SecurityGroup -securityGroupName $securityGroupName -securityGroupDescription $securityGroupDescription
        # Create the Readers Security Group if it doesn't exist
        $securityGroupName = $PSItem.name + "-Readers"
        Write-Output "Creating Security Group: $securityGroupName"
        $securityGroupDescription = "Members of Security Group: $securityGroupName, are assigned as Readers to Resource Group: $($PSItem.name)"
        $readersSecurityGroup = New-SecurityGroup -securityGroupName $securityGroupName -securityGroupDescription $securityGroupDescription
        # Create the Contributors Security Group if it doesn't exist
        $securityGroupName = $PSItem.name + "-Contributors"
        Write-Output "Creating Security Group: $securityGroupName"
        $securityGroupDescription = "Members of Security Group: $securityGroupName, are assigned as Contributors to Resource Group: $($PSItem.name)"
        $contributorsSecurityGroup = New-SecurityGroup -securityGroupName $securityGroupName -securityGroupDescription $securityGroupDescription
        ### Create Security Groups End ###
        
        #
        ### Assign PIM eligibility to Groups Start ### 
        # readersSecurityGroup
        Write-Output "Assigning PIM eligibility to Group: $($defaultSecurityGroup.DisplayName), PIM Group: $($readersSecurityGroup.DisplayName), EndDateTime: $using:endDateTime"    
        $newEligibilityScheduleRequest = New-EligibilityScheduleRequest `
            -accessId "member" `
            -principalId $defaultSecurityGroup.Id `
            -principalDisplayName $defaultSecurityGroup.DisplayName `
            -groupId $readersSecurityGroup.Id `
            -groupDisplayName $readersSecurityGroup.DisplayName `
            -action "AdminAssign" `
            -scheduleInfo @{
            startDateTime = $(Get-Date)
            expiration    = @{
                type        = "AfterDateTime"
                endDateTime = $using:endDateTime
            }
        } `
            -justification "Members of $($defaultSecurityGroup.DisplayName) eligible members of $($readersSecurityGroup.DisplayName) until $using:endDateTime"
        # contributorsSecurityGroup
        Write-Output "Assigning PIM eligibility to Group: $($defaultSecurityGroup.DisplayName), PIM Group: $($contributorsSecurityGroup.DisplayName), EndDateTime: $using:endDateTime"    
        $newEligibilityScheduleRequest = New-EligibilityScheduleRequest `
            -accessId "member" `
            -principalId $defaultSecurityGroup.Id `
            -principalDisplayName $defaultSecurityGroup.DisplayName `
            -groupId $contributorsSecurityGroup.Id `
            -groupDisplayName $contributorsSecurityGroup.DisplayName `
            -action "AdminAssign" `
            -scheduleInfo @{
            startDateTime = $(Get-Date)
            expiration    = @{
                type        = "AfterDateTime"
                endDateTime = $using:endDateTime
            }
        } `
            -justification "Members of $($defaultSecurityGroup.DisplayName) eligible members of $($contributorsSecurityGroup.DisplayName) until $using:endDateTime"
        ### Assign PIM eligibility to Groups End ###
        #>
		 
        ### Create Reader Role Assignments on Resource Group Start ###
        $readersSecurityGroup = Get-MgGroup -Filter ("DisplayName eq '$($PSItem.name)-Readers'") -Property DisplayName, Id
        if ($readersSecurityGroup -and $readersSecurityGroup.count -eq 1) {
            Write-Output "Assigning Role: Reader, Security Group: $($readersSecurityGroup.DisplayName), Resource Group: $($PSItem.name)"
            $newRoleAssignment = New-RoleAssignment -resourceGroup $PSItem -securityGroup $readersSecurityGroup -roleDefinitionName "Reader"
        }
        elseif ($readersSecurityGroup.count -gt 1) {
            Write-Error "Error: Check Security Group: $($PSItem.name)-Readers for duplicates."
        }
        elseif (-not $readersSecurityGroup) {
            Write-Error "Error: Check Security Group: $($PSItem.name)-Readers if exists."
        }
        ### Create Reader Role Assignments on Resource Group End ###

        ### Create Contributor Role Assignments on Resource Group Start ###
        $contributorsSecurityGroup = Get-MgGroup -Filter ("DisplayName eq '$($PSItem.name)-Contributors'") -Property DisplayName, Id
        if ($contributorsSecurityGroup -and $contributorsSecurityGroup.count -eq 1) {
            Write-Output "Assigning Role: Contributor, Security Group: $($contributorsSecurityGroup.DisplayName), Resource Group: $($PSItem.name)"
            $newRoleAssignment = New-RoleAssignment -resourceGroup $PSItem -securityGroup $contributorsSecurityGroup -roleDefinitionName "Contributor"
        }
        elseif ($contributorsSecurityGroup.count -gt 1) {
            Write-Error "Error: Check Security Group: $($PSItem.name)-Contributors for duplicates."
        }
        elseif (-not $contributorsSecurityGroup) {
            Write-Error "Error: Check Security Group: $($PSItem.name)-Contributors if exists."
        }
        ### Create Contributor Role Assignments on Resource Group End ###

    } -ThrottleLimit 10 #End
    Write-Output "Script completed."
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}