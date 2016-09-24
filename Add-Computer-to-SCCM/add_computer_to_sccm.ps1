﻿# This Script imports a CSV and creates Datasets in SCCM
# It then creates a file for the Collection to be updated. 
# This script must be run on a SCCM Server with AD-Powershell Modules enabled.
# This is What your CSV should look like:
# Name, Mac, Collection, Archticture, OSVersion, Network,  TypID
#
# WARNING: Computername can not be longer than 15 Characters.
# 
# You can use this to automatically import with Varibales useable in an AIO Task Sequence.

# Define Varibales
[string]$SCCMComputer = "."
[string]$smssite = "YOURSITECODE"
$filepath="F:\SCCM_Import\CSVImport\"
$backuppath="F:\SCCM_Import\CSVImportBackup\"
$collectionfile="F:\SCCM_Import\RefreshCollection\"
$targetOU="OU=Client_Install,OU=Client,DC=Install,DC=example,DC=com"

# No editing beyond this point.
[int]$varcount=0
[int]$i=0
[int]$clientscount=0
$mac= $null
$logentries=@()
$clients=@()
$groupmember=@()
$runtime=Get-Date -format yyyyMMddHHmm
$logfile=$backuppath+$runtime+".log"
$errorlogfile=$backuppath+$runtime+"ERROR.log"
$collectionfile=$collectionfile+$runtime+"Collection.txt"
$Error.Clear()

#Active Directory Modul hinzufügen
Import-Module -Name "ActiveDirectory" -Force -ErrorAction SilentlyContinue


$refreshCol=@()
$Class = "SMS_Site"
$Method = "ImportMachineEntry"
$MC = [WmiClass]"\\$SCCMComputer\ROOT\SMS\site_$($smssite):$Class"
$error.clear()

# Function for Creating a Logfile with timestamp
Function writeLog ($logs)
{
    $time=(get-date).toLongTimestring()
    add-content -path $logfile -Value "$time  $logs"
}

# Function for setting a varibale in SCCM
function setvariable ($ResourceID,$variablename,$variablevalue)
{
    # If there is not yet a variable attached to the Computer Object
	if ($varcount -lt 1) 
	{
		$objPCSet.psbase.properties["ResourceID"].value = $compResourceID
		$objPCSet.psbase.properties["SourceSite"].value = $smssite
		$objPCSet.MachineVariables = $objPCSet.MachineVariables + [WmiClass]"\\$SCCMComputer\ROOT\SMS\SITE_$($smssite):SMS_MachineVariable"
		$machinevariables =  $objPCSet.MachineVariables
		$machinevariables[($machinevariables.count)-1].Name = $variablename 
		$machinevariables[($machinevariables.count)-1].value = $variablevalue
		$objPCSet.MachineVariables = $machinevariables
		$objPCSet=$objPCSet.put()
		if ($?)
		{
            $varcount++
			return $true
		}
		else
		{
			return $false
		}
		
	}
    # If there already are variables
	else 
	{
		$objPCSet = [WmiClass]""
		$objPCSet.psbase.Path ="\\$SCCMComputer\ROOT\SMS\SITE_$($smssite):SMS_MachineSettings"
		$objPCSet = $objPCSet.createInstance()
		$objPCSet.ResourceID = $compResourceID
		$objPCSet.SourceSite = $smssite
		$objPCSet.psbase.get() 
		$objPCSet.MachineVariables = $objPCSet.MachineVariables + [WmiClass]"\\$SCCMComputer\ROOT\SMS\SITE_$($smssite):SMS_MachineVariable"
		$machinevariables = $objPCSet.MachineVariables 
		$machinevariables[($machinevariables.count)-1].Name = $variablename 
		$machinevariables[($machinevariables.count)-1].value = $variablevalue 
		$objPCSet.MachineVariables = $machinevariables 
		$objPCSet=$objPCSet.put()
		if ($?)
		{
            $varcount++
			return $true
		}
		else
		{
			return $false
		}
	}
}

# Find computer in AD
function findcomputer ($adclient)
{
	trap {$error.Clear();continue;return $false} 
	if (($global:adclientpath=(get-adcomputer $adclient).DistinguishedName) -ne $null) {return $true}

}

# Check if target collection exists
function findcollection ($strCollection)
{
    
    if (!((Get-WmiObject -class "SMS_Collection" -namespace "root\SMS\Site_$smssite" -Filter "Name = '$strCollection'") -eq $null))
    {
        writelog ("Verbindung zur Sammlung $strCollection wurde aufgebaut.")
        return $true
    }
    else 
    {
        writelog "ERROR: Sammlung $strCollection konnte nicht gefunden werden."
        return $false
    }
}

# Split the MAC
function SplitMAC ($mac)
{

    $i=0
    while ($i -lt 12)
    {
        if ($i -eq 0) {$mac=$mac.insert($i+2,":")}
        else {$mac=$mac.insert(($i++)+3,":")}
    $i=$i+2
    }
    $global:InParams.MACAddress = $mac
    $global:delmac=$mac
 }
 


# Check Input Fileformat
function checkFormat ($importfile)
{
    $checks=get-content $importfile.fullname
    foreach ($check in $checks)
    {
        if (!$check.contains(",")) {return $false} 
        else {$check=$check.split(",")}

        #Anzahl der Parameter überprüfen
        if ($check.count -ne 8 -or $check[1].length -ne 12) {return $false} 
        else {continue}
    }
    return $true
    
}

# Get the files
$importfiles= get-childitem -path $filepath -filter *.csv
if ($importfiles -eq $null) 
{
    exit
}


# Create Logfile
New-Item -ItemType file -Path $logfile -force

# Copy CSV File
$importfiles| foreach {
    Copy-Item $_.fullname $backuppath -Force
    writelog "$($_.fullname) was copied"
   }
writelog ("A copy of the CSV file(s) was created.")


#Format der ImportDatei überprüfen

#Computerdateien importieren
foreach ($importfile in $importfiles)
{
    
    if (checkformat $importfile) 
    {
        $clients+= Get-Content -Path $importfile.fullname
    }
    else
    {
        writelog "ERROR: The File $importfile is invalid. Check Formatting."
        writelog "This Script will stop now."
        exit
    }
}


$directruleClass = [WMIClass] "root\SMS\Site_$($smssite):SMS_CollectionRuleDirect"
$directruleInstance = $directruleClass.CreateInstance() 
$directruleInstance.ResourceClassName = "SMS_R_System"

# Creating the Computer Object in SCCM
Foreach ($client in $clients)
{
    $i=0
    # get the MAC
    $client=$client.Split(",")
    $InParams = $mc.psbase.GetMethodParameters($Method)
    # split it
    splitmac ($Client[1])
    # use it as NetbiosName
	$InParams.NetbiosName = $Client[0]
	$objcomputer=$client[0]
    $runclient=$client[0]
    writelog ("Now working on '$runclient'")
	# Check if there is a USMT entry
	$objMig = Get-WmiObject -namespace "root\SMS\Site_$($smssite)" -Query "select * from SMS_StateMigration where Restorename = '$($client[0])'"
´	# 
	if ($objmig -ne $null -and $obj.MigrationType -eq 1)
	{
		writelog ("There is a USMT record for $($objmig.sourcename) .")
		writelog ("I will not delete this Object for you!")
        continue
	}

	# Delete existing Computer with the same name
    $objcomputer = Get-WmiObject -class "SMS_R_System" -namespace "root\SMS\Site_$($smssite)" -Filter "Name = '$($client[0])'"
	if ($objComputer -ne $null) 
     {
       foreach ($obj in $objcomputer)
        {
            $obj.delete()
        }
        if ($?)
		{
			writelog ("WARNING: Object $runclient was deleted based on it's name in SCCM.")
		}
		else
		{
			writelog ("ERROR: Object $runclient could not be deleted (based on it's name) in SCCM.")
		}
    }
    # Delete existing Computer with the same MAC
    $objcomputermac = Get-WmiObject -class "SMS_R_System" -namespace "root\SMS\Site_$($smssite)" -Filter "MACAddresses = '$delmac'"
    if ($objComputermac -ne $null) 
    {
        foreach ($objmac in $objcomputermac)
        {
            $objmac.delete()
        }
		if ($?)
		{
        	writelog ("WARNING: Object $runclient was deleted based on it's MAC in SCCM.")
		}
		else
		{
			writelog ("ERROR: Object $runclient could not be deleted (based on it's MAC) in SCCM.")
		}
   }
    
	# Create Computer in SCCM
	$objComputer = $mc.PSBase.InvokeMethod($Method, $inParams, $Null)
	$directruleInstance.ResourceID = $objcomputer.ResourceId
	if ($?)
	{
    	writelog ("Object $runclient was created or updated with ResourceId " + $objcomputer.ResourceId)
    }
	else
	{
		writelog ("ERROR: Object $runclient could not be created or updated.")
		writelog ("ERROR: Aborting work on $runclient .")
		continue		
	}
	
	$compResourceID=$objcomputer.ResourceId
   
	# Search for Computer Object in AD and extract Groups
	$adclient=$client[0]
	if ((findcomputer $adclient)) 
		{
			$comp= (get-adcomputer $adclient -properties memberof)

	           foreach ($group in $comp.memberof)
	               {
		              if ((get-adgroup $group).samaccountname -like "sccm*")
                      {
                      $groupmember+=(get-adgroup $group).samaccountname
                      }
	               }
		} 
	else # Create new Computer Object
	{
		New-ADComputer -Name $adclient -Path $targetOU
		if ($?)
		{
			writelog ("Computer Object $adclient was created in AD.")
		}
		else
		{
			writelog ("ERROR: Computer Object $adclient could not be created in AD.")
		}
	}

	# Define SCCM Computer Object
	$objPCSet = [WmiClass]"" 
	$objPCSet.psbase.Path ="\\$SCCMComputer\ROOT\SMS\SITE_$($smssite):SMS_MachineSettings" 
	$objPCSet =  $objPCSet.CreateInstance()
	$varcount=0
	foreach ($ClientProperty in $Client)        
	{           
        # Set the Collection
        If ($i -eq 2){
            if (findcollection ($ClientProperty))
                {
	            (Get-WmiObject -class "SMS_Collection" -namespace "root\SMS\Site_$smssite" -Filter "Name = '$ClientProperty'").AddMembershipRule($directruleInstance)
                if ($?)
                {
                        writelog ("Object $runclient was added to Collection $ClientProperty.")
                }
	            else
	            {
			            writelog ("ERROR: Object $runclient could not be added to Collection $ClientProperty.")
	            }
            }
        }
        # Set all other Variables
		elseIf ($i -gt 2 -and $i -lt 7) 
	    {
            switch($i)
            {
                3 {$variableName="SMSTSOsArchitecture"}
                4 {$variableName="SMSTSOsVersion"}
                5 {$variableName="SMSTSNetwork"}
                6 {$variableName="TYPID"}
            }

            if (setvariable $compResourceID $variablename $ClientProperty)
			{
                writelog ("Variable $variablename was set to $ClientProperty for Object $runclient.")
			}
			else
			{
				writelog ("ERROR: Variable $variablename could not be set to $ClientProperty for Object $runclient.")
			}

		}
		$i++
        Continue
	}
	writelog ("Client $runclient was successfully processed.")
    $clientscount++
}

# Create Collection File
IF ($groupmember -ne $null)
{
    $refreshCol= ($groupmember| select -Unique)
    add-content -path (New-Item -ItemType file -Path $collectionfile -force) -value $refreshCol
    if ($?)
	{
		writelog ("Collectionfile $collectionfile was created.")
	}
	else
	{
		writelog ("ERROR: Collectionfile $collectionfile could not be created.")
	}
}

# Delete Imported File
get-childitem -path $filepath -filter *.csv| Remove-Item -Force
writelog "Importfiles were deleted"

if (!$error)
{
    writelog ("Script was successfully completed: $clientscount Computers were imported.")
}
else
{
    writelog ("There where errors during processing. Please check Errorlogfile: $errorlogfile.")
}


# Write errors to file
if ($error -ne $null)
{
    $Error| Out-File -filepath $errorlogfile -force
	add-content -path $errorlogfile -Value "There where errors during processing. Please check Errorlogfile: $logfile."
}
