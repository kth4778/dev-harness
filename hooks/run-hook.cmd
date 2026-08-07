: << 'CMDBLOCK'
@echo off
REM ASCII ONLY. Do not put non-ASCII characters in this file.
REM
REM cmd.exe reads .cmd files in the OEM codepage (cp949 on Korean Windows).
REM UTF-8 Korean bytes decoded that way can produce cmd metacharacters, which
REM split a REM line so its tail runs as a command. The batch then dies with
REM exit /b 1, and Claude Code treats exit 1 as "error but allow" -- so every
REM hook silently stops guarding. Observed 2026-08-07. Korean notes: README.md.
REM
REM NEVER put "exit /b %ERRORLEVEL%" inside a parenthesized if-block. cmd
REM expands %ERRORLEVEL% when it parses the whole block, i.e. BEFORE the
REM command inside it runs, so the hook's exit 2 (block) is reported as 0
REM (allow). Same silent failure as above. Keep the call and the exit at top
REM level, as below. Verified 2026-08-07: exit 2 now survives the dispatcher.
REM
REM Cross-platform polyglot dispatcher.
REM   Windows: cmd.exe runs this batch block, finds bash, hands off the script.
REM   Unix:    ':' is a no-op, the block is eaten as a heredoc, bash part runs.
REM
REM Hook scripts have no extension (session-start, not session-start.sh).
REM Claude Code's Windows auto-detection prepends bash when it sees .sh,
REM which breaks this dispatcher.
REM
REM Usage: run-hook.cmd <script-name> [args...]

if "%~1"=="" goto :noscript

set "HOOK_DIR=%~dp0"
set "BASH_EXE="

if exist "C:\Program Files\Git\bin\bash.exe" set "BASH_EXE=C:\Program Files\Git\bin\bash.exe"
if not defined BASH_EXE if exist "C:\Program Files (x86)\Git\bin\bash.exe" set "BASH_EXE=C:\Program Files (x86)\Git\bin\bash.exe"
if not defined BASH_EXE where bash >nul 2>nul
if not defined BASH_EXE if %ERRORLEVEL% equ 0 set "BASH_EXE=bash"
if not defined BASH_EXE goto :nobash

"%BASH_EXE%" "%HOOK_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%

:noscript
echo run-hook.cmd: missing script name >&2
exit /b 1

:nobash
REM No bash: exit quietly. The plugin must work even without hooks.
exit /b 0
CMDBLOCK

# Unix: run the named script directly
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$1"
shift
exec bash "${SCRIPT_DIR}/${SCRIPT_NAME}" "$@"
