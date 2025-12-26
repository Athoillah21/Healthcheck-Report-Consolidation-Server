@echo off
REM ============================================================
REM Deploy Script for Healthcheck-Report-Consolidation-Server
REM Repository: https://github.com/Athoillah21/Healthcheck-Report-Consolidation-Server
REM ============================================================

echo.
echo ============================================
echo   Deploying to GitHub Repository
echo ============================================
echo.

REM Change to the script directory
cd /d "%~dp0"

REM Check if git is installed
where git >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Git is not installed or not in PATH!
    echo Please install Git from https://git-scm.com/
    pause
    exit /b 1
)

REM Check if .git folder exists (repo already initialized)
if not exist ".git" (
    echo [INFO] Initializing new Git repository...
    git init
    git remote add origin https://github.com/Athoillah21/Healthcheck-Report-Consolidation-Server.git
    echo [SUCCESS] Git repository initialized!
) else (
    echo [INFO] Git repository already exists.
)

REM Create .gitignore if it doesn't exist
if not exist ".gitignore" (
    echo [INFO] Creating .gitignore file...
    (
        echo # Ignore original reports with sensitive data
        echo *.log
        echo *.tmp
        echo .env
        echo .pgpass
    ) > .gitignore
    echo [SUCCESS] .gitignore created!
)

REM Show current status
echo.
echo [INFO] Current Git Status:
git status --short
echo.

REM Prompt for commit message
set /p COMMIT_MSG="Enter commit message (or press Enter for default): "
if "%COMMIT_MSG%"=="" set COMMIT_MSG=Update healthcheck report consolidation server

REM Add all files
echo.
echo [INFO] Adding files to staging...
git add .

REM Commit changes
echo [INFO] Committing changes...
git commit -m "%COMMIT_MSG%"

REM Check if commit was successful
if %ERRORLEVEL% neq 0 (
    echo [WARNING] Nothing to commit or commit failed.
)

REM Set main branch
echo [INFO] Ensuring main branch...
git branch -M main

REM Push to GitHub
echo.
echo [INFO] Pushing to GitHub...
git push -u origin main

if %ERRORLEVEL% equ 0 (
    echo.
    echo ============================================
    echo   [SUCCESS] Deployed Successfully!
    echo ============================================
    echo.
    echo Repository: https://github.com/Athoillah21/Healthcheck-Report-Consolidation-Server
    echo.
) else (
    echo.
    echo [ERROR] Push failed! 
    echo.
    echo Possible solutions:
    echo 1. Check your GitHub credentials
    echo 2. Run: git config --global credential.helper manager
    echo 3. Make sure you have write access to the repository
    echo.
)

pause
