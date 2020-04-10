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
if "%CONTROLLER_HOME%" == "" (
    echo Could not determine Controller installation directory from the registy, key=%REG_KEY% 1>&2
    exit /b 1
)
if not exist "%CONTROLLER_HOME%" (
    echo Controller install directory does not exist, installdir=%CONTROLLER_HOME% 1>&2
    exit /b 1
)

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
rem Run the MySQL client passing all script arguments to it
rem
"%CONTROLLER_HOME%\db\bin\mysql" %MYSQL_OPTS% %*
