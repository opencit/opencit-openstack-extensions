@ECHO off
:: default settings
call :%*
goto :EOF

:apply_patch
	set PATH=%PATH%;C:\cygwin64\bin
	set target_dir=%1
	set patch_file_path=%2
	set strip_num=%3
	echo -------------------------------------------------------------------------
	echo *******************************************************
	echo Going to execute apply_patch function
	echo *******************************************************
	echo Target dir is: %target_dir%
	echo Patch file path is: %patch_file_path%
	echo Strip Num is: %strip_num%
	echo -------------------------------------------------------------------------
	
	set ERRORLEVEL=
	patch --dry-run --silent --strip=%strip_num% -d %target_dir% -i %patch_file_path%
	IF ERRORLEVEL 1 (
		echo Not able to apply patches.
		goto :EOF)
	
	patch --strip=%strip_num% -N -b -V numbered -d %target_dir% -i %patch_file_path%
	if Not %ERRORLEVEL%==0 (
		echo Error while applying patch
	) else ( echo Patch applied successfully)
			
pause
goto :EOF

:revert_patch
	set PATH=%PATH%;C:\cygwin64\bin
	set target_dir=%1
	set patch_file_path=%2
	set strip_num=%3
	echo -------------------------------------------------------------------------
	echo Going to execute revert_patch function
	echo Target dir is: %target_dir%
	echo Patch file path is: %patch_file_path%
	echo Strip Num is: %strip_num%
	echo -------------------------------------------------------------------------
	echo *******************************************************
	echo Patches on following files will be reverted: 
	echo *******************************************************
	
	set ERRORLEVEL=
	
	patch --dry-run --silent --strip=%strip_num% -R -d %target_dir% -i %patch_file_path%
	IF ERRORLEVEL 1 (
		echo Not able to revert patches. 
		goto :EOF )
		
	
	patch --strip=%strip_num% -R -b -V numbered -d %target_dir% -i %patch_file_path%
	IF Not %ERRORLEVEL%==0 (
		echo Error while reverting patch
	)  else ( echo Patch reverted successfully)
		

pause
goto :EOF
	
:openstackrestart
	::Restarting nova services
	echo Restarting nova-compute service
	net stop nova-compute
	net start nova-compute

echo OpenStack Compute Node Extensions Installation complete
goto :EOF

:help
  echo Usage: patch-util-win.cmd FUNC_NAME [ARG1]...[ARGN]
  echo 
  echo This utility provides different utility methods related to patching source code.
  echo Following functions are supported by this utility
  echo 
  echo :help -- Print complete help
  echo apply_patch TARGET_DIR PATCH_FILE STRIP_NUM --- Apply patches on the files in given directory
  echo revert_patch TARGET_DIR PATCH_FILE STRIP_NUM --- Revert patches on the files in given directory
  
goto :EOF

if [ %1 == "help" ] (
		call :help
	)

pause

