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

rem
rem Nice looking paths
rem
pushd "%CONTROLLER_HOME%\.."
    set DESTINATION=%cd%\dump
    set LOG=%DESTINATION%\load.log
popd

rem
rem Get the MySQL connection options from controller.bat
rem
set MYSQL_PORT=
for /f "tokens=2 delims==" %%i in ('FINDSTR /C:"DB_PORT=" "%CONTROLLER_HOME%\bin\controller.bat"') do (
    set MYSQL_PORT=%%i
)

set /p MYSQL_PASSWD=<"%CONTROLLER_HOME%\db\.rootpw"

set MYSQL_OPTS=-uroot -p%MYSQL_PASSWD% -P%MYSQL_PORT% -h127.0.0.1

echo Starting load... > "%LOG%"
echo MySQL Options: %MYSQL_OPTS% >> "%LOG%"

echo Log: %LOG%

rem
rem Perform load, one file for metadata, one file each for partitioned tables
rem

echo Loading metadata...
if exist "%DESTINATION%\metadata.sql" (
    "%CONTROLLER_HOME%\db\bin\mysql" %MYSQL_OPTS% controller < "%DESTINATION%\metadata.sql" 2>>"%LOG%"
    if errorlevel 1 (
        echo Loading metadata failed!
        echo See: %LOG%
        exit /b 1
    ) else (
        move "%DESTINATION%\metadata.sql" "%DESTINATION%\metadata.done" >nul
    )
)
