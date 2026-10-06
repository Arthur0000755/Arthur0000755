@echo off
title Kit de Manutencao do Windows
cd /d "%~dp0"

:menu
cls
echo =================================================================
echo                 KIT DE MANUTENCAO DO WINDOWS
echo =================================================================
echo   [1] Diagnostico do PC (relatorio para o cliente)
echo   [2] Otimizar o Windows
echo   [3] Reparar o Windows (SFC, DISM, disco, Update, rede)
echo   [4] Pos-formatacao (instalar e atualizar programas)
echo   [5] Otimizacao para jogos (com medicao de FPS)
echo   [6] Limpeza profunda (temporarios, logs, cache de atualizacoes, lixeira)
echo   [0] Sair
echo -----------------------------------------------------------------
set "opcao="
set /p "opcao=Escolha uma opcao: "

if "%opcao%"=="1" call :executar Diagnostico-PC.ps1
if "%opcao%"=="2" call :executar Otimizar-Windows.ps1
if "%opcao%"=="3" call :executar Reparar-Windows.ps1
if "%opcao%"=="4" call :executar Pos-Formatacao.ps1
if "%opcao%"=="5" call :executar Otimizar-Jogos.ps1
if "%opcao%"=="6" call :executar Limpeza-Profunda.ps1
if "%opcao%"=="0" exit /b
goto menu

:executar
if not exist "%~dp0%~1" (
    echo Arquivo %~1 nao encontrado nesta pasta.
    pause
    exit /b
)
rem Os scripts pedem permissao de administrador sozinhos e abrem em nova janela.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0%~1"
exit /b
