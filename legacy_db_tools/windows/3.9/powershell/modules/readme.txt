
    AppDynamics Windows Controller Powershell Modules Oct/2014


Required Powershell version (2.0+)


To run cmdlets from this module you must be running:
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
OR
C:\Windows\System32\WindowsPowerShell\v1.0\powershell_ise.exe
OR
type powershell in a command window
OR
Use the '>_' button from the task bar

NOTE: if powershell.exe is not available
      2008 R2 + it is a 'feature' that can be installed in ServerManager
      2003 it is a separate download (part of the management framework pack)
      
      
Before using this module from Powershell it must be loaded.
The execution policy must be set to 'unrestricted' in order to 
load non-signed third-party script modules.
PS> set-executionpolicy Unrestricted

Next this script module must be imported into the current powershell session.
PS> Import-Module <path to module folder>
-- OR -- Copy this folder into %USERPROFILE%\Documents\WindowsPowerShell\Modules (v3 ?)


Full Example (Powershell 2.0):
>> Start Powershell <<
Windows PowerShell
Copyright (C) 2009 Microsoft Corporation. All rights reserved.


>> Set Execution Policy <<
PS > set-executionpolicy Unrestricted

Execution Policy Change
The execution policy helps protect you from scripts that you do not trust. 
Changing the execution policy might expose you to the security risks described in the about_Execution_Policies help topic. 
Do you want to change the execution
policy?
[Y] Yes  [N] No  [S] Suspend  [?] Help (default is "Y"):


>> Import a module <<
PS > Import-Module ...\modules\<module>

Security Warning
Run only scripts that you trust. 
While scripts from the Internet can be useful, this script can potentially harm your computer. 
Do you want to run ...\modules\<module>\<module>.psm1?
[D] Do not run  [R] Run once  [S] Suspend  [?] Help (default is "D"): r
