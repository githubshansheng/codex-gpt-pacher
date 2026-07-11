@echo off
setlocal
pushd "%~dp0" >nul || exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File ".\patch-windows.ps1" %*
set EXIT_CODE=%errorlevel%
popd >nul
echo.
if not %EXIT_CODE%==0 echo Patch failed with exit code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
