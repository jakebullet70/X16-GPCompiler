@ECHO OFF
REM Build EDIT and run it in the emulator from the run\ folder.
REM The run\ folder is the host filesystem root the editor sees, and holds
REM sample text files to open/save.
REM
REM Usage:  run.bat [source.p8]    (defaults to edit.p8)

SETLOCAL
SET SRC=%1
IF "%SRC%"=="" SET SRC=edit.p8

REM 1) compile (build.bat writes edit.prg to the project root)
CALL "%~dp0build.bat" %SRC%
IF ERRORLEVEL 1 GOTO :EOF

REM 2) stage the fresh .prg into the run folder
SET RUNDIR=%~dp0run
IF NOT EXIST "%RUNDIR%" MKDIR "%RUNDIR%"
COPY /Y "%~dp0edit.prg" "%RUNDIR%\edit.prg" >NUL

REM 3) launch with the run folder as the host filesystem root, so the emulator
REM    boots straight into edit.prg.
CALL "%~dp0LOCAL.BAT"
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -prg edit.prg -run -rtc -joy1
ENDLOCAL
