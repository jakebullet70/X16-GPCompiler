@ECHO OFF
REM Launch the C64 Blitz! compiler test environment in VICE (x64sc).
REM
REM   drive 8 : utils.d64  ->  DIR + C64 demos (HELLO, SQUARES, LOGIC, STRINGS; INTMATH is
REM             X16-only -- it uses FOR I%= which stock C64 BASIC rejects). Filenames are
REM             stored lower-case so they render correctly on the C64's upper-case charset.
REM             The TURBO V5 cart wedge owns the boot, so NOTHING auto-runs. At the READY
REM             prompt, type:
REM               $                 -> list this disk (readable now)
REM               LOAD"DIR",8:RUN   -> run the directory lister
REM               LOAD"HELLO",8:RUN -> run a demo
REM             Blitz also reads sources / writes output on this disk.
REM   drive 9 : the Blitz! compiler disk  ->  LOAD "BLITZ",9 : RUN   (start the compiler)
REM   cart    : SnappyROM -- an open Super Snapshot V5 freezer/utility ROM
REM             (github.com/adrianglz64/snappyrom), attached if present.
REM
REM All C64 assets live in demo-c64\ . demo-c64\snappyrom.crt is the PAL build (matches x64sc's
REM default PAL model); demo-c64\snappyrom-ntsc.crt is the NTSC build -- to use it, add -ntsc to
REM the launch line and point CART at it. See demo-c64\snappyrom-readme.txt for cart usage.
REM (demo-c64\work.d64 is a spare blank disk -- swap it onto -8 if you want an empty working disk.)
REM
REM Usage:  run64.bat

SETLOCAL
CALL "%~dp0LOCAL.BAT"

SET "C64=%~dp0demo-c64"
SET "BLITZ=%C64%\blitz_compiler.d64"
SET "UTILS=%C64%\utils.d64"
SET "CART=%C64%\snappyrom.crt"

IF EXIST "%CART%" (
    START "" "%x64%" -cartcrt "%CART%" -8 "%UTILS%" -drive9type 1541 -9 "%BLITZ%"
) ELSE (
    ECHO [run64] SnappyROM cart not found at "%CART%" -- booting without it.
    START "" "%x64%" -8 "%UTILS%" -drive9type 1541 -9 "%BLITZ%"
)
ENDLOCAL
