Param(
    [Parameter(Mandatory = $true)]
    [String]$hostPoolName,
    [Parameter(Mandatory = $true)]
    [String]$resourceGroup,
    [Parameter(Mandatory = $true)]
    [String]$vmResourceGroup,
    [Parameter(Mandatory = $true)]
    [String]$domain,
    [Parameter(Mandatory = $true)]
    [String]$version,
    [Parameter(Mandatory = $true)]
    [String]$update
)

if ($update -eq "true") {
    Write-Host "Updating existing deployment. Cleanup of old hosts started"
    $VMs = Get-AzVM -ResourceGroupName $vmResourceGroup -Status
    $VMList = @()
    $userList = @()
    
    foreach ($VM in $VMs) {
        if (($VM.tags["Version"]) -ne $version) { 
            try {
                Write-Host "Checking if machine is AVD Session Host"
                $sessionHost = Get-AzWVDSessionHost -HostPool $hostPoolName -ResourceGroup $resourceGroup -Name "$($VM.name).$($domain)" -ErrorAction Stop
                Write-Host "$($VM.name) added to Powerdown script."
                $VMList += $VM
            } catch {
                Write-Host "$($VM.Name) is not a session host skipping."
            }
        }
    }

    if ($VMList.count -gt 0) {
        Write-Host "$($VMList.count) Machines marked for shutdown."
    
        foreach ($VM in $VMList) {
            Write-Host "Setting Session Host $($VM.name) to not allow new connections (drain mode)"
            Update-AzWVDSessionHost -HostPool $hostPoolName -ResourceGroup $resourceGroup -SessionHost "$($VM.name).$($domain)" -AllowNewSession:$false
            
            $users = Get-AzWVDUserSession -HostPoolName $hostPoolName -ResourceGroupName $resourceGroup -SessionHostName "$($VM.name).$($domain)"
            Write-Host "Checking if existing users on Session Host $($VM.name)"
            if ($users.count -gt 0) {
    
                Write-Host "$($users.count) users are currently logged into Session Host: $($VM.name)"
                Write-Host "Sending log off message to users."
    
                foreach ($user in $users) {
                    $userList += $user
                    $userid = $user.name.split("/")[2]
                    Send-AzWVDUserSessionMessage -HostPool $hostPoolName -ResourceGroupName $resourceGroup -SessionHostName "$($vm.name).$($domain)" `
                        -UserSessionId $userid -MessageTitle "Maintenance in Progress" `
                        -MessageBody "You will be logged of in 5 minutes for routine maintenance. `nPlease save your documents"
                }
            } 
            else {
                Write-Host "No users present on Session Host: $($VM.name)"
            }
        }
    
        if ($userList.count -gt 0) {
            Write-Host "Sleeping for 5 mins to allow user logoff."
            Start-Sleep -Seconds 300
        
            foreach ($user in $userList) {
                $userid = $user.name.split("/")[2]
                $sessionHostName = $user.name.split("/")[1]
                Remove-AzWVDUserSession -HostPoolName $hostPoolName -ResourceGroupName $resourceGroup -SessionHostName $sessionHostName `
                    -Id $userid -Force
            }
        
            Write-Host "Waiting for all users to be logged off successfully."
            while ($true) { 
                $userSessions = (Get-AzWvdUserSession -HostPoolName $hostPoolName -ResourceGroupName $resourceGroup).count
                if ($userSessions -gt "0") { 
                    Write-Output "$userSessions users are currently logged onto: $HostpoolName"
                    Start-Sleep -s 10 
                }
                else {
                    break 
                } 
            }
        }
    
        Write-Host "Shutting down old AVD Session Hosts."
        $jobs = @()
    
        foreach ($VM in $VMList) {
        
            #Set Tag for removal
            $tags = (Get-AzResource -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name).Tags
            $tags += @{Remove = "True" }
            Set-AzResource -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -ResourceType "Microsoft.Compute/VirtualMachines" -Tag $tags -Force

            if ($VM.PowerState -eq "VM running") {
               
                $params = @($VM.Name, $VM.ResourceGroupName)
    
                $job = Start-Job -ScriptBlock {
                    param($VMName, $ResourceGroupName)
                    Write-Host "Stopping VM: $($VM)"
                    if ($VM.PowerState -ne "VM deallocated") {
                        Stop-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -Force
                    }
                } -ArgumentList $params
    
                $jobs = $jobs + $job
            } 
            else {
                Write-Host "$($VM) already stopped. Moving to next VM."
            }
        }
        if ($jobs.count -gt 0)
        {
            Wait-Job $jobs | Out-Null
        }
    }
}
else {
    Write-Host "Cleanup of old hosts not required."
}
