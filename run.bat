@ECHO OFF
REM Launch the GPC on-device demo in the Commander X16 emulator.
REM
REM   demo\ is used as the HostFS root (the disk the emulated X16 sees), and the
REM   interactive compiler demo\gpc.prg boots straight up. At its prompts:
REM       compile file:  SQUARES      (any sample name -- see demo\README)
REM       write to:                   (press RETURN to auto-name c.SQUARES)
REM   then back at READY:  LOAD "C.SQUARES",8 : RUN
REM
REM   Tip: LOAD "DIR.PRG",8 : RUN  lists the files on disk.
REM
REM Usage:  run.bat              boot the compiler (default)
REM         run.bat C.HELLO      boot straight into a pre-compiled standalone (then RUN)
REM         run.bat SQUARES      boot with a different .prg loaded
REM
REM   Int-optional (noint) build -- % vars/literals degrade to float, output is SMALLER:
REM         run.bat GPC.NOINT.PRG    boot the int-optional compiler (prompts like gpc.prg)
REM         run.bat C.INTMATH        run the native-integer INTMATH standalone
REM         run.bat C.INTMATH.NI     run the int-optional INTMATH standalone
REM     LOAD "DIR.PRG",8 : RUN  and compare the block counts of C.INTMATH vs C.INTMATH.NI.

SETLOCAL
CALL "%~dp0LOCAL.BAT"

SET "DEMO=%~dp0demo"
SET "PRG=%~1"
IF "%PRG%"=="" SET "PRG=gpc.prg"

START "" "%x16%" -fsroot "%DEMO%" -prg "%DEMO%\%PRG%" -run -rtc
ENDLOCAL
