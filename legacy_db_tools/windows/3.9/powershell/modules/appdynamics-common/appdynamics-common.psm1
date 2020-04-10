# Derived from: http://stackoverflow.com/questions/13883404/custom-robocopy-progress-bar-in-powershell
Function Copy-WithRobocopy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Source, 
        [Parameter(Mandatory = $true)]
        [string] $Destination,
        [string[]]$excludeFiles,
        [string[]]$excludeDirs
    )

    # Define regular expression that will gather number of bytes copied
    $RegexBytes = '(?<=\s+)\d+(?=\s+)';

    # MIR   = Mirror mode
    # NP    = Don't show progress percentage in log
    # NC    = Don't log file classes (existing, new file, etc.)
    # BYTES = Show file sizes in bytes
    # NJH   = Do not display robocopy job header (JH)
    # NJS   = Do not display robocopy job summary (JS)
    # TEE   = Display log in stdout AND in target log file
    # XF    = Exclude files
    # XD    = Exclude directories
    $CommonRobocopyParams = '/MIR /NP /NDL /NC /BYTES /NJH /NJS';
    If ($excludeFiles) {
        $CommonRobocopyParams += " /XF $($excludeFiles -Join ' ')";
    }
    If ($excludeDirs) {
        $CommonRobocopyParams += " /XD $($excludeDirs -Join ' ')";
    }
    $CommonRobocopyParams += " /R:1 /W:0"

    # Robocopy Staging
    Write-Verbose -Message 'Analyzing robocopy job ...';
    $StagingLogPath = '{0}\temp\{1} robocopy staging.log' -f $env:windir, (Get-Date -Format 'yyyy-MM-dd hh-mm-ss');

    $StagingArgumentList = '"{0}" "{1}" /LOG:"{2}" /L {3}' -f $Source, $Destination, $StagingLogPath, $CommonRobocopyParams;
    Write-Verbose -Message ('Staging arguments: {0}' -f $StagingArgumentList);
    Start-Process -Wait -FilePath robocopy.exe -ArgumentList $StagingArgumentList -NoNewWindow;
    
    # Get the total number of files that will be copied
    $StagingContent = Get-Content -Path $StagingLogPath;
    $FileCount = $StagingContent.Count;

    # Get the total number of bytes to be copied
    [RegEx]::Matches(($StagingContent -join "`n"), $RegexBytes) | % { $BytesTotal = 0; } { $BytesTotal += $_.Value; };
    Write-Verbose -Message ('Total bytes to be copied: {0}' -f $BytesTotal);

    # Begin the robocopy process
    $RobocopyLogPath = '{0}\temp\{1} robocopy.log' -f $env:windir, (Get-Date -Format 'yyyy-MM-dd hh-mm-ss');
    $ArgumentList = '"{0}" "{1}" /LOG:"{2}" {3}' -f $Source, $Destination, $RobocopyLogPath, $CommonRobocopyParams;
    Write-Verbose -Message ('Beginning the robocopy process with arguments: {0}' -f $ArgumentList);
    $Robocopy = Start-Process -FilePath robocopy.exe -ArgumentList $ArgumentList -Verbose -PassThru -NoNewWindow;
    Start-Sleep -Milliseconds 100;

    while (!$Robocopy.HasExited) {
        $BytesCopied = 0;
        $LogContent = Get-Content -Path $RobocopyLogPath;
        $BytesCopied = [Regex]::Matches($LogContent, $RegexBytes) | ForEach-Object -Process { $BytesCopied += $_.Value; } -End { $BytesCopied; };
        Write-Verbose -Message ('Bytes copied: {0}' -f $BytesCopied);
        Write-Verbose -Message ('Files copied: {0}' -f $LogContent.Count);
        Write-Progress -Activity Robocopy -Status ("Copied {0} files; Copied {1} of {2} bytes" -f $LogContent.Count, $BytesCopied, $BytesTotal) -PercentComplete (($BytesCopied/$BytesTotal)*100);
    
        Start-Sleep -Milliseconds 100;
    }

    [PSCustomObject]@{
        BytesCopied = $BytesCopied;
        FilesCopied = $LogContent.Count;
    };
}
