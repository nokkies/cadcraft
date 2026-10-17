@echo off
REM cadcraft-cli wrapper (PSA Fusion, M0-C3).
REM Calls the release build of the headless CLI by full path, so every later card can
REM write `cadcraft-cli` and have it run from any folder. Rebuild with:
REM   cargo build --release -p cadcraft-cli
REM in C:\Users\ReinachvanNieuwenhui\src\cadcraft
"C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe" %*
exit /b %ERRORLEVEL%
