#Requires -Version 5.1
<#
.SYNOPSIS
    Limpeza profunda do Windows: arquivos temporários, logs antigos, cache de
    atualizações e Lixeira, com log detalhado do processo.

.DESCRIPTION
    Categorias sempre executadas:
      - Temporários de todos os usuários e do Windows (mais antigos que -HorasTemp)
      - Logs antigos do Windows (mais antigos que -DiasLogs) e relatórios de erro
      - Cache de downloads do Windows Update e da Otimização de Entrega
      - Lixeira de todas as unidades

    Categorias opcionais (perguntadas no modo interativo ou ativadas por parâmetro):
      - Despejos de memória (arquivos de tela azul)
      - Cache dos navegadores (Chrome, Edge, Firefox)
      - Limpeza de componentes do Windows Update (DISM)
      - Instalação anterior do Windows (Windows.old) e arquivos de setup

    Segurança:
      - Pede elevação para Administrador automaticamente.
      - Não entra em links simbólicos/junções (evita apagar algo fora da pasta).
      - Arquivos em uso são ignorados e contados como "em uso" no relatório.
      - Não limpa o Prefetch nem os Logs de Eventos (pioram o desempenho ou
        apagam informação de diagnóstico).

    O log fica em %ProgramData%\OtimizadorWindows\limpeza-AAAAMMDD-HHMMSS.txt.

.PARAMETER DiasLogs
    Remove logs com mais de N dias. Padrão: 30.

.PARAMETER HorasTemp
    Remove temporários com mais de N horas. Padrão: 24 (0 = todos).

.PARAMETER SemPerguntas
    Executa sem perguntar; as opcionais só rodam se o parâmetro delas for informado.

.PARAMETER Simular
    Apenas calcula quanto seria liberado, sem apagar nada.

.PARAMETER IncluirDumps
    Remove despejos de memória (MEMORY.DMP, Minidump, LiveKernelReports).

.PARAMETER IncluirNavegadores
    Limpa o cache do Chrome, Edge e Firefox (somente se estiverem fechados).

.PARAMETER IncluirDism
    Executa DISM /StartComponentCleanup (remove versões antigas de atualizações).

.PARAMETER IncluirWindowsOld
    Remove a instalação anterior do Windows (Windows.old). Impede voltar à versão anterior.

.PARAMETER LogDetalhado
    Registra no log cada arquivo removido (o log pode ficar grande).

.PARAMETER PastaLog
    Pasta do arquivo de log. Padrão: %ProgramData%\OtimizadorWindows.

.EXAMPLE
    .\Limpeza-Profunda.ps1
    .\Limpeza-Profunda.ps1 -Simular
    .\Limpeza-Profunda.ps1 -SemPerguntas -IncluirDism -IncluirNavegadores
    .\Limpeza-Profunda.ps1 -DiasLogs 7 -HorasTemp 0 -LogDetalhado
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 3650)][int]$DiasLogs = 30,
    [ValidateRange(0, 8760)][int]$HorasTemp = 24,
    [switch]$SemPerguntas,
    [switch]$Simular,
    [switch]$IncluirDumps,
    [switch]$IncluirNavegadores,
    [switch]$IncluirDism,
    [switch]$IncluirWindowsOld,
    [switch]$LogDetalhado,
    [string]$PastaLog
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Elevação para Administrador (e Windows PowerShell 5.1)
# ---------------------------------------------------------------------------
if ($env:OS -ne 'Windows_NT') {
    Write-Host 'Este script só funciona no Windows.' -ForegroundColor Red
    exit 1
}

$ehAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $ehAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($chave in $PSBoundParameters.Keys) {
        $valor = $PSBoundParameters[$chave]
        if ($valor -is [switch]) { if ($valor) { $argumentos += "-$chave" } }
        else { $argumentos += "-$chave", "`"$valor`"" }
    }
    $inicio = @{ FilePath = 'powershell.exe'; ArgumentList = $argumentos }
    if (-not $ehAdmin) {
        $inicio.Verb = 'RunAs'
        Write-Host 'Solicitando permissão de Administrador...' -ForegroundColor Yellow
    }
    try {
        Start-Process @inicio -ErrorAction Stop
    } catch {
        Write-Host 'A limpeza precisa ser executada como Administrador. Permissão negada.' -ForegroundColor Red
        exit 1
    }
    exit
}

# ---------------------------------------------------------------------------
# Log
# ---------------------------------------------------------------------------
if (-not $PastaLog) { $PastaLog = Join-Path $env:ProgramData 'OtimizadorWindows' }
New-Item -Path $PastaLog -ItemType Directory -Force | Out-Null
$Script:LogFile = Join-Path $PastaLog ('limpeza-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))

function Write-ArquivoLog([string]$Linha) {
    try { Add-Content -Path $Script:LogFile -Value $Linha -Encoding UTF8 } catch { }
}

function Write-Log {
    param(
        [string]$Mensagem,
        [ValidateSet('INFO', 'OK', 'AVISO', 'ERRO', 'TITULO')][string]$Nivel = 'INFO'
    )
    $cor = switch ($Nivel) {
        'OK' { 'Green' } 'AVISO' { 'Yellow' } 'ERRO' { 'Red' } 'TITULO' { 'Cyan' } default { 'Gray' }
    }
    if ($Nivel -eq 'TITULO') { Write-Host '' }
    Write-Host $Mensagem -ForegroundColor $cor
    Write-ArquivoLog ('[{0:yyyy-MM-dd HH:mm:ss}] [{1,-6}] {2}' -f (Get-Date), $Nivel, $Mensagem)
}

function Confirm-Acao([string]$Pergunta, [bool]$Padrao = $false) {
    if ($SemPerguntas) { return $Padrao }
    $sufixo = if ($Padrao) { '[S/n]' } else { '[s/N]' }
    $r = Read-Host "$Pergunta $sufixo"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Padrao }
    return $r.Trim().ToUpper().StartsWith('S')
}

function Format-Tamanho([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -gt 0 -and $Bytes -lt 1KB) { return '< 1 KB' }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-EspacoLivre {
    [double](Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
}

# ---------------------------------------------------------------------------
# Remoção segura de arquivos
# ---------------------------------------------------------------------------
$Script:Resultados = [ordered]@{}

function Add-Resultado([string]$Categoria, [int]$Arquivos, [double]$Bytes, [int]$Falhas) {
    if (-not $Script:Resultados.Contains($Categoria)) {
        $Script:Resultados[$Categoria] = [pscustomobject]@{ Arquivos = 0; Bytes = 0.0; EmUso = 0 }
    }
    $r = $Script:Resultados[$Categoria]
    $r.Arquivos += $Arquivos
    $r.Bytes += $Bytes
    $r.EmUso += $Falhas
}

function Test-ReparsePoint($Item) {
    ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

# Percorre a pasta sem seguir links/junções e devolve os arquivos mais antigos que $AntesDe.
function Get-ArquivosSeguros {
    param([string]$Pasta, [datetime]$AntesDe = [datetime]::MaxValue, [string[]]$ExcluirPastas = @())
    if (-not [IO.Directory]::Exists($Pasta)) { return }
    $raiz = New-Object IO.DirectoryInfo $Pasta
    if (Test-ReparsePoint $raiz) { return }

    $pilha = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $pilha.Push($raiz)
    while ($pilha.Count -gt 0) {
        $dir = $pilha.Pop()
        try { $itens = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($item in $itens) {
            if (Test-ReparsePoint $item) { continue }
            if ($item -is [IO.DirectoryInfo]) {
                if ($ExcluirPastas -notcontains $item.Name) { $pilha.Push($item) }
            } elseif ($item.LastWriteTime -lt $AntesDe) {
                $item
            }
        }
    }
}

function Measure-Pasta([string]$Pasta) {
    $total = 0.0
    foreach ($a in Get-ArquivosSeguros $Pasta) { $total += $a.Length }
    return $total
}

# Remove subpastas vazias (da mais profunda para a mais rasa), mantendo a pasta raiz.
function Remove-PastasVazias([string]$Pasta) {
    if (-not [IO.Directory]::Exists($Pasta)) { return }
    $pastas = New-Object System.Collections.Generic.List[IO.DirectoryInfo]
    $pilha = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $pilha.Push((New-Object IO.DirectoryInfo $Pasta))
    while ($pilha.Count -gt 0) {
        $dir = $pilha.Pop()
        try { $filhas = $dir.GetDirectories() } catch { continue }
        foreach ($f in $filhas) {
            if (Test-ReparsePoint $f) { continue }
            $pastas.Add($f); $pilha.Push($f)
        }
    }
    foreach ($d in ($pastas | Sort-Object { $_.FullName.Length } -Descending)) {
        try { $d.Delete() } catch { }   # só apaga se estiver vazia
    }
}

function Clear-Pasta {
    param(
        [string]$Categoria,
        [string]$Pasta,
        [int]$HorasMinimas = 0,
        [string[]]$Filtro,
        [string[]]$ExcluirPastas = @(),
        [switch]$ManterSubpastas
    )
    if (-not [IO.Directory]::Exists($Pasta)) { return }
    $limite = if ($HorasMinimas -gt 0) { (Get-Date).AddHours(-$HorasMinimas) } else { [datetime]::MaxValue }
    $removidos = 0; $bytes = 0.0; $falhas = 0

    foreach ($arq in Get-ArquivosSeguros -Pasta $Pasta -AntesDe $limite -ExcluirPastas $ExcluirPastas) {
        if ($Filtro) {
            $nome = $arq.Name
            if (-not ($Filtro | Where-Object { $nome -like $_ })) { continue }
        }
        $tamanho = $arq.Length
        if ($Simular) { $removidos++; $bytes += $tamanho; continue }
        try {
            if ($arq.IsReadOnly) { $arq.IsReadOnly = $false }
            $arq.Delete()
            $removidos++; $bytes += $tamanho
            if ($LogDetalhado) { Write-ArquivoLog "    removido: $($arq.FullName)" }
        } catch {
            $falhas++
            if ($LogDetalhado) { Write-ArquivoLog "    em uso:   $($arq.FullName)" }
        }
    }
    if (-not $Simular -and -not $ManterSubpastas) { Remove-PastasVazias $Pasta }

    Add-Resultado $Categoria $removidos $bytes $falhas
    if ($removidos -gt 0 -or $falhas -gt 0) {
        $texto = '  {0}: {1} arquivo(s), {2}' -f $Pasta, $removidos, (Format-Tamanho $bytes)
        if ($falhas -gt 0) { $texto += " ($falhas em uso, ignorados)" }
        Write-Log $texto
    }
}

function Remove-ArquivoUnico([string]$Categoria, [string]$Caminho) {
    if (-not [IO.File]::Exists($Caminho)) { return }
    $arq = New-Object IO.FileInfo $Caminho
    $tamanho = $arq.Length
    if ($Simular) { Add-Resultado $Categoria 1 $tamanho 0; Write-Log "  $Caminho ($(Format-Tamanho $tamanho))"; return }
    try {
        $arq.Delete()
        Add-Resultado $Categoria 1 $tamanho 0
        Write-Log "  $Caminho ($(Format-Tamanho $tamanho))"
    } catch {
        Add-Resultado $Categoria 0 0 1
        Write-Log "  $Caminho em uso: $($_.Exception.Message)" 'AVISO'
    }
}

# Pastas de perfil reais (ignora "All Users", "Default User" e outras junções)
function Get-PerfisUsuario {
    $usuarios = Join-Path $env:SystemDrive 'Users'
    if (-not (Test-Path $usuarios)) { return @() }
    @((New-Object IO.DirectoryInfo $usuarios).GetDirectories() | Where-Object { -not (Test-ReparsePoint $_) })
}

# ---------------------------------------------------------------------------
# Categorias
# ---------------------------------------------------------------------------
function Invoke-Temporarios {
    $categoria = 'Arquivos temporários'
    $idade = if ($HorasTemp -gt 0) { "com mais de $HorasTemp h" } else { 'todos' }
    Write-Log "[1] $categoria ($idade)" 'TITULO'
    foreach ($perfil in Get-PerfisUsuario) {
        Clear-Pasta $categoria (Join-Path $perfil.FullName 'AppData\Local\Temp') -HorasMinimas $HorasTemp
        Clear-Pasta $categoria (Join-Path $perfil.FullName 'AppData\Local\CrashDumps')
        Clear-Pasta $categoria (Join-Path $perfil.FullName 'AppData\Local\Microsoft\Windows\INetCache') -HorasMinimas $HorasTemp
    }
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'Temp') -HorasMinimas $HorasTemp
    # Temporários dos serviços do sistema
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Local\Temp') -HorasMinimas $HorasTemp
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Temp') -HorasMinimas $HorasTemp
}

function Invoke-LogsAntigos {
    $categoria = 'Logs antigos e relatórios de erro'
    Write-Log "[2] $categoria (com mais de $DiasLogs dias)" 'TITULO'
    $horas = $DiasLogs * 24
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'Logs') -HorasMinimas $horas
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'Panther') -HorasMinimas $horas -ManterSubpastas
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'Debug') -HorasMinimas $horas -Filtro '*.log' -ManterSubpastas
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'INF') -HorasMinimas $horas -Filtro 'setupapi*.log' -ManterSubpastas
    # "Sum" e "WMI" guardam bancos de dados em uso pelo sistema, não logs.
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'System32\LogFiles') -HorasMinimas $horas `
        -ExcluirPastas 'Sum', 'WMI' -ManterSubpastas
    # Relatórios de erro do Windows (WER) já enviados ou na fila
    foreach ($sub in 'ReportArchive', 'ReportQueue', 'Temp') {
        Clear-Pasta $categoria (Join-Path $env:ProgramData "Microsoft\Windows\WER\$sub")
    }
    foreach ($perfil in Get-PerfisUsuario) {
        Clear-Pasta $categoria (Join-Path $perfil.FullName 'AppData\Local\Microsoft\Windows\WER') -HorasMinimas $horas
    }
}

function Invoke-CacheAtualizacoes {
    $categoria = 'Cache de atualizações'
    Write-Log "[3] $categoria" 'TITULO'

    # O Windows Update precisa estar parado para liberar os arquivos baixados.
    $servicos = @('wuauserv', 'bits')
    $estavamRodando = @($servicos | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -eq 'Running' })
    try {
        if (-not $Simular) {
            foreach ($s in $servicos) {
                Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
                Write-ArquivoLog "    serviço parado: $s"
            }
        }
        Clear-Pasta $categoria (Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
    } finally {
        if (-not $Simular) {
            foreach ($s in $estavamRodando) {
                Start-Service -Name $s -ErrorAction SilentlyContinue
                Write-ArquivoLog "    serviço reiniciado: $s"
            }
        }
    }

    # Otimização de Entrega (cópias de atualizações compartilhadas entre PCs)
    $pastaDO = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    $comando = Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue
    if ($comando -and [IO.Directory]::Exists($pastaDO)) {
        $antes = Measure-Pasta $pastaDO
        if ($Simular) {
            Add-Resultado $categoria 0 $antes 0
        } else {
            Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
            $liberado = [math]::Max(0, $antes - (Measure-Pasta $pastaDO))
            Add-Resultado $categoria 0 $liberado 0
        }
        Write-Log "  Cache da Otimização de Entrega: $(Format-Tamanho $antes)"
    } else {
        Clear-Pasta $categoria $pastaDO
    }
}

function Invoke-Lixeira {
    $categoria = 'Lixeira'
    Write-Log "[4] $categoria (todas as unidades)" 'TITULO'
    $arquivos = 0; $bytes = 0.0
    $unidades = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object -ExpandProperty DeviceID
    foreach ($u in $unidades) {
        foreach ($a in Get-ArquivosSeguros (Join-Path "$u\" '$Recycle.Bin')) {
            if ($a.Name -ne 'desktop.ini') { $arquivos++; $bytes += $a.Length }
        }
    }
    if (-not $Simular -and $arquivos -gt 0) {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
        } catch {
            Write-Log "  Não foi possível esvaziar a Lixeira: $($_.Exception.Message)" 'AVISO'
            return
        }
    }
    Add-Resultado $categoria $arquivos $bytes 0
    Write-Log "  $arquivos item(ns), $(Format-Tamanho $bytes)"
}

function Invoke-Dumps {
    $categoria = 'Despejos de memória'
    Write-Log "[+] $categoria" 'TITULO'
    Remove-ArquivoUnico $categoria (Join-Path $env:SystemRoot 'MEMORY.DMP')
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'Minidump') -ManterSubpastas
    Clear-Pasta $categoria (Join-Path $env:SystemRoot 'LiveKernelReports') -Filtro '*.dmp'
}

function Invoke-Navegadores {
    $categoria = 'Cache dos navegadores'
    Write-Log "[+] $categoria" 'TITULO'
    $abertos = @(Get-Process -Name chrome, msedge, firefox -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty ProcessName -Unique)
    if ($abertos.Count -gt 0) {
        Write-Log "  Ignorado: feche os navegadores antes ($($abertos -join ', ') aberto)." 'AVISO'
        return
    }
    # Apenas cache: histórico, senhas, favoritos e cookies NÃO são apagados.
    $subpastasCache = 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage'
    foreach ($perfil in Get-PerfisUsuario) {
        $local = Join-Path $perfil.FullName 'AppData\Local'
        foreach ($dados in @("$local\Google\Chrome\User Data", "$local\Microsoft\Edge\User Data")) {
            if (-not [IO.Directory]::Exists($dados)) { continue }
            foreach ($perfilNav in (New-Object IO.DirectoryInfo $dados).GetDirectories()) {
                if ($perfilNav.Name -ne 'Default' -and $perfilNav.Name -notlike 'Profile *') { continue }
                foreach ($sub in $subpastasCache) { Clear-Pasta $categoria (Join-Path $perfilNav.FullName $sub) }
            }
        }
        $firefox = "$local\Mozilla\Firefox\Profiles"
        if ([IO.Directory]::Exists($firefox)) {
            foreach ($perfilFx in (New-Object IO.DirectoryInfo $firefox).GetDirectories()) {
                Clear-Pasta $categoria (Join-Path $perfilFx.FullName 'cache2')
            }
        }
    }
}

function Invoke-Dism {
    $categoria = 'Componentes do Windows (DISM)'
    Write-Log "[+] $categoria - pode levar vários minutos" 'TITULO'
    if ($Simular) { Write-Log '  [simulação] DISM /Online /Cleanup-Image /StartComponentCleanup'; return }
    $antes = Get-EspacoLivre
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart 2>&1 |
        Where-Object { $_ -and $_ -notmatch '^\s*\[[= .0-9%]*\]\s*$' } |
        ForEach-Object { Write-ArquivoLog "    dism: $_" }
    $codigo = $LASTEXITCODE
    $liberado = [math]::Max(0, (Get-EspacoLivre) - $antes)
    Add-Resultado $categoria 0 $liberado 0
    if ($codigo -eq 0) { Write-Log "  Concluído: $(Format-Tamanho $liberado)" 'OK' }
    else { Write-Log "  DISM terminou com código $codigo (detalhes no log)" 'AVISO' }
}

function Invoke-WindowsOld {
    $categoria = 'Instalação anterior do Windows'
    Write-Log "[+] $categoria (Windows.old)" 'TITULO'
    if ($Simular) { Write-Log '  [simulação] Limpeza de Disco: Instalações Anteriores e Arquivos de Setup'; return }

    # A pasta pertence ao TrustedInstaller; a própria Limpeza de Disco do Windows
    # a remove corretamente. StateFlags0099 marca só estes itens para o perfil 99.
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $itens = 'Previous Installations', 'Temporary Setup Files'
    $antes = Get-EspacoLivre
    try {
        foreach ($i in $itens) {
            if (Test-Path "$base\$i") { Set-ItemProperty -Path "$base\$i" -Name StateFlags0099 -Value 2 -Type DWord }
        }
        Write-Log '  Executando a Limpeza de Disco do Windows...'
        Start-Process -FilePath cleanmgr.exe -ArgumentList '/sagerun:99' -Wait
    } finally {
        foreach ($i in $itens) { Remove-ItemProperty -Path "$base\$i" -Name StateFlags0099 -ErrorAction SilentlyContinue }
    }
    $liberado = [math]::Max(0, (Get-EspacoLivre) - $antes)
    Add-Resultado $categoria 0 $liberado 0
    Write-Log "  Concluído: $(Format-Tamanho $liberado)" 'OK'
}

# ---------------------------------------------------------------------------
# Execução
# ---------------------------------------------------------------------------
Clear-Host
Write-Host '=================================================================' -ForegroundColor Cyan
Write-Host '                   LIMPEZA PROFUNDA DO WINDOWS' -ForegroundColor Cyan
Write-Host '=================================================================' -ForegroundColor Cyan
if ($Simular) { Write-Host ' MODO SIMULAÇÃO: nada será apagado.' -ForegroundColor Yellow }

$livreAntes = Get-EspacoLivre
$so = Get-CimInstance Win32_OperatingSystem
Write-ArquivoLog '================================================================='
Write-Log "Limpeza profunda iniciada por $env:USERDOMAIN\$env:USERNAME em $env:COMPUTERNAME"
Write-Log "Sistema: $($so.Caption) (build $($so.BuildNumber))"
Write-Log ("Parâmetros: DiasLogs={0} HorasTemp={1} Simular={2} LogDetalhado={3}" -f $DiasLogs, $HorasTemp, [bool]$Simular, [bool]$LogDetalhado)
Write-Log "Espaço livre em ${env:SystemDrive}: $(Format-Tamanho $livreAntes)"
Write-Log "Log: $Script:LogFile"

Write-Host ''
Write-Host 'Será limpo:' -ForegroundColor Cyan
Write-Host "  - Arquivos temporários (com mais de $HorasTemp h)"
Write-Host "  - Logs com mais de $DiasLogs dias e relatórios de erro"
Write-Host '  - Cache de downloads do Windows Update e da Otimização de Entrega'
Write-Host '  - Lixeira de todas as unidades'
Write-Host ''

$fazerDumps = $IncluirDumps -or (Confirm-Acao 'Remover despejos de memória de telas azuis? (só são úteis para diagnosticar travamentos)' $false)
$fazerNavegadores = $IncluirNavegadores -or (Confirm-Acao 'Limpar o cache do Chrome/Edge/Firefox? (não apaga senhas, histórico nem favoritos)' $false)
$fazerDism = $IncluirDism -or (Confirm-Acao 'Limpar componentes antigos do Windows Update com DISM? (demora alguns minutos)' $false)

$windowsOld = Join-Path $env:SystemDrive 'Windows.old'
$fazerWindowsOld = $false
if ([IO.Directory]::Exists($windowsOld)) {
    $fazerWindowsOld = $IncluirWindowsOld -or (Confirm-Acao 'Encontrada a pasta Windows.old. Removê-la? (NÃO será mais possível voltar à versão anterior do Windows)' $false)
}

if (-not $SemPerguntas -and -not (Confirm-Acao 'Iniciar a limpeza?' $true)) {
    Write-Log 'Limpeza cancelada pelo usuário.' 'AVISO'
    exit
}

$inicio = Get-Date
Invoke-Temporarios
Invoke-LogsAntigos
Invoke-CacheAtualizacoes
Invoke-Lixeira
if ($fazerDumps) { Invoke-Dumps }
if ($fazerNavegadores) { Invoke-Navegadores }
if ($fazerDism) { Invoke-Dism }
if ($fazerWindowsOld) { Invoke-WindowsOld }

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
$livreDepois = Get-EspacoLivre
$totalBytes = 0.0; $totalArquivos = 0; $totalEmUso = 0
$tabela = foreach ($nome in $Script:Resultados.Keys) {
    $r = $Script:Resultados[$nome]
    $totalBytes += $r.Bytes; $totalArquivos += $r.Arquivos; $totalEmUso += $r.EmUso
    [pscustomobject]@{
        'Categoria' = $nome
        'Arquivos'  = $r.Arquivos
        'Liberado'  = Format-Tamanho $r.Bytes
        'Em uso'    = $r.EmUso
    }
}

Write-Log 'Resumo' 'TITULO'
$textoTabela = ($tabela | Format-Table -AutoSize | Out-String).TrimEnd()
Write-Host $textoTabela
Write-ArquivoLog $textoTabela

$verbo = if ($Simular) { 'Seria liberado' } else { 'Total liberado' }
Write-Log ('{0}: {1} em {2} arquivo(s)' -f $verbo, (Format-Tamanho $totalBytes), $totalArquivos) 'OK'
if ($totalEmUso -gt 0) {
    Write-Log "$totalEmUso arquivo(s) estavam em uso e foram mantidos (normal; reiniciar e rodar de novo libera parte deles)."
}
if (-not $Simular) {
    Write-Log ("Espaço livre em {0}: {1} -> {2}" -f $env:SystemDrive, (Format-Tamanho $livreAntes), (Format-Tamanho $livreDepois)) 'OK'
}
Write-Log ('Duração: {0:mm\:ss}' -f ((Get-Date) - $inicio))
Write-Log "Log completo salvo em: $Script:LogFile" 'OK'

if (-not $SemPerguntas) { Read-Host 'Pressione ENTER para sair' | Out-Null }
