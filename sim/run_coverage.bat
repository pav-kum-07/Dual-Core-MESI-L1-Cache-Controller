@echo off
REM ============================================================================
REM Script: run_coverage.bat
REM Description: Compile RTL and Testbench, run simulation with Code Coverage
REM              and Functional Coverage collection, and generate HTML reports.
REM ============================================================================

set VIVADO_BIN=C:\Xilinx\Vivado\2024.1\bin
set RTL_DIR=..\rtl
set TB_DIR=..\tb
set COV_DIR=.\cov
set REPORT_DIR=.\coverage_report

echo [1/4] Compiling RTL and Testbench with SystemVerilog...
call "%VIVADO_BIN%\xvlog.bat" -sv -i "%RTL_DIR%" "%RTL_DIR%\cache_def.sv" "%RTL_DIR%\cache_tag_array.sv" "%RTL_DIR%\cache_data_array.sv" "%RTL_DIR%\lru_array.sv" "%RTL_DIR%\cache_controller.sv" "%RTL_DIR%\bus_arbiter.sv" "%RTL_DIR%\dual_core_cache_subsystem.sv" "%TB_DIR%\mem_slave_model.sv" "%TB_DIR%\tb_dual_core_cache.sv"
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Compilation failed!
    exit /b %ERRORLEVEL%
)

echo [2/4] Elaborating Design with Code & Functional Coverage instrumentation...
call "%VIVADO_BIN%\xelab.bat" -timescale 1ns/1ps -top tb_dual_core_cache -snapshot tb_dual_core_cache_sim -debug typical -cc_type sbct -cov_db_dir "%COV_DIR%" -cov_db_name cache_cov
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Elaboration failed!
    exit /b %ERRORLEVEL%
)

echo [3/4] Running Simulation to collect coverage...
call "%VIVADO_BIN%\xsim.bat" tb_dual_core_cache_sim -R -cov_db_dir "%COV_DIR%" -cov_db_name cache_cov
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Simulation execution failed!
    exit /b %ERRORLEVEL%
)

echo [4/4] Generating HTML Coverage Reports with XCRG...
call "%VIVADO_BIN%\xcrg.bat" -cov_db_dir "%COV_DIR%" -cov_db_name cache_cov -report_dir "%REPORT_DIR%" -report_format all

echo.
echo ============================================================================
echo   COVERAGE REPORTS GENERATED:
echo   - Code Coverage Report:       %REPORT_DIR%\codeCoverageReport\index.html
echo   - Functional Coverage Report: %REPORT_DIR%\functionalCoverageReport\dashboard.html
echo ============================================================================
pause
