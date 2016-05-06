@ECHO OFF
::#######################################################################################################################
:::
::: NAME
:::      rman-backup.bat - RMAN backup script
:::
::: SYNOPSIS
:::      rman-backup.bat [OPTIONS] ORACLE_SID BACKUP_TYPE
::+ USAGE
::+      rman-backup.bat [-h] [-d] [-D] [-n] [-i {0|D|C}] ORACLE_SID { ALL| ARCHIVELOG | DATABASE | DATAFILECOPY | CUSTOM { cmdfile } }
:::
::: DESCRIPTION
:::      ORACLE_SID              SID of the instance to be backed up
:::      BACKUP_TYPE             Type of backup. Valid values are
:::                                      ALL              - Backup database, current controlfile, and archivelogs
:::                                      ARCHIVELOG       - Backup archivelogs only
:::                                      DATABASE         - Backup database only
:::					 DATAFILECOPY	  - Backup using datafilecopy method
:::                                      CUSTOM {cmdfile} - Use a custom cmdfile
:::
::: OPTIONS
:::	 -a			 Backup archivelogs. Only valid when specifying DATAFILECOPY as the BACKUP_TYPE.
:::      -d                      Delete all archivelogs after they have been backed up
:::      -D                      Delete obsolete backups
:::      -h                      Show help
:::      -i { 0 | C | D }        Speficy an incremental backup. Valid values are
:::                                      0 - Incremental level 0
:::                                      C - Incremental level 1 cummulative
:::                                      D - Incremental level 1 diferential
::-      -l string               Log directory
:::      -n                      Backup only archivelogs that have not been backed up.
:::	 -w number		 Retention window for datafilecopy backups in days
:::
:: REVISION HISTORY
:: DATE          NAME                    CHANGES
:: ------------  ----------------------- ------------------------------------------------------
:: 2008-10-8     steven			 Initial Release
::#######################################################################################################################
:: EXAMPLE SCHEDULED TASK
:: schtasks /create /sc daily /st 01:00:00 /tn "RMAN Backup" /ru "System" /tr C:\oracle\scripts\rman-backup.bat -n ORADB ALL


SETLOCAL ENABLEEXTENSIONS
for /F "tokens=2-7 delims=/:. " %%i in ('echo %DATE% %TIME%') do set timestamp=%%k-%%i-%%j.%%l%%m%%n
set BASE=%~d0%~p0
set NAME=%~n0

:GETOPTS
echo %1 | findstr /B /C:- > NUL
IF %ERRORLEVEL% EQU 0 (
    IF "%1"=="-d" (
        set DELETE_INPUT=DELETE ALL INPUT
    )
    IF "%1"=="-D" (
        set DELETE_OBSOLETE=DELETE NOPROMPT OBSOLETE
    )
    IF "%1"=="-n" (
	set NOT_BACKED_UP=NOT BACKED UP
    )
    IF "%1"=="-i" (
	IF "%2"=="0" set INCREMENTAL_LEVEL=INCREMENTAL LEVEL 0
	IF "%2"=="D" set INCREMENTAL_LEVEL=INCREMENTAL LEVEL 1
	IF "%2"=="C" set INCREMENTAL_LEVEL=INCREMENTAL LEVEL 1 CUMULATIVE
	SHIFT
    )
    IF "%1"=="-a" (
	set PLUS_ARCHIVELOG=PLUS ARCHIVELOG
    )
    IF "%1"=="-w" (
	set DATAFILECOPY_RETENTION_WINDOW=UNTIL TIME 'SYSDATE - %2%'
	SHIFT
    )
    IF "%1"=="-h" (
	CALL :SHOWHELP EXTENDED
	EXIT /B 0
    )
    SHIFT
    GOTO GETOPTS
)
IF NOT "%PLUS_ARCHIVELOG%"=="" set PLUS_ARCHIVELOG=%PLUS_ARCHIVELOG% %NOT_BACKED_UP% %DELETE_INPUT%

SET ORACLE_SID=%1
SET BACKUP_TYPE=%2
SET COMMAND_FILE=%3
SET TARGET_CONNECT_STR=/

IF "%ORACLE_SID%"==""  echo error: ORACLE_SID is not specified. use -h for help && EXIT /B 1
IF "%BACKUP_TYPE%"=="" echo error: BACKUP_TYPE is not specified. use -h for help && EXIT /B 1

CALL :toUpper BACKUP_TYPE
SET RMANTMP=%TEMP%\RMAN_%ORACLE_SID%.cmd
IF "%BACKUP_TYPE%" == "ALL"		set RMAN_CMD=BACKUP %INCREMENTAL_LEVEL% DATABASE INCLUDE CURRENT CONTROLFILE PLUS ARCHIVELOG %NOT_BACKED_UP% %DELETE_INPUT%
IF "%BACKUP_TYPE%" == "ARCHIVELOG"	set RMAN_CMD=BACKUP ARCHIVELOG ALL %NOT_BACKED_UP% %DELETE_INPUT%
IF "%BACKUP_TYPE%" == "DATABASE"	set RMAN_CMD=BACKUP %INCREMENTAL_LEVEL% DATABASE INCLUDE CURRENT CONTROLFILE
IF "%BACKUP_TYPE%" == "CUSTOM" (
	IF NOT EXIST %~3 echo error: custom RMAN command file %~3 does not exist && EXIT /B 1
	SET RMAN_COMMAND_FILE=%~3
	SET RMAN_CMD=CUSTOM
) ELSE IF "%BACKUP_TYPE%"=="DATAFILECOPY" (
	set RMAN_CMD=DATAFILECOPY
	(
		ECHO run {
		ECHO RECOVER COPY OF DATABASE WITH TAG 'IMAGECOPY' %DATAFILECOPY_RETENTION_WINDOW%; 
		ECHO BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG 'IMAGECOPY' DATABASE INCLUDE CURRENT CONTROLFILE %PLUS_ARCHIVELOG%;
		IF NOT "%DELETE_OBSOLETE%" == "" (
			ECHO %DELETE_OBSOLETE%;
		)
		ECHO }
	) > %RMANTMP%
	SET RMAN_COMMAND_FILE=%RMANTMP%
) ELSE (
	(
		ECHO run {
		ECHO %RMAN_CMD%;
		IF NOT "%DELETE_OBSOLETE%" == "" (
			ECHO %DELETE_OBSOLETE%;
		)
		ECHO }
	) > %RMANTMP%
	SET RMAN_COMMAND_FILE=%RMANTMP%
)
IF "%RMAN_CMD%"=="" echo error: Invalid BACKUP_TYPE && CALL :SHOWHELP BASIC && EXIT /B 1


SET LOG_DIR=%BASE%%NAME%
SET LOG_FILE="%LOG_DIR%\%NAME%_%ORACLE_SID%_%BACKUP_TYPE%_%timestamp%.log"


:: MAIN
IF NOT EXIST %LOG_DIR% md %LOG_DIR% 					|| CALL :ERR && EXIT /B 1
CALL :GETORACLEHOME %ORACLE_SID% ORACLE_HOME				|| CALL :ERR && EXIT /B 1
CALL :LOG "BODY" "Started on %DATE% %TIME%"
CALL :LOG "HEAD" "Running Pre-Backup Checks"
REM CALL :PRECHECK 								|| CALL :ERR && EXIT /B 1
CALL :LOG "HEAD" "Running Backup"
CALL :RUNRMANBACKUP %RMAN_COMMAND_FILE%					|| CALL :ERR && EXIT /B 1
CALL :LOG "BODY" "Finished on %DATE% %TIME%"

EXIT /B 0

::=================================================================================================
::FUNCTIONS
::=================================================================================================
::
::-------------------------------------------------------------------------------------------------
:SHOWHELP	-- Shows help
::		-- %~1: SHORT or EXTENDED version
::
::-------------------------------------------------------------------------------------------------
SETLOCAL

IF "%~1" == "BASIC"    FINDSTR /B /C:"::+" %BASE%%NAME%.bat
IF "%~1" == "EXTENDED" FINDSTR /B /C:":::" %BASE%%NAME%.bat

(ENDLOCAL & REM -- RETURN VALUES
)
GOTO :EOF

::-------------------------------------------------------------------------------------------------
:GETORACLEHOME	-- Get's the ORACLE_HOME for a given SID
::		-- %~1: SID
::		-- %~2: return variable via reference
::
::-------------------------------------------------------------------------------------------------
SETLOCAL

SET OSID=%~1
SET TMPFILE=%TEMP%\RMAN_%ORACLE_SID%.tmp

SC QC ORACLESERVICE%OSID% | FINDSTR BINARY_PATH_NAME > %TMPFILE%
IF %ERRORLEVEL% NEQ 0 (
	CALL :LOG "BODY" "error: unable to get ORACLE_HOME for SID %OSID%. Check to see if serivce OracleService%OSID% exists
	DEL %TMPFILE%
	EXIT /B 1
)

set /P OHOME=<%TMPFILE%
set OHOME=%OHOME:\bin\ORACLE.EXE= :%

FOR /F "tokens=2-3 delims=: " %%i in ('echo %OHOME%') do set OHOME=%%i:%%j

(ENDLOCAL & REM -- RETURN VALUES
	IF "%~2" NEQ "" SET %~2=%OHOME%
	DEL %TMPFILE%
)
GOTO :EOF


::-------------------------------------------------------------------------------------------------
:RUNRMANBACKUP	-- Run's an RMAN backup
::		-- %~1: RMAN Command File
::
::
::-------------------------------------------------------------------------------------------------
SETLOCAL

set RMANCMD=%~1
set RMANLOG=%TEMP%\RMAN_%ORACLE_SID%.log
set RMANERR=%TEMP%\RMAN_%ORACLE_SID%.err
set RMANEXE=%ORACLE_HOME%\bin\rman.exe

CALL :LOG "FILE" "%RMANCMD%"

REM EXIT /B 0

%RMANEXE% target %TARGET_CONNECT_STR% log %RMANLOG% cmdfile %RMANCMD%

FINDSTR /B [OR][RM]A[-N][-0-9] %RMANLOG% > %RMANERR%
IF %ERRORLEVEL% EQU 0 (
	CALL :LOG "FILE" "%RMANERR%"
	DEL %RMANLOG% %RMANERR% 
	EXIT /B 1
) ELSE (
	CALL :LOG "FILE" "%RMANLOG%"
)

(ENDLOCAL & REM -- RETURN VALUES
	DEL %RMANLOG% %RMANERR% 
)
GOTO :EOF



::-------------------------------------------------------------------------------------------------
:PRECHECK	-- Check for various things
::		-- Nothing gets passed in/out
::
::
::-------------------------------------------------------------------------------------------------
SETLOCAL

CALL :RUNSQL "%TARGET_CONNECT_STR% as sysdba" "PROMT;" TMPVAR || CALL :LOG "BODY" "%ORACLE_SID% Connectivity	: FAIL" && EXIT /B 1
CALL :LOG "BODY" "%ORACLE_SID% Connectivity	: OK"

CALL :RUNSQL "%TARGET_CONNECT_STR% as sysdba" "select open_mode from v$database;" TMPVAR || EXIT /B 1
CALL :LOG "BODY" "%ORACLE_SID% Open Mode	: %TMPVAR%"

CALL :RUNSQL "%TARGET_CONNECT_STR% as sysdba" "select log_mode from v$database;" TMPVAR || EXIT /B 1
CALL :LOG "BODY" "%ORACLE_SID% LogMode		: %TMPVAR%"

(ENDLOCAL & REM -- RETURN VALUES
)
GOTO :EOF


::-------------------------------------------------------------------------------------------------
:RUNSQL		-- Runs sqlplus query
::		-- %~1: connect string
::		-- %~2: the sql
::		-- %~3: return variable via reference
::-------------------------------------------------------------------------------------------------
SETLOCAL

set CONNECT_STRING=%~1
set "SQL_QUERY=%~2"
set "SQL_QUERY=%SQL_QUERY:^^=^%"
set SQL_RUN_FILE=%TEMP%\runsql.sql
set SQL_OUT_FILE=%TEMP%\runsql.out
set SQL_ERR_FILE=%TEMP%\runsql.err

( 
  echo set lin 200 pages 0 head off feed off
  echo WHENEVER OSERROR  EXIT 1
  echo WHENEVER SQLERROR EXIT 1
) > %SQL_RUN_FILE%
echo %SQL_QUERY% >> %SQL_RUN_FILE%

TYPE %SQL_RUN_FILE% | %ORACLE_HOME%\bin\sqlplus -s "%CONNECT_STRING%" > %SQL_OUT_FILE%
IF %ERRORLEVEL% NEQ 0 (
	FINDSTR /B ORA- %SQL_OUT_FILE% > %SQL_ERR_FILE%
	CALL :LOG "FILE" %SQL_ERR_FILE%
 	DEL %SQL_TEMP_FILE% %SQL_OUT_FILE% %SQL_ERR_FILE%
	ENDLOCAL
	EXIT /B 1
)

IF "%~3" NEQ "" (
	set /P SQL_RESULT=<%SQL_OUT_FILE%
) ELSE (
	CALL :LOG "FILE" "%SQL_OUT_FILE%"
)

(ENDLOCAL & REM -- RETURN VALUES
    IF "%~3" NEQ "" SET %~3=%SQL_RESULT%
    DEL %SQL_RUN_FILE% %SQL_OUT_FILE% %SQL_ERR_FILE%
)
GOTO :EOF


::-------------------------------------------------------------------------------------------------
:LOG		-- Writes a log
::		-- %~1: type {HEAD | BODY | FILE}
::		-- %~2: the text or file
::-------------------------------------------------------------------------------------------------
SETLOCAL

IF %~1 == HEAD (
	echo.
	echo. >> %LOG_FILE%
	echo.
	echo. >> %LOG_FILE%
	echo %~2
	echo %~2 >> %LOG_FILE%
	echo ============================================================
	echo ============================================================ >> %LOG_FILE%
) ELSE (
	IF %~1 == BODY (
		echo %~2
		echo %~2 >> %LOG_FILE%
	) ELSE (
		IF %~1 == FILE (
			TYPE %~2
			TYPE %~2 >> %LOG_FILE%
		)
	)
)

(ENDLOCAL & REM -- RETURN VALUES
	EXIT /B 0
)
GOTO :EOF


::-------------------------------------------------------------------------------------------------
:ERR		-- for errors
::		--
::		--
::-------------------------------------------------------------------------------------------------
SETLOCAL

CALL :LOG "BODY" "Encountered an error. Aborting."
REM cleanup
del %RMANTMP%


REM send an email with %LOG_FILE%.

(ENDLOCAL & REM -- RETURN VALUES
    EXIT /B 0
)
GOTO :EOF

::-------------------------------------------------------------------------------------------------
:toUpper str -- converts lowercase character to uppercase
::           -- str [in,out] - valref of string variable to be converted
:$created 20060101 :$changed 20080219 :$categories StringManipulation
:$source http://www.dostips.com
::-------------------------------------------------------------------------------------------------
if not defined %~1 EXIT /b
for %%a in ("a=A" "b=B" "c=C" "d=D" "e=E" "f=F" "g=G" "h=H" "i=I"
            "j=J" "k=K" "l=L" "m=M" "n=N" "o=O" "p=P" "q=Q" "r=R"
            "s=S" "t=T" "u=U" "v=V" "w=W" "x=X" "y=Y" "z=Z" "ä=Ä"
            "ö=Ö" "ü=Ü") do (
    call set %~1=%%%~1:%%~a%%
)
EXIT /b
