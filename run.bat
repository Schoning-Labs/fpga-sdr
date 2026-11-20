@echo off
rem SPDX-License-Identifier: Apache-2.0
rem Copyright 2026 Franz Schöning, https://www.schoning.com
rem
rem Starts the radio: loads it into the Tang Mega 138K Pro board (into the SRAM only, nothing is written to the flash),
rem then opens the mouse and keyboard window for the radio's HDMI screen. Run it again after every power-off of the board.
rem
rem   run.bat            load the radio and open the input window
rem   run.bat noinput    load the radio only
rem
rem The loading itself is done by tools\radio_start.py, which needs a board loader tool (board.py with its board.json) that is
rem not part of this repository. Set the environment variable RADIO_BOARD_TOOL to its folder, RADIO_NETBOOT to the network boot
rem image and RADIO_BOARD_LOCK to the lock file path; none has a default. It also needs the built radio, that is sdr_top.fs
rem and ft8fw.img in the folder named by RADIO_KEEP (the default is the author's build folder). The PC also needs Python 3.10
rem or newer with the py launcher and the pyserial module, which this script checks for first.
rem
rem Before it: board powered, debug USB-C cable and HDMI monitor connected, the RJ45 cable in the home network,
rem the Hermes-Lite 2 on at the SFP0 module. The whole procedure is in docs\USER_MANUAL.md
setlocal
rem Work from the folder of this file, so that tools\radio_start.py is found wherever the script is started from.
cd /d "%~dp0"

rem Stop with a clear message when the Python launcher or pyserial is missing, since radio_start.py cannot run without them.
where py >nul 2>&1
if errorlevel 1 (
    echo Python launcher "py" not found. Install Python 3.10 or newer.
    goto :fail
)
py -c "import serial" >nul 2>&1
if errorlevel 1 (
    echo The Python module pyserial is missing: py -m pip install pyserial
    goto :fail
)

rem UTF-8 output, so that the messages of radio_start.py print the same in a console with another code page.
set PYTHONIOENCODING=utf-8
rem With the argument noinput only the radio is loaded, otherwise radio_start.py also opens tools\radio_input.py for the mouse and keyboard.
if /i "%~1"=="noinput" (
    py tools\radio_start.py
) else (
    py tools\radio_start.py --input
)
if errorlevel 1 goto :fail
exit /b 0

rem Common exit for every failure. Nothing has been written to the flash at this point, because radio_start.py only loads the SRAM.
:fail
echo.
echo The radio did not start. Read the message above. Nothing was written to the board's flash.
pause
exit /b 1
