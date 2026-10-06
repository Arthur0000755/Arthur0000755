#Requires -Version 5.1
<#
.SYNOPSIS
    Pós-formatação: instala programas pelo winget, atualiza os já instalados
    e (opcionalmente) aplica a otimização recomendada.

.DESCRIPTION
    Escolha os programas pelo número (ex.: 1,3,7-10), por "B" (pacote básico)
    ou "T" (todos). A lista fica no início do script e pode ser editada.

.PARAMETER Basico
    Instala o pacote básico sem perguntas.

.PARAMETER Programas
    IDs do winget para instalar sem perguntas (ex.: -Programas Google.Chrome,7zip.7zip).

.EXAMPLE
    .\Pos-Formatacao.ps1
    .\Pos-Formatacao.ps1 -Basico
#>
[CmdletBinding()]
param(
    [switch]$Basico,
    [string[]]$Programas
)

$ErrorActionPreference = 'Continue'

if ($env:OS -ne 'Windows_NT') { Write-Host 'Este script só funciona no Windows.' -ForegroundColor Red; exit 1 }

$ehAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Basico) { $argumentos += '-Basico' }
    if ($Programas) { $argumentos += '-Programas', ($Programas -join ',') }
    $inicio = @{ FilePath = 'powershell.exe'; ArgumentList = $argumentos }
    if (-not $ehAdmin) { $inicio.Verb = 'RunAs' }
    Start-Process @inicio
    exit
}

# ---------------------------------------------------------------------------
# Catálogo (Categoria, Nome, ID do winget, faz parte do básico?)
# ---------------------------------------------------------------------------
function P([string]$Categoria, [string]$Nome, [string]$Id, [bool]$Basico = $false) {
    [pscustomobject]@{ Categoria = $Categoria; Nome = $Nome; Id = $Id; Basico = $Basico }
}

$Catalogo = @(
    P 'Navegador' 'Google Chrome' 'Google.Chrome' $true
    P 'Navegador' 'Mozilla Firefox' 'Mozilla.Firefox.pt-BR'
    P 'Navegador' 'Brave' 'Brave.Brave'
    P 'Utilitário' '7-Zip' '7zip.7zip' $true
    P 'Utilitário' 'Notepad++' 'Notepad++.Notepad++'
    P 'Utilitário' 'PowerToys' 'Microsoft.PowerToys'
    P 'Utilitário' 'ShareX (captura de tela)' 'ShareX.ShareX'
    P 'Documentos' 'Adobe Acrobat Reader' 'Adobe.Acrobat.Reader.64-bit' $true
    P 'Documentos' 'SumatraPDF (leitor leve)' 'SumatraPDF.SumatraPDF'
    P 'Documentos' 'LibreOffice' 'TheDocumentFoundation.LibreOffice'
    P 'Mídia' 'VLC' 'VideoLAN.VLC' $true
    P 'Comunicação' 'WhatsApp' '9NKSQGP7F2NH'
    P 'Comunicação' 'Discord' 'Discord.Discord'
    P 'Comunicação' 'Zoom' 'Zoom.Zoom'
    P 'Comunicação' 'Telegram' 'Telegram.TelegramDesktop'
    P 'Acesso remoto' 'AnyDesk' 'AnyDesk.AnyDesk'
    P 'Acesso remoto' 'RustDesk' 'RustDesk.RustDesk'
    P 'Jogos' 'Steam' 'Valve.Steam'
    P 'Runtimes' 'Visual C++ 2015-2022 (x64)' 'Microsoft.VCRedist.2015+.x64' $true
    P 'Runtimes' 'Visual C++ 2015-2022 (x86)' 'Microsoft.VCRedist.2015+.x86' $true
    P 'Runtimes' '.NET Desktop Runtime 8' 'Microsoft.DotNet.DesktopRuntime.8' $true
    P 'Runtimes' 'Java (JRE)' 'Oracle.JavaRuntimeEnvironment'
    P 'Técnico' 'CrystalDiskInfo (saúde do disco)' 'CrystalDewWorld.CrystalDiskInfo'
    P 'Técnico' 'CPU-Z' 'CPUID.CPU-Z'
    P 'Técnico' 'HWMonitor (temperaturas)' 'CPUID.HWMonitor'
)

# ---------------------------------------------------------------------------
function Test-Winget {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { return $true }
    Write-Host 'winget não encontrado. Tentando registrar o Instalador de Aplicativo...' -ForegroundColor Yellow
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    } catch { }
    # Após registrar, o executável fica em WindowsApps do usuário.
    $env:Path += ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { return $true }
    Write-Host 'Não foi possível usar o winget.' -ForegroundColor Red
    Write-Host 'Atualize o "Instalador de Aplicativo" pela Microsoft Store (ou instale as atualizações do Windows) e rode de novo.' -ForegroundColor Yellow
    return $false
}

function Install-Programa($Programa) {
    Write-Host ''
    Write-Host "==> Instalando $($Programa.Nome)..." -ForegroundColor Cyan
    $argumentos = @('install', '--id', $Programa.Id, '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    # IDs da Microsoft Store não têm ponto (ex.: 9NKSQGP7F2NH)
    if ($Programa.Id -notmatch '\.') { $argumentos += '--source', 'msstore' } else { $argumentos += '--source', 'winget' }
    & winget.exe @argumentos
    # -1978335189 = já instalado e sem atualização disponível
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
        return $true
    }
    Write-Host "  Falhou (código $LASTEXITCODE)" -ForegroundColor Red
    return $false
}

function Install-Lista($Lista) {
    $ok = @(); $falhas = @()
    foreach ($p in $Lista) {
        if (Install-Programa $p) { $ok += $p.Nome } else { $falhas += $p.Nome }
    }
    Write-Host ''
    Write-Host "Instalados: $($ok.Count)" -ForegroundColor Green
    if ($falhas) { Write-Host "Com falha: $($falhas -join ', ')" -ForegroundColor Red }
}

function ConvertFrom-Selecao([string]$Texto, [int]$Maximo) {
    $numeros = New-Object System.Collections.Generic.List[int]
    foreach ($parte in ($Texto -split '[,; ]+' | Where-Object { $_ })) {
        if ($parte -match '^(\d+)-(\d+)$') {
            [int]$a = $Matches[1]; [int]$b = $Matches[2]
            foreach ($n in $a..$b) { $numeros.Add($n) }
        } elseif ($parte -match '^\d+$') {
            $numeros.Add([int]$parte)
        }
    }
    return @($numeros | Where-Object { $_ -ge 1 -and $_ -le $Maximo } | Sort-Object -Unique)
}

function Show-Catalogo {
    $categoria = ''
    for ($i = 0; $i -lt $Catalogo.Count; $i++) {
        $p = $Catalogo[$i]
        if ($p.Categoria -ne $categoria) {
            $categoria = $p.Categoria
            Write-Host ''
            Write-Host "  $categoria" -ForegroundColor Cyan
        }
        $marca = if ($p.Basico) { ' (básico)' } else { '' }
        Write-Host ('   [{0,2}] {1}{2}' -f ($i + 1), $p.Nome, $marca)
    }
    Write-Host ''
}

function Invoke-EscolherProgramas {
    Show-Catalogo
    Write-Host 'Digite os números (ex.: 1,4,7-9), B para o pacote básico ou T para todos.' -ForegroundColor Yellow
    $entrada = (Read-Host 'Programas').Trim().ToUpper()
    $selecionados = @(switch ($entrada) {
        'B' { @($Catalogo | Where-Object Basico) }
        'T' { @($Catalogo) }
        default {
            $idx = ConvertFrom-Selecao $entrada $Catalogo.Count
            @($idx | ForEach-Object { $Catalogo[$_ - 1] })
        }
    })
    if ($selecionados.Count -eq 0) { Write-Host 'Nada selecionado.'; return }
    Write-Host ''
    Write-Host 'Serão instalados:' -ForegroundColor Cyan
    $selecionados | ForEach-Object { Write-Host "  - $($_.Nome)" }
    $r = Read-Host 'Confirmar? [S/n]'
    if ($r -and -not $r.Trim().ToUpper().StartsWith('S')) { return }
    Install-Lista $selecionados
}

function Update-Todos {
    Write-Host ''
    Write-Host '==> Atualizando todos os programas instalados...' -ForegroundColor Cyan
    & winget.exe upgrade --all --silent --include-unknown `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
}

function Invoke-Script([string]$Nome, [string[]]$Parametros = @()) {
    $caminho = Join-Path $PSScriptRoot $Nome
    if (-not (Test-Path $caminho)) {
        Write-Host "$Nome não encontrado na mesma pasta deste script." -ForegroundColor Red
        return
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $caminho @Parametros
}

# ---------------------------------------------------------------------------
if (-not (Test-Winget)) { Read-Host 'Pressione ENTER para sair' | Out-Null; exit 1 }

if ($Basico -or $Programas) {
    $lista = if ($Programas) {
        $ids = $Programas -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($id in $ids) {
            $item = $Catalogo | Where-Object Id -eq $id | Select-Object -First 1
            if (-not $item) { $item = [pscustomobject]@{ Categoria = ''; Nome = $id; Id = $id; Basico = $false } }
            $item
        }
    } else {
        $Catalogo | Where-Object Basico
    }
    Install-Lista @($lista)
    exit
}

do {
    Clear-Host
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host '                      PÓS-FORMATAÇÃO' -ForegroundColor Cyan
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host '  [1] Instalar programas' -ForegroundColor Green
    Write-Host '  [2] Atualizar todos os programas instalados'
    Write-Host '  [3] Aplicar otimização recomendada (Otimizar-Windows.ps1)'
    Write-Host '  [4] Gerar diagnóstico do PC (Diagnostico-PC.ps1)'
    Write-Host '  [0] Sair'
    Write-Host '-----------------------------------------------------------------' -ForegroundColor Cyan
    $opcao = (Read-Host 'Escolha uma opção').Trim()
    switch ($opcao) {
        '1' { Invoke-EscolherProgramas }
        '2' { Update-Todos }
        '3' { Invoke-Script 'Otimizar-Windows.ps1' @('-Recomendado') }
        '4' { Invoke-Script 'Diagnostico-PC.ps1' }
        '0' { break }
        default { Write-Host 'Opção inválida.' -ForegroundColor Red }
    }
    if ($opcao -ne '0') { Read-Host 'Pressione ENTER para voltar ao menu' | Out-Null }
} while ($opcao -ne '0')
