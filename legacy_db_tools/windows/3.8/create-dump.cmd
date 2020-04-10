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
rem Get Controller installation folder from windows registry
rem
set REG_KEY=HKEY_LOCAL_MACHINE\SOFTWARE\ej-technologies\install4j\installations
set REG_VAL=instdir8984-6429-2132-5090
set CONTROLLER_HOME=
for /f "usebackq skip=2 tokens=3*" %%i in (`reg query "%REG_KEY%" /v "%REG_VAL%"`) do (
	set CONTROLLER_HOME=%%i
)

rem
rem Nice looking paths
rem
pushd "%CONTROLLER_HOME%\.."
    set DESTINATION=%cd%\dump
    set LOG=%DESTINATION%\dump.log
popd

mkdir "%DESTINATION%" >nul 2>&1
compact /c "%DESTINATION%" >nul

rem
rem Get the MySQL connection options from controller.bat
rem
set MYSQL_PORT=
for /f "tokens=2 delims==" %%i in ('FINDSTR /C:"DB_PORT=" "%CONTROLLER_HOME%\bin\controller.bat"') do (
    set MYSQL_PORT=%%i
)

set /p MYSQL_PASSWD=<"%CONTROLLER_HOME%\db\.rootpw"

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

echo InstallDir: %CONTROLLER_HOME%
echo    DataDir: %DATA_DIR%
echo    DumpDir: %DESTINATION%
echo    LogFile: %LOG%
echo.

rem
rem Build partitioned/ignore lists from MySQL db/data folder contents
rem
set PARTITIONED=
set DAMAGED=
set IGNORE_LIST=--ignore-table=controller.ejb__timer__tbl

echo Scanning tables...
for /f "usebackq tokens=1" %%t in (`mysql %MYSQL_OPTS% -s -r -N -e "show tables;" controller 2^>^>"%LOG%"`) do (
    set TABLE_NAME=%%t

    "%CONTROLLER_HOME%\db\bin\mysql" %MYSQL_OPTS% -e "desc !TABLE_NAME!;" controller >nul 2>>"%LOG%"
    if errorlevel 1 (
        echo ignoring table: !TABLE_NAME! >>"%LOG%"
        echo ignoring table: !TABLE_NAME!
        set IGNORE_LIST=!IGNORE_LIST! --ignore-table=controller.!TABLE_NAME!

        echo Ensuring DB is running...
		wmic path win32_process get ExecutablePath | findstr "/c:%CONTROLLER_HOME%\db\bin\mysqld.exe"
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

echo Scanning partitions...
for /f %%f in ('dir /b /o:NE "%DATA_DIR%\controller"') do (
	set FILE=%%f
	if "!FILE:~-4!" == ".frm" (
		set TABLE_NAME=!FILE:~0,-4!

		if exist "%DATA_DIR%\controller\!TABLE_NAME!.par" (
			rem Partitioned table
			set IGNORE_LIST=!IGNORE_LIST! --ignore-table=controller.!TABLE_NAME!
			set PARTITIONED=!PARTITIONED! !TABLE_NAME!
			echo Partitioned Table:        !TABLE_NAME! >> "%LOG%"
		) else (
			rem Metadata or Damaged Partition table
			set /a PARTITION_COUNT=0
			for /f %%g in ('dir /b /o:NE "%DATA_DIR%\controller\!TABLE_NAME!#p#*" 2^>nul') do (
				set /a PARTITION_COUNT=!PARTITION_COUNT!+1
			)
			if !PARTITION_COUNT! gtr 0 (
				rem Damaged Partitioned table
				set IGNORE_LIST=!IGNORE_LIST! --ignore-table=controller.!TABLE_NAME!
				set DAMAGED=!DAMAGED! !TABLE_NAME!
				echo Damaged Partition Table:  !TABLE_NAME! >> "%LOG%"
				echo Damaged Partition Table:  !TABLE_NAME!
			) else (
				rem Metadata table
				echo Metadata Table:           !TABLE_NAME! >> "%LOG%"
			)
		)
	)
)
echo Partitioned Tables:          %PARTITIONED% >> "%LOG%"
echo Damaged Partitioned Tables:  %DAMAGED%     >> "%LOG%"

rem
rem Perform dumps
rem

rem
rem One file for metadata
rem
if not exist "%DESTINATION%\metadata.sql" (
    echo Dumping metadata...
    "%CONTROLLER_HOME%\db\bin\mysqldump" -v %MYSQL_OPTS% -r "%DESTINATION%\metadata.tmp" %IGNORE_LIST% controller 2>>"%LOG%"
    if errorlevel 1 (
        echo Error (^%ERRORLEVEL%^): metadata
        echo See: %LOG%

        echo Error (^%ERRORLEVEL%^): metadata >>"%LOG%"
    ) else (
        move "%DESTINATION%\metadata.tmp" "%DESTINATION%\metadata.sql" >nul
    )
)

rem
rem Append EJB Timer Table
rem
findstr "ejb__timer__tbl" "%DESTINATION%\metadata.sql" >nul
if errorlevel 1 (
    echo Dumping EJB Timer Table ^(Schema Only^)
    "%CONTROLLER_HOME%\db\bin\mysqldump" -v %MYSQL_OPTS% --no-data controller ejb__timer__tbl >> "%DESTINATION%\metadata.sql" 2>>"%LOG%"
    if errorlevel 1 (
        echo Error (^%ERRORLEVEL%^): ejb__timer__tbl
        echo Error (^%ERRORLEVEL%^): ejb__timer__tbl >>"%LOG%"
    )
)

rem
rem One for each partitioned table
rem
for %%t in (%PARTITIONED%) do (
    set TABLE_NAME=%%t

    if exist "%DESTINATION%\!TABLE_NAME!.tmp" (
        echo     Skipping table: ^(detected failed previous dump^)  !TABLE_NAME! >> "%LOG%"
        echo     Skipping table: ^(detected failed previous dump^)  !TABLE_NAME!
    ) else (
        if exist "%DESTINATION%\!TABLE_NAME!.done" (
            echo     Skipping table: ^(detected previous import^)       !TABLE_NAME! >> "%LOG%"
            echo     Skipping table: ^(detected previous import^)       !TABLE_NAME!
        ) else (
            if not exist "%DESTINATION%\!TABLE_NAME!.sql" (
                echo Dumping partitioned data^: !TABLE_NAME!...
                "%CONTROLLER_HOME%\db\bin\mysqldump" -v %MYSQL_OPTS% -r "%DESTINATION%\!TABLE_NAME!.tmp" controller !TABLE_NAME! 2>>"%LOG%"
                if errorlevel 1 (
                    echo Error (^%ERRORLEVEL%^): table=!TABLE_NAME!
                    echo Error (^%ERRORLEVEL%^): table=!TABLE_NAME! >>"%LOG%"
                    echo See: %LOG%

                    echo Ensuring DB is running...
                    wmic path win32_process get ExecutablePath | findstr "/c:%CONTROLLER_HOME%\db\bin\mysqld.exe"
                    if errorlevel 1 (
                        pushd "%CONTROLLER_HOME%\bin"
                        call controller start-db
                        popd
                    ) else (
                        echo DB is still running.
                    )
                    echo Continuing...
                ) else (
                    move "%DESTINATION%\!TABLE_NAME!.tmp" "%DESTINATION%\!TABLE_NAME!.sql" >nul
                )
            )
        )
    )
)

:EXIT