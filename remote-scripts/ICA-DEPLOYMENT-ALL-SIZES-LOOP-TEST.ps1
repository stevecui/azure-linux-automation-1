<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$VMSizes = @()
$StandardSizes = @()
$XioSizes = @()

if($currentTestData.SubtestValuesSpecified -eq 'True')
{
	$VMSizes = ($currentTestData.SubtestValues).Split(",")
}
# Get all supported sizes in this region
else
{
	if ( $UseAzureResourceManager )
	{
		$StorAccount = $xmlConfig.config.Azure.General.ARMStorageAccount

		$saInfoCollected = $false
		$retryCount = 0
		$maxRetryCount = 999
		while(!$saInfoCollected -and ($retryCount -lt $maxRetryCount))
		{
			try
			{
				$retryCount += 1
				LogMsg "[Attempt $retryCount/$maxRetryCount] : Getting $StorAccount Storage Account details ..."
				$GetAzureRmStorageAccount = $null
				$GetAzureRmStorageAccount = Get-AzureRmStorageAccount
				if ($GetAzureRmStorageAccount -eq $null)
				{
					throw
				}
				$saInfoCollected = $true
			}
			catch
			{
				$saInfoCollected = $false
				LogErr "Error in fetching Storage Account info. Retrying in 10 seconds."
				sleep -Seconds 10
			}
		}
		
		$AccountDetail =  $GetAzureRMStorageAccount | where {$_.StorageAccountName -eq $StorAccount}
		$Location = $AccountDetail.PrimaryLocation
		$AccountType = $AccountDetail.Sku.Tier.ToString()
		$SupportSizes = (Get-AzureRmVMSize -Location $location).Name
	}
	else
	{
		$StorAccount = $xmlConfig.config.Azure.General.StorageAccount
		$Location = (Get-AzureStorageAccount -StorageAccountName $StorAccount).GeoPrimaryLocation
		$AccountType = (Get-AzureStorageAccount -StorageAccountName $StorAccount).AccountType
		$SupportSizes = (Get-AzureLocation | where {$_.Name -eq $location}).VirtualMachineRoleSizes
    }
    if ($currentTestData.StandardVMSizes   -and $AccountType -match 'Standard' )
    {
        $targetVMSizes = ($currentTestData.StandardVMSizes).Split(",")
    }
    elseif ($currentTestData.PremiumVMSizes  -and $AccountType -match 'Premium')
    {
        $targetVMSizes = ($currentTestData.PremiumVMSizes).Split(",")
    }
    else 
    {
        $targetVMSizes = $SupportSizes
    }
    Write-Host "targetVMSizes = $targetVMSizes"
    
	foreach($size in $SupportSizes)
	{
        $ResourceSku=Get-AzureRmComputeResourceSku | where {$_.Locations -icontains $Location -and $_.Name -eq $size}
        if($ResourceSku.Restrictions.ReasonCode -ne "NotAvailableForSubscription")
        {
		    if ($size -imatch 'Promo')
		    {
		        LogMsg "Skipping $size"
		    }
		    else
		    {
                if(($size -match 'DS') -or ($size -match 'GS') -or ($size.Trim().EndsWith("s")) -or ($size.Contains("s_v")))
                {
                    if ( $targetVMsizes.Contains("$size") )
                    {
                        $XioSizes += $size.Trim()
                    }
                }
                else
                {
                    if ( $targetVMsizes.Contains("$size") )
                    {
                        $StandardSizes += $size.Trim()
                    }
                }
            }
	    }
        else
        {
            LogMsg "Skipping $size"
        }
    }
	if($AccountType -match 'Premium')
	{
		$VMSizes = $XioSizes
	}
	else
	{
		$VMSizes = $StandardSizes
	}
}
LogMsg "test VM sizes: $VMSizes"
$NumberOfSizes = $VMSizes.Count
$DeploymentCount = $NumberOfSizes*1

#Test Starts Here..
    try
    {
        $count = 0
        $allowedFails = 20
        $successCount = 0
        $failCount = 0
        $VMSizeNumber = 0
        $allDeploymentStatistics = @()

        function CreateDeploymentResultObject()
        {
            $DeploymentStatistics = New-Object -TypeName PSObject
            Add-Member -InputObject $DeploymentStatistics -MemberType NoteProperty -Name attempt -Value $attempt -Force
            Add-Member -InputObject $DeploymentStatistics -MemberType NoteProperty -Name VMSize -Value $VMSize -Force
            Add-Member -InputObject $DeploymentStatistics -MemberType NoteProperty -Name result -Value $result -Force
            Add-Member -InputObject $DeploymentStatistics -MemberType NoteProperty -Name DeploymentTime -Value $DeploymentTime -Force 
            if ( !$UseAzureResourceManager )
            {
                Add-Member -InputObject $DeploymentStatistics -MemberType NoteProperty -Name BootTime -Value $BootTime -Force
                Add-Member -InputObject $DeploymentStatistics -MemberType NoteProperty -Name ProvisionTime -Value $ProvisionTime -Force
            }
            return $DeploymentStatistics
        }

        #Do this only when CustomKernel or CustomLIS is set 
        if (($cycleName.ToUpper() -eq "DEPLOYMENT") -and ($customKernel -or $customLIS))
        {
            #create a resource group and use the VHD for Deployment Test
            $isDeployed = DeployVMS -setupType "SingleVM" -Distro $Distro -xmlConfig $xmlConfig -GetDeploymentStatistics $True
                
            foreach ($VM in $allVMData)
            {
                $ResourceGroupUnderTest = $VM.ResourceGroupName
                $VHDuri = (Get-AzureRMVM -ResourceGroupName $VM.ResourceGroupName).StorageProfile.OsDisk.Vhd.Uri
                #Deprovision VM
		        LogMsg "Executing: waagent -deprovision..."
		        $DeprovisionInfo = RunLinuxCmd -username $user -password $password -ip $VM.PublicIP -port $VM.SSHPort -command "/usr/sbin/waagent -force -deprovision" -runAsSudo
		        LogMsg $DeprovisionInfo
		        LogMsg "Execution of waagent -deprovision done successfully"
                LogMsg "Stopping Virtual Machine ...."
                $out = Stop-AzureRmVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.RoleName -Force
                WaitFor -seconds 60
            }
            #get the VHD file name from the VHD uri
            $VHDuri = Split-Path $VHDuri -Leaf
            #set BaseOsVHD so that deployment will pick the VHD
            Set-Variable -Name BaseOsVHD -Value $VHDuri -Scope Global

            #Finally set customKernl and customLIS to null which are not required to be installed after deploying Virtual machine
            $customKernel = $null
            Set-Variable -Name customKernel -Value $customKernel -Scope Global
            $customLIS = $null
            Set-Variable -Name customLIS -Value $customLIS -Scope Global
        }
        While ($count -lt $DeploymentCount)
        {
            $count += 1
            $deployedServiceName = $null
            $deployedResourceGroupName = $null
            $DeploymentStatistics = CreateDeploymentResultObject
            #Create A VM here and Wait for the VM to come up.
            LogMsg "Current Progress : Success : $successCount, Fail : $failCount, Remaining : $($DeploymentCount - $successCount - $failCount)"
            LogMsg "ATTEMPT : $count/$DeploymentCount : Deploying $($VMSizes[$VMSizeNumber]) VM.."
            Set-Variable -Name OverrideVMSize -Value $($VMSizes[$VMSizeNumber]) -Scope Global -Force
            $xmlConfig.config.Azure.Deployment.SingleVM.HostedService.Tag = $($VMSizes[$VMSizeNumber]).Replace("_","-")
            $isDeployed = DeployVMS -setupType "SingleVM" -Distro $Distro -xmlConfig $xmlConfig -GetDeploymentStatistics $True
                        
            $DeploymentStatistics.VMSize = $($VMSizes[$VMSizeNumber])
            $DeploymentStatistics.attempt = $count
            if ( !$UseAzureResourceManager )
            {
                $deployedServiceName = $isDeployed[0]
                $DeploymentStatistics.DeploymentTime = $isDeployed[1].TotalSeconds
                $DeploymentStatistics.BootTime = $isDeployed[2].TotalSeconds
                $DeploymentStatistics.ProvisionTime = $isDeployed[3].TotalSeconds
            }
            else
            {
                $deployedResourceGroupName = $isDeployed[0]
                $DeploymentStatistics.DeploymentTime = $isDeployed[1].TotalSeconds
            }
            if ($deployedServiceName -or $deployedResourceGroupName)
            {
                if ( $UseAzureResourceManager )
                {
                        LogMsg "ATTEMPT : $count/$DeploymentCount : Deploying $($VMSizes[$VMSizeNumber]) VM.. SUCCESS"
                        LogMsg "deployment Time = $($DeploymentStatistics.DeploymentTime)"
                        #Added restart check for the deployment
                        $isRestarted = RestartAllDeployments -allVMData $allVMData
                        if($isRestarted)
                        {
                            $successCount += 1
                            LogMsg "ATTEMPT : $count/$DeploymentCount : Reboot $($VMSizes[$VMSizeNumber]) VM.. SUCCESS"
                            LogMsg "deployment Time = $($DeploymentStatistics.DeploymentTime)"
                            $deployResult = "PASS"
                        }
                        else 
                        {
                            $hash = @{}
                            $hash.Add($preserveKeyword,"yes")
                            $hash.Add("testName","$($currentTestData.testName)")
                            $out = Set-AzureRmResourceGroup -Name $deployedServiceName -Tag $hash
                        }
                }
                else
                {
                    if ( $DeploymentStatistics.BootTime -lt 1800 )
                    {
                        $successCount += 1
                        LogMsg "ATTEMPT : $count/$DeploymentCount : Deploying $($VMSizes[$VMSizeNumber]) VM.. SUCCESS"
                        LogMsg "deployment Time = $($DeploymentStatistics.DeploymentTime)"
                        LogMsg "Boot Time = $($DeploymentStatistics.BootTime)"
                        LogMsg "Provision Time = $($DeploymentStatistics.ProvisionTime)"
                        $deployResult = "PASS"
                    }
                    else
                    {
                        $failCount += 1
                        LogErr "ATTEMPT : $count/$DeploymentCount : Deploying $($VMSizes[$VMSizeNumber]) VM.. FAIL due to exceeding boot time."

                        LogMsg "deployment Time/Timeout  = $($DeploymentStatistics.DeploymentTime)"
                        LogMsg "Boot Time/Timeout = $($DeploymentStatistics.BootTime)"
                        LogMsg "Provision Time/Timeout= $($DeploymentStatistics.ProvisionTime)"
                        $deployResult = "FAIL"
                        if ( $failCount -lt $allowedFails )
                        {
                            $VMSizeNumber += 1
                        }
                        else
                        {
                            break;
                        }
                    }
                }
				$DeploymentStatistics.result = $deployResult
				$allDeploymentStatistics += $DeploymentStatistics
                DoTestCleanUp -result $deployResult -testName $currentTestData.testName -deployedServices $deployedServiceName -ResourceGroups $deployedResourceGroupName
            }
            else
            {
                
                $failCount += 1
                $deployResult = "FAIL"
                LogErr "ATTEMPT : $count/$DeploymentCount : Deploying $($VMSizes[$VMSizeNumber]) VM.. FAIL"
                $DeploymentStatistics.result = $deployResult
                LogMsg "deployment Time/Timeout  = $($DeploymentStatistics.DeploymentTime)"
                LogMsg "Boot Time/Timeout = $($DeploymentStatistics.BootTime)"
                LogMsg "Provision Time/Timeout= $($DeploymentStatistics.ProvisionTime)"
                LogMsg "[PASS/FAIL/REMAINING] : $successCount/$failCount/$($DeploymentCount-$count)"
                $allDeploymentStatistics += $DeploymentStatistics
                DoTestCleanUp -result $deployResult -testName $currentTestData.testName -deployedServices $deployedServiceName -ResourceGroups $deployedResourceGroupName
                if ( $failCount -lt $allowedFails )
                {
                }
                else
                {
                    break;
                }
            }
            if($VMSizeNumber -gt ($NumberOfSizes-2))
            {
                $VMSizeNumber = 0
            }
            else
            {
                $VMSizeNumber += 1
            }
            
        }
        if (($successCount -eq $DeploymentCount) -and ($failCount -eq 0))
        {
            $testResult = "PASS"
        }
        else
        {
            $testResult = "FAIL"
        }
        if ($UseAzureResourceManager )
        {
			$count = 1
            LogMsg "Attempt`tVMSize`tresult`tDeployment Time"
			$deploymentTimes=@()
            foreach ( $value in $allDeploymentStatistics )
            {
				$deploymentTimes += $value.DeploymentTime
                LogMsg "$($value.attempt)`t$($value.VMSize)`t$($value.result)`t$($value.DeploymentTime)"
				$metaData = "$count/$DeploymentCount`tTestSize: $($value.VMSize)`tDeploymentTime: $($value.DeploymentTime)`t"
				$resultSummary +=  CreateResultSummary -testResult $($value.result) -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName "DeploymentCount"
				$count += 1
            }
			$DT = $deploymentTimes | Measure-Object -Minimum -Maximum -Average
			LogMsg "Deployment Time - [MIN/AVG/MAX] - $($DT.Minimum)/$($DT.Average)/$($DT.Maximum)"
        }
        else
        {
			$count = 1
            LogMsg "Attempt`tVMSize`tresult`tDeployment Time`tBoot Time`tProvision Time"
            $deploymentTimes=@()
            $bootTimes=@()
            $ProvisionTimes=@()
            foreach ( $value in $allDeploymentStatistics )
            {
                $deploymentTimes += $value.DeploymentTime
                $bootTimes += $value.BootTime
                $ProvisionTimes += $value.ProvisionTime
                LogMsg "$($value.attempt)`t$($value.VMSize)`t$($value.result)`t$($value.DeploymentTime)`t$($value.BootTime)`t$($value.ProvisionTime)"
				$metaData = "$count/$DeploymentCount`tTestSize: $($value.VMSize)`tProvisionTime: $($value.ProvisionTime)`t"
				$resultSummary +=  CreateResultSummary -testResult $($value.result) -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName "DeploymentCount"
				$count += 1
            }
            $DT = $deploymentTimes | Measure-Object -Minimum -Maximum -Average
            $BT = $bootTimes | Measure-Object -Minimum -Maximum -Average
            $PT = $ProvisionTimes | Measure-Object -Minimum -Maximum -Average
            LogMsg "Deployment Time - [MIN/AVG/MAX] - $($DT.Minimum)/$($DT.Average)/$($DT.Maximum)"
            LogMsg "Boot Time - [MIN/AVG/MAX] - $($BT.Minimum)/$($BT.Average)/$($BT.Maximum)"
            LogMsg "Provision Time - [MIN/AVG/MAX] - $($PT.Minimum)/$($PT.Average)/$($PT.Maximum)"
        }
    }
    catch
    {
        $ErrorMessage =  $_.Exception.Message
        LogMsg "EXCEPTION : $ErrorMessage"   
    }
    Finally
    {
        if (!$testResult)
        {
            $testResult = "Aborted"
        }
        #delete the resource group with captured VHD
        elseif ($testResult -eq "PASS")
        {
            $out = DeleteResourceGroup -RGName $ResourceGroupUnderTest
        }
        $resultArr += $testResult
    }   
$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
#DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary
