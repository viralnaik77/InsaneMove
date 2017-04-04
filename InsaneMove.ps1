﻿<#
.SYNOPSIS
	Insane Move - Copy sites to Office 365 in parallel.  ShareGate Insane Mode times ten!
.DESCRIPTION
	Copy SharePoint site collections to Office 365 in parallel.  CSV input list of source/destination URLs.  XML with general preferences.
	
	Comments and suggestions always welcome!  spjeff@spjeff.com or @spjeff
	
	Requires folder "D:\InsaneMove\" to run within.  Please create or update below code.  Future planned feature to auto detect current folder.
	
.NOTES
	File Name		: InsaneMove.ps1
	Author			: Jeff Jones - @spjeff
	Version			: 0.53
	Last Modified	: 04-04-2017
.LINK
	Source Code
	http://www.github.com/spjeff/insanemove
#>

[CmdletBinding()]
param (
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='CSV list of source and destination SharePoint site URLs to copy to Office 365.')]
	[string]$fileCSV,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Verify all Office 365 site collections.  Prep step before real migration.')]
	[Alias("v")]
	[switch]$verifyCloudSites = $false,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Copy incremental changes only. http://help.share-gate.com/article/443-incremental-copy-copy-sharepoint-content')]
	[Alias("i")]
	[switch]$incremental = $false,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Measure size of site collections in GB.')]
	[Alias("m")]
	[switch]$measure = $false,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Send email notifications with summary of migration batch progress.')]
	[Alias("e")]
	[switch]$email = $false,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Lock sites read-only.')]
	[Alias("ro")]
	[switch]$readOnly = $false,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Unlock sites read-write.')]
	[Alias("rw")]
	[switch]$readWrite = $false,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Lock sites no access.')]
	[Alias("na")]
	[switch]$noAccess = $false,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Grant Site Collection Admin rights to the migration user specified in XML settings file.')]
	[Alias("sca")]
	[switch]$siteCollectionAdmin = $false,
	
	[Parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage='Update local User Profile Service with cloud personal URL.  Helps with Hybrid Onedrive audience rules.  Need to recompile audiences after running this.')]
	[Alias("ups")]
	[switch]$userProfileSetHybridURL = $false
)

# Plugin
Add-PSSnapIn Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue | Out-Null
Import-Module SharePointPnPPowerShellOnline -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null

# Config
$root = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
[xml]$settings = Get-Content "$root\InsaneMove.xml"
$maxWorker = $settings.settings.maxWorker

Function VerifyPSRemoting() {
	"<VerifyPSRemoting>"
	$ssp = Get-WSManCredSSP
	if ($ssp[0] -match "not configured to allow delegating") {
		# Enable remote PowerShell over CredSSP authentication
		Enable-WSManCredSSP -DelegateComputer * -Role Client -Force
		Restart-Service WinRM
	}
}

Function ReadIISPW {
	"<ReadIISPW>"
	# Read IIS password for current logged in user
	$pass = $null
	Write-Host "===== Read IIS PW ===== $(Get-Date)" -Fore Yellow

	# Current user (ex: Farm Account)
	$userdomain = $env:userdomain
	$username = $env:username
	Write-Host "Logged in as $userdomain\$username"
	
	# Start IISAdmin if needed
	$iisadmin = Get-Service IISADMIN
	if ($iisadmin.Status -ne "Running") {
		#set Automatic and Start
		Set-Service -Name IISADMIN -StartupType Automatic -ErrorAction SilentlyContinue
		Start-Service IISADMIN -ErrorAction SilentlyContinue
	}
	
	# Attempt to detect password from IIS Pool (if current user is local admin and farm account)
	Import-Module WebAdministration -ErrorAction SilentlyContinue | Out-Null
	$m = Get-Module WebAdministration
	if ($m) {
		#PowerShell ver 2.0+ IIS technique
		$appPools = Get-ChildItem "IIS:\AppPools\"
		foreach ($pool in $appPools) {	
			if ($pool.processModel.userName -like "*$username") {
				Write-Host "Found - "$pool.processModel.userName
				$pass = $pool.processModel.password
				if ($pass) {
					break
				}
			}
		}
	} else {
		#PowerShell ver 3.0+ WMI technique
		$appPools = Get-CimInstance -Namespace "root/MicrosoftIISv2" -ClassName "IIsApplicationPoolSetting" -Property Name, WAMUserName, WAMUserPass | select WAMUserName, WAMUserPass
		foreach ($pool in $appPools) {	
			if ($pool.WAMUserName -like "*$username") {
				Write-Host "Found - "$pool.WAMUserName
				$pass = $pool.WAMUserPass
				if ($pass) {
					break
				}
			}
		}
	}

	# Prompt for password
	if (!$pass) {
		$pass = Read-Host "Enter password for $userdomain\$username"
	} 
	$sec = $pass | ConvertTo-SecureString -AsPlainText -Force
	$global:pass = $pass
	$global:cred = New-Object System.Management.Automation.PSCredential -ArgumentList "$userdomain\$username", $sec
}

Function DetectVendor() {
	"<DetectVendor>"
	# SharePoint Servers in local farm
	$spservers = Get-SPServer |? {$_.Role -ne "Invalid"} | sort Address

	# Detect if Vendor software installed
	$coll = @()
	foreach ($s in $spservers) {
		$found = Get-ChildItem "\\$($s.Address)\C$\Program Files (x86)\Sharegate\Sharegate.exe" -ErrorAction SilentlyContinue
		if ($found) {
			if ($settings.settings.optionalLimitServers) {
				if ($settings.settings.optionalLimitServers.Contains($s.Address)) {
					$coll += $s.Address
				}
			} else {
				$coll += $s.Address
			}
		}
	}
	
	# Display and return
	$coll |% {Write-Host $_ -Fore Green}
	$global:servers = $coll
	
	# Safety
	if (!$coll) {
		Write-Host "No Servers Have ShareGate Installed.  Please Verify." -Fore Red
		Exit
	}
}

Function ReadCloudPW() {
	"<ReadCloudPW>"
	# Prompt for admin password
	Read-Host "Enter O365 Cloud Password for $($settings.settings.tenant.adminUser)"
}

Function CloseSession() {
	"<CloseSession>"
	# Close remote PS sessions
	Get-PSSession | Remove-PSSession
}

Function CreateWorkers() {
	"<CreateWorkers>"
	# Open worker sessions per server.  Runspace to create local SCHTASK on remote PC
    # Template command
    $cmd = @'
mkdir "d:\InsaneMove" -ErrorAction SilentlyContinue | Out-Null

Function VerifySchtask($name, $file) {
	$found = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
	if ($found) {
		$found | Unregister-ScheduledTask -Confirm:$false
	}

	$user = "[USERDOMAIN]\[USERNAME]"
	$pw = "[USERPASS]"
	
	$folder = Split-Path $file
	$a = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $file -WorkingDirectory $folder
	$p = New-ScheduledTaskPrincipal -RunLevel Highest -UserId $user -LogonType Password
	$task = New-ScheduledTask -Action $a -Principal $p
	return Register-ScheduledTask -TaskName $name -InputObject $task -Password $pw -User $user
}

VerifySchtask "worker1-[USERNAME]" "d:\InsaneMove\worker1-[USERNAME].ps1"
'@
$cmd = $cmd.replace("[USERDOMAIN]", $env:userdomain)
$cmd = $cmd.replace("[USERNAME]", $env:username)
$cmd = $cmd.replace("[USERPASS]", $global:pass.replace("`$","``$"))
$cmd

# Loop available servers
	$global:workers = @()
	$wid = 0
	$username = $env:username
	foreach ($pc in $global:servers) {
		# Loop maximum worker
		$s = New-PSSession -ComputerName $pc -Credential $global:cred -Authentication CredSSP -ErrorAction SilentlyContinue
        $s
        1..$maxWorker |% {
            # create worker
            $curr = $cmd.replace("worker1","worker$wid")
            Write-Host "CREATE Worker$wid-$username on $pc ..." -Fore Yellow
            $sb = [Scriptblock]::Create($curr)
            $result = Invoke-Command -Session $s -ScriptBlock $sb
			"[RESULT]"
            $result | ft -a
			
			# purge old worker XML output
			$resultfile = "\\$pc\d$\insanemove\worker$wid-$username.xml"
            Remove-Item $resultfile -confirm:$false -ErrorAction SilentlyContinue
			
            # track worker
			$obj = New-Object -TypeName PSObject -Prop (@{"Id"=$wid;"PC"=$pc})
			$global:workers += $obj
			$wid++
		}
	}
	"WORKERS"
	$global:workers | ft -a
}

Function CreateTracker() {
	"<CreateTracker>"
	# CSV migration source/destination URL
	Write-Host "===== Populate Tracking table ===== $(Get-Date)" -Fore Yellow

	$global:track = @()
	$csv = Import-Csv $fileCSV
	$i = 0	
	$wid = 0
	foreach ($row in $csv) {
		# Assign each row to a Worker
		$pc = $global:workers[$wid].PC
		
		# Get SharePoint total storage
		$site = Get-SPSite $row.SourceURL
		if ($site) {
			$SPStorage = [Math]::Round($site.Usage.Storage/1MB,2)
		}
		
		# MySite URL Lookup
		if ($row.MySiteEmail) {
			$destUrl = FindCloudMySite $row.MySiteEmail
		} else {
			$destUrl = $row.DestinationURL;
		}

		# Add row
		$obj = New-Object -TypeName PSObject -Prop (@{
			"SourceURL"=$row.SourceURL;
			"DestinationURL"=$destUrl;
			"MySiteEmail"=$row.MySiteEmail;
			"CsvID"=$i;
			"WorkerID"=$wid;
			"PC"=$pc;
			"Status"="New";
			"SGResult"="";
			"SGServer"="";
			"SGSessionId"="";
			"SGSiteObjectsCopied"="";
			"SGItemsCopied"="";
			"SGWarnings"="";
			"SGErrors"="";
			"Error"="";
			"ErrorCount"="";
			"TaskXML"="";
			"SPStorage"=$SPStorage;
			"TimeCopyStart"="";
			"TimeCopyEnd"=""
		})
		$global:track += $obj

		# Increment ID
		$i++
		$wid++
		if ($wid -ge $global:workers.count) {
			# Reset, back to first Session
			$wid = 0
		}
	}
	
	# Display
	"[SESSION-CreateTracker]"
	Get-PSSession | ft -a
}

Function UpdateTracker () {
	"<UpdateTracker>"
	# Update tracker with latest SCHTASK status
	$active = $global:track |? {$_.Status -eq "InProgress"}
	foreach ($row in $active) {
		# Monitor remote SCHTASK
		$wid = $row.WorkerID
        $pc = $row.PC
		
		# Reconnect Broken remote PS
		$broken = Get-PSSession |? {$_.State -ne "Opened"}
		if ($broken) {
			# Make new session
			if ($broken -is [array]) {
				# Multiple
				foreach ($brokenCurrent in $broken) {
					New-PSSession -ComputerName $brokenCurrent.ComputerName -Credential $global:cred -Authentication CredSSP -ErrorAction SilentlyContinue
					$brokenCurrent | Remove-PSSession
				}
			} else {
				# Single
				New-PSSession -ComputerName $broken.ComputerName -Credential $global:cred -Authentication CredSSP -ErrorAction SilentlyContinue
				$broken | Remove-PSSession
			}
		}
		
		# Check SCHTASK State=Ready
		$s = Get-PSSession |? {$_.ComputerName -eq $pc}
		$username = $env:username
		$cmd = "Get-Scheduledtask -TaskName 'worker$wid-$username'"
		$sb = [Scriptblock]::Create($cmd)
		$schtask = $null
		$schtask = Invoke-Command -Session $s -Command $sb
		if ($schtask) {
			"[SCHTASK]"
			$schtask | select {$pc},TaskName,State | ft -a
			"[SESSION-UpdateTracker]"
			Get-PSSession | ft -a
			if ($schtask.State -eq 3) {
				$row.Status = "Completed"
				$row.TimeCopyEnd = (Get-Date).ToString()
				
				# Do we have ShareGate XML?
				$resultfile = "\\$pc\d$\insanemove\worker$wid-$username.xml"
				if (Test-Path $resultfile) {
					# Read XML
					$x = $null
					[xml]$x = Get-Content $resultfile
					if ($x) {
						# Parse XML nodes
						$row.SGServer = $pc
						$row.SGResult = ($x.Objs.Obj.Props.S |? {$_.N -eq "Result"})."#text"
						$row.SGSessionId = ($x.Objs.Obj.Props.S |? {$_.N -eq "SessionId"})."#text"
						$row.SGSiteObjectsCopied = ($x.Objs.Obj.Props.I32 |? {$_.N -eq "SiteObjectsCopied"})."#text"
						$row.SGItemsCopied = ($x.Objs.Obj.Props.I32 |? {$_.N -eq "ItemsCopied"})."#text"
						$row.SGWarnings = ($x.Objs.Obj.Props.I32 |? {$_.N -eq "Warnings"})."#text"
						$row.SGErrors = ($x.Objs.Obj.Props.I32 |? {$_.N -eq "Errors"})."#text"
						
						# TaskXML
						$row.TaskXML = $x.OuterXml
						
						# Delete XML
						Remove-Item $resultfile -confirm:$false -ErrorAction SilentlyContinue
					}

					# Error
					$err = ""
					$errcount = 0
					$task.Error |% {
						$err += ($_|ConvertTo-Xml).OuterXml
						$errcount++
					}
					$row.ErrorCount = $errCount
				}
			}
		}
	}
}

Function ExecuteSiteCopy($row, $worker) {
	# Parse fields
	$name = $row.Name
	$srcUrl = $row.SourceURL
	
	# Destination
	if ($row.MySiteEmail) {
		# MySite /personal/
		$destUrl = $row.DestinationURL
	} else {
		# Team /sites/
		$destUrl = FormatCloudMP $row.DestinationURL
	}
	
	# Make NEW Session - remote PowerShell
	$username = $env:domainuser
    $wid = $worker.Id	
    $pc = $worker.PC
	$s = Get-PSSession |? {$_.ComputerName -eq $pc}
	
	# Generate local secure CloudPW
	$sb = [Scriptblock]::Create("""$global:cloudPW"" | ConvertTo-SecureString -Force -AsPlainText | ConvertFrom-SecureString")
	$localHash = Invoke-Command $sb -Session $s
	
	# Generate PS1 worker script
	$now = (Get-Date).tostring("yyyy-MM-dd_hh-mm-ss")
	if ($incremental) {
		# Team site INCREMENTAL
		$copyparam = "-CopySettings `$csIncr"
	}
	if ($row.MySiteEmail) {
		# MySite /personal/ = always RENAME
		$copyparam = "-CopySettings `$csMysite"
	}
	$username = $env:username
	$ps = "`$pw='$global:cloudPW';`nmd ""d:\insanemove\log"" -ErrorAction SilentlyContinue;`nStart-Transcript ""d:\insanemove\log\worker$wid-$username-$now.log"";`n""SOURCE=$srcUrl"";`n""DESTINATION=$destUrl"";`n`$secpw = ConvertTo-SecureString -String `$pw -AsPlainText -Force;`n`$cred = New-Object System.Management.Automation.PSCredential (""$($settings.settings.tenant.adminUser)"", `$secpw);`nImport-Module ShareGate;`n`$src=`$null;`n`$dest=`$null;`n`$src = Connect-Site ""$srcUrl"";`n`$dest = Connect-Site ""$destUrl"" -Credential `$cred;`nif (`$src.Url -eq `$dest.Url) {`n`$csMysite = New-CopySettings -OnSiteObjectExists Merge -OnContentItemExists Rename;`n`$csIncr = New-CopySettings -OnSiteObjectExists Merge -OnContentItemExists IncrementalUpdate;`n`$result = Copy-Site -Site `$src -DestinationSite `$dest -Subsites -Merge `$copyparam -InsaneMode -VersionLimit 50;`n`$result | Export-Clixml ""d:\insanemove\worker$wid-$username.xml"" -Force;`n} else {`n""URLs don't match""`n}`nStop-Transcript"
    $ps | Out-File "\\$pc\d$\insanemove\worker$wid-$username.ps1" -Force
    Write-Host $ps -Fore Yellow

    # Invoke SCHTASK
    $cmd = "Get-ScheduledTask -TaskName ""worker$wid-$username"" | Start-ScheduledTask"
	
	# Display
    Write-Host "START worker $wid on $pc" -Fore Green
	Write-Host "$srcUrl,$destUrl" -Fore yellow

	# Execute
	$sb = [Scriptblock]::Create($cmd) 
	return Invoke-Command $sb -Session $s
}

Function FindCloudMySite ($MySiteEmail) {
	# Lookup /personal/ site URL based on User Principal Name (UPN)
	$coll = @()
	$coll += $MySiteEmail
	$profile = Get-PnPUserProfileProperty -Account $coll
	if ($profile) {
		if ($profile.PersonalUrl) {
			$url = $profile.PersonalUrl.TrimEnd('/')
		}
	}
	Write-Host "SEARCH for $MySiteEmail found URL $url" -Fore Yellow
	return $url
}

Function WriteCSV() {
	"<WriteCSV>"
    # Write new CSV output with detailed results
    $file = $fileCSV.Replace(".csv", "-results.csv")
    $global:track | Select SourceURL,DestinationURL,MySiteEmail,CsvID,WorkerID,PC,Status,SGResult,SGServer,SGSessionId,SGSiteObjectsCopied,SGItemsCopied,SGWarnings,SGErrors,Error,ErrorCount,TaskXML,SPStorage | Export-Csv $file -NoTypeInformation -Force -ErrorAction Continue
}

Function CopySites() {
	"<CopySites>"
	# Monitor and Run loop
	Write-Host "===== Start Site Copy to O365 ===== $(Get-Date)" -Fore Yellow
	CreateTracker
	
	# Safety
	if (!$global:workers) {
		Write-Host "No Workers Found" -Fore Red
		return
	}
	
	$csvCounter = 0
	do {
		$csvCounter++
		# Get latest Job status
		UpdateTracker
		Write-Host "." -NoNewline
		
		# Ensure all sessions are active
		foreach ($worker in $global:workers) {
			# Count active sessions per server
			$wid = $worker.Id
			$active = $global:track |? {$_.Status -eq "InProgress" -and $_.WorkerID -eq $wid}
            
			if (!$active) {
				Write-Host " -- AVAIL" -Fore Green
				# Available session.  Assign new work
				Write-Host $wid -Fore Yellow
				$row = $global:track |? {$_.Status -eq "New" -and $_.WorkerID -eq $wid}
			
                if ($row) {
                    if ($row -is [Array]) {
                        $row = $row[0]
                    }
					$row |ft -a
					"GLOBAL TRACK"
					$global:track | ft -a

                    # Kick off copy
					Start-Sleep 5
					"sleep 5 sec..."
				    $result = ExecuteSiteCopy $row $worker

				    # Update DB tracking
				    $row.Status = "InProgress"
					$row.TimeCopyStart = (Get-Date).ToString()
                }
			} else {
				Write-Host " -- NO AVAIL" -Fore Green
			}
				
			# Progress bar %
			$complete = ($global:track |? {$_.Status -eq "Completed"}).Count
			$total = $global:track.Count
			$prct = [Math]::Round(($complete/$total)*100)
			
			# ETA
			if ($prct) {
				$elapsed = (Get-Date) - $start
				$remain = ($elapsed.TotalSeconds) / ($prct / 100.0)
				$eta = (Get-Date).AddSeconds($remain - $elapsed.TotalSeconds)
			}
			
			# Display
			Write-Progress -Activity "Copy site - ETA $eta" -Status "$name ($prct %)" -PercentComplete $prct

			# Detail table
			"[TRACK]"
			$global:track |? {$_.Status -eq "InProgress"} | select CsvID,WorkerID,PC,SourceURL,DestinationURL | ft -a
			$grp = $global:track | group Status
			$grp | select Count,Name | sort Name | ft -a
		}
		
		# Write CSV with partial results.  Enables monitoring long runs.
		if ($csvCounter -gt 5) {
			WriteCSV
			$csvCounter = 0
		}

		# Latest counter
		$remain = $global:track |? {$_.status -ne "Completed" -and $_.status -ne "Failed"}
		"Sleep 5 sec..."
		Start-Sleep 5
	} while ($remain)
	
	# Complete
	Write-Host "===== Finish Site Copy to O365 ===== $(Get-Date)" -Fore Yellow
	"[TRACK]"
	$global:track | group status | ft -a
	$global:track | select CsvID,JobID,SessionID,SGSessionId,PC,SourceURL,DestinationURL | ft -a
}

Function VerifyCloudSites() {
	"<VerifyCloudSites>"
	# Read CSV and ensure cloud sites exists for each row
	Write-Host "===== Verify Site Collections exist in O365 ===== $(Get-Date)" -Fore Yellow
	$global:collMySiteEmail = @()

	
	# Loop CSV
	$csv = Import-Csv $fileCSV
	foreach ($row in $csv) {
		$row | ft -a
		#REM EnsureCloudSite $row.SourceURL $row.DestinationURL $row.MySiteEmail
		$global:collMySiteEmail += $row.MySiteEmail
	}
	
	# Execute creation of OneDrive /personal/ sites in batches (200 each) https://technet.microsoft.com/en-us/library/dn792367.aspx
	Write-Host " - PROCESS MySite bulk creation"
	$i = 0
	$batch = @()
	foreach ($MySiteEmail in $global:collMySiteEmail) {
		if ($i -lt 199) {
			# append batch
			$batch += $MySiteEmail
			Write-Host "." -NoNewline
		} else {
			$batch += $MySiteEmail
			BulkCreateMysite $batch
			$i = 0
			$batch = @()
		}
		$i++
	}
	if ($batch.count) {
		BulkCreateMysite $batch
	}
	Write-Host "OK"
}

Function BulkCreateMysite ($batch) {
	"<BulkCreateMysite>"
	# execute and clear batch
	Write-Host "`nBATCH New-PnPPersonalSite $($batch.count)" -Fore Green
	$batch
	$batch.length
	New-PnPPersonalSite -Email $batch
}

Function EnsureCloudSite($srcUrl, $destUrl, $MySiteEmail) {
	"<EnsureCloudSite>"
	# Create site in O365 if does not exist
	$destUrl = FormatCloudMP $destUrl
	Write-Host $destUrl -Fore Yellow
	$srcUrl
	if ($srcUrl) {
		$web = (Get-SPSite $srcUrl).RootWeb
		if ($web.RequestAccessEmail) {
			$upn = $web.RequestAccessEmail.Split(",;")[0].Split("@")[0] + "@" + $settings.settings.tenant.suffix;
		}
		if (!$upn) {
			$upn = $settings.settings.tenant.adminUser
		}
	}
	
	# Verify User
     try {
		$web = Get-PnPWeb $settings.settings.tenant.adminURL
	    $u = New-PnPUser -Web $web -LoginName $upn -ErrorAction SilentlyContinue
    } catch {}
	if (!$u) {
		$upn = $settings.settings.tenant.adminUser
	}
	
	# Verify Site
	try {
		if ($destUrl) {
			$cloud = Get-PnPTenantSite -Url $destUrl -ErrorAction SilentlyContinue
		}
	} catch {}
	if (!$cloud) {
		Write-Host "- CREATING $destUrl"
		
		if ($MySiteEmail) {
			# Provision MYSITE
			$global:collMySiteEmail += $MySiteEmail
		} else {
			# Provision TEAMSITE
			$quota = 1024*50
			New-PnPTenantSite -Owner $upn -Url $destUrl -StorageQuota $quota 
		}
	} else {
		Write-Host "- FOUND $destUrl"
	}
}

Function FormatCloudMP($url) {
	# Replace Managed Path with O365 /sites/ only
	if (!$url) {return}
	$managedPath = "sites"
	$i = $url.Indexof("://")+3
	$split = $url.SubString($i, $url.length-$i).Split("/")
	$split[1] = $managedPath
	$final = ($url.SubString(0,$i) + ($split -join "/")).Replace("http:","https:")
	return $final
}

Function ConnectCloud {
	"<ConnectCloud>"
	# Prepare
	$pw = $global:cloudPW
	$pw
	$settings.settings.tenant.adminUser
	$secpw = ConvertTo-SecureString -String $pw -AsPlainText -Force
	$c = New-Object System.Management.Automation.PSCredential ($settings.settings.tenant.adminUser, $secpw)
	
	# Connect PNP
	Connect-PnpOnline -URL $settings.settings.tenant.adminURL -Credential $c
}

Function MeasureSiteCSV {
	"<MeasureSiteCSV>"
	# Populate CSV with local farm SharePoint site collection size
	$csv = Import-Csv $fileCSV
	foreach ($row in $csv) {
		$s = Get-SPSite $row.SourceURL
		if ($s) {
			$storage = [Math]::Round($s.Usage.Storage/1GB, 2)
			$row.SPStorage = $storage
		}
	}
	$csv | Export-Csv $fileCSV -Force
}

Function LockSite($lock) {
	"<LockSite>"
	# Modfiy on-prem site collection lock
	Write-Host $lock -Fore Yellow
	$csv = Import-Csv $fileCSV
	foreach ($row in $csv) {
		$url = $row.SourceURL
		Set-SPSite $url -LockState $lock
		"[SPSITE]"
		Get-SPSite $url | Select URL,*Lock* | ft -a
	}
}

Function SiteCollectionAdmin($user) {
	"<SiteCollectionAdmin>"
	# Grant site collection admin rights
	$csv = Import-Csv $fileCSV
	foreach ($row in $csv) {
		if ($row.MySiteEmail) {
			$url = FindCloudMySite $row.MySiteEmail
		} else  {
			$url = $row.DestinationURL.TrimEnd('/')
		}
		$url
		Set-PnPTenantSite -Url $url -Owners $user
	}
}

Function CompileAudiences() {
	# Find all local Audiences
	$AUDIENCEJOB_START       = '1'
	$AUDIENCEJOB_INCREMENTAL = '0'
	$site          = (Get-SPSite)[0]
	$context       = Get-SPServiceContext $site  
	$proxy         = $context.GetDefaultProxy([Microsoft.Office.Server.Audience.AudienceJob].Assembly.GetType('Microsoft.Office.Server.Administration.UserProfileApplicationProxy'))
	$applicationId = $proxy.GetType().GetProperty('UserProfileApplication', [System.Reflection.BindingFlags]'NonPublic, Instance').GetValue($proxy, $null).Id.Guid
	$auManager     = New-Object Microsoft.Office.Server.Audience.AudienceManager $context
	$auManager.Audiences | Sort-Object AudienceName |% {
		# Compile each Audience
		$an = $_.AudienceName
		$an
		[Microsoft.Office.Server.Audience.AudienceJob]::RunAudienceJob(@($applicationId, $AUDIENCEJOB_START, $AUDIENCEJOB_INCREMENTAL, $an))
	}
}

Function UserProfileSetHybridURL() {
	# UPS Manager
	$site = (Get-SPSite)[0]
	$context = Get-SPServiceContext $site
	$profileManager = New-Object Microsoft.Office.Server.UserProfiles.UserProfileManager($context)
	
	# MySite Host URL
	$myhost =  $settings.settings.tenant.adminURL.replace("-admin","-my")
	if (!$myhost.EndsWith("/")) {$myhost += "/"}
	
	# Loop CSV
	$csv = Import-Csv $fileCSV
	foreach ($row in $csv) {
		$login = $row.MySiteEmail.Split("@")[0]
		$p = $profileManager.GetUserProfile($login)
		if ($p) {
			# User Found
			$dest = FindCloudMySite $row.MySiteEmail
			if (!$dest.EndsWith("/")) {$dest += "/"}
			$dest = $dest.Replace($myhost,"/")
			
			# Update Properties - drives URL redirect Audience
			Write-Host "SET UPS for $login to $dest"
			$p["PersonalSpace"].Value = $dest
			$p.Commit()
		}
	}
}

Function Main() {
	"<Main>"
	# Start LOG
	$start = Get-Date
	$when = $start.ToString("yyyy-MM-dd-hh-mm-ss")
	$logFile = "$root\log\InsaneMove-$when.txt"
	mkdir "$root\log" -ErrorAction SilentlyContinue | Out-Null
	if (!$psISE) {
		try {
			Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
		} catch {}
		Start-Transcript $logFile
	}
	Write-Host "fileCSV = $fileCSV"

	# Core logic
	if ($userProfileSetHybridURL) {
		# Update local user profiles.  Set Personal site URL for Hybrid OneDrive audience compilation and redirect
		ReadCloudPW
		ConnectCloud
		UserProfileSetHybridURL
		CompileAudiences
	} elseif ($measure) {
		# Populate CSV with size (GB)
		MeasureSiteCSV
	} elseif ($readOnly) {
		# Lock on-prem sites
		LockSite "ReadOnly"
	} elseif ($readWrite) {
		# Unlock on-prem sites
		LockSite "Unlock"
	} elseif ($noAccess) {
		# NoAccess on-prem sites
		LockSite "NoAccess"	
	} elseif ($siteCollectionAdmin) {
		# Grant cloud sites SCA permission to XML migration cloud user
		ReadCloudPW
		ConnectCloud
		SiteCollectionAdmin $settings.settings.tenant.adminUser
	} else {
		if ($verifyCloudSites) {
			# Create site collection
			ReadCloudPW
			ConnectCloud
			VerifyCloudSites
		} else {
			# Copy site content
			VerifyPSRemoting
			ReadIISPW
			ReadCloudPW
			ConnectCloud
			DetectVendor
			CloseSession
			CreateWorkers
			CopySites
			CloseSession
			WriteCSV
		}
	}
	
	# Finish LOG
	Write-Host "===== DONE ===== $(Get-Date)" -Fore Yellow
	$th				= [Math]::Round(((Get-Date) - $start).TotalHours, 2)
	$attemptMb		= ($global:track |measure SPStorage -Sum).Sum
	$actualMb		= ($global:track |? {$_.SGSessionId -ne ""} |measure SPStorage -Sum).Sum
	$actualSites	= ($global:track |? {$_.SGSessionId -ne ""}).Count
	Write-Host ("Duration Hours              : {0:N2}" -f $th) -Fore Yellow
	Write-Host ("Total Sites Attempted       : {0}" -f $($global:track.count)) -Fore Green
	Write-Host ("Total Sites Copied          : {0}" -f $actualSites) -Fore Green
	Write-Host ("Total Storage Attempted (MB): {0:N0}" -f $attemptMb) -Fore Green
	Write-Host ("Total Storage Copied (MB)   : {0:N0}" -f $actualMb) -Fore Green
	Write-Host ("Total Objects               : {0:N0}" -f $(($global:track |measure SGItemsCopied -Sum).Sum)) -Fore Green
	Write-Host ("Total Worker Threads        : {0}" -f $maxWorker) -Fore Green
	Write-Host "====="  -Fore Yellow
	Write-Host ("GB per Hour                 : {0:N2}" -f (($actualMb/1KB)/$th)) -Fore Green
	Write-Host $fileCSV
	if (!$psISE) {Stop-Transcript}
}

Main