If (!$PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
Import-Module "$PSScriptRoot/../appdynamics-controller"

$mysqldump = "$ControllerDir\db\bin\mysqldump.exe"

Function Get-MySQLTableInfo {
    Param([string]$database)

    $tables = @{}
    $tables["all-tables"] = Invoke-MySQLCommand -sql "show tables" -database "$database" -raw
    
    $metadataTables = New-Object System.Collections.Generic.List[System.String]
    $partitionTables = New-Object System.Collections.Generic.List[System.String]
    $damagedPartitionTables = New-Object System.Collections.Generic.List[System.String]
    
    foreach ($table in $tables["all-tables"]) {
        If (Test-Path "$($MySQLConfig['mysqld']['datadir'])\$database\$table.par") {
            $partitionTables.Add("$table")
        } ElseIf ((dir "$($MySQLConfig['mysqld']['datadir'])\$database\$table#p#*") -gt 0) {
            $damagedPartitionTables.Add("$table")
        } Else {
            $metadataTables.Add("$table")
        }
    } 

    $tables["metadata-tables"] = $metadataTables.ToArray()
    $tables["partition-tables"] = $partitionTables.ToArray()
    $tables["damaged-partition-tables"] = $damagedPartitionTables.ToArray()
    
    $nonMetadataTables = New-Object System.Collections.Generic.List[System.String]
    $nonMetadataTables.AddRange($partitionTables)
    $nonMetadataTables.AddRange($damagedPartitionTables)
    $tables["non-metadata-tables"] = $nonMetadataTables.ToArray()  
         
    return $tables
}

Function Invoke-MySQLDump {
    Param([string]$file, 
          [string]$database, 
          [string[]]$ignoreList, 
          [string]$table, 
          [string[]]$tables,
          [switch]$append = $False,
          [switch]$noData = $False)
    
    $dumpOptions = @("--verbose")
    If (!$append) {
        $dumpOptions += "--result-file=$file"
    }
    If ($noData) {
        $dumpOptions += "--no-data"
    }
    
    If ($ignoreList) {
        $ignore = New-Object System.Collections.Generic.List[System.String]
        $ignore.Add("--ignore-table=controller.ejb__timer__tbl")
        for ($i = 0; $i -lt $ignoreList.Length; $i++) {
            $ignore.Add("--ignore-table=$database." + $ignoreList[$i])
        }      
        If ($append) {  
            &$mysqldump $MySQLConnectionOptions $dumpOptions $ignore.ToArray() $database 2>&1 | ForEach-Object { "$_" } | Out-File $file -Append -Encoding UTF8
        } Else {
            &$mysqldump $MySQLConnectionOptions $dumpOptions $ignore.ToArray() $database 2>&1 | ForEach-Object { "$_" }
        } 
    } ElseIf ($table) {
        If ($append) {
            &$mysqldump $MySQLConnectionOptions $dumpOptions $database $table 2>&1 | ForEach-Object { "$_" } | Out-File $file -Append -Encoding UTF8
         } Else {
            &$mysqldump $MySQLConnectionOptions $dumpOptions $database $table 2>&1 | ForEach-Object { "$_" }
        }
    } ElseIf ($tables) {
        If ($append) {
            &$mysqldump $MySQLConnectionOptions $dumpOptions $database $tables 2>&1 | ForEach-Object { "$_" } | Out-File $file -Append -Encoding UTF8
        } Else {
            &$mysqldump $MySQLConnectionOptions $dumpOptions $database $tables 2>&1 | ForEach-Object { "$_" }
        }
    } Else {
        If ($append) {
            &$mysqldump $MySQLConnectionOptions $dumpOptions $database 2>&1 | ForEach-Object { "$_" } | Out-File $file -Append -Encoding UTF8
        } Else {
            &$mysqldump $MySQLConnectionOptions $dumpOptions $database 2>&1 | ForEach-Object { "$_" }
        }
    }
}

Function New-ControllerMetaDataDump {
    Param([string]$file = "c:\dump\metadata.sql", $tableInfo)
    
    $folder = Split-Path -Path $file -Parent
    If (!(Test-Path -Path $folder)) {
        New-Item -ItemType directory -Path $folder | Out-Null
    }
    
    If (!$tableInfo) {
        $tableInfo = Get-MySQLTableInfo -database "controller"
    }
    
    Invoke-MySQLDump -file $file -database "controller" -ignoreList $tableInfo["non-metadata-tables"] 
    Invoke-MySQLDump -file $file -database "controller" -append -noData -table "ejb__timer__tbl"
}

Function New-ControllerMetricDataDump {
    Param([string]$folder, $tableInfo)
    
    If (!(Test-Path -Path $folder)) {
        New-Item -ItemType directory -Path $folder | Out-Null
    }

    If (!$tableInfo) {
        $tableInfo = Get-MySQLTableInfo -database "controller"
    }
    
    foreach ($table in $tableInfo["partition-tables"]) {
        Invoke-MySQLDump -file $folder\$table.sql -database "controller" -table "$table"
    }
}

Function New-ControllerDataDump {
    Param([string]$folder = "c:\dump")
    
    $tableInfo = Get-MySQLTableInfo -database "controller"

    New-ControllerMetaDataDump -tableInfo $tableInfo -file "$folder\metadata.sql"
    New-ControllerMetricDataDump -tableInfo $tableInfo -folder $folder
}
