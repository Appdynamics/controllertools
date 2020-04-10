@echo off

setlocal enabledelayedexpansion

if not "%1" == "/?" goto :BEGIN
echo.
echo Dumps the embedded Controller database as .sql files using mysqldump.
echo.
echo Usage:
echo  ^> create-dump
echo.
echo Features:
echo * Self contained
echo * "Smart"
echo * Error tolerance
echo * Logging
echo * Resume
echo.
goto :EXIT
:BEGIN

rem
rem Unique name for the log file
rem dump-YYYY-MM-dd-HH_MM_SS_s.log
rem
for /f "delims=/ tokens=1-3" %%a in ("%DATE:~4%") do (
    for /f "delims=:. tokens=1-4" %%m in ("%TIME: =0%") do (
        set LOG=scan-%%c-%%b-%%a-%%m_%%n_%%o_%%p.log
    )
)

rem
rem Get Controller installation folder from windows registry
rem
set REG_KEY=HKEY_LOCAL_MACHINE\SOFTWARE\ej-technologies\install4j\installations
set REG_VAL=instdir8984-6429-2132-5090
set CONTROLLER_HOME=
for /f "usebackq skip=2 tokens=3*" %%i in (`reg query "%REG_KEY%" /v "%REG_VAL%"`) do (
	set CONTROLLER_HOME=%%i
)
if "%CONTROLLER_HOME%" == "" (
    echo Could not determine Controller installation directory from the registy, key=%REG_KEY% 1>&2
    exit /b 1
)
if not exist "%CONTROLLER_HOME%" (
    echo Controller install directory does not exist, installdir=%CONTROLLER_HOME% 1>&2
    exit /b 1
)

rem
rem Nice looking paths
rem
pushd "%CONTROLLER_HOME%\.."
    set DESTINATION=%cd%\dump
    set LOG=%DESTINATION%\logs\%LOG%
popd

rem
rem Init the output directory
rem
mkdir "%DESTINATION%" >nul 2>&1
mkdir "%DESTINATION%\logs" >nul 2>&1
mkdir "%DESTINATION%\scanned" >nul 2>&1
mkdir "%DESTINATION%\tmp" >nul 2>&1
mkdir "%DESTINATION%\ddl" >nul 2>&1
mkdir "%DESTINATION%\types" >nul 2>&1
compact /c "%DESTINATION%" >nul

rem
rem Get the MySQL connection options
rem
set MYSQL_PORT=
for /f "tokens=2 delims==" %%i in ('FINDSTR /C:"DB_PORT=" "%CONTROLLER_HOME%\bin\controller.bat"') do (
    set MYSQL_PORT=%%i
)
if exist "%CONTROLLER_HOME%\db\.rootpw" (
    set /p MYSQL_PASSWD=<"%CONTROLLER_HOME%\db\.rootpw"
) else (
    set MYSQL_PASSWD=
    for /f "tokens=2 delims==" %%i in ('FINDSTR /C:"mysql_root_user_password=" "%CONTROLLER_HOME%\bin\controller.bat"') do (
        set MYSQL_PASSWD=%%i
    )
)
set MYSQL_OPTS=-uroot -p%MYSQL_PASSWD% -P%MYSQL_PORT% -h127.0.0.1

rem
rem Get the MySQL data/ folder
rem
rem datadir=C:/AppDynamics/Controller/db/data
set DATA_DIR=
for /f "tokens=2 delims==" %%i in ('FINDSTR /R /C:"^datadir=" "%CONTROLLER_HOME%\db\db.cnf"') do (
    set DATA_DIR=%%i
)
set "DATA_DIR=%DATA_DIR:/=\%"

rem
rem Set working directory to db/bin so for loops
rem work with paths that have spaces
rem
pushd "%CONTROLLER_HOME%\db\bin"

echo Starting dump... > "%LOG%"
echo MySQL Options: %MYSQL_OPTS% >> "%LOG%"

echo.
echo Start Time: %DATE% %TIME%
echo InstallDir: %CONTROLLER_HOME%
echo    DataDir: %DATA_DIR%
echo    DumpDir: %DESTINATION%
echo    LogFile: %LOG%
echo.

rem
rem Build partitioned/ignore lists from MySQL db/data folder contents
rem
set IGNORE_LIST=--ignore-table=controller.ejb__timer__tbl

echo Scanning tables...
for /f "usebackq tokens=1" %%t in (`mysql %MYSQL_OPTS% -s -r -N -e "show tables;" controller 2^>^>"%LOG%"`) do (
    set TABLE_NAME=%%t

    if exist "%DESTINATION%\scanned\!TABLE_NAME!.scan" (
        if exist "%DESTINATION%\scanned\!TABLE_NAME!.ignore" (
            echo     ignoring table: !TABLE_NAME! >>"%LOG%"
            echo     ignoring table: !TABLE_NAME!
            set IGNORE_LIST=!IGNORE_LIST! --ignore-table=controller.!TABLE_NAME!
        )
    ) else (
        echo "%DATE% %TIME%" > "%DESTINATION%\scanned\!TABLE_NAME!.scan"

        rem
        rem Determine if table is safe to use
        rem

        echo    checking !TABLE_NAME! ...
        "%CONTROLLER_HOME%\db\bin\mysql" %MYSQL_OPTS% --skip-column-names --batch -e "show create table !TABLE_NAME!;" controller >"%DESTINATION%\tmp\!TABLE_NAME!.sql" 2>>"%LOG%"
        if errorlevel 1 (
            echo     ignoring table: !TABLE_NAME! >>"%LOG%"
            echo     ignoring table: !TABLE_NAME!
            set IGNORE_LIST=!IGNORE_LIST! --ignore-table=controller.!TABLE_NAME!
            echo "%DATE% %TIME%" > "%DESTINATION%\scanned\!TABLE_NAME!.ignore"
            echo !TABLE_NAME!>> ""%DESTINATION%\types\damaged-tables.txt"

            echo Ensuring DB is running...
            wmic path win32_process get ExecutablePath | findstr "/c:%CONTROLLER_HOME%\db\bin\mysqld.exe" >nul
            if errorlevel 1 (
                pushd "%CONTROLLER_HOME%\bin"
                call controller start-db
                popd
            ) else (
                echo DB is still running.
            )
            echo Continuing...
        ) else (
            echo checking table !TABLE_NAME! ^(ok^) >>"%LOG%"
        )
    )
)

echo Scanning partitions...
for /f %%f in ('dir /b /o:NE "%DATA_DIR%\controller"') do (
	set FILE=%%f
	if "!FILE:~-4!" == ".frm" (
		set TABLE_NAME=!FILE:~0,-4!

        if not exist "%DESTINATION%\scanned\!TABLE_NAME!.ignore" (
            if not exist "%DESTINATION%\types\!TABLE_NAME!.metadata" (
                if not exist "%DESTINATION%\types\!TABLE_NAME!.partition" (
                    if exist "%DATA_DIR%\controller\!TABLE_NAME!.par" (
                        rem Partitioned table
                        echo Partitioned Table:        !TABLE_NAME! >> "%LOG%"
                        echo Partitioned Table:        !TABLE_NAME!
                        echo %DATE% %TIME% > "%DESTINATION%\types\!TABLE_NAME!.partition"
                        echo !TABLE_NAME!>> "%DESTINATION%\types\partition-tables.txt"
                    ) else (
                        rem Metadata or Damaged Partition table
                        set /a PARTITION_COUNT=0
                        for /f %%g in ('dir /b /o:NE "%DATA_DIR%\controller\!TABLE_NAME!#p#*" 2^>nul') do (
                            set /a PARTITION_COUNT=!PARTITION_COUNT!+1
                        )
                        if !PARTITION_COUNT! gtr 0 (
                            rem Damaged Partitioned table
                            echo Damaged Partition Table:  !TABLE_NAME! >> "%LOG%"
                            echo Damaged Partition Table:  !TABLE_NAME!
                            echo %DATE% %TIME% > "%DESTINATION%\scanned\!TABLE_NAME!.ignore"
                            echo !TABLE_NAME!>> "%DESTINATION%\types\damaged-tables.txt"
                        ) else (
                            rem Metadata table
                            echo Metadata Table:           !TABLE_NAME! >> "%LOG%"
                            echo Metadata Table:           !TABLE_NAME!
                            echo %DATE% %TIME% > "%DESTINATION%\types\!TABLE_NAME!.metadata"
                            echo !TABLE_NAME!>> "%DESTINATION%\types\metadata-tables.txt"
                        )
                    )
                )
            )
        )
	)
)
for /f "usebackq tokens=*" %%t in ("%DESTINATION%\types\partition-tables.txt") do (
    set IGNORE_LIST=!IGNORE_LIST! --ignore-table=controller.%%t
)
for /f "usebackq tokens=*" %%t in ("%DESTINATION%\types\damaged-tables.txt") do (
    set IGNORE_LIST=!IGNORE_LIST! --ignore-table=controller.%%t
)

echo.
echo Ended: %DATE% %TIME%
echo Ended: %DATE% %TIME% >> "%LOG%"
