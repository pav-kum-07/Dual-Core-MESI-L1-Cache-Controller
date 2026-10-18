@echo off
REM ============================================================================
REM Script: run_non_uvm_sim.bat
REM Description: Compile and run the non-UVM Dual-Core Cache Testbench with Vivado XSIM
REM ============================================================================

set VIVADO_BIN=C:\Xilinx\Vivado\2024.1\bin
set RTL_DIR=..\rtl
set TB_DIR=..\tb

echo [1/3] Compiling RTL and Non-UVM Testbench...
call "%VIVADO_BIN%\xvlog.bat" -sv -i "%RTL_DIR%" "%RTL_DIR%\cache_def.sv" "%RTL_DIR%\cache_tag_array.sv" "%RTL_DIR%\cache_data_array.sv" "%RTL_DIR%\lru_array.sv" "%RTL_DIR%\cache_controller.sv" "%RTL_DIR%\bus_arbiter.sv" "%RTL_DIR%\dual_core_cache_subsystem.sv" "%TB_DIR%\mem_slave_model.sv" "%TB_DIR%\tb_dual_core_cache.sv"
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Compilation failed!
    exit /b %ERRORLEVEL%
)

echo [2/3] Elaborating Design Snapshot...
call "%VIVADO_BIN%\xelab.bat" -timescale 1ns/1ps -top tb_dual_core_cache -snapshot tb_dual_core_cache_sim -debug typical
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Elaboration failed!
    exit /b %ERRORLEVEL%
)

echo [3/3] Running Simulation...
call "%VIVADO_BIN%\xsim.bat" tb_dual_core_cache_sim -R
pause
