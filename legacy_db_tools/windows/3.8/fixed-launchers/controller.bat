@echo off

REM The script for managing the controller lifecycle

setlocal enabledelayedexpansion

REM Variables configured by the installer
set DB_PORT=3388
set APPSERVER_ADMIN_PORT=4848
set APPSERVER_DIR=appserver
set GF_DIR=appserver\glassfish

set SERVICE_NAME_DB=AppDynamics Database
set SERVICE_NAME_APP=AppDynamics_Domain1


IF NOT DEFINED AD_SHUTDOWN_TIMEOUT_IN_MIN (
        set AD_SHUTDOWN_TIMEOUT_IN_MIN=10
)
SET /A STOP_TIMEOUT=%AD_SHUTDOWN_TIMEOUT_IN_MIN% * 60

IF NOT DEFINED AD_STARTUP_TIMEOUT_IN_MIN (
        set AD_STARTUP_TIMEOUT_IN_MIN=3
)
SET /A START_TIMEOUT=%AD_STARTUP_TIMEOUT_IN_MIN% * 60

REM DO NOT EDIT BELOW THIS LINE!

REM need this so we don't depend on user being in this directory when running
set CURRENT_DIR="%cd%"
for %%F in ("%0") do set SCRIPT_DIR=%%~dpF
cd %SCRIPT_DIR%

cd ..
set INSTALL_DIR="%cd%"
set IMQ_JAVAHOME=%cd%

IF NOT DEFINED MYSQL_BIN (
        set MYSQL_BIN=%INSTALL_DIR%\db\bin
)
echo [INFO] Using mysql from %MYSQL_BIN%

IF NOT DEFINED AD_DB_CNF (
        set AD_DB_CNF=%INSTALL_DIR%\db\db.cnf
)
echo [INFO] Using mysql configuration file: %AD_DB_CNF%

IF NOT DEFINED MYSQL_ROOT_PASSWD (
	if EXIST %INSTALL_DIR%\db\.rootpw (
        	set /p MYSQL_ROOT_PASSWD=<%INSTALL_DIR%\db\.rootpw
        )
)

REM if "%1" == "reset-app-data" goto resetApplicationData
if "%1" == "patch-upgrade" goto patchUpgrade
if "%1" == "start" goto startControllerDB
if "%1" == "start-appserver" goto startControllerAppServer
if "%1" == "start-db" goto startControllerDB
if "%1" == "stop" goto stopControllerAppServer
if "%1" == "stop-appserver" goto stopControllerAppServer
if "%1" == "stop-db" goto stopControllerDB
if "%1" == "login-db" goto controllerDBLogin
if "%1" == "optimize-db" goto optimizeControllerDB
if "%1" == "start-svcs" goto startServices
if "%1" == "stop-svcs" goto stopServices
if "%1" == "install" goto installServices
if "%1" == "uninstall" goto uninstallServices
if "%1" == "reset-ejb-jms-tables" goto resetControllerDB
if "%1" == "recreate-jms-tables" goto recreateJMSTables
if "%1" == "enable-http-listeners" goto enableHttpListeners
if "%1" == "disable-http-listeners" goto disableHttpListeners
if "%1" == "upgrade-db-internals" goto upgradeDatabaseInternals
if "%1" == "zip-logs" goto zipLogs

echo "usage: controller [start | stop | start-appserver | stop-appserver | start-db | stop-db | login-db | optimize-db | reset-ejb-jms-tables | recreate-jms-tables | enable-http-listeners | disable-http-listeners | patch-upgrade /path/to/controller_patch_upgrade.zip | zip-logs]"
echo "usage (for Windows service controller only): controller [start-svcs | stop-svcs | install | uninstall]"
goto end

:stopControllerAppServer
REM Stop the application server only if it is running
cd %INSTALL_DIR%\%GF_DIR%\bin
DEL as_status
CALL asadmin.bat list-domains > as_status 2>&1
FINDSTR /I /C:"domain1 not running" as_status >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
	echo Stopping controller application server
	cd %INSTALL_DIR%\%GF_DIR%\bin
	CALL asadmin.bat stop-domain domain1
	IF !ERRORLEVEL! NEQ 0 (
		echo ***** Failed to stop Controller application server *****
		goto end
	) else (
		REM Wait for the Controller application server to stop
		echo | set /p=Waiting for Controller application server to stop
		set /a "TIME = 0"
		:checkAppStop
		CALL asadmin.bat list-domains | FINDSTR /I /C:"domain1 not running" >nul
		IF !ERRORLEVEL! NEQ 0 (
			IF "%TIME%" == "%STOP_TIMEOUT%" (
				echo | set /p=***** Timed out waiting for Controller application server to stop *****
				goto end
			) else (

				echo | set /p dot=.
				TIMEOUT /T 1 /NOBREAK >nul
				set /a "TIME = TIME + 1"
				goto :checkAppStop
			)
		) else (
			echo.
			echo | set /p=***** Controller application server stopped *****
			echo.
		)
	)
) else (
	echo.
	echo ***** Controller application server is not running *****
	echo.
)
if "%1" == "stop" goto stopControllerDB
goto end

:stopControllerDB
cd /D "%MYSQL_BIN%"
CALL mysqladmin --user=root -p%MYSQL_ROOT_PASSWD% --port=%DB_PORT% --protocol=TCP status > .status 2>&1

REM Check if controller database is running on port %DB_PORT%
FINDSTR /I /C:"Uptime:" .status >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
        echo ***** Controller database is not running on port %DB_PORT% *****
	goto end
)

REM Stop the database
echo Stopping controller database
START /B mysqladmin --user=root -p%MYSQL_ROOT_PASSWD% --port=%DB_PORT% --protocol=TCP shutdown 1> NUL 2>&1

REM Wait up to 10 minutes for the database to stop
echo | set /p=Waiting for Controller database to stop
set /a "TIME = 0"

rem Get the mysqld.exe process id
for /f "tokens=2 delims==" %%i in ('FINDSTR /C:"pid_file=" "%INSTALL_DIR%\db\db.cnf"') do (
    set DB_PIDFILE=%%i
)
if "%DB_PIDFILE%" == "" (
	for /f "tokens=2 delims==" %%i in ('FINDSTR /C:"datadir=" "%INSTALL_DIR%\db\db.cnf"') do (
	    set DB_DATADIR=%%i
	)
	if "%DB_DATADIR%" == "" (
		set DB_DATADIR=%INSTALL_DIR%\db\data
	)

	for /f "usebackq tokens=*" %%i in (`hostname`) do (
		set DB_PIDFILE=!DB_DATADIR!\%%i.pid
	)
)
if not exist "%DB_PIDFILE%" (
	goto end
)
set /p DB_PID=<"%DB_PIDFILE%"

:checkDBStop
for /f "usebackq tokens=* skip=1" %%i in (`wmic path win32_process where ^(Processid^='!DB_PID!'^) get ExecutablePath 2^>nul`) do (
	set WMIC_OUTPUT=%%i

	if not "!WMIC_OUTPUT:mysqld.exe=!"=="!WMIC_OUTPUT!" (
        IF "%TIME%" == "%STOP_TIMEOUT%" (
            echo "Timed out waiting for database to stop"
            goto end
        )

        echo | set /p dot=.
        TIMEOUT /T 1 /NOBREAK >nul
        set /a "TIME = TIME + 1"
        goto :checkDBStop
	)
)

echo.
echo ***** Controller database stopped *****
echo.

goto end

:controllerDBLogin
echo Logging into the controller database
cd /D "%MYSQL_BIN%"
.\mysql -A -u root -p%MYSQL_ROOT_PASSWD% --port=%DB_PORT% --protocol=TCP controller

goto end

:optimizeControllerDB
REM Analyze and optimize the database (this is important to do after an upgrade
REM or if there are performance issues with the database)
echo Analyzing and optimizing controller database
cd /D "%MYSQL_BIN%"
.\mysqlcheck -u root -p%MYSQL_ROOT_PASSWD% --port=%DB_PORT% --protocol=TCP --analyze controller
.\mysqlcheck -u root -p%MYSQL_ROOT_PASSWD% --port=%DB_PORT% --protocol=TCP --optimize controller
echo Controller database analyzed and optimized
echo.
goto end

:startControllerDB
REM Start the database
REM NOTE: The database startup command must be kept in sync with the
REM App Server MySQL Watchdog
echo Starting controller database on port %DB_PORT%
cd /D "%MYSQL_BIN%"
CALL mysqladmin --user=root -p%MYSQL_ROOT_PASSWD% --port=%DB_PORT% --protocol=TCP status > .status 2>&1

REM Check if controller database is running on port %DB_PORT%
FINDSTR /I /C:"Uptime:" .status >nul 2>&1
IF %ERRORLEVEL% EQU 0 (
	echo ***** Controller database is already running on port %DB_PORT% *****
) else (
	START /B mysqld --defaults-file=%AD_DB_CNF%

	REM Wait up to 2 minutes for the database to start up
	echo | set /p=Waiting for Controller database to start on port %DB_PORT%
	set /a "TIME = 0"
	:checkDBStart
	CALL mysqladmin --user=root -p%MYSQL_ROOT_PASSWD% --port=%DB_PORT% --protocol=TCP status >nul 2>&1
	IF %ERRORLEVEL% NEQ 0 (
		IF "%TIME%" == "%START_TIMEOUT%" (
			echo "Timed out wating for database to start"
			goto end
		) else (
			echo | set /p dot=.
			TIMEOUT /T 1 /NOBREAK >nul
			set /a "TIME = TIME + 1"
			goto :checkDBStart
		)
	) else (
		echo.
		echo ***** Controller database started on port %DB_PORT% *****
		echo.
	)
)

if "%1" == "start" goto startControllerAppServer
if "%1" == "patch-upgrade" goto startPatchUpgrade
if "%1" == "recreate-jms-tables" goto startJSMReset
if "%1" == "reset-ejb-jms-tables" goto startDBReset
goto end

:startControllerAppServer
REM Do not start controller if it is already running.
cd %INSTALL_DIR%\%GF_DIR%\bin
DEL as_status
CALL asadmin.bat list-domains > as_status 2>&1
FINDSTR /I /C:"domain1 running" as_status >nul 2>&1
IF %ERRORLEVEL% EQU 0 (
	echo ***** Controller application server is already running *****
	goto end
)

REM Reset the JMS table lock
cd %INSTALL_DIR%\%APPSERVER_DIR%\mq\bin
.\imqdbmgr -varhome %INSTALL_DIR%\%GF_DIR%\domains\domain1\imq -b imqbroker reset lck

REM Extra step to remove lock file just in case above command did not do it...
if EXIST %INSTALL_DIR%\%GF_DIR%\domains\domain1\imq\instances\imqbroker\lock (
	echo Removing IMQ lock file...
	rm %INSTALL_DIR%\%GF_DIR%\domains\domain1\imq\instances\imqbroker\lock
)

REM Start the application server in mode passes as the second argument
if "%2" equ "active" goto setMode

if "%2" equ "passive" goto setMode

if "%2" equ "" (
	echo Starting controller application server in default mode
	goto startDefault
) else (
	echo Invalid value passed for the command line '%1'
	goto end
)

:setMode
echo Starting controller application server in '%2' mode
cd %INSTALL_DIR%\bin
call ant_bootstrap.bat -f %INSTALL_DIR%\bin\controller_maintenance.xml -Ddb-port=%DB_PORT% set-appserver-mode -Dappserver-mode=%2%

:startDefault
REM echo Starting controller application server
cd %INSTALL_DIR%\%GF_DIR%\bin
call asadmin.bat start-domain domain1 > %INSTALL_DIR%\logs\startAS.log

TIMEOUT /T 10 /NOBREAK
echo Controller application server started
echo.
goto end

:patchUpgrade
echo The controller must be running for the patch upgrade to succeed
goto startControllerDB
:startPatchUpgrade
cd %INSTALL_DIR%\bin
if '%2' == '' (set UPGRADE_ZIP="") else (set UPGRADE_ZIP=%2)
call ant_bootstrap.bat -f %INSTALL_DIR%\bin\controller_maintenance.xml -Ddb-port=%DB_PORT% -Dappserver-admin-port=%APPSERVER_ADMIN_PORT% patch-controller-upgrade -Dupgrade-zip=%UPGRADE_ZIP%
goto end

:startServices
REM We expect that the services are installed before starting them
REM NOTE: The "%SERVICE_NAME_DB%" service name must be kept in sync
REM with the App Server MySQL Watchdog
echo Starting controller services
sc start "%SERVICE_NAME_DB%"

echo Give the database some time to start up
TIMEOUT /T 10 /NOBREAK

cd %INSTALL_DIR%\%APPSERVER_DIR%\mq\bin
.\imqdbmgr -varhome %INSTALL_DIR%\%GF_DIR%\domains\domain1\imq -b imqbroker reset lck

%INSTALL_DIR%\%GF_DIR%\domains\domain1\bin\%SERVICE_NAME_APP%Service.exe start
echo Controller services started
echo.
goto end

:stopServices
REM We expect that the services are installed before stopping them
echo Stopping controller services
%INSTALL_DIR%\%GF_DIR%\domains\domain1\bin\%SERVICE_NAME_APP%Service.exe stop

echo Give the appserver some time to stop
TIMEOUT /T 10 /NOBREAK

sc stop "%SERVICE_NAME_DB%"
echo Controller services stopped
echo.
goto end

:uninstallServices
echo Uninstalling controller database Windows service
sc delete "%SERVICE_NAME_DB%"
echo Controller database Windows service uninstalled
echo.

echo Uninstalling controller app server Windows service
%INSTALL_DIR%\%GF_DIR%\domains\domain1\bin\%SERVICE_NAME_APP%Service.exe uninstall
echo Controller app server Windows service uninstalled
echo.
echo Don't forget to reboot your computer after this service uninstall!
TIMEOUT /T 5 /NOBREAK
goto end

:installServices
echo Installing controller database as a Windows service
cd /D "%MYSQL_BIN%"
.\mysqld --install "%SERVICE_NAME_DB%" --defaults-file=%AD_DB_CNF%
echo Controller database Windows service installed
echo.

echo Installing controller app server as a Windows service
cd %INSTALL_DIR%\%GF_DIR%\bin
call asadmin create-service --name %SERVICE_NAME_APP% --force
REM Set display name in service control manager
sc config %SERVICE_NAME_APP% DisplayName= "AppDynamics Application Server"
sc config %SERVICE_NAME_APP% depend= "%SERVICE_NAME_DB%"
echo Controller app server Windows service installed
echo.
TIMEOUT /T 5 /NOBREAK
goto end

:resetControllerDB
goto startControllerDB
:startDBReset
cd %INSTALL_DIR%\bin
call ant_bootstrap.bat -f %INSTALL_DIR%\bin\controller_maintenance.xml -Ddb-port=%DB_PORT% -Dappserver-admin-port=%APPSERVER_ADMIN_PORT% reset-db-after-restore
goto end

:recreateJMSTables
goto startControllerDB
:startJSMReset
cd %INSTALL_DIR%\bin
call ant_bootstrap.bat -f %INSTALL_DIR%\bin\controller_maintenance.xml -Ddb-port=%DB_PORT% -Dappserver-admin-port=%APPSERVER_ADMIN_PORT% recreate-jms-tables
goto end

:resetApplicationData
cd %INSTALL_DIR%\bin
if '%2' == '' (set APP_TO_RESET="") else (set APP_TO_RESET=%2)
call ant_bootstrap.bat -f %INSTALL_DIR%\bin\controller_maintenance.xml -Ddb-port=%DB_PORT% -Dappserver-admin-port=%APPSERVER_ADMIN_PORT% reset-app-data -Dapp-to-reset=%APP_TO_RESET%
goto end

:enableHttpListeners
cd %INSTALL_DIR%\bin
call ant_bootstrap.bat -f %INSTALL_DIR%\bin\controller_maintenance.xml -Ddb-port=%DB_PORT% -Dappserver-admin-port=%APPSERVER_ADMIN_PORT% enable-http-listeners
goto end

:disableHttpListeners
cd %INSTALL_DIR%\bin
call ant_bootstrap.bat -f %INSTALL_DIR%\bin\controller_maintenance.xml -Ddb-port=%DB_PORT% -Dappserver-admin-port=%APPSERVER_ADMIN_PORT% disable-http-listeners
goto end

:upgradeDatabaseInternals
cd /D "%MYSQL_BIN%"
.\mysql_upgrade -u root -p%MYSQL_ROOT_PASSWD% --port=%DB_PORT% --protocol=TCP
goto end

:zipLogs
cd %INSTALL_DIR%\bin
call ant_bootstrap.bat -f %INSTALL_DIR%\bin\controller_maintenance.xml zip-logs
echo "Created the archive logs.zip"
goto end

:end
REM go back to your directory where you started
cd %CURRENT_DIR%
endlocal
