controller_dbtool.sh
====================
- Has function library, dbfunctions.sh, that needs including before using. Make runnable script (_e.sh extn) with: make

Restore workflow is roughly:
1) stop all AppD processes, especially MySQL and verify that no MySQL is running 
2) mv db/data to db/data.broken1 (or equiv on Windows)
3) download pre-prepared vanilla install db/data from URL (change URL to linux or windows and try exact version you need): 
https://appdynamics-cs-support-system.s3-us-west-1.amazonaws.com/db/linux/data-20.3.5.zip
https://s3-us-west-1.amazonaws.com/appdynamics-cs-support-system/db/windows/data-4.1.6.0.zip
# note the dummy password used for the prepared MySQL datadir is: autoinstall
4) If the exact version you need has not been pre-prepared then download installer of exactly the same version as your broken controller, install somewhere temporary, stop all AppD processes and finally ZIP up and copy the created db/data directory
5) cd db; unzip /tmp/data-20.3.5.zip
6) change the dummy autoinstall MySQL root password to your local desired value using Docs: https://docs.appdynamics.com/display/PRO45/User+Management under the section: To change the Controller database root user password:
7) verify that the database can be reliably started/stopped using bin/controller.sh on Linux or Services facility under Windows
8) restore earlier backup (metadata or full)
9) start Controller Appserver
