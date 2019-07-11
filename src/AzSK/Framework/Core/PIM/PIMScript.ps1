#Acquire Access token
class PIM: CommandBase {
    hidden $APIroot = [string]::Empty
    hidden $headerParams = "";
    hidden $UserId = "";
    hidden  $AccessToken = "";
    hidden $AccountId = "" ;
    hidden $abortflow = 0;

    PIM([string] $subscriptionId, [InvocationInfo] $invocationContext)
    : Base([string] $subscriptionId, [InvocationInfo] $invocationContext) {
        $this.DoNotOpenOutputFolder = $true;
        $this.AccessToken = "";
        $this.AccountId = "";
        $this.APIroot = "https://api.azrbac.mspim.azure.com/api/v2/privilegedAccess/azureResources";
    }
  
    #Acquire Access token
    AcquireToken() {
        # Using helper method to get current context and access token   
        $ResourceAppIdURI = [WebRequestHelper]::GetServiceManagementUrl()
        $this.AccessToken = [Helpers]::GetAccessToken($ResourceAppIdURI);
        $this.headerParams = @{'Authorization' = "Bearer $($this.AccessToken)" }
        $this.AccountId = [Helpers]::GetCurrentSessionUser()
        $ADUserDetails = Get-AzADUser -UserPrincipalName  $this.AccountId
        if($null -ne $ADUserDetails) {
        $this.UserId = ($ADUserDetails).Id
        }
        
        
    
    }

    #Gets the jit assignments for logged-in user
    hidden [PSObject] MyJitAssignments() {
        $this.AcquireToken();  
        if( -not [string]::IsNullOrEmpty($this.UserId))
        {  
            $urlme = $this.APIroot + "/roleAssignments?`$expand=linkedEligibleRoleAssignment,subject,roleDefinition(`$expand=resource)&`$filter=(subject/id%20eq%20%27$($this.UserId)%27)+and+(assignmentState%20eq%20%27Eligible%27)"
            $assignments = [WebRequestHelper]::InvokeWebRequest('Get', $urlme, $this.headerParams, $null, [string]::Empty, $false, $false )
            $assignments = $assignments | Sort-Object  roleDefinition.resource.type , roleDefinition.resource.displayName
            $obj = @()        
            if (($assignments | Measure-Object).Count -gt 0) {
                $i = 0
                foreach ($assignment in $assignments) {
                    $item = New-Object psobject -Property @{
                        Id             = ++$i
                        IdGuid         = $assignment.id
                        ResourceId     = $assignment.roleDefinition.resource.id
                        OriginalId     = $assignment.roleDefinition.resource.externalId
                        ResourceName   = $assignment.roleDefinition.resource.displayName
                        ResourceType   = $assignment.roleDefinition.resource.type
                        RoleId         = $assignment.roleDefinition.id
                        RoleName       = $assignment.roleDefinition.displayName
                        ExpirationDate = $assignment.endDateTime
                        SubjectId      = $assignment.subject.id
                    }
                    $obj = $obj + $item
                }
            }
            
            return $obj
        }
        else {
            $this.PublishCustomMessage("Unable to retrieve details for the current context.",[MessageType]::Error)
            return $null
        }
    }

    # This function resolves the resource that matches to parameters passed in command
    hidden [PIMResource] PIMResourceResolver($SubscriptionId, $ResourceGroupName, $ResourceName) {
        $rtype = 'subscription'
        $selectedResourceName = $SubscriptionId.Trim()
    
        if (-not([string]::IsNullOrEmpty($resourcegroupName))) {
            $selectedResourceName = $resourcegroupName;
            $rtype = 'resourcegroup'
        }
        if (-not([string]::IsNullOrEmpty($resourceName))) {
            $selectedResourceName = $resourceName;
            $rtype = 'resource'
        }
        $item = New-Object psobject -Property @{
            ResourceType = $rtype
            ResourceName = $selectedResourceName
        }
        $resources = $this.ListResources($item.ResourceType, $item.ResourceName);
        if($item.ResourceType -eq 'resource')
        {
            $resolvedResource = $resources | Where-Object { $_.ResourceName -eq $item.ResourceName}
            #If context has access over resourcegroups or resources with same name, get a match based on Subscription and rg passed in param
            if (($resolvedResource | Measure-Object).Count -gt 1) {       
           
                $resolvedResource = $resolvedResource | Where-Object { $_.ExternalId -match $SubscriptionId }
                if (-not([string]::IsNullOrEmpty($ResourceGroupName))) {
                    $resolvedResource = $resolvedResource | Where-Object { $_.ExternalId -match $ResourceGroupName }
                }
        
            }
        }
        else
        {
            $resolvedResource = [PIMResource]::new()
            if($item.ResourceType -eq 'subscription')
            {
                $resolvedResource.ExternalId = "/subscriptions/$($item.ResourceName)"
            }
            elseif($item.ResourceType -eq 'resourcegroup')
            {
                $resolvedResource.ExternalId = "/subscriptions/$($SubscriptionId.Trim())/resourceGroups/$($item.ResourceName)"
            }
            if($null -ne $resources)
            {
                $temp = $resources | Where-Object { $_.ExternalId -eq $resolvedResource.ExternalId}
                if(($temp| Measure-Object).Count -gt 0)
                {
                    $resolvedResource = $temp
                }
            }
        }
        return $resolvedResource    
    }
    #List all the resources accessible to context.
    hidden [System.Collections.Generic.List[PIMResource]] ListResources($type, $resourceName) {
        $this.AcquireToken();
        $resources = $null
        $resourceUrl = $null
        # This seperation is required due to nature of API, it operates in paging/batching manner when we query for all types
        # Note: At present, we do not provide PIM operation management for management group. However, if needed in the future, it can be added in the else statement. >> $filter=(type%20eq%20%27managementgroup%27)
        
        if($type -eq 'subscription')
        {
            # Fetch PIM details of the all subscriptions user has access to
            $resourceUrl = $this.APIroot + "/resources?`$select=id,displayName,type&`$filter=(type%20eq%20%27subscription%27)&`$orderby=type"
        }
        elseif($type -eq 'resourcegroup')
        {
            # Fetch PIM details of the specified resource group
            $resourceUrl = $this.APIroot + "/resources?`$select=id,displayName,type&`$filter=(type%20eq%20%27resourcegroup%27)%20and%20contains(tolower(displayName),%20%27{0}%27)&`$orderby=type" -f $resourceName.ToLower()
        }
        elseif($type -eq 'resource')
        {
            # Fetch PIM details of the specified resource
            $resourceUrl = $this.APIroot + "/resources?`$select=id,displayName,type&`$filter=(type%20ne%20%27resourcegroup%27%20and%20type%20ne%20%27subscription%27%20and%20type%20ne%20%27managementgroup%27)%20and%20contains(tolower(displayName),%20%27{0}%27)" -f $resourceName.ToLower()
        }               
        
        $response = $null
        try
        {
            $response = Invoke-WebRequest -UseBasicParsing -Headers $this.headerParams -Uri $resourceUrl -Method Get
            $values = ConvertFrom-Json $response.Content
            $resources = $values.value
            $hasOdata = $values | Get-Member -Name '@odata.nextLink'
            while ($null -ne $hasOdata -and -not([string]::IsNullOrEmpty(($values).'@odata.nextLink')))
            {
                $response = Invoke-WebRequest -UseBasicParsing -Headers $this.headerParams -Uri $(($values).'@odata.nextLink') -Method Get
                $values = ConvertFrom-Json $response.Content
                $resources += $values.value
                $hasOdata = $values | Get-Member -Name '@odata.nextLink'
            }
        }
        catch
        {
            if([Helpers]::CheckMember($_,"ErrorDetails.Message"))
            {
                $this.PublishCustomMessage($_.ErrorDetails.Message,[MessageType]::Error)
            }
            else
            {
                $this.PublishCustomMessage($_.Exception, [MessageType]::Error)
            }
            return $null;
        }
        
        $i = 0
        $obj = New-Object "System.Collections.Generic.List[PIMResource]"
        foreach ($resource in $resources) {
            $item = New-Object PIMResource
            $item.Id = ++$i
            $item.ResourceId = $resource.id
            $item.ResourceName = $resource.DisplayName
            $item.Type = $resource.type
            $item.ExternalId = $resource.externalId
            $obj.Add($item);
        }
        return $obj
    }



    #List roles
    hidden [PSObject] ListRoles($resourceId) {
        $this.AcquireToken();
        $url = $this.APIroot + "resources/" + $resourceId + "/roleDefinitions?`$select=id,displayName,type,templateId,resourceId,externalId,subjectCount,eligibleAssignmentCount,activeAssignmentCount&`$orderby=activeAssignmentCount%20desc"
        $roles = [WebRequestHelper]::InvokeWebRequest("Get", $url, $this.headerParams, $null, [string]::Empty, $false, $false )
        $i = 0
        $obj = @()
        foreach ($role in $roles.value) {
            $item = New-Object psobject -Property @{
                Id               = ++$i
                RoleDefinitionId = $role.id
                RoleName         = $role.DisplayName
                SubjectCount     = $role.SubjectCount
            }
            $obj = $obj + $item
        }

        return $obj 
    }

    #List Assignment
    hidden [PSObject] ListAssignmentsWithFilter($resourceId, $IsPermanent) {
        $this.AcquireToken()
        $url = $this.APIroot + "resources/" + $resourceId + "`/roleAssignments?`$expand=subject,roleDefinition(`$expand=resource)"
        #Write-Host $url
        $roleAssignments = [WebRequestHelper]::InvokeWebRequest('Get', $url, $this.headerParams, $null, [string]::Empty, $false, $false )
        $i = 0
        $obj = @()
        $assignments = @();
        foreach ($roleAssignment in $roleAssignments.value) {
            $item = New-Object psobject -Property @{
                Id               = ++$i
                RoleAssignmentId = $roleAssignment.id
                ResourceId       = $roleAssignment.roleDefinition.resource.id
                OriginalId       = $roleAssignment.roleDefinition.resource.externalId
                ResourceName     = $roleAssignment.roleDefinition.resource.displayName
                ResourceType     = $roleAssignment.roleDefinition.resource.type
                RoleId           = $roleAssignment.roleDefinition.id
                IsPermanent      = $roleAssignment.IsPermanent
                RoleName         = $roleAssignment.roleDefinition.displayName
                ExpirationDate   = $roleAssignment.endDateTime
                SubjectId        = $roleAssignment.subject.id
                SubjectType      = $roleAssignment.subject.type
                UserName         = $roleAssignment.subject.displayName
                AssignmentState  = $roleAssignment.AssignmentState
                MemberType       = $roleAssignment.memberType
                PrincipalName    = $roleAssignment.subject.principalName
            }
            $obj = $obj + $item
        }
        if (($obj | Measure-Object).Count -gt 0) {
            if ($IsPermanent) {
                $assignments = $obj | Where-Object { $_.IsPermanent -eq $true }
                
            }
            else {
                $assignments = $obj | Where-Object { $_.IsPermanent -eq $false }
                
            }
        }
        
        return $assignments
    }

    #Activates the user
    hidden Activate($SubscriptionId, $ResourceGroupName, $ResourceName, $roleName, $Justification, $Duration) {
        $this.AcquireToken();
        $assignments = $this.MyJitAssignments()
        $resource = $this.PIMResourceResolver($SubscriptionId, $ResourceGroupName, $ResourceName)

        if (($assignments | Measure-Object).Count -gt 0 -and (-not [string]::IsNullOrEmpty($resource.ExternalId))) {
            $matchingAssignment = $assignments | Where-Object { $_.OriginalId -eq $resource.ExternalId -and $_.RoleName -eq $roleName }
            if (($matchingAssignment | Measure-Object).Count -gt 0) {
                $this.PublishCustomMessage("Requesting activation of your [$($matchingAssignment.RoleName)] role on [$($matchingAssignment.ResourceName)]... ", [MessageType]::Info);
                $resourceId = $matchingAssignment.ResourceId
                $roleDefinitionId = $matchingAssignment.RoleId
                $subjectId = $matchingAssignment.SubjectId
                $RoleActivationurl = $this.APIroot + "/roleAssignmentRequests "
                $postParams = '{"roleDefinitionId":"' + $roleDefinitionId + '","resourceId":"' + $resourceId + '","subjectId":"' + $subjectId + '","assignmentState":"Active","type":"UserAdd","reason":"' + $Justification + '","schedule":{"type":"Once","startDateTime":"' + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + '","duration":"PT' + $Duration + 'H"},"linkedEligibleRoleAssignmentId":"' + $matchingAssignment.IdGuid + '"}'
                $response = [WebRequestHelper]::InvokeWebRequest('Post', $RoleActivationurl, $this.headerParams, $postParams, "application/json", $false, $true )
                    if ($response.StatusCode -eq 201) {
                        $this.PublishCustomMessage("Activation queued successfully. The role(s) should get activated in a few minutes.", [MessageType]::Update);
                    }
            }
            else {
                $this.PublishCustomMessage("No matching eligible role found for the current context", [MessageType]::Warning)
            }
        }    
        else {
            $this.PublishCustomMessage("No eligible role found for the current context", [MessageType]::Warning)
        }
    }

    #Deactivates the user
    hidden Deactivate($SubscriptionId, $ResourceGroupName, $ResourceName, $roleName) {
        $this.AcquireToken();
        $assignments = $this.MyJitAssignments() 
        if(($assignments| Measure-Object).Count -gt 0) {
            $assignments = $assignments|Where-Object { -not [string]::IsNullorEmpty($_.ExpirationDate) }
            $resource = $this.PIMResourceResolver($SubscriptionId, $ResourceGroupName, $ResourceName)

            if (($assignments | Measure-Object).Count -gt 0 -and (-not [string]::IsNullOrEmpty($resource.ExternalId))) {
                $matchingAssignment = $assignments | Where-Object { $_.OriginalId -eq $resource.ExternalId -and $_.RoleName -eq $roleName }
                if (($matchingAssignment | Measure-Object).Count -gt 0)
                {     
                    $this.PublishCustomMessage("Requesting deactivation of your [$($matchingAssignment.RoleName)] role on [$($matchingAssignment.ResourceName)]... ", [MessageType]::Info);
                    $id = $matchingAssignment.IdGuid
                    $resourceId = $matchingAssignment.ResourceId
                    $roleDefinitionId = $matchingAssignment.RoleId
                    $subjectId = $matchingAssignment.SubjectId
                    $deactivationurl = $this.APIroot + "/roleAssignmentRequests "
                    $postParams = '{"roleDefinitionId":"' + $roleDefinitionId + '","resourceId":"' + $resourceId + '","subjectId":"' + $subjectId + '","assignmentState":"Active","type":"UserRemove","linkedEligibleRoleAssignmentId":"' + $id + '"}'
                    $response = [WebRequestHelper]::InvokeWebRequest('Post', $deactivationurl, $this.headerParams, $postParams, "application/json", $false, $true )
                        if ($response.StatusCode -eq '201') {
                            $this.PublishCustomMessage("Deactivation queued successfully. The role(s) should get deactivated in a few minutes.", [MessageType]::Update);
                        }
                }
                else
                {
                    $this.PublishCustomMessage("No active assignments found for the current context.", [MessageType]::Warning);
                }
            }
            else {
                $this.PublishCustomMessage("No active assignments found for the current context.", [MessageType]::Warning);
            }
        }

    }

    #List RoleAssignment
    hidden ListAssignment($SubscriptionId, $ResourceGroupName, $ResourceName, $RoleNames, $CheckPermanent) {
        $this.AcquireToken();
        $criticalRoles = @();
        $criticalRoles += $this.ConvertToStringArray($RoleNames)
        $resources = $this.PIMResourceResolver($SubscriptionId, $ResourceGroupName, $ResourceName)
        if (($resources | Measure-Object).Count -gt 0 -and (-not [string]::IsNullOrEmpty($resources.ResourceId))) {       
            $roleAssignments = $this.ListAssignmentsWithFilter($resources.ResourceId, $CheckPermanent)
            if(-not [String]::IsNullOrEmpty($RoleNames))
            {
                $roleAssignments = $roleAssignments | Where-Object { $_.RoleName -in $criticalRoles -and $_.MemberType -ne 'Inherited' }
            }
            else
            {
                $roleAssignments = $roleAssignments | Where-Object { $_.MemberType -ne 'Inherited' }
            }
            if (($roleAssignments | Measure-Object).Count -gt 0) {
                $roleAssignments = $roleAssignments | Sort-Object -Property RoleName, Name 
                $this.PublishCustomMessage("")
                $this.PublishCustomMessage([Constants]::SingleDashLine, [MessageType]::Default)
                $this.PublishCustomMessage($($roleAssignments | Format-Table -Property @{Label = "Role"; Expression = { $_.RoleName } }, PrincipalName, AssignmentState, @{Label = "Type"; Expression = { $_.SubjectType } } | Out-String), [MessageType]::Default)
            }
            else {
                if ($CheckPermanent) {
                    $this.PublishCustomMessage("No permanent assignments found for this combination.", [MessageType]::Warning);
                }
                else {
                    $this.PublishCustomMessage("No PIM eligible assignments found for this combination.", [MessageType]::Warning);
                }    
            }
        }
        else {
            $this.PublishCustomMessage("No active assignments found for the current logged in context.", [MessageType]::Warning )
        }
        
    }

    #Assign a user to Eligible Role
    hidden AssignPIMRole($subscriptionId, $resourcegroupName, $resourceName, $roleName, $PrincipalName, $duration) {
        $this.AcquireToken();
        $resolvedResource = $this.PIMResourceResolver($subscriptionId, $resourcegroupName, $resourceName)
        if (($resolvedResource | Measure-Object).Count -gt 0 -and (-not [string]::IsNullOrEmpty($resolvedResource.ResourceId))) {
            $resourceId = $resolvedResource.ResourceId
            $roles = $this.ListRoles($resourceId)
            $roleDefinitionId = ($roles | Where-Object { $_.RoleName -eq $RoleName }).RoleDefinitionId
            $users = $null
            $subjectId = "";
            try {
                $users = Get-AzADUser -UserPrincipalName $PrincipalName
            }
            catch {
                $this.PublishCustomMessage("Unable to fetch details of the principal name provided.", [MessageType]::Warning)
                return;
            }
            if (($users | Measure-Object).Count -gt 0) {
                $subjectId = $users.Id
            }
            else {
                $this.PublishCustomMessage("Unable to fetch details of the principal name provided.", [MessageType]::Error)
                return;
            }            
            $url = $this.APIroot + "/roleAssignmentRequests"
            # Update end time
            if (-not($duration)) {
                $duration = 15
            }
            $ts = New-TimeSpan -Days $duration
            $postParams = '{"assignmentState":"Eligible","type":"AdminAdd","reason":"Assign","roleDefinitionId":"' + $roleDefinitionId + '","resourceId":"' + $resourceId + '","subjectId":"' + $subjectId + '","schedule":{"startDateTime":"' + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + '","endDateTime":"' + ((get-date) + $ts).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + '","type":"Once"}}'
            $response = [WebRequestHelper]::InvokeWebRequest('Post', $url, $this.headerParams, $postParams, "application/json", $false, $true )
            if ($response.StatusCode -eq 201) {
                $this.PublishCustomMessage("Assignment request for [$PrincipalName] for the [$RoleName] role on [$($resolvedResource.ResourceName)] queued successfully.", [MessageType]::Update);
            }  
            if ($response.StatusCode -eq 401) {
                $this.PublishCustomMessage("You are not eligible to assign a role. If you have recently elevated/activated your permissions, please run Connect-AzAccount and re-run the script.", [MessageType]::Error);
            }          
            
           
        }
        else {
            $this.PublishCustomMessage( "Unable to find resource on which assignment was requested. Either the resource does not exist or you may not have permissions for assigning a role on it", [MessageType]::Warning)
        }
    }

    hidden ListMyEligibleRoles() {
        $assignments = $this.MyJitAssignments()
        if (($assignments | Measure-Object).Count -gt 0) {
            $this.PublishCustomMessage("Your eligible role assignments:", [MessageType]::Default)
            $this.PublishCustomMessage("");
            $this.PublishCustomMessage([Constants]::SingleDashLine, [MessageType]::Default)
            $this.PublishCustomMessage(($assignments | Format-Table -AutoSize Id, RoleName, ResourceName, ResourceType, ExpirationDate | Out-String), [MessageType]::Default)
            $this.PublishCustomMessage([Constants]::SingleDashLine, [MessageType]::Default)
            $this.PublishCustomMessage("");
        }
        else {
            $this.PublishCustomMessage("No eligible roles found for the current login.", [MessageType]::Warning);
        }
    }

    hidden TransitionFromPermanentRolesToPIM($SubscriptionId, $ResourceGroupName, $ResourceName, $RoleNames, $DurationInDays, $Force) {
       
        $resolvedResource = $this.PIMResourceResolver($subscriptionId, $resourcegroupName, $resourceName)
        if (($resolvedResource | Measure-Object).Count -gt 0 -and (-not [string]::IsNullOrEmpty($resolvedResource.ResourceId))) {    
            $resourceId = $resolvedResource.ResourceId
            $roles = $this.ListRoles($resourceId)
            $roles = ($roles | Where-Object { $_.RoleName -in $($RoleNames.split(",").Trim()) })
            # $roleDefinitionId = $role.RoleDefinitionId
            $CriticalRoles = $roles.RoleName #$ControlSettings.CriticalPIMRoles 
            $this.PublishCustomMessage("Fetching permanent assignment for [$(($criticalRoles) -join ", ")] role on $($resolvedResource.Type) [$($resolvedResource.ResourceName)]...",[MessageType]::Info)
            $permanentRoles = $this.ListAssignmentsWithFilter($resourceId, $true)
            if (($permanentRoles | Measure-Object).Count -gt 0) {
                $permanentRolesForTransition = $permanentRoles | Where-Object { $_.SubjectType -eq 'User' -and $_.MemberType -ne 'Inherited' -and $_.RoleName -in $CriticalRoles }
                if (($permanentRolesForTransition | Measure-Object).Count -gt 0) {
                    $ToContinue = ''
                    if(!$Force)
                    {
                        $this.PublishCustomMessage($($permanentRolesForTransition | Format-Table -AutoSize -Wrap PrincipalName, ResourceName, ResourceType, RoleName | Out-String), [MessageType]::Default)
                        $this.PublishCustomMessage("");
                        Write-Host "The above role assignments will be moved from 'permanent' to 'PIM'. `nPlease confirm (Y/N): " -ForegroundColor Yellow -NoNewline
                        $ToContinue = Read-Host
                    }
                    if ($ToContinue -eq 'y' -or $Force) {               
                        $Assignmenturl = $this.APIroot + "/roleAssignmentRequests"
                        $roles = $this.ListRoles($resourceId)  
                        $ts = $DurationInDays;
                        $totalPermanentAssignments = ($permanentRolesForTransition | Measure-Object).Count
                        $this.PublishCustomMessage("Initiating PIM assignment for [$totalPermanentAssignments] permanent assignments..."); #TODO: Check the color
                        $i = 1
                        $permanentRolesForTransition | ForEach-Object {
                            $roleName = $_.RoleName
                            $roleDefinitionId = ($roles | Where-Object { $_.RoleName -eq $roleName }).RoleDefinitionId 
                            $subjectId = $_.SubjectId
                            $PrincipalName = $_.PrincipalName
                            #$Scope= $_.OriginalId
                            $postParams = '{"assignmentState":"Eligible","type":"AdminAdd","reason":"Assign","roleDefinitionId":"' + $roleDefinitionId + '","resourceId":"' + $resourceId + '","subjectId":"' + $subjectId + '","schedule":{"startDateTime":"' + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + '","endDateTime":"' + ((get-date).AddDays($ts).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")) + '","type":"Once"}}'
                            
                                $this.PublishCustomMessage([Constants]::SingleDashLine)
                                # $this.PublishCustomMessage("Requesting PIM assignment for [$($_.RoleName)' role for $($_.PrincipalName) on $($_.ResourceType) '$($resolvedResource.ResourceName)'...");
                               try{
                                $response = [WebRequestHelper]::InvokeWebRequest('Post', $Assignmenturl, $this.headerParams, $postParams, "application/json", $false, $true )
                                if ($response.StatusCode -eq 201) {
                                    $this.PublishCustomMessage("[$i`/$totalPermanentAssignments] Successfully requested PIM assignment for [$PrincipalName]", [MessageType]::Update);
                                }
                                $this.PublishCustomMessage([Constants]::SingleDashLine)
                          
                               }
                            catch {
                                if([Helpers]::CheckMember($_,"error.code"))
                                {
                                    if ($code.error.code -eq "RoleAssignmentExists") {
                                        $this.PublishCustomMessage("[$i`/$totalPermanentAssignments] PIM Assignment for [$PrincipalName] already exists.", [MessageType]::Update)
                                    }
                                    else {
                                        $this.PublishCustomMessage("$($code.error)", [MessageType]::Error)
                                    }
                                }
                                else
                                {
                                    $this.PublishCustomMessage("$($_.Exception)", [MessageType]::Error)
                                }                                                             
                            }         
                            $i++;
                        }#foreach  
                    }
                    else {
                        return;
                    }
                }
                else {
                    $this.PublishCustomMessage("No permanent assignments eligible for PIM assignment found.", [MessageType]::Warning);       
                }
            }
            else {
                $this.PublishCustomMessage("No permanent assignments found for this resource.", [MessageType]::Warning);       
            }
        }
        else
        {
            $this.PublishCustomMessage("No matching resource found for the current context.", [MessageType]::Warning)
        }
    }

    hidden RemovePermanentAssignments($SubscriptionId, $ResourceGroupName, $ResourceName, $RoleNames, $RemoveAssignmentFor, $Force) {
        $this.AcquireToken();
        $resolvedResource = $this.PIMResourceResolver($subscriptionId, $resourcegroupName, $resourceName)
        if(-not [String]::IsNullOrEmpty($resolvedResource.ResourceId))
        {
            $resourceId = ($resolvedResource).ResourceId 
            $users = @();
            $CriticalRoles = $RoleNames.split(",").Trim()
            $this.PublishCustomMessage("Note: This command will *not* remove your permanent assignment if one exists.", [MessageType]::Warning)
            $this.PublishCustomMessage("Fetching permanent assignment for [$(($criticalRoles) -join ", ")] role on $($resolvedResource.Type) [$($resolvedResource.ResourceName)]...", [MessageType]::Info)
            $permanentRoles = $this.ListAssignmentsWithFilter($resourceId, $true)
            $eligibleAssignments = $this.ListAssignmentsWithFilter($resourceId, $false)
            $eligibleAssignments = $eligibleAssignments | Where-Object { $_.SubjectType -eq 'User' -and $_.MemberType -ne 'Inherited' -and $_.RoleName -in $CriticalRoles }
            if (($permanentRoles | Measure-Object).Count -gt 0) {
                $permanentRolesForTransition = $permanentRoles | Where-Object { $_.SubjectType -eq 'User' -and $_.MemberType -ne 'Inherited' -and $_.RoleName -in $CriticalRoles }
                $successfullyassignedRoles = @();
                $currentContext = [Helpers]::GetCurrentRmContext();
                $permanentRolesForTransition = $permanentRolesForTransition | Where-Object { $_.PrincipalName -ne $currentContext.Account.Id }
                if ($RemoveAssignmentFor -ne "AllExceptMe") {
                    $eligibleAssignments | ForEach-Object {
                        $allUser = $_;
                        $permanentRolesForTransition | ForEach-Object {
                    
                            if ($_.SubjectId -eq $allUser.SubjectId -and $_.RoleName -eq $allUser.RoleName) {
                                $successfullyassignedRoles += $_
                            } 
                        }
                    }             
                    $users = $successfullyassignedRoles            
                }
                else {
                    $users = $permanentRolesForTransition
                }
            }
        
            if (($users | Measure-Object).Count -gt 0) {
                $userResp = ''
                $totalRemovableAssignments = ($users | Measure-Object).Count
                if(!$Force)
                {
                    $this.PublishCustomMessage($($users | Format-Table -Property PrincipalName, RoleName, OriginalId | Out-String), [MessageType]::Default)
                    Write-Host "The above role assignments will be moved from 'permanent' to 'PIM'. `nPlease confirm (Y/N): " -ForegroundColor Yellow -NoNewline
                    $userResp = Read-Host
                } 
                if ($userResp -eq 'y' -or $Force) {
                    $i = 0
                    $this.PublishCustomMessage("Initiating removal of [$totalRemovableAssignments] permanent assignments...")
                    foreach ($user in $users) {
                        $i++;
                        $this.PublishCustomMessage([Constants]::SingleDashLine);
                        Remove-AzRoleAssignment -SignInName $user.PrincipalName -RoleDefinitionName $user.RoleName -Scope $user.OriginalId
                        $this.PublishCustomMessage("[$i`/$totalRemovableAssignments]Successfully removed permanent assignment", [MessageType]::Update )                
                        $this.PublishCustomMessage([Constants]::SingleDashLine);

                    }
                }
            }
            else {
                $this.PublishCustomMessage("No permanent assignments found for the scope.", [MessageType]::Warning)
            }
        }
        else
        {
            $this.PublishCustomMessage("No matching resource found for the current context.", [MessageType]::Warning)
        }
    }
}

class PIMResource {
    [int] $Id
    [string] $ResourceId #Id refered by PIM API to uniquely identify a resource
    [string] $ResourceName 
    [string] $Type 
    [string] $ExternalId #ARM resourceId
}

