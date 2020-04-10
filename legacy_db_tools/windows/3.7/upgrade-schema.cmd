@echo off

setlocal enabledelayedexpansion

rem
rem Get Controller installation folder from windows registry
rem
set REG_KEY=HKEY_LOCAL_MACHINE\SOFTWARE\ej-technologies\install4j\installations
set REG_VAL=instdir8984-6429-2132-5090
set CONTROLLER_HOME=
for /f "usebackq skip=2 tokens=3*" %%i in (`reg query "%REG_KEY%" /v "%REG_VAL%"`) do (
	set CONTROLLER_HOME=%%i
)

set DESTINATION=%CONTROLLER_HOME%\db\upgrade
set LOG=%DESTINATION%\upgrade.log

mkdir "%DESTINATION%" >nul 2>&1

rem
rem Get the MySQL connection options from controller.bat
rem
set MYSQL_PORT=
for /f "tokens=2 delims==" %%i in ('FINDSTR /C:"DB_PORT=" "%CONTROLLER_HOME%\bin\controller.bat"') do (
    set MYSQL_PORT=%%i
)
set MYSQL_PASSWD=
for /f "tokens=2 delims==" %%i in ('FINDSTR /C:"mysql_root_user_password=" "%CONTROLLER_HOME%\bin\controller.bat"') do (
    set MYSQL_PASSWD=%%i
)
set MYSQL_OPTS=-uroot -p%MYSQL_PASSWD% -P%MYSQL_PORT% -h127.0.0.1

rem
rem Set working directory to db/bin so for loops
rem work with paths that have spaces
rem
pushd "%CONTROLLER_HOME%\db\bin"

echo Log: %LOG%
echo. > "%LOG%"

echo MySQL Options: %MYSQL_OPTS% >> "%LOG%"
echo MySQL Options: %MYSQL_OPTS%

rem
rem Get current schema version
rem
set SCHEMA_VERSION_SQL=
for /f "usebackq tokens=1" %%s in (`mysql %MYSQL_OPTS% -s -r -N -e "select value from global_configuration where name='schema.version';" controller 2^>^>"%LOG%"`) do (
	set SCHEMA_VERSION_SQL=%%s
)
set SCHEMA_VERSION_PROC=
for /f "usebackq tokens=1" %%s in (`mysql %MYSQL_OPTS% -s -r -N -e "select value from global_configuration where name='schema.proc.version';" controller 2^>^>"%LOG%"`) do (
	set SCHEMA_VERSION_PROC=%%s
)
if "%SCHEMA_VERSION_PROC%" equ "" (
    set SCHEMA_VERSION_PROC=%SCHEMA_VERSION_SQL%
)

echo.
echo.
echo Schema (DDL)  version: %SCHEMA_VERSION_SQL% >> "%LOG%"
echo Schema (DDL)  version: %SCHEMA_VERSION_SQL%
echo Schema (PROC) version: %SCHEMA_VERSION_PROC% >> "%LOG%"
echo Schema (PROC) version: %SCHEMA_VERSION_PROC%

echo.
echo.
echo Starting upgrade... >> "%LOG%"
echo Starting upgrade...
echo.
echo.

rem
rem Run the upgrade DDL files that are for versions higher
rem than the current db schema version (as set in the global_configuration* tables)
rem
for /f %%f in ('dir /b /o:NE "%CONTROLLER_HOME%\upgrade-scripts"') do (
	set FILE=%%f
	if "!FILE:~0,8!" == "upgrade-" (
		set VERSION=!FILE:upgrade-=!
		set VERSION=!VERSION:.sql=!
		set VERSION=!VERSION:.proc=!

		echo Checking !FILE! >> "%LOG%"

        if "!VERSION!" gtr "!SCHEMA_VERSION_PROC!" (
            echo !FILE! >> "%LOG%"
            echo !FILE!

            findstr /R /V /C:"^^--" "%CONTROLLER_HOME%\upgrade-scripts\upgrade-!VERSION!.sql.proc" ^
            | "%CONTROLLER_HOME%\db\bin\mysql" %MYSQL_OPTS% controller --delimiter="//" 2>>"%LOG%"
            if errorlevel 1 (
                echo Script Failed: !FILE!
                echo See: %LOG%
                exit /b 1
            )

            echo     schema.proc.version --^> !VERSION! >> "%LOG%"
            echo     schema.proc.version --^> !VERSION!

            "%CONTROLLER_HOME%\db\bin\mysql" %MYSQL_OPTS% -e "update global_configuration_cluster set value = '!VERSION!' where name='schema.proc.version'" controller 2>>"%LOG%"
            if errorlevel 1 (
                echo 'schema.version' updated failed.
                echo See: %LOG%
                exit /b 1
            )
            set SCHEMA_VERSION_PROC=!VERSION!
        ) else (
            echo Skipping proc update !VERSION! >> "%LOG%"
        )

		if "!VERSION!" gtr "!SCHEMA_VERSION_SQL!" (
			echo !FILE! >> "%LOG%"
			echo !FILE!

			findstr /R /V /C:"^^--" "%CONTROLLER_HOME%\upgrade-scripts\upgrade-!VERSION!.sql" ^
			| "%CONTROLLER_HOME%\db\bin\mysql" %MYSQL_OPTS% controller 2>>"%LOG%"
			if errorlevel 1 (
				echo Script Failed: !FILE!
				echo See: %LOG%
				exit /b 1
			)
			
            echo     schema.version --^> !VERSION! >> "%LOG%"
            echo     schema.version --^> !VERSION!

            "%CONTROLLER_HOME%\db\bin\mysql" %MYSQL_OPTS% -e "update global_configuration_cluster set value = '!VERSION!' where name='schema.version'" controller 2>>"%LOG%"
            if errorlevel 1 (
                echo 'schema.version' updated failed.
                echo See: %LOG%
                exit /b 1
            )
		) else (
			echo Skipping sql update !VERSION! >> "%LOG%"
		)
	)
)
