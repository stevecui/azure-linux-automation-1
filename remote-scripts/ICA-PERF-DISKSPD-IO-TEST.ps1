# This script deploys a VM with 12xP30 disks for DISKSPD IO test and trigger the test based on given buffer 4k/1024k.
#
# Author: Maruthi Sivakanth Rebba
# Email: v-sirebb@microsoft.com
###################################################################################

<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$testVMData = $allVMData
		ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
		LogMsg "Generating constansts.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		foreach ( $param in $currentTestData.TestParameters.param)
		{
			Add-Content -Value "$param" -Path $constantsFile
			LogMsg "$param added to constants.sh"
			if ( $param -imatch "startThread" )
			{
				$startThread = [int]($param.Replace("startThread=",""))
			}
			if ( $param -imatch "maxThread" )
			{
				$maxThread = [int]($param.Replace("maxThread=",""))
			}
		}
		LogMsg "constanst.sh created successfully..."
		#endregion
		
		#region EXECUTE TEST
		$myString = @"
chmod +x perf_diskspd.sh
echo "Execution of script started.." > /root/runlog.txt
./perf_diskspd.sh &> diskspdConsoleLogs.txt
. azuremodules.sh
collect_VM_properties
"@

		Set-Content "$LogDir\StartDiskSpdTest.sh" $myString
		RemoteCopy -uploadTo $testVMData.PublicIP -port $testVMData.SSHPort -files ".\$constantsFile,.\remote-scripts\azuremodules.sh,.\remote-scripts\perf_diskspd.sh,.\$LogDir\StartDiskSpdTest.sh," -username "root" -password $password -upload
		$out = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh" -runAsSudo
		$testJob = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "./StartDiskSpdTest.sh" -RunInBackground -runAsSudo
		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "tail -1 runlog.txt"-runAsSudo
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 20
		}

		$finalStatus = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "cat state.txt"
		RemoteCopy -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "DiskSpdIOTest-*.tar.gz"
		RemoteCopy -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "*.txt, *.csv"
		
		$testSummary = $null
		#endregion

		if ( $finalStatus -imatch "TestFailed")
		{
			LogErr "Test failed. Last known status : $currentStatus."
			$testResult = "FAIL"
		}
		elseif ( $finalStatus -imatch "TestAborted")
		{
			LogErr "Test Aborted. Last known status : $currentStatus."
			$testResult = "ABORTED"
		}
		elseif ( $finalStatus -imatch "TestCompleted")
		{
			LogMsg "Test Completed."
			$testResult = "PASS"
		}
		elseif ( $finalStatus -imatch "TestRunning")
		{
			LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
			LogMsg "Contests of summary.log : $testSummary"
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
		$resultSummary +=  CreateResultSummary -testResult $testResult -metaData "" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
		
    try
        {
			foreach($line in (Get-Content "$LogDir\DiskspdResults.csv"))
			{
				if ( $line -imatch "Iteration,TestType,BlockSize" )
				{
					$fioData = $true
				}
				if ( $fioData )
				{
					Add-Content -Value $line -Path $LogDir\diskspdData.csv
				}
			}
			$diskspdDataCsv = Import-Csv -Path $LogDir\diskspdData.csv
			LogMsg "Uploading the test results.."
			$dataSource = $xmlConfig.config.Azure.database.server
			$DBuser = $xmlConfig.config.Azure.database.user
			$DBpassword = $xmlConfig.config.Azure.database.password
			$database = $xmlConfig.config.Azure.database.dbname
			$dataTableName = $xmlConfig.config.Azure.database.dbtable
			$TestCaseName = $xmlConfig.config.Azure.database.testTag
			if ($dataSource -And $DBuser -And $DBpassword -And $database -And $dataTableName) 
			{
				$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
				if ( $UseAzureResourceManager )
				{
					$HostType	= "Azure-ARM"
				}
				else
				{
					$HostType	= "Azure"
				}
				
				$HostBy	= ($xmlConfig.config.Azure.General.Location).Replace('"','')
				$HostOS	= cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
				$GuestOSType	= "Linux"
				$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
				$GuestSize = $testVMData.InstanceSize
				$KernelVersion	= cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
				
				$connectionString = "Server=$dataSource;uid=$DBuser; pwd=$DBpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
				
				$SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,DiskSetup,BlockSize_KB,QDepth,seq_read_iops,seq_read_lat_avg,rand_read_iops,rand_read_lat_avg,seq_write_iops,seq_write_lat_avg,rand_write_iops,rand_write_lat_avg) VALUES "

				for ( $QDepth = $startThread; $QDepth -le $maxThread; $QDepth *= 2 ) 
				{
					$seq_read_iops = ($diskspdDataCsv |  where { $_.TestType -eq "sequential-read" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS
					$seq_read_lat_avg = ($diskspdDataCsv |  where { $_.TestType -eq "sequential-read" -and  $_.Threads -eq "$QDepth"} | Select ReadAvgLat).ReadAvgLat

					$rand_read_iops = ($diskspdDataCsv |  where { $_.TestType -eq "random-read" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS
					$rand_read_lat_avg = ($diskspdDataCsv |  where { $_.TestType -eq "random-read" -and  $_.Threads -eq "$QDepth"} | Select ReadAvgLat).ReadAvgLat
					
					$seq_write_iops = ($diskspdDataCsv |  where { $_.TestType -eq "sequential-write" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS
					$seq_write_lat_avg = ($diskspdDataCsv |  where { $_.TestType -eq "sequential-write" -and  $_.Threads -eq "$QDepth"} | Select WriteAvgLat).WriteAvgLat
					
					$rand_write_iops = ($diskspdDataCsv |  where { $_.TestType -eq "random-write" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS
					$rand_write_lat_avg= ($diskspdDataCsv |  where { $_.TestType -eq "random-write" -and  $_.Threads -eq "$QDepth"} | Select WriteAvgLat).WriteAvgLat

					$BlockSize_KB= (($diskspdDataCsv |  where { $_.Threads -eq "$QDepth"} | Select BlockSize)[0].BlockSize).Replace("K","")
                    
				    $SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$HostType','$HostBy','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','RAID0:12xP30','$BlockSize_KB','$QDepth','$seq_read_iops','$seq_read_lat_avg','$rand_read_iops','$rand_read_lat_avg','$seq_write_iops','$seq_write_lat_avg','$rand_write_iops','$rand_write_lat_avg'),"	
				    LogMsg "Collected performace data for $QDepth QDepth."
				}
				
				$SQLQuery = $SQLQuery.TrimEnd(',')
				$connection = New-Object System.Data.SqlClient.SqlConnection
				$connection.ConnectionString = $connectionString
				$connection.Open()

				$command = $connection.CreateCommand()
				$command.CommandText = $SQLQuery
				
				$result = $command.executenonquery()
				$connection.Close()
				LogMsg "Uploading the test results done!!"
			}
			else
			{
				LogMsg "Invalid database details. Failed to upload result to database!"
			}
		
		}
		catch 
		{
			$ErrorMessage =  $_.Exception.Message
			LogErr "EXCEPTION : $ErrorMessage"
		}
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "NTTTCP RESULT"
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}   
}

else
{
	$testResult = "Aborted"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary