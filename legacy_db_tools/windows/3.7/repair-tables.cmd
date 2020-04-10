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
    set DESTINATION=%cd%
    set LOG=%DESTINATION%\repair.log
popd

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

echo Running repair command... > "%LOG%"
echo MySQL Options: %MYSQL_OPTS% >> "%LOG%"

echo Log: %LOG%

rem
rem Perform the repair table command
rem
"%CONTROLLER_HOME%\db\bin\mysqlcheck" %MYSQL_OPTS% --check mysql 2>>"%LOG%"
"%CONTROLLER_HOME%\db\bin\mysqlcheck" %MYSQL_OPTS% --auto-repair mysql 2>>"%LOG%"
