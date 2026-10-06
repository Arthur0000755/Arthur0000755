#Requires -Version 5.1
<#
.SYNOPSIS
    Reparo do Windows: arquivos do sistema (DISM + SFC), disco, Windows Update e rede.

.DESCRIPTION
    Menu com as correções mais usadas no dia a dia de manutenção:
      [1] Reparar arquivos do sistema (DISM RestoreHealth + SFC)
      [2] Verificar o disco (CHKDSK)
      [3] Resetar o Windows Update (quando as atualizações travam ou dão erro)
      [4] Resetar a rede (DNS, Winsock, TCP/IP)
      [5] Trocar o DNS (Cloudflare / Google / automático)
    Todos os passos ficam registrados em %ProgramData%\OtimizadorWindows.

.PARAMETER Completo
    Executa sem perguntas: DISM + SFC + verificação do disco (sem reiniciar).

.EXAMPLE
    .\Reparar-Windows.ps1
    .\Reparar-Windows.ps1 -Completo
#>
[CmdletBinding()]
param([switch]$Completo)

$ErrorActionPreference = 'Continue'

if ($env:OS -ne 'Windows_NT') { Write-Host 'Este script só funciona no Windows.' -ForegroundColor Red; exit 1 }

$ehAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($chave in $PSBoundParameters.Keys) { $argumentos += "-$chave" }
    $inicio = @{ FilePath = 'powershell.exe'; ArgumentList = $argumentos }
    if (-not $ehAdmin) { $inicio.Verb = 'RunAs' }
    Start-Process @inicio
    exit
}

$Script:DataDir = Join-Path $env:ProgramData 'OtimizadorWindows'
New-Item -Path $Script:DataDir -ItemType Directory -Force | Out-Null
$Script:LogFile = Join-Path $Script:DataDir ('reparo-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
$Script:PrecisaReiniciar = $false

function Write-Log {
    param([string]$Mensagem, [ValidateSet('INFO', 'OK', 'AVISO', 'ERRO', 'TITULO')][string]$Nivel = 'INFO')
    $cor = switch ($Nivel) { 'OK' { 'Green' } 'AVISO' { 'Yellow' } 'ERRO' { 'Red' } 'TITULO' { 'Cyan' } default { 'Gray' } }
    if ($Nivel -eq 'TITULO') { Write-Host '' }
    Write-Host $Mensagem -ForegroundColor $cor
    try { Add-Content -Path $Script:LogFile -Encoding UTF8 -Value ('[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Nivel, $Mensagem) } catch { }
}

function Confirm-Acao([string]$Pergunta, [bool]$Padrao = $false) {
    if ($Completo) { return $Padrao }
    $sufixo = if ($Padrao) { '[S/n]' } else { '[s/N]' }
    $r = Read-Host "$Pergunta $sufixo"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Padrao }
    return $r.Trim().ToUpper().StartsWith('S')
}

# ---------------------------------------------------------------------------
function Invoke-ReparoSistema {
    Write-Log '[Sistema] Etapa 1/2: DISM - reparando a imagem do Windows (pode levar 10-30 min)' 'TITULO'
    & dism.exe /Online /Cleanup-Image /RestoreHealth
    $codigoDism = $LASTEXITCODE
    if ($codigoDism -eq 0) {
        Write-Log 'DISM concluído sem erros.' 'OK'
    } else {
        Write-Log "DISM terminou com código $codigoDism. Verifique a internet (o DISM baixa arquivos do Windows Update)." 'AVISO'
    }

    Write-Log '[Sistema] Etapa 2/2: SFC - verificando arquivos do sistema' 'TITULO'
    # O SFC escreve em UTF-16; capturar a saída deixa o texto embaralhado, então só o executamos.
    & sfc.exe /scannow
    switch ($LASTEXITCODE) {
        0       { Write-Log 'SFC: nenhuma violação de integridade encontrada (ou tudo corrigido).' 'OK' }
        default { Write-Log "SFC terminou com código $LASTEXITCODE. Detalhes em C:\Windows\Logs\CBS\CBS.log" 'AVISO' }
    }
    $Script:PrecisaReiniciar = $true
}

function Invoke-VerificarDisco {
    Write-Log "[Disco] Verificação online da unidade $env:SystemDrive (sem reiniciar)" 'TITULO'
    & chkdsk.exe $env:SystemDrive /scan
    # 0 = sem erros, 1 = erros corrigidos, 2 = limpeza feita, 3 = precisa de correção offline
    if ($LASTEXITCODE -le 2) {
        Write-Log 'Sistema de arquivos sem erros pendentes.' 'OK'
        if (-not (Confirm-Acao 'Agendar mesmo assim uma verificação completa na próxima inicialização?' $false)) { return }
    }
    else {
        Write-Log "CHKDSK encontrou problemas (código $LASTEXITCODE)." 'AVISO'
        Write-Log 'Para corrigir é preciso agendar a verificação para a próxima inicialização.'
    }
    Write-Log '  /f  = corrige o sistema de arquivos (rápido)'
    Write-Log '  /r  = também procura setores defeituosos (em HD mecânico pode levar HORAS)'
    if (Confirm-Acao 'Agendar CHKDSK na próxima inicialização?' $true) {
        if (Confirm-Acao 'Incluir busca de setores defeituosos (/r)?' $false) {
            # O chkdsk pergunta se deve agendar; a letra da resposta depende do idioma do Windows.
            $resposta = if ((Get-UICulture).TwoLetterISOLanguageName -eq 'pt') { 'S' } else { 'Y' }
            $resposta | & chkdsk.exe $env:SystemDrive /r | Out-Null
            Write-Log 'CHKDSK /r agendado.' 'OK'
        } else {
            # Marcar a unidade como "suja" faz o Windows corrigir o sistema de arquivos ao iniciar.
            & fsutil.exe dirty set $env:SystemDrive | Out-Null
            Write-Log 'CHKDSK /f agendado.' 'OK'
        }
        Write-Log 'A verificação roda ao reiniciar. Não desligue o PC durante o processo.'
        $Script:PrecisaReiniciar = $true
    }
}

function Invoke-ResetWindowsUpdate {
    Write-Log '[Windows Update] Resetando componentes' 'TITULO'
    $servicos = @('wuauserv', 'bits', 'cryptsvc', 'msiserver', 'UsoSvc')
    foreach ($s in $servicos) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }

    $sufixo = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($pasta in @(
            (Join-Path $env:SystemRoot 'SoftwareDistribution'),
            (Join-Path $env:SystemRoot 'System32\catroot2'))) {
        if (Test-Path $pasta) {
            try {
                Rename-Item -Path $pasta -NewName ("{0}.old-{1}" -f (Split-Path $pasta -Leaf), $sufixo) -ErrorAction Stop
                Write-Log "  + $pasta renomeada (o Windows cria uma nova)" 'OK'
            } catch {
                Write-Log "  ! Não foi possível renomear $pasta : $($_.Exception.Message)" 'AVISO'
            }
        }
    }
    # Remove backups antigos de resets anteriores, mantendo só o que acabou de ser criado.
    Get-ChildItem -Path $env:SystemRoot, (Join-Path $env:SystemRoot 'System32') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(SoftwareDistribution|catroot2)\.old-' -and $_.Name -notlike "*$sufixo" } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    foreach ($s in $servicos) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    & UsoClient.exe StartScan 2>$null
    Write-Log 'Windows Update resetado. Abra Configurações > Windows Update e clique em "Verificar atualizações".' 'OK'
}

function Invoke-ResetRede {
    Write-Log '[Rede] Resetando DNS, Winsock e TCP/IP' 'TITULO'
    & ipconfig.exe /flushdns | Out-Null
    Write-Log '  + Cache de DNS limpo' 'OK'
    if (-not (Confirm-Acao 'Resetar também Winsock e TCP/IP? Exige reiniciar e apaga IPs fixos configurados manualmente.' $false)) { return }
    & netsh.exe winsock reset | Out-Null
    & netsh.exe int ip reset | Out-Null
    & ipconfig.exe /release | Out-Null
    & ipconfig.exe /renew | Out-Null
    Write-Log '  + Winsock e TCP/IP resetados' 'OK'
    $Script:PrecisaReiniciar = $true
}

function Invoke-TrocarDns {
    Write-Log '[DNS] Trocar servidor DNS' 'TITULO'
    $adaptadores = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    if ($adaptadores.Count -eq 0) { Write-Log 'Nenhum adaptador de rede conectado.' 'AVISO'; return }
    foreach ($a in $adaptadores) {
        $atual = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses -join ', '
        Write-Log "  $($a.Name): $atual"
    }
    Write-Host '  [1] Cloudflare (1.1.1.1)   [2] Google (8.8.8.8)   [3] Automático (DHCP)   [0] Cancelar'
    $opcao = Read-Host '  Escolha'
    $servidores = switch ($opcao) {
        '1' { @('1.1.1.1', '1.0.0.1') }
        '2' { @('8.8.8.8', '8.8.4.4') }
        '3' { 'auto' }
        default { $null }
    }
    if (-not $servidores) { return }
    foreach ($a in $adaptadores) {
        try {
            if ($servidores -eq 'auto') {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servidores -ErrorAction Stop
            }
            Write-Log "  + DNS alterado em $($a.Name)" 'OK'
        } catch {
            Write-Log "  ! $($a.Name): $($_.Exception.Message)" 'AVISO'
        }
    }
    & ipconfig.exe /flushdns | Out-Null
}

function Show-Final {
    Write-Host ''
    Write-Log "Log salvo em: $Script:LogFile" 'OK'
    if ($Script:PrecisaReiniciar) {
        Write-Host 'Reinicie o computador para concluir os reparos.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
if ($Completo) {
    Invoke-ReparoSistema
    Invoke-VerificarDisco
    Show-Final
    exit
}

do {
    Clear-Host
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host '                     REPARO DO WINDOWS' -ForegroundColor Cyan
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host '  [1] Reparar arquivos do sistema (DISM + SFC)' -ForegroundColor Green
    Write-Host '  [2] Verificar o disco (CHKDSK)'
    Write-Host '  [3] Resetar o Windows Update'
    Write-Host '  [4] Resetar a rede'
    Write-Host '  [5] Trocar o DNS'
    Write-Host '  [0] Sair'
    Write-Host '-----------------------------------------------------------------' -ForegroundColor Cyan
    $opcao = (Read-Host 'Escolha uma opção').Trim()
    switch ($opcao) {
        '1' { Invoke-ReparoSistema }
        '2' { Invoke-VerificarDisco }
        '3' { Invoke-ResetWindowsUpdate }
        '4' { Invoke-ResetRede }
        '5' { Invoke-TrocarDns }
        '0' { break }
        default { Write-Host 'Opção inválida.' -ForegroundColor Red }
    }
    if ($opcao -ne '0') {
        Show-Final
        Read-Host 'Pressione ENTER para voltar ao menu' | Out-Null
    }
} while ($opcao -ne '0')
