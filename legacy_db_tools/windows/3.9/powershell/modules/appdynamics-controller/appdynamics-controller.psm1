Function Get-ControllerDir {
    $key = 'HKLM:\SOFTWARE\ej-technologies\install4j\installations'
    $name = 'instdir8984-6429-2132-5090'
    $value = get-itemproperty -path $key -name $name
    return $value.$name
}
$ControllerDir = Get-ControllerDir   
$controller = "$ControllerDir\bin\controller.bat"

# Workaround: CORE-34518
$controllerScript = Get-Content -Path $controller
$pattern = '^for %%F in \("%0"\) do set SCRIPT_DIR=%%~dpF'
If ($controllerScript -match $pattern) {
    $controllerScript | Set-Content -Path "$($controller).orig"
    $controllerScript -Replace $pattern, "set SCRIPT_DIR=%~dp0" | Set-Content -Path $controller
}

Function Invoke-Controller {
    Param([string]$cmd)

    &$controller $cmd
}
Function Start-Controller {
    Invoke-Controller -cmd "start"
}
Function Stop-Controller {
    Invoke-Controller -cmd "stop"
}
Function Start-ControllerDB {
    # Check MySQL pid
    $mysqlPid = Get-Content -Path "$MySQLDataDir\$(hostname).pid" -ErrorAction SilentlyContinue
    If ($mysqlPid) {
        foreach ($process in (Get-Process | Where-Object { $_.id -eq $mysqlPid })) {
            return
        }
    }
    
    # MySQL could still be running
    foreach ($process in (Get-Process mysqld -ErrorAction SilentlyContinue | Foreach-Object { $_.Path -eq $mysql })) { 
        return
    }
    
    Invoke-Controller -cmd "start-db"
}
Function Stop-ControllerDB {
    # Check MySQL pid
    $mysqlPid = Get-Content -Path "$MySQLDataDir\$(hostname).pid" -ErrorAction SilentlyContinue
    If ($mysqlPid) {
        Get-Process | Where-Object { $_.id -eq $mysqlPid } | Foreach-Object {
            Invoke-Controller -cmd "stop-db"
            return
        }
    }
    
    # MySQL could still be running
    Get-Process mysqld -ErrorAction SilentlyContinue | Foreach-Object { $_.Path -eq $mysql } | Foreach-Object {
        Invoke-Controller -cmd "stop-db"
        return
    }
}

Function Get-MySQLConfigFile ($file) {
    $conf = @{}

    switch -regex -file $file {
        # Ignore Comments
        "^#.*" {
        }
        # Section [mysqld_safe, mysqld, ...]
        "^\[(.+)\]$" {
            $section = $matches[1].Trim()
            $conf[$section] = @{}
        }
        # Name / Value pairs (can have comments)
        "^\s*([^#].+?)\s*=\s*([^#]*)#?.*" {
            $name, $value = $matches[1..2]
            $conf[$section][$name] = $value.Trim()
        }
    }
    
    $conf
}
$MySQLConfigPath = "$ControllerDir\db\db.cnf"
$MySQLConfig = Get-MySQLConfigFile "$MySQLConfigPath"
$MySQLDataDir = $MySQLConfig['mysqld']['datadir']
$MySQLRootPwPath = "$ControllerDir\db\.rootpw"
$MySQLRootPassword = Get-Content "$MySQLRootPwPath"

Function Get-ControllerDataDir {
    $MySQLDataDir
}

$DomainXmlPath = "$ControllerDir\appserver\glassfish\domains\domain1\config\domain.xml"
[xml]$DomainXml = Get-Content $DomainXmlPath
Function Get-MySQLPortFromDomainXml {
    $xpath = "/domain/resources/jdbc-connection-pool[@name='controller_mysql_pool']/property[@name='portNumber']/@value"
    return $DomainXml.SelectSingleNode($xpath)
}
$MySQLPort = $MySQLConfig['mysqld']['port']

$mysql = "$ControllerDir\db\bin\mysql.exe"
$MySQLConnectionOptions = @(
    "-u", "root",
    "-p$MySQLRootPassword",
    "-h", "127.0.0.1",
    "-P", $MySQLPort
)
$MySQLRawFormattingOptions = @("-s", "-r", "-N")

Function Invoke-MySQLCommand {
    Param([string]$sql, 
          [string]$database = "controller", 
          [switch]$raw)

    If ($raw) {
        &$mysql $MySQLConnectionOptions $MySQLRawFormattingOptions -e "$sql;" $database
    } Else {
        &$mysql $MySQLConnectionOptions -e "$sql;" $database
    }
}

Function Wait-ControllerDBReady {
    &$mysql $MySQLConnectionOptions -e ";"
    while ($LastExitCode -ne 0) {
        Start-Sleep -seconds 2
        
        &$mysql $MySQLConnectionOptions -e ";"
    }
}

Export-ModuleMember -function * -variable ControllerDir, DomainXml, MySQLConfigPath, MySQLConfig, MySQLConnectionOptions
