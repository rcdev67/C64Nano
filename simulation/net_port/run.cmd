@echo off
rem ---------------------------------------------------------------------------
rem Simulate src\misc\net_port.v with the external UART, TX looped back to RX:
rem what the companion writes to its port 1 has to come back unchanged and in
rem order, at the three bit rates the companion uses.
rem
rem Needs iverilog and vvp on PATH: open a prompt through the oss-cad-suite's
rem environment.bat first. Writes into src\impl\sim, next to the other build
rem output.
rem ---------------------------------------------------------------------------

setlocal
where iverilog >nul 2>nul || ( echo iverilog is not on PATH - run the oss-cad-suite environment.bat first & exit /b 1 )

set HERE=%~dp0
set SRC=%HERE%..\..\src
set RUN=%SRC%\impl\sim
if not exist "%RUN%" mkdir "%RUN%"
pushd "%RUN%"

set RC=0
for %%R in (460800 38400 19200) do (
  echo bit rate %%R:
  iverilog -g2012 -DRATE=24'd%%R -o net_port.vvp "%HERE%tb_net_port.v" "%SRC%\misc\net_port.v" "%SRC%\uart6551\io_fifo.v" "%SRC%\misc\uart_ext.v" || set RC=1
  vvp -n net_port.vvp | findstr /v "finish" || set RC=1
)

popd
exit /b %RC%
