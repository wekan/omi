@echo off
setlocal

set ROOT_DIR=%~dp0
set BUILD_DIR=%ROOT_DIR%build
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

echo Build targets:
echo  1) All (Haxe + C89 + C#)
echo  2) Haxe: cpp
echo  3) Haxe: js
echo  4) Haxe: python
echo  5) Haxe: php
echo  6) Haxe: cs
echo  7) Haxe: java
echo  8) C89 (native)
echo  9) C# / Mono
echo  0) Quit
set /p CHOICE=Select target: 

if "%CHOICE%"=="1" goto :all
if "%CHOICE%"=="2" goto :haxe_cpp
if "%CHOICE%"=="3" goto :haxe_js
if "%CHOICE%"=="4" goto :haxe_python
if "%CHOICE%"=="5" goto :haxe_php
if "%CHOICE%"=="6" goto :haxe_cs
if "%CHOICE%"=="7" goto :haxe_java
if "%CHOICE%"=="8" goto :c89
if "%CHOICE%"=="9" goto :csharp
if "%CHOICE%"=="0" goto :eof

echo Unknown choice
goto :eof

:all
call :haxe_cpp
call :haxe_js
call :haxe_python
call :haxe_php
call :haxe_cs
call :haxe_java
call :c89
call :csharp
goto :done

:haxe_cpp
if not exist "%BUILD_DIR%\cpp" mkdir "%BUILD_DIR%\cpp"
where haxe >nul 2>nul || (echo Haxe not found & goto :eof)
haxe -cp "%ROOT_DIR%" -main Omi -cpp "%BUILD_DIR%\cpp"
goto :eof

:haxe_js
if not exist "%BUILD_DIR%\js" mkdir "%BUILD_DIR%\js"
where haxe >nul 2>nul || (echo Haxe not found & goto :eof)
haxe -cp "%ROOT_DIR%" -main Omi -js "%BUILD_DIR%\js\omi.js"
goto :eof

:haxe_python
if not exist "%BUILD_DIR%\python" mkdir "%BUILD_DIR%\python"
where haxe >nul 2>nul || (echo Haxe not found & goto :eof)
haxe -cp "%ROOT_DIR%" -main Omi -python "%BUILD_DIR%\python\omi.py"
goto :eof

:haxe_php
if not exist "%BUILD_DIR%\php" mkdir "%BUILD_DIR%\php"
where haxe >nul 2>nul || (echo Haxe not found & goto :eof)
haxe -cp "%ROOT_DIR%" -main Omi -php "%BUILD_DIR%\php"
goto :eof

:haxe_cs
if not exist "%BUILD_DIR%\cs" mkdir "%BUILD_DIR%\cs"
where haxe >nul 2>nul || (echo Haxe not found & goto :eof)
haxe -cp "%ROOT_DIR%" -main Omi -cs "%BUILD_DIR%\cs"
goto :eof

:haxe_java
if not exist "%BUILD_DIR%\java" mkdir "%BUILD_DIR%\java"
where haxe >nul 2>nul || (echo Haxe not found & goto :eof)
haxe -cp "%ROOT_DIR%" -main Omi -java "%BUILD_DIR%\java"
goto :eof

:c89
if not exist "%BUILD_DIR%\c89" mkdir "%BUILD_DIR%\c89"
where gcc >nul 2>nul && gcc -std=c89 -O2 -o "%BUILD_DIR%\c89\omi.exe" "%ROOT_DIR%omi.c" -lsqlite3 && goto :eof
where clang >nul 2>nul && clang -std=c89 -O2 -o "%BUILD_DIR%\c89\omi.exe" "%ROOT_DIR%omi.c" -lsqlite3 && goto :eof
echo No C compiler found (gcc/clang). Skipping C89 build.
goto :eof

:csharp
if not exist "%BUILD_DIR%\csharp" mkdir "%BUILD_DIR%\csharp"
where mcs >nul 2>nul || (echo mcs not found. Skipping C# build. & goto :eof)
mcs -out:"%BUILD_DIR%\csharp\omi.exe" "%ROOT_DIR%omi.cs" -r:System.Data.SQLite
goto :eof

:done
echo Build complete. Output in %BUILD_DIR%
endlocal
