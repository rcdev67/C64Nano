@echo off
rem ---------------------------------------------------------------------------
rem Simulate src\misc\drive_sound.v and check it against its model.
rem
rem Needs iverilog and vvp on PATH: open a prompt through the oss-cad-suite's
rem environment.bat first. Writes into src\impl\sim, next to the other build
rem output, because drive_sound.v names its sample files relative to a build
rem directory two levels below src -- which is where synthesis runs as well.
rem
rem Ends with drive_sound.wav in src\impl\sim: what the board has to sound like.
rem ---------------------------------------------------------------------------

setlocal
where iverilog >nul 2>nul || ( echo iverilog is not on PATH - run the oss-cad-suite environment.bat first & exit /b 1 )

set HERE=%~dp0
set RUN=%HERE%..\..\src\impl\sim
if not exist "%RUN%" mkdir "%RUN%"
pushd "%RUN%"

iverilog -g2012 -o tb.vvp "%HERE%tb_drive_sound.v" ..\..\misc\drive_sound.v || ( popd & exit /b 1 )
vvp -n tb.vvp >nul || ( popd & exit /b 1 )
py -3 "%HERE%check.py" tb_out.txt
set RC=%ERRORLEVEL%

popd
exit /b %RC%
