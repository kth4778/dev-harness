: << 'CMDBLOCK'
@echo off
REM 크로스 플랫폼 폴리글롯 래퍼.
REM Windows: cmd.exe가 이 배치 블록을 실행하고, bash를 찾아 훅 스크립트를 넘긴다.
REM Unix: ':'는 no-op이라 이 블록 전체가 heredoc으로 소비되고 아래 bash 구간이 실행된다.
REM
REM 훅 스크립트는 확장자가 없다(session-start, session-start.sh 아님).
REM Claude Code의 Windows 자동 감지가 .sh를 보면 명령 앞에 bash를 붙여
REM 이 디스패처를 깨뜨리기 때문이다.
REM
REM 사용법: run-hook.cmd <스크립트명> [인자...]

if "%~1"=="" (
    echo run-hook.cmd: missing script name >&2
    exit /b 1
)

set "HOOK_DIR=%~dp0"

if exist "C:\Program Files\Git\bin\bash.exe" (
    "C:\Program Files\Git\bin\bash.exe" "%HOOK_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b %ERRORLEVEL%
)
if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    "C:\Program Files (x86)\Git\bin\bash.exe" "%HOOK_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b %ERRORLEVEL%
)

where bash >nul 2>nul
if %ERRORLEVEL% equ 0 (
    bash "%HOOK_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b %ERRORLEVEL%
)

REM bash가 없으면 조용히 종료한다. 훅이 없어도 플러그인 자체는 동작해야 한다.
exit /b 0
CMDBLOCK

# Unix: 지정된 스크립트를 직접 실행
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$1"
shift
exec bash "${SCRIPT_DIR}/${SCRIPT_NAME}" "$@"
