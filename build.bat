@ECHO OFF
REM Build an EDIT Prog8 source (in SRC\) to a .prg for the Commander X16.
REM Usage:  build.bat <source.p8>      (defaults to edit.p8 if omitted)
REM         The source name is resolved inside the SRC\ directory.
REM         The .prg is written to the project root (-out .).
REM Needs:  java (JRE) and the 64tass assembler. Paths set below.
REM
REM After a successful compile it prints a memory-stats block: the program image
REM (code+data), variable (BSS) and slab sizes, the main-RAM high-water address and
REM how much low RAM is free below the I/O area at $9F00, plus the .prg size on disk.
REM Banked HIRAM ($A000+) is NOT counted - that is used dynamically by the document
REM arena and grows as the text document does.

SETLOCAL
SET JAVABIN=C:\dev\b4x\java19\bin
SET TASSBIN=C:\8bitProgramming\64tass-1.60
SET "PATH=%JAVABIN%;%TASSBIN%;%PATH%"

SET SRCDIR=%~dp0SRC
SET SRC=%1
IF "%SRC%"=="" SET SRC=edit.p8
REM the .prg is named after the source (edit.p8 -> edit.prg), written to the root
FOR %%F IN ("%SRC%") DO SET PRGFILE=%~dp0%%~nF.prg

SET BUILDLOG=%TEMP%\edit_build.txt
java -jar "%~dp0prog8c.jar" -target cx16 -out "%~dp0." "%SRCDIR%\%SRC%" > "%BUILDLOG%" 2>&1
SET ERR=%ERRORLEVEL%
TYPE "%BUILDLOG%"
IF NOT "%ERR%"=="0" ( ENDLOCAL & EXIT /B %ERR% )

REM --- memory-stats block parsed from the segment map ---
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memstats.ps1" -Log "%BUILDLOG%" -Prg "%PRGFILE%"

ENDLOCAL & EXIT /B 0
