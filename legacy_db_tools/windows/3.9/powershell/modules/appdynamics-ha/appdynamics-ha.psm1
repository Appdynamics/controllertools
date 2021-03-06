If (!$PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
Import-Module "$PSScriptRoot/../appdynamics-controller" -ErrorAction Stop
Import-Module "$PSScriptRoot/../appdynamics-common" -ErrorAction Stop

$PSModuleRoot = Split-Path -Parent $PSScriptRoot

Function Initialize-ControllerReplication {
    Param (
        [string]$PrimaryController,
        [System.Management.Automation.PSCredential]$PrimaryCred,
        [string]$SecondaryController,
        [System.Management.Automation.PSCredential]$SecondaryCred,
        [switch]$final
    )
    
    If ($PrimaryCred) {
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $PrimaryController -Concatenate -Force
        $primary = New-PSSession -ComputerName $PrimaryController -Credential $PrimaryCred -ErrorAction Stop
    } Else {
        $primary = New-PSSession -ComputerName $PrimaryController -ErrorAction Stop
    }
    
    If ($SecondaryCred) {
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $SecondaryController -Concatenate -Force
        $secondary = New-PSSession -ComputerName $SecondaryController -Credential $SecondaryCred -ErrorAction Stop        
    } Else {
        $secondary = New-PSSession -ComputerName $SecondaryController -ErrorAction Stop
    }

    try {
        # 0) Load remote modules
        New-PSDrive -Name "P" -PSProvider FileSystem -Root "\\$PrimaryController\c$"  -ErrorAction Stop | Out-Null
        New-PSDrive -Name "S" -PSProvider FileSystem -Root "\\$SecondaryController\c$"  -ErrorAction Stop | Out-Null
        
        $primaryHome = Invoke-Command -Session $primary  -ScriptBlock { Split-Path -NoQualifier $HOME } -ErrorAction Stop
        $secondaryHome = Invoke-Command -Session $secondary  -ScriptBlock { Split-Path -NoQualifier $HOME } -ErrorAction Stop
        
        Invoke-Command -Session $primary { New-Item -ItemType directory -Path "$HOME\Documents\WindowsPowerShell\Modules" 2>&1 | Out-Null }
        Invoke-Command -Session $secondary { New-Item -ItemType directory -Path "$HOME\Documents\WindowsPowerShell\Modules" 2>&1 | Out-Null }

        Copy-Item $PSModuleRoot\* "P:$primaryHome\Documents\WindowsPowerShell\Modules" -Recurse -Force -ErrorAction Stop
        Copy-Item $PSModuleRoot\* "S:$secondaryHome\Documents\WindowsPowerShell\Modules" -Recurse -Force -ErrorAction Stop

        Invoke-Command -Session $primary   -ScriptBlock { Set-ExecutionPolicy Unrestricted; Import-Module -Name "appdynamics-ha" -Force } -ErrorAction Stop
        Invoke-Command -Session $secondary -ScriptBlock { Set-ExecutionPolicy Unrestricted; Import-Module -Name "appdynamics-ha" -Force } -ErrorAction Stop
        
        # 1) Test we are not replicating the wrong node
        $mode = Invoke-Command -session $primary { Get-ControllerMode } -ErrorAction Stop
        If ([string]::IsNullOrEmpty($mode) -or $mode -eq "passive") {
            Write-Error "Primary Controller must be in active mode, mode=$mode"
            Return
        }

        # 2) Stop Primary replication
        Invoke-Command -session $primary { Stop-ControllerReplication }

        # 3) Stop the secondary controller
        Invoke-Command -session $secondary { Stop-Controller } -ErrorAction Stop
        
        If ($final) {
            Invoke-Command -session $primary { Stop-Controller } -ErrorAction Stop
        }
        
        # 4) Enable Primary HA
        Invoke-Command -session $secondary { Enable-ControllerReplication }
        
        # 5) Disable Primary slave start
        Invoke-Command -session $primary { Set-ControllerSlaveStart -value "false" } -ErrorAction Stop
        
        # 6) Set Primary server-id to 666
        Invoke-Command -session $primary { Set-ControllerServerId -serverId 666 } -ErrorAction Stop
        
        # 7) Copy controller + data to the secondary
        $backupConfig = Invoke-Command -session $secondary { Backup-ControllerDBConfig }
        Invoke-ControllerSync -primary $primary -secondary $secondary -ErrorAction Stop
        Invoke-Command -session $secondary { Restore-ControllerDBConfig -backupConfig $backupConfig }
        
        # Incremental stops here
        
        # 8 Restart the primary controller db
        If ($final) {
            Start-ControllerDB -session $primary -ErrorAction Stop
            Wait-ControllerDBReady -session $primary -ErrorAction Stop
            
            $primaryHAStart = @(
                "STOP SLAVE; RESET SLAVE; RESET MASTER;",
                "GRANT ALL ON *.* TO 'controller_repl'@'$SecondaryController' IDENTIFIED BY 'controller_repl';",
                "FLUSH HOSTS;",
                "CHANGE",
                " MASTER TO MASTER_HOST='$SecondaryController',",
                " MASTER_USER='controller_repl',",
                " MASTER_PASSWORD='controller_repl',",
                " MASTER_PORT=3388;",
                "update global_configuration_local set value = 'active' where name = 'appserver.mode';",
                "update global_configuration_local set value = 'primary' where name = 'ha.controller.type';",
                "truncate ejb__timer__tbl;"
            )
            Invoke-MySQLCommand -sql $($primaryHAStart -join " ") -ErrorAction Stop
            
            Start-ControllerDB -session $secondary -ErrorAction Stop
            Wait-ControllerDBReady -session $secondary -ErrorAction Stop
            
            $secondaryHAStart = @(
                "STOP SLAVE; RESET SLAVE; RESET MASTER;",
                "GRANT ALL ON *.* TO 'controller_repl'@'$PrimaryController' IDENTIFIED BY 'controller_repl';",
                "FLUSH HOSTS;",
                "CHANGE",
                " MASTER TO MASTER_HOST='$PrimaryController',",
                " MASTER_USER='controller_repl',",
                " MASTER_PASSWORD='controller_repl',",
                " MASTER_PORT=3388;",
                "update global_configuration_local set value = 'passive' where name = 'appserver.mode';",
                "update global_configuration_local set value = 'secondary' where name = 'ha.controller.type';",
                "truncate ejb__timer__tbl;"
            )
            Invoke-MySQLCommand -sql $($secondaryHAStart -join " ") -ErrorAction Stop

            Set-ControllerSlaveStart -session $primary -value "true" -ErrorAction Stop
            Set-ControllerSlaveStart -session $secondary -value "true" -ErrorAction Stop
            
            Start-ControllerReplication -session $primary -ErrorAction Stop
            Start-ControllerReplication -session $secondary -ErrorAction Stop
            
            Start-Controller -session $primary -ErrorAction Stop
        }
    } Finally {
        If ($primary) {
            Remove-PSSession $primary
        }
        If ($secondary) {
            Remove-PSSession $secondary
        }
        #If ($PrimaryCred) {
        #    $th = ((Get-Item -Path WSMan:\localhost\Client\TrustedHosts).Value).Replace($PrimaryController, '')
        #    Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $th
        #}
        #If ($SecondaryCred) {
        #    $th = ((Get-Item -Path WSMan:\localhost\Client\TrustedHosts).Value).Replace($SecondaryController, '')
        #    Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $th
        #}
    }
}`

Function Get-ControllerMode {
    $sql = "select value from global_configuration where name = 'appserver.mode'"

    Invoke-MySQLCommand -sql $sql -raw
}

Function Enable-ControllerReplication {
    If (!$MySQLConfig["mysqld"]["server-id"]) {
        Get-Content $PSScriptRoot/master-db.cnf | Out-File $MySQLConfigPath -Append -Encoding UTF8
        $MySQLConfig = Get-MySQLConfigFile "$MySQLConfigPath"
    }
}

Function Stop-ControllerReplication {
    $result = Invoke-MySQLCommand -sql "SHOW SLAVE STATUS;"
    if ($result) {
        Invoke-MySQLCommand -sql "STOP SLAVE; RESET SLAVE; RESET MASTER;"
    }
}

Function Start-ControllerReplication {
    Invoke-MySQLCommand -sql "START SLAVE;"
}

Function Set-ControllerSlaveStart {
    Param([string]$value)
    
    ${db.cnf} = Get-Content $MySQLConfigPath
    if (${db.cnf} -match "^skip-slave-start=" ) {
        ${db.cnf} -replace "^skip-slave-start=.*", "skip-slave-start=$value" | Set-Content $MySQLConfigPath     
    } else {
        Invoke-Command { "skip-slave-start=$value" | Out-File $MySQLConfigPath -Append -Encoding UTF8 }
    }
}

Function Set-ControllerServerId {
    Param([int]$serverId)

    ${db.cnf} = Get-Content $MySQLConfigPath
    if (${db.cnf} -match "^server-id=" ) {
        ${db.cnf} -replace "^server-id=.*", "server-id=$serverId" | Set-Content $MySQLConfigPath     
    } else {
        Add-Content $MySQLConfigPath "server-id=$serverId"
    }
}

Function Invoke-ControllerSync {
    Param(
        [System.Management.Automation.Runspaces.PSSession]$primary, 
        [System.Management.Automation.Runspaces.PSSession]$secondary
    )
    
    # ControllerDir Paths
    $pControllerHome = Invoke-Command -Session $primary   -ScriptBlock { Get-ControllerDir }
    $sControllerHome = Invoke-Command -Session $secondary -ScriptBlock { Get-ControllerDir }
    $source      = "\\$($primary.ComputerName  )\$(Split-Path -Qualifier $pControllerHome | %{ $_ -replace ':', '' })$\$(Split-Path $pControllerHome -NoQualifier)"
    $destination = "\\$($secondary.ComputerName)\$(Split-Path -Qualifier $sControllerHome | %{ $_ -replace ':', '' })$\$(Split-Path $sControllerHome -NoQualifier)"
    
    # ControllerDir Excludes
    $controllerExcludeFiles = @(
        'license.lic', 
        'db\bin\.status'
    )
    $controllerExcludeDirs = @(
        'logs', 
        'db\data',
        'app_agent_operation_logs', 
        'appserver\glassfish\domains\domain1\appagent\logs',
        'tmp'
    )
    
    # ControllerDir sync
    Copy-WithRobocopy -source $source -destination $destination -excludeFiles $controllerExcludeFiles -excludeDirs $controllerExcludeDirs -ErrorAction stop
    
    # DataDir Paths
    $pDataDir = Invoke-Command -Session $primary   -ScriptBlock { Get-ControllerDataDir }
    $sDataDir = Invoke-Command -Session $secondary -ScriptBlock { Get-ControllerDataDir }
    $source      = "P:" + $(Split-Path $pDataDir -NoQualifier)
    $destination = "S:" + $(Split-Path $sDataDir -NoQualifier)
    
    # DataDir Excludes
    $dataDirExcludeFiles = @(
        '*.log',
        '*.pid'
    )
    $dataDirExcludeDirs = @(
        'bin-log',
        'relay-log'
    )
    
    # DataDir sync
    Copy-WithRobocopy -source $primary -destination $secondary -excludeFiles $dataDirExcludeFiles -excludeDirs $dataDirExcludeDirs -ErrorAction stop
}

Function Backup-ControllerDBConfig {
    [PSCustomObject]@{
        datadir  = $MySQLConfig['mysqld']['datadir'];
        serverId = $MySQLConfig['mysqld']['server-id'];
    };
}

Function Restore-ControllerDBConfig {
    Param($backupConfig)
    
    # restore db.cnf datadir setting
    # change the server id
    ${db.cnf} = Get-Content $MySQLConfigPath
    ${db.cnf} = ${db.cnf} -replace "^datadir=.*", "datadir=$backupConfig.dataDir" 
    ${db.cnf} = ${db.cnf} -replace "^server-id=.*", "server-id=$backupConfig.serverId"
    ${db.cnf} | Set-Content $MySQLConfigPath
}
