#Requires -Version 5.1
<#
.SYNOPSIS
    Otimizador do Windows 10/11 - deixa o sistema mais leve, com menos processos
    em segundo plano, menos telemetria e menos "propaganda".

.DESCRIPTION
    Menu interativo com módulos independentes:
      - Limpeza de arquivos temporários e caches
      - Desativação de serviços desnecessários
      - Redução de telemetria / coleta de dados
      - Desativação de Widgets, Copilot, Bing na pesquisa, dicas e anúncios
      - Bloqueio de apps da Store rodando em segundo plano
      - Efeitos visuais voltados para desempenho
      - Ajustes de desempenho (svchost, energia, Game DVR, atraso de inicialização)
      - Remoção de aplicativos pré-instalados (bloatware)

    Segurança:
      - Cria um Ponto de Restauração do Sistema antes de alterar qualquer coisa.
      - Guarda o valor ORIGINAL de cada registro/serviço/tarefa alterado em
        %ProgramData%\OtimizadorWindows\backup.json. A opção [R] do menu (ou o
        parâmetro -Restaurar) desfaz tudo, exceto a remoção de aplicativos
        (que podem ser reinstalados pela Microsoft Store).

.PARAMETER Recomendado
    Aplica a otimização recomendada sem perguntas (não remove aplicativos).

.PARAMETER RemoverApps
    Usado junto com -Recomendado: também remove os aplicativos pré-instalados.

.PARAMETER Restaurar
    Desfaz as alterações registradas no backup.

.PARAMETER Simular
    Mostra o que seria feito, sem alterar nada.

.PARAMETER SemPontoRestauracao
    Não cria Ponto de Restauração do Sistema.

.EXAMPLE
    .\Otimizar-Windows.ps1
    .\Otimizar-Windows.ps1 -Recomendado
    .\Otimizar-Windows.ps1 -Recomendado -RemoverApps
    .\Otimizar-Windows.ps1 -Simular
    .\Otimizar-Windows.ps1 -Restaurar
#>
[CmdletBinding()]
param(
    [switch]$Recomendado,
    [switch]$RemoverApps,
    [switch]$Restaurar,
    [switch]$Simular,
    [switch]$SemPontoRestauracao
)

$ErrorActionPreference = 'Continue'
$Script:Versao = '1.0.0'

# ---------------------------------------------------------------------------
# Pré-requisitos: Windows, Windows PowerShell 5.1 e privilégios de administrador
# ---------------------------------------------------------------------------
if ($env:OS -ne 'Windows_NT') {
    Write-Host 'Este script só funciona no Windows.' -ForegroundColor Red
    exit 1
}

$identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
$ehAdmin = (New-Object Security.Principal.WindowsPrincipal($identidade)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$ehCore = $PSVersionTable.PSEdition -eq 'Core'

if (-not $ehAdmin -or $ehCore) {
    # Reabre no Windows PowerShell 5.1 (necessário para Appx e Ponto de Restauração)
    # e como administrador, repassando os mesmos parâmetros.
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($chave in $PSBoundParameters.Keys) { $argumentos += "-$chave" }
    $inicio = @{ FilePath = 'powershell.exe'; ArgumentList = $argumentos }
    if (-not $ehAdmin) { $inicio.Verb = 'RunAs' }
    try {
        Start-Process @inicio
    } catch {
        Write-Host 'É necessário executar como Administrador.' -ForegroundColor Red
        exit 1
    }
    exit
}

$Script:NaoInterativo = [bool]($Recomendado -or $Restaurar)
$Script:DataDir    = Join-Path $env:ProgramData 'OtimizadorWindows'
$Script:BackupFile = Join-Path $Script:DataDir 'backup.json'
$Script:LogFile    = Join-Path $Script:DataDir ('log-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
New-Item -Path $Script:DataDir -ItemType Directory -Force | Out-Null

# ---------------------------------------------------------------------------
# Listas configuráveis
# ---------------------------------------------------------------------------

# Serviços que podem ser DESATIVADOS com segurança na maioria dos PCs domésticos.
$Script:ServicosDesativar = [ordered]@{
    'DiagTrack'        = 'Telemetria (Experiências do Usuário Conectado)'
    'dmwappushservice' = 'Roteamento de mensagens push WAP (telemetria)'
    'RemoteRegistry'   = 'Registro Remoto'
    'RetailDemo'       = 'Modo de demonstração de loja'
    'Fax'              = 'Fax'
    'WMPNetworkSvc'    = 'Compartilhamento de rede do Windows Media Player'
}

# Serviços colocados em MANUAL: só iniciam quando algum programa precisar deles.
$Script:ServicosManual = [ordered]@{
    'MapsBroker'      = 'Gerenciador de mapas baixados'
    'TrkWks'          = 'Cliente de rastreamento de link distribuído'
    'PcaSvc'          = 'Assistente de compatibilidade de programas'
    'WpcMonSvc'       = 'Controle dos pais'
    'PhoneSvc'        = 'Serviço de telefonia'
    'SEMgrSvc'        = 'Pagamentos e NFC'
    'wisvc'           = 'Programa Windows Insider'
    'XblAuthManager'  = 'Xbox Live - autenticação'
    'XblGameSave'     = 'Xbox Live - salvamento de jogos'
    'XboxNetApiSvc'   = 'Xbox Live - rede'
    'XboxGipSvc'      = 'Acessórios Xbox'
    'diagnosticshub.standardcollector.service' = 'Coletor do hub de diagnóstico'
}

# Tarefas agendadas de telemetria / coleta de dados.
$Script:TarefasDesativar = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
    '\Microsoft\Windows\Autochk\Proxy'
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
    '\Microsoft\Windows\Feedback\Siuf\DmClient'
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
    '\Microsoft\Windows\Maps\MapsUpdateTask'
)

# Aplicativos pré-instalados (aceita curingas). Edite à vontade.
$Script:Bloatware = @(
    'Microsoft.BingNews'
    'Microsoft.BingWeather'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.People'
    'Microsoft.SkypeApp'
    'Microsoft.ZuneVideo'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.MixedReality.Portal'
    'Microsoft.Microsoft3DViewer'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.Wallet'
    'Microsoft.WindowsMaps'
    'Microsoft.Todos'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.549981C3F5F10'      # Cortana
    'MicrosoftTeams'               # Teams pessoal (não o corporativo)
    'Clipchamp.Clipchamp'
    '*CandyCrush*'
    '*BubbleWitch*'
    '*Disney*'
)

# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Mensagem,
        [ValidateSet('INFO', 'OK', 'AVISO', 'ERRO', 'TITULO')][string]$Nivel = 'INFO'
    )
    $cor = switch ($Nivel) {
        'OK'     { 'Green' }
        'AVISO'  { 'Yellow' }
        'ERRO'   { 'Red' }
        'TITULO' { 'Cyan' }
        default  { 'Gray' }
    }
    if ($Nivel -eq 'TITULO') { Write-Host '' }
    Write-Host $Mensagem -ForegroundColor $cor
    try {
        Add-Content -Path $Script:LogFile -Encoding UTF8 `
            -Value ('[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Nivel, $Mensagem)
    } catch { }
}

function Confirm-Acao {
    param([string]$Pergunta, [bool]$Padrao = $false)
    if ($Script:NaoInterativo) { return $Padrao }
    $sufixo = if ($Padrao) { '[S/n]' } else { '[s/N]' }
    $resposta = Read-Host "$Pergunta $sufixo"
    if ([string]::IsNullOrWhiteSpace($resposta)) { return $Padrao }
    return $resposta.Trim().ToUpper().StartsWith('S')
}

function Get-EspacoLivreGB {
    $disco = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    return [math]::Round($disco.FreeSpace / 1GB, 2)
}

# ---------------------------------------------------------------------------
# Backup (guarda apenas o estado ORIGINAL, mesmo rodando o script várias vezes)
# ---------------------------------------------------------------------------
$Script:Backup = New-Object System.Collections.ArrayList
$Script:BackupChaves = @{}

function Get-ChaveBackup($Entrada) { '{0}|{1}|{2}' -f $Entrada.Kind, $Entrada.Path, $Entrada.Name }

function Import-Backup {
    if (-not (Test-Path $Script:BackupFile)) { return }
    try {
        $dados = Get-Content -Path $Script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entrada in @($dados)) {
            [void]$Script:Backup.Add($entrada)
            $Script:BackupChaves[(Get-ChaveBackup $entrada)] = $true
        }
    } catch {
        Write-Log "Não foi possível ler o backup existente: $($_.Exception.Message)" 'AVISO'
    }
}

function Add-Backup([hashtable]$Entrada) {
    $chave = Get-ChaveBackup $Entrada
    if ($Script:BackupChaves.ContainsKey($chave)) { return }
    $Script:BackupChaves[$chave] = $true
    [void]$Script:Backup.Add([pscustomobject]$Entrada)
}

function Save-Backup {
    if ($Simular -or $Script:Backup.Count -eq 0) { return }
    ConvertTo-Json -InputObject $Script:Backup.ToArray() -Depth 5 |
        Set-Content -Path $Script:BackupFile -Encoding UTF8
}

function Backup-ValorRegistro([string]$Path, [string]$Name) {
    $entrada = @{ Kind = 'Registry'; Path = $Path; Name = $Name; Existed = $false; Value = $null; Type = $null }
    if (Test-Path $Path) {
        $item = Get-Item -Path $Path
        if ($item.GetValueNames() -contains $Name) {
            $entrada.Existed = $true
            $entrada.Value = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $entrada.Type = $item.GetValueKind($Name).ToString()
        }
    }
    Add-Backup $entrada
}

function Set-Reg {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')]
        [string]$Type = 'DWord'
    )
    if ($Simular) {
        Write-Log "  [simulação] $Path\$Name = $Value"
        return
    }
    try {
        Backup-ValorRegistro $Path $Name
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch {
        Write-Log "  Falha ao gravar $Path\$Name : $($_.Exception.Message)" 'ERRO'
    }
}

function Set-InicioServico {
    param([string]$Nome, [string]$Descricao, [ValidateSet('Disabled', 'Manual')][string]$Modo)

    $servico = Get-Service -Name $Nome -ErrorAction SilentlyContinue
    if (-not $servico) { Write-Log "  - $Descricao ($Nome): não existe neste PC"; return }

    $caminho = "HKLM:\SYSTEM\CurrentControlSet\Services\$Nome"
    $atual = (Get-ItemProperty -Path $caminho -Name Start -ErrorAction SilentlyContinue).Start
    $desejado = if ($Modo -eq 'Disabled') { 4 } else { 3 }
    # Nunca "promove" um serviço: se já está manual/desativado, mantém.
    if ($null -ne $atual -and $atual -ge $desejado) {
        Write-Log "  - $Descricao ($Nome): já está otimizado"
        return
    }
    if ($Simular) { Write-Log "  [simulação] $Descricao ($Nome) -> $Modo"; return }

    try {
        Backup-ValorRegistro $caminho 'Start'
        Set-Service -Name $Nome -StartupType $Modo -ErrorAction Stop
        if ($Modo -eq 'Disabled' -and $servico.Status -eq 'Running') {
            Stop-Service -Name $Nome -Force -ErrorAction SilentlyContinue
        }
        $texto = if ($Modo -eq 'Disabled') { 'desativado' } else { 'manual' }
        Write-Log "  + $Descricao ($Nome) -> $texto" 'OK'
    } catch {
        Write-Log "  ! $Descricao ($Nome): $($_.Exception.Message)" 'AVISO'
    }
}

function Disable-Tarefa([string]$CaminhoCompleto) {
    $pasta = (Split-Path $CaminhoCompleto -Parent) + '\'
    $nome = Split-Path $CaminhoCompleto -Leaf
    $tarefa = Get-ScheduledTask -TaskPath $pasta -TaskName $nome -ErrorAction SilentlyContinue
    if (-not $tarefa) { return }
    if ($tarefa.State -eq 'Disabled') { Write-Log "  - Tarefa ${nome}: já desativada"; return }
    if ($Simular) { Write-Log "  [simulação] desativar tarefa $CaminhoCompleto"; return }
    try {
        Add-Backup @{ Kind = 'Task'; Path = $pasta; Name = $nome; Value = 'Enabled' }
        Disable-ScheduledTask -TaskPath $pasta -TaskName $nome -ErrorAction Stop | Out-Null
        Write-Log "  + Tarefa desativada: $nome" 'OK'
    } catch {
        Write-Log "  ! Tarefa $nome : $($_.Exception.Message)" 'AVISO'
    }
}

function Remove-ConteudoPasta([string]$Pasta) {
    if (-not (Test-Path $Pasta)) { return }
    if ($Simular) { Write-Log "  [simulação] limpar $Pasta"; return }
    Get-ChildItem -Path $Pasta -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "  + Limpo: $Pasta" 'OK'
}

# ---------------------------------------------------------------------------
# Ponto de Restauração
# ---------------------------------------------------------------------------
function New-PontoRestauracao {
    if ($SemPontoRestauracao -or $Simular -or $Script:PontoCriado) { return }
    Write-Log 'Criando Ponto de Restauração do Sistema...' 'TITULO'
    $chave = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $frequenciaOriginal = (Get-ItemProperty -Path $chave -Name SystemRestorePointCreationFrequency `
        -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Por padrão o Windows só permite 1 ponto a cada 24h; libera temporariamente.
        Set-ItemProperty -Path $chave -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
        Checkpoint-Computer -Description 'Antes do Otimizador Windows' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Ponto de Restauração criado.' 'OK'
        $Script:PontoCriado = $true
    } catch {
        Write-Log "Não foi possível criar o Ponto de Restauração: $($_.Exception.Message)" 'AVISO'
        if (-not (Confirm-Acao 'Continuar mesmo assim?' $true)) { exit 1 }
    } finally {
        if ($null -eq $frequenciaOriginal) {
            Remove-ItemProperty -Path $chave -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $chave -Name SystemRestorePointCreationFrequency -Value $frequenciaOriginal -Type DWord
        }
    }
}

# ---------------------------------------------------------------------------
# Módulos de otimização
# ---------------------------------------------------------------------------
function Invoke-Limpeza {
    Write-Log '[Limpeza] Removendo arquivos temporários e caches' 'TITULO'
    $antes = Get-EspacoLivreGB

    Remove-ConteudoPasta $env:TEMP
    Remove-ConteudoPasta (Join-Path $env:SystemRoot 'Temp')
    Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } |
        Where-Object { $_ -ne $env:TEMP } |
        ForEach-Object { Remove-ConteudoPasta $_ }
    Remove-ConteudoPasta (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')
    Remove-ConteudoPasta (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')

    # Cache de downloads do Windows Update
    if (-not $Simular) {
        $servicosWU = @('wuauserv', 'bits')
        Stop-Service -Name $servicosWU -Force -ErrorAction SilentlyContinue
        Remove-ConteudoPasta (Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
        Start-Service -Name $servicosWU -ErrorAction SilentlyContinue
    } else {
        Remove-ConteudoPasta (Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
    }

    # Cache de Otimização de Entrega
    if ((Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) -and -not $Simular) {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
        Write-Log '  + Cache de Otimização de Entrega limpo' 'OK'
    }

    if (-not $Simular) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log '  + Lixeira esvaziada' 'OK'
    }

    if (Confirm-Acao 'Executar limpeza de componentes do Windows (DISM)? Pode levar vários minutos.' $false) {
        if ($Simular) {
            Write-Log '  [simulação] DISM /Online /Cleanup-Image /StartComponentCleanup'
        } else {
            Write-Log '  Executando DISM, aguarde...'
            & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet /NoRestart
            Write-Log '  + Limpeza de componentes concluída' 'OK'
        }
    }

    $depois = Get-EspacoLivreGB
    Write-Log ("Espaço livre em {0}: {1} GB -> {2} GB (liberado: {3} GB)" -f `
        $env:SystemDrive, $antes, $depois, [math]::Round($depois - $antes, 2)) 'OK'
}

function Invoke-Servicos {
    Write-Log '[Serviços] Desativando serviços desnecessários' 'TITULO'
    foreach ($nome in $Script:ServicosDesativar.Keys) {
        Set-InicioServico -Nome $nome -Descricao $Script:ServicosDesativar[$nome] -Modo Disabled
    }
    Write-Log '[Serviços] Colocando serviços pouco usados em modo manual' 'TITULO'
    foreach ($nome in $Script:ServicosManual.Keys) {
        Set-InicioServico -Nome $nome -Descricao $Script:ServicosManual[$nome] -Modo Manual
    }

    # Opcionais: dependem do uso de cada pessoa. No modo automático não são alterados.
    Write-Log '[Serviços] Opcionais' 'TITULO'
    if (Confirm-Acao 'Você NÃO usa impressora nem "Imprimir em PDF"? Desativar o Spooler de impressão?' $false) {
        Set-InicioServico -Nome 'Spooler' -Descricao 'Spooler de impressão' -Modo Disabled
    }
    if (Confirm-Acao 'Desativar a indexação de pesquisa (Windows Search)? Economiza CPU/disco, mas a busca de arquivos fica mais lenta.' $false) {
        Set-InicioServico -Nome 'WSearch' -Descricao 'Windows Search (indexação)' -Modo Disabled
    }
    if (Confirm-Acao 'Desativar o SysMain (Superfetch)? Recomendado apenas se o Windows estiver em SSD e com pouca RAM.' $false) {
        Set-InicioServico -Nome 'SysMain' -Descricao 'SysMain (Superfetch)' -Modo Disabled
    }
}

function Invoke-Privacidade {
    Write-Log '[Privacidade] Reduzindo telemetria e coleta de dados' 'TITULO'
    $dc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    Set-Reg $dc 'AllowTelemetry' 0
    Set-Reg $dc 'DoNotShowFeedbackNotifications' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0

    # Histórico de atividades
    $sys = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    Set-Reg $sys 'EnableActivityFeed' 0
    Set-Reg $sys 'PublishUserActivities' 0
    Set-Reg $sys 'UploadUserActivities' 0

    # Relatório de erros do Windows
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1

    # Recall / análise de dados por IA (Windows 11 24H2+)
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Write-Log '  + Políticas de privacidade aplicadas' 'OK'

    Write-Log '[Privacidade] Desativando tarefas agendadas de telemetria' 'TITULO'
    foreach ($tarefa in $Script:TarefasDesativar) { Disable-Tarefa $tarefa }
}

function Invoke-RecursosExtras {
    Write-Log '[Recursos] Desativando Widgets, Copilot, Bing, dicas e anúncios' 'TITULO'

    # Widgets / Notícias e interesses
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0

    # Copilot
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1

    # Cortana e resultados do Bing no menu Iniciar
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0

    # Instalação silenciosa de apps sugeridos, dicas e anúncios
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($valor in @(
            'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
            'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'SubscribedContent-338388Enabled',
            'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled',
            'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled')) {
        Set-Reg $cdm $valor 0
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0

    # Microsoft Edge: impede que fique rodando em segundo plano após ser fechado
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $edge 'StartupBoostEnabled' 0
    Set-Reg $edge 'BackgroundModeEnabled' 0
    Write-Log '  + Recursos desnecessários desativados' 'OK'
}

function Invoke-AppsSegundoPlano {
    Write-Log '[Segundo plano] Bloqueando apps da Store em segundo plano' 'TITULO'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
    Write-Log '  + Apps em segundo plano bloqueados (podem ser liberados individualmente em Configurações)' 'OK'
}

function Invoke-EfeitosVisuais {
    Write-Log '[Visual] Ajustando efeitos visuais para desempenho' 'TITULO'
    # 3 = personalizado. Mantém a suavização de fontes e as miniaturas.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
    Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Write-Log '  + Animações e transparência desativadas' 'OK'
}

function Invoke-Desempenho {
    Write-Log '[Desempenho] Ajustes de sistema' 'TITULO'

    # Agrupa serviços em menos processos svchost.exe (o Windows separa cada
    # serviço em um processo quando há mais de 3,5 GB de RAM).
    $ramKB = [int]((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1KB)
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' $ramKB
    Write-Log '  + Serviços agrupados em menos processos svchost.exe (vale após reiniciar)' 'OK'

    # Prioridade para programas em primeiro plano / multimídia
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-Reg $mm 'SystemResponsiveness' 10
    Set-Reg $mm 'NetworkThrottlingIndex' 0xffffffff

    # Remove o atraso artificial dos programas de inicialização
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0

    # Game DVR (gravação em segundo plano) desligado; Modo de Jogo mantido
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Write-Log '  + Prioridade de CPU, atraso de inicialização e Game DVR ajustados' 'OK'

    # Plano de energia
    $notebook = [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    $aplicarEnergia = if ($notebook) {
        Confirm-Acao 'Notebook detectado. Ativar plano "Alto desempenho"? (gasta mais bateria)' $false
    } else {
        Confirm-Acao 'Ativar plano de energia "Alto desempenho"?' $true
    }
    if ($aplicarEnergia) { Set-PlanoAltoDesempenho }
}

function Set-PlanoAltoDesempenho {
    $regexGuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $altoDesempenho = '8c5e7fda-e8bf-4a96-9a85-cf2dd4252f43'
    $atual = [regex]::Match((& powercfg.exe /getactivescheme | Out-String), $regexGuid).Value
    if ($atual -eq $altoDesempenho) { Write-Log '  - Plano Alto desempenho já está ativo'; return }
    if ($Simular) { Write-Log '  [simulação] ativar plano Alto desempenho'; return }

    if ($atual) { Add-Backup @{ Kind = 'PowerPlan'; Path = 'ativo'; Name = 'plano'; Value = $atual } }
    & powercfg.exe /setactive $altoDesempenho 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Em alguns PCs o plano está oculto; cria uma cópia dele.
        $saida = & powercfg.exe -duplicatescheme $altoDesempenho | Out-String
        $novo = [regex]::Match($saida, $regexGuid).Value
        if ($novo) { & powercfg.exe /setactive $novo }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Log '  + Plano de energia Alto desempenho ativado' 'OK'
    } else {
        Write-Log '  ! Não foi possível ativar o plano Alto desempenho' 'AVISO'
    }
}

function Invoke-RemoverBloatware {
    param([bool]$SemPerguntar = $false)
    Write-Log '[Apps] Procurando aplicativos pré-instalados' 'TITULO'

    $instalados = @(foreach ($padrao in $Script:Bloatware) {
            Get-AppxPackage -AllUsers -Name $padrao -ErrorAction SilentlyContinue
        }) | Sort-Object PackageFullName -Unique
    $provisionados = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object {
            $nome = $_.DisplayName
            @($Script:Bloatware | Where-Object { $nome -like $_ }).Count -gt 0
        })

    $nomes = @(@($instalados | ForEach-Object { $_.Name }) + @($provisionados | ForEach-Object { $_.DisplayName }) |
        Sort-Object -Unique)
    if ($nomes.Count -eq 0) { Write-Log '  Nenhum aplicativo da lista encontrado.' 'OK'; return }

    Write-Log '  Aplicativos encontrados:'
    $nomes | ForEach-Object { Write-Log "    - $_" }
    if ($Simular) { Write-Log '  [simulação] nada foi removido'; return }
    if (-not $SemPerguntar -and -not (Confirm-Acao 'Remover estes aplicativos? (podem ser reinstalados pela Microsoft Store)' $false)) {
        return
    }

    foreach ($pacote in $instalados) {
        try {
            Remove-AppxPackage -Package $pacote.PackageFullName -AllUsers -ErrorAction Stop
            Write-Log "  + Removido: $($pacote.Name)" 'OK'
        } catch {
            Write-Log "  ! $($pacote.Name): $($_.Exception.Message)" 'AVISO'
        }
    }
    foreach ($pacote in $provisionados) {
        # Impede que o app volte a ser instalado para novos usuários
        Remove-AppxProvisionedPackage -Online -PackageName $pacote.PackageName -ErrorAction SilentlyContinue | Out-Null
    }
}

function Show-Inicializacao {
    Write-Log '[Inicialização] Programas que iniciam com o Windows' 'TITULO'
    Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue |
        Select-Object Name, Location, Command |
        Format-Table -AutoSize -Wrap | Out-Host
    Write-Host 'Dica: desative os que não usa em Gerenciador de Tarefas > Aplicativos de inicialização.' -ForegroundColor Yellow
    if (Confirm-Acao 'Abrir o Gerenciador de Tarefas agora?' $false) { Start-Process taskmgr.exe -ArgumentList '/0 /startup' }
}

function Invoke-Recomendado {
    Invoke-Limpeza
    Invoke-Servicos
    Invoke-Privacidade
    Invoke-RecursosExtras
    Invoke-AppsSegundoPlano
    Invoke-EfeitosVisuais
    Invoke-Desempenho
}

# ---------------------------------------------------------------------------
# Restauração
# ---------------------------------------------------------------------------
function ConvertTo-ValorRegistro($Entrada) {
    switch ($Entrada.Type) {
        'Binary'      { return [byte[]]@($Entrada.Value) }
        'MultiString' { return [string[]]@($Entrada.Value) }
        'DWord'       { return [int]$Entrada.Value }
        'QWord'       { return [long]$Entrada.Value }
        default       { return [string]$Entrada.Value }
    }
}

function Invoke-Restaurar {
    Write-Log '[Restaurar] Revertendo alterações' 'TITULO'
    if (-not (Test-Path $Script:BackupFile)) {
        Write-Log 'Nenhum backup encontrado. Nada para restaurar.' 'AVISO'
        Write-Log 'Você ainda pode usar o Ponto de Restauração "Antes do Otimizador Windows" (rstrui.exe).'
        return
    }
    $entradas = @(Get-Content -Path $Script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    [array]::Reverse($entradas)
    $tiposServico = @{ 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }

    foreach ($e in $entradas) {
        try {
            switch ($e.Kind) {
                'Registry' {
                    if ($e.Existed) {
                        if (-not (Test-Path $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                        New-ItemProperty -Path $e.Path -Name $e.Name -Value (ConvertTo-ValorRegistro $e) `
                            -PropertyType $e.Type -Force | Out-Null
                        # Serviço: aplica também no gerenciador de serviços
                        if ($e.Name -eq 'Start' -and $e.Path -match 'Services\\([^\\]+)$' -and
                            $tiposServico.ContainsKey([int]$e.Value)) {
                            Set-Service -Name $Matches[1] -StartupType $tiposServico[[int]$e.Value] -ErrorAction SilentlyContinue
                        }
                    } else {
                        Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                    }
                }
                'Task' {
                    Enable-ScheduledTask -TaskPath $e.Path -TaskName $e.Name -ErrorAction Stop | Out-Null
                }
                'PowerPlan' {
                    & powercfg.exe /setactive $e.Value
                }
            }
        } catch {
            Write-Log "  ! $($e.Kind) $($e.Path)\$($e.Name): $($_.Exception.Message)" 'AVISO'
        }
    }
    $arquivado = Join-Path $Script:DataDir ('backup-restaurado-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    Move-Item -Path $Script:BackupFile -Destination $arquivado -Force
    $Script:Backup.Clear()
    $Script:BackupChaves.Clear()
    Write-Log "Configurações originais restauradas ($($entradas.Count) itens). Reinicie o computador." 'OK'
}

# ---------------------------------------------------------------------------
# Interface
# ---------------------------------------------------------------------------
function Show-Cabecalho {
    Clear-Host
    $so = Get-CimInstance -ClassName Win32_OperatingSystem
    $ramGB = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $processos = @(Get-Process).Count
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host "              OTIMIZADOR DO WINDOWS  v$Script:Versao" -ForegroundColor Cyan
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host (" Sistema   : {0} (build {1})" -f $so.Caption, $so.BuildNumber)
    Write-Host (" Memória   : {0} GB  |  Processos em execução: {1}" -f $ramGB, $processos)
    if ($Simular) { Write-Host ' MODO SIMULAÇÃO: nenhuma alteração será feita.' -ForegroundColor Yellow }
    Write-Host '-----------------------------------------------------------------' -ForegroundColor Cyan
}

function Show-Menu {
    Write-Host '  [1]  Otimização RECOMENDADA (itens 2 a 8)' -ForegroundColor Green
    Write-Host '  [2]  Limpeza de arquivos temporários'
    Write-Host '  [3]  Desativar serviços desnecessários'
    Write-Host '  [4]  Telemetria e privacidade'
    Write-Host '  [5]  Desativar Widgets, Copilot, Bing, dicas e anúncios'
    Write-Host '  [6]  Bloquear apps em segundo plano'
    Write-Host '  [7]  Efeitos visuais para desempenho'
    Write-Host '  [8]  Ajustes de desempenho (energia, svchost, jogos)'
    Write-Host '  [9]  Remover aplicativos pré-instalados (bloatware)'
    Write-Host '  [10] Ver programas que iniciam com o Windows'
    Write-Host '  [R]  Restaurar configurações originais' -ForegroundColor Yellow
    Write-Host '  [0]  Sair'
    Write-Host '-----------------------------------------------------------------' -ForegroundColor Cyan
}

function Invoke-ComPontoRestauracao([scriptblock]$Acao) {
    New-PontoRestauracao
    & $Acao
    Save-Backup
}

function Show-Final {
    Write-Host ''
    Write-Log "Log salvo em: $Script:LogFile" 'OK'
    if (-not $Simular) {
        Write-Host 'Reinicie o computador para que todas as alterações tenham efeito.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Execução
# ---------------------------------------------------------------------------
Import-Backup
Write-Log "Otimizador do Windows v$Script:Versao iniciado"

if ($Restaurar) {
    Invoke-Restaurar
    Show-Final
    exit
}

if ($Recomendado) {
    Invoke-ComPontoRestauracao { Invoke-Recomendado }
    if ($RemoverApps) {
        Invoke-RemoverBloatware -SemPerguntar $true
    }
    Show-Final
    exit
}

do {
    Show-Cabecalho
    Show-Menu
    $opcao = (Read-Host 'Escolha uma opção').Trim().ToUpper()
    switch ($opcao) {
        '1'  { Invoke-ComPontoRestauracao { Invoke-Recomendado } }
        '2'  { Invoke-Limpeza }
        '3'  { Invoke-ComPontoRestauracao { Invoke-Servicos } }
        '4'  { Invoke-ComPontoRestauracao { Invoke-Privacidade } }
        '5'  { Invoke-ComPontoRestauracao { Invoke-RecursosExtras } }
        '6'  { Invoke-ComPontoRestauracao { Invoke-AppsSegundoPlano } }
        '7'  { Invoke-ComPontoRestauracao { Invoke-EfeitosVisuais } }
        '8'  { Invoke-ComPontoRestauracao { Invoke-Desempenho } }
        '9'  { Invoke-ComPontoRestauracao { Invoke-RemoverBloatware } }
        '10' { Show-Inicializacao }
        'R'  {
            if (Confirm-Acao 'Restaurar todas as configurações alteradas por este script?' $false) { Invoke-Restaurar }
        }
        '0'  { break }
        default { Write-Host 'Opção inválida.' -ForegroundColor Red }
    }
    if ($opcao -ne '0') {
        Show-Final
        Read-Host 'Pressione ENTER para voltar ao menu' | Out-Null
    }
} while ($opcao -ne '0')
