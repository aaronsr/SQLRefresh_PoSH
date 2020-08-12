[Cmdletbinding()]
Param (
    [Parameter(Mandatory)][string]$TargetServer,
    [Parameter(Mandatory)][string]$TargetDatabase,
    [Parameter(Mandatory)][string]$SharePath,
    [string]$SourceServer,
    [string]$SourceDatabase,
    [string]$BackupFileName, 
    [switch]$UseExistingBackup,
    [string]$DBOwner,
    [switch]$KeepPermissions,
    [switch]$DropUsers,
    [switch]$KeepDBBackup,
    [switch]$UseBackupAlreadyInShare,
    [string]$PathToBackupAlreadyInShare,
    [string]$DestinationDataDirectory,
    [string]$DestinationLogDirectory
)

Write-verbose "Source server = $SourceServer"
write-verbose "Source database = $SourceDatabase"
Write-verbose "Target server = $TargetServer"
Write-verbose "Target database = $TargetDatabase"
Write-verbose "Share path = $SharePath"
Write-verbose "Use existing DB = $UseExistingBackup"
Write-verbose "Backup already in share? = $UseBackupAlreadyInShare"
Write-verbose "Path to backup already in share location = $PathToBackupAlreadyInShare"
Write-verbose "Custom destination for SQL data file = $DestinationDataDirectory"
Write-verbose "Custom destination for SQL log file = $DestinationLogDirectory"


#Stop on any error by default
$ErrorActionPreference = 'Stop'

#Temporary permissions will be stored here
$permissionsFile = $SharePath + "\" + "Permissions-$TargetDatabase.sql"

#Record and store permissions
if ($KeepPermissions -or $DropUsers) {
    $permissions = Export-DbaUser -SqlInstance $TargetServer -Database $TargetDatabase -FilePath $permissionsFile
    Write-Verbose "Exported permissions from $TargetServer.$TargetDatabase`: $permissions"
    Write-Verbose "Storing permissions of $TargetServer.$TargetDatabase in a file $permissionsFile"
}

if ($UseExistingBackup) {
    Write-verbose "UseExistingBackup"
    try {
        $GetLastFullBackup = Get-DbaDbBackupHistory -SqlInstance $SourceServer -Database $SourceDatabase -LastFull
        $PathOfLastFullBackup = $GetLastFullBackup.FullName
    }catch {Write-Verbose $_
           Exit}

    Try{
        $UNCPathOfFullBackup = $PathOfLastFullBackup.replace(":\", "$\")
        $UNCPathOfFullBackup = "\\$SourceServer\" + $UNCPathOfFullBackup
        Copy-Item -Path $UNCPathOfFullBackup -Destination $SharePath -Force
        $FileName = (Get-ChildItem -Path $UNCPathOfFullBackup).Name
        $BackupFilePath = $SharePath + "\" + $FileName
    }catch {Write-Verbose $_
           Exit}
}


    # Uses a backup already in the share location 
elseif($UseBackupAlreadyInShare){
    $BackupFilePath = $PathToBackupAlreadyInShare
}

    # This uses the $BackupFileName & performs a manual backup to a specific location
else {
    Write-verbose "Full Backup and Restore"
    $BackupFilePath = $SharePath + "\" + $BackupFileName
    if (Test-Path ($BackupFilePath + ".old")){
        Remove-Item ($BackupFilePath + ".old")
    }
    if (Test-Path $BackupFilePath) {
        if($KeepDBBackup){
            Rename-Item -Path $BackupFilePath -NewName ($BackupFilePath + ".old") -Force
        }
    else{
        #Removing old temporary backup if it still exists for some reason
        Write-Verbose "Removing old backup file $BackupFilePath"
        Remove-Item $BackupFilePath
        }
    }
    #Run copy-only backup
    Write-Verbose "Initiating database backup`: $SourceServer.$SourceDatabase to $BackupFilePath"
    $backup = Backup-DbaDatabase -SqlInstance $SourceServer -Database $SourceDatabase -BackupFileName $BackupFilePath -CopyOnly -CompressBackup -Checksum -EnableException -verbose

    if (!$backup.BackupComplete) {
        throw "Backup to $BackupFilePath was not completed successfully on $SourceServer.$SourceDatabase"
    }
}

#Perform the DB restore
if (Test-Path $BackupFilePath){
    Write-Verbose "BackupFilePath = $BackupFilePath"
    Write-Verbose "TargetServer = $TargetServer"
    Write-Verbose "TargetDatabase = $TargetDatabase"
    Write-Verbose "Initiating database restore`: $BackupFilePath to $TargetServer.$TargetDatabase"
    try {
        # Custom restore path for the database files. 
        if ($DestinationDataDirectory -and $DestinationLogDirectory){
            Write-Verbose "Custom restore"
            Restore-DbaDatabase -SqlInstance $TargetServer -DatabaseName $TargetDatabase -Path $BackupFilePath -DestinationDataDirectory $DestinationDataDirectory -DestinationLogDirectory $DestinationLogDirectory -WithReplace -ReplaceDbNameInFile -EnableException -Verbose
        }
        # This restores the DB files to the original location that is mapped on the Source server. 
        # If this path doesn't exist on the Target server you will need to use the custom destination path for the data and log files. 
        else {
            Restore-DbaDatabase -SqlInstance $TargetServer -DatabaseName $TargetDatabase -Path $BackupFilePath -ReuseSourceFolderStructure -WithReplace -ReplaceDbNameInFile -EnableException -Verbose
        }
    }catch {Write-Verbose $Error
        Exit}

}
#Update database owner
if ($DBOwner) {
    Write-Verbose "Updating database owner to $DBOwner"
    Set-DbaDbOwner -SqlInstance $TargetServer -Database $TargetDatabase -TargetLogin $DBOwner
}


#Drop users if requested
if ($DropUsers) {
    $users = Get-DbaDbUser -SqlInstance $TargetServer -Database $TargetDatabase -ExcludeSystemUser
    foreach ($user in $users) {
        Write-Verbose "Dropping user $($user.Name) from $TargetServer.$TargetDatabase"
        try {
            $user.Drop()
        }
        catch {
            # No need to throw, maybe a user owns a schema of its own
            Write-Warning -Message "DropUser Error $_"
        }
    }
}


#Restore permissions
if ($KeepPermissions) {
    Write-Verbose "Restoring permissions of $TargetServer.$TargetDatabase from a file $permissionsFile"
    try{
        Invoke-DbaQuery -SqlInstance $TargetServer -Database $TargetDatabase -CommandType Text -File $permissionsFile
        }catch{"Keep Permissions: $_"}
}


#Remove backup file
if ((!$KeepDBBackup) -and (Test-Path $BackupFilePath)) {
   try {
       Write-Verbose "Removing backup file $BackupFilePath"
       Remove-Item $BackupFilePath
   }catch {Write-Warning -Message "Remove Backup File Error $_"}   
}


#Remove permissions file
if (Test-Path $permissionsFile) {
   Write-Verbose "Removing permissions file $permissionsFile"
   Remove-Item $permissionsFile
}

