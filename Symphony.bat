@echo off
setlocal
rem Tells SymphonyApp to terminate MATLAB when the app window is closed.
set SYMPHONY_STANDALONE=1

rem Lingering MATLAB processes hold the filter-wheel COM port, the MultiClamp
rem telegraph link and the DAQ; warn before stacking another one on top.
set N=0
for /f %%c in ('tasklist /FI "IMAGENAME eq MATLAB.exe" ^| find /C /I "MATLAB.exe"') do set N=%%c
if %N% GTR 0 (
    echo.
    echo %N% MATLAB process^(es^) already running. They may hold COM10 ^(filter wheel^) or the DAQ.
    echo.
    choice /C KCA /M "K = kill them and launch Symphony, C = continue anyway, A = abort"
    if errorlevel 3 exit /b
    if errorlevel 2 goto launch
    taskkill /IM MATLAB.exe /F >nul 2>&1
    timeout /t 3 /nobreak >nul
)

:launch
start "" "C:\Program Files\MATLAB\R2024b\bin\matlab.exe" -nosplash -r "SymphonyApp"
endlocal
