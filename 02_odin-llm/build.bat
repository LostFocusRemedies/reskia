@echo off
rem Build Reskia (odin). Run from this directory.
odin build src -out:reskia.exe -o:speed || exit /b 1

rem vendor:lua/5.4 links against lua54.dll on Windows; copy it next to the exe.
for /f "delims=" %%i in ('odin root') do set ODIN_ROOT=%%i
copy /y "%ODIN_ROOT%\vendor\lua\5.4\windows\lua54.dll" . >nul

echo Built reskia.exe
