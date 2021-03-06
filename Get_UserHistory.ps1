cls

$Var_IntRelay = "emailrelay"
$Var_Sender = "sender"
$Var_Recipients = @("recipients")

$Var_DatabaseServer = "dbservername"
$Var_DatabaseInstanceName = "Default"
$Var_DatabaseName = "dbname"

$Modules = @("sqlserver","ActiveDirectory","PoshRSJob","C:\Program Files\Citrix\PowerShellModules\Citrix.Broker.Commands\Citrix.Broker.Commands.psd1")
$Modules | % {
	Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Importing Module $_"
	Remove-Module $_ -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
	Import-Module $_ -ErrorAction Stop -WarningAction SilentlyContinue
}

Set-Location SQLSERVER:\SQL\$Var_DatabaseServer\$Var_DatabaseInstanceName\Databases\$Var_DatabaseName\ -ErrorAction Stop

[void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

$msg   = 'Enter UserName:'
while($true){
	$title = 'User'
	$name = [Microsoft.VisualBasic.Interaction]::InputBox($msg, $title)
	$User = Get-ADUser -LDAPFilter "(sAMAccountName=$name)"
	if($User -eq $Null){
		#"User does not exist in AD"
		$msg   = 'Enter UserName:
		
		User does not exist, please try again:
		'
	}else{
		#"User found in AD"
		break;
	}
}


$monitoringCSV = "$($PSScriptRoot)\$($name)_monitoring_$(Get-Date -Format 'yyyy-MM-dd_HH_mm').csv"
$usbCSV = "$($PSScriptRoot)\$($name)_usb_$(Get-Date -Format 'yyyy-MM-dd_HH_mm').csv"

$getHistory = "
	
select User_Session_MachineTable.UserName,User_Session_MachineTable.HostedMachineName, ConnectTable.ClientName,ConnectTable.ClientAddress, connecttable.clientversion, ConnectTable.LogOnStartDate,ConnectTable.DisconnectDate, User_Session_MachineTable.EndDate
from (					
					select *
					from (
								select UserID, upn, domain, username, MachineId,SessionKey,EndDate
								from (
									SELECT id, upn, domain, username
									FROM [$Database].[MonitorData].[User]
									where UserName = '$name'
								) as UserTable
								join (
									select MachineId,SessionKey, UserId,EndDate
									FROM [$Database].[MonitorData].[Session]
								) as SessionTable
								on UserTable.Id = SessionTable.UserId

					) as User_SessionTable
					join (
								select HostedMachineId, HostedMachineName,Id
								from [$Database].[MonitorData].[Machine]
					) as MachineTable
					on User_SessionTable.MachineId = MachineTable.Id
) as User_Session_MachineTable 
join (
	select SessionKey,ClientName,LogOnStartDate,DisconnectDate, clientversion, clientaddress
	from [$Database].[MonitorData].[Connection]
)as ConnectTable
on User_Session_MachineTable.SessionKey = ConnectTable.SessionKey
order by ConnectTable.LogOnStartDate Desc

"

$tableUTC = Invoke-Sqlcmd -Query $getHistory

#convert UTC times to EST
$tableEST = @()
$tableUTC| foreach{
		$row = New-Object -TypeName PSObject    
		$row | Add-Member -MemberType NoteProperty -Name "UserName" -Value $_.UserName
		$row | Add-Member -MemberType NoteProperty -Name "HostedMachineName" -Value $_.HostedMachineName
		$row | Add-Member -MemberType NoteProperty -Name "ClientName" -Value $_.ClientName
		$row | Add-Member -MemberType NoteProperty -Name "ClientAddress" -Value $_.ClientAddress
		$row | Add-Member -MemberType NoteProperty -Name "ClientVersion" -Value $_.ClientVersion
		if(([DBNull]::Value).Equals($_.LogOnStartDate)){
			$row | Add-Member -MemberType NoteProperty -Name "LogOnStartDate" -Value $null
		}else{
			$row | Add-Member -MemberType NoteProperty -Name "LogOnStartDate" -Value ($_.LogOnStartDate).toLocalTime()
		}
		
		if(([DBNull]::Value).Equals($_.DisconnectDate)){
			$row | Add-Member -MemberType NoteProperty -Name "DisconnectDate" -Value $null
		}else{
			$row | Add-Member -MemberType NoteProperty -Name "DisconnectDate" -Value ($_.DisconnectDate).toLocalTime()
		}
		
		if(([DBNull]::Value).Equals($_.EndDate)){
			$row | Add-Member -MemberType NoteProperty -Name "EndDate" -Value $null
		}else{
			$row | Add-Member -MemberType NoteProperty -Name "EndDate" -Value ($_.EndDate).toLocalTime()
		}
		$tableEST += $row
}

$sessions = $tableEST
 
$Threads_MaxParallel = 50
$Threads_TimeOut = 120
$ObjectRunspaceFunctions = @()
$ObjectRunspaceModules = @()
$ObjectRunspaceSnapins = @()
$ObjectRunspaceScriptBlock = {
    $DesktopPrefixes = @("NYC")
	try{
			if( $desktopPrefixes -contains $_.clientname.substring(0,3) ){
				#(Get-WmiObject -computername $sessions[0].clientname -Class Win32_ComputerSystem).partofdomain

				if($_.disconnectdate -ne $null){
					#tuple has both logon and disconnectdate
					$Events = Get-WinEvent -ComputerName $_.clientname -FilterHashtable @{logname='Microsoft-Windows-DriverFrameworks-UserMode/Operational'; ID=2101; StartTime = $_.Logonstartdate; EndTime = $_.disconnectdate } -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
				}
				if(($_.enddate -ne $null) -and ($_.disconnectdate -eq $null) ){
					#tuple has both logon and enddate but no disconnect (user logged off)
					$Events = Get-WinEvent -ComputerName $_.clientname -FilterHashtable @{logname='Microsoft-Windows-DriverFrameworks-UserMode/Operational'; ID=2101; StartTime = $_.Logonstartdate; EndTime = $_.enddate } -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
				}
				if(($_.enddate -eq $null) -and ($_.disconnectdate -eq $null) ){
					#tuple has logon only active session
					$Events = Get-WinEvent -ComputerName $_.clientname -FilterHashtable @{logname='Microsoft-Windows-DriverFrameworks-UserMode/Operational'; ID=2101; StartTime = $_.Logonstartdate } -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
				}
			}
		}catch{
		}
		$Events      
}

$sessions| Start-RSJob -FunctionsToLoad $ObjectRunspaceFunctions -ScriptBlock $ObjectRunspaceScriptBlock -Name {$_.HostedMachineName} -Throttle $Threads_MaxParallel | Out-Null
Get-RSJob | Wait-RSJob -ShowProgress -Timeout $Threads_TimeOut | Out-Null
$Results = Get-RSJob -State Completed | Receive-RSJob
Get-RSJob | Remove-RSJob -Force 

$Results | select machinename, timecreated, id, message | Export-Csv $usbCSV -NoTypeInformation
$tableEST | Export-Csv $monitoringCSV -NoTypeInformation

 Send-MailMessage -from $Var_Sender `
                       -to $Var_Recipients `
                       -subject "User History Report" `
                       -body ("
                          Team,<br /><br />
                          
						  See attached.<br /><br />
                          Thanks<br /><br /> 
                                                                                          
                       "  )` -Attachments $monitoringCSV , $usbCSV -smtpServer $Var_IntRelay -BodyAsHtml 

#>