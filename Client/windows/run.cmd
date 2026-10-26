@echo off
rem LanScreen for Windows 7: checks the three things it needs, then starts.
rem Anything after run.cmd is passed on, e.g.  run.cmd -windowed
setlocal
cd /d "%~dp0"

if not exist "%SystemRoot%\System32\ucrtbase.dll" (
    echo LanScreen needs the Universal C Runtime, which this copy of Windows 7
    echo does not have yet. Windows Update installs it as KB2999226 or KB3118401,
    echo or install the Visual C++ 2015-2022 x64 redistributable from Microsoft.
    echo See README.txt.
    pause
    exit /b 1
)

ipconfig | find "10.0.0.2" >nul
if errorlevel 1 (
    echo This PC does not have the address 10.0.0.2, which is where the Mac
    echo sends the picture. Set the Ethernet adapter on the cable to 10.0.0.2,
    echo mask 255.255.255.0 - see README.txt. Starting anyway.
    timeout /t 5 >nul
)

rem Without this rule Windows Firewall asks whether to let the picture in, and
rem asks behind the fullscreen picture, where nobody can see the question.
netsh advfirewall firewall show rule name="LanScreen video" >nul 2>&1
if errorlevel 1 (
    echo.
    echo Windows Firewall has to let the picture in. Windows will ask for
    echo permission to add one rule: UDP port 5000, from 10.0.0.1 only, for
    echo lanscreen.exe only.
    powershell -NoProfile -Command "Start-Process netsh -Verb RunAs -Wait -ArgumentList 'advfirewall firewall add rule name=\"LanScreen video\" dir=in action=allow protocol=UDP localport=5000 remoteip=10.0.0.1 program=\"%~dp0lanscreen.exe\" profile=any'"
    netsh advfirewall firewall show rule name="LanScreen video" >nul 2>&1
    if errorlevel 1 (
        echo The rule was not added, so the picture may be blocked.
        pause
    )
)

start "" "%~dp0lanscreen.exe" %*
