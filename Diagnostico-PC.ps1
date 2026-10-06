#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnóstico do PC: gera um relatório HTML com hardware, saúde do disco,
    uso de memória, programas pesados e recomendações. Não altera nada.

.DESCRIPTION
    Pensado para técnicos: rode no PC do cliente e mostre o relatório.
    O relatório é salvo na Área de Trabalho (ou na pasta indicada em -Pasta)
    e aberto no navegador.

.PARAMETER Pasta
    Pasta onde salvar o relatório. Padrão: Área de Trabalho.

.PARAMETER NaoAbrir
    Não abre o relatório no navegador ao final.

.EXAMPLE
    .\Diagnostico-PC.ps1
    .\Diagnostico-PC.ps1 -Pasta E:\Relatorios
#>
[CmdletBinding()]
param(
    [string]$Pasta,
    [switch]$NaoAbrir
)

$ErrorActionPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT') { Write-Host 'Este script só funciona no Windows.' -ForegroundColor Red; exit 1 }

$ehAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($chave in $PSBoundParameters.Keys) {
        $valor = $PSBoundParameters[$chave]
        if ($valor -is [switch]) { $argumentos += "-$chave" } else { $argumentos += "-$chave", "`"$valor`"" }
    }
    $inicio = @{ FilePath = 'powershell.exe'; ArgumentList = $argumentos }
    if (-not $ehAdmin) { $inicio.Verb = 'RunAs' }
    Start-Process @inicio
    exit
}

if (-not $Pasta) { $Pasta = [Environment]::GetFolderPath('Desktop') }
New-Item -Path $Pasta -ItemType Directory -Force | Out-Null

function Write-Etapa([string]$Texto) { Write-Host "  > $Texto" -ForegroundColor Gray }
function ConvertTo-Html2([object]$Texto) { [System.Net.WebUtility]::HtmlEncode([string]$Texto) }
function Format-GB([double]$Bytes) { '{0:N1} GB' -f ($Bytes / 1GB) }

$recomendacoes = New-Object System.Collections.ArrayList
# Gravidade: 'critico', 'alerta' ou 'info'
function Add-Recomendacao([string]$Gravidade, [string]$Texto) {
    [void]$recomendacoes.Add([pscustomobject]@{ Gravidade = $Gravidade; Texto = $Texto })
}

Write-Host ''
Write-Host '=== DIAGNÓSTICO DO PC ===' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Sistema
# ---------------------------------------------------------------------------
Write-Etapa 'Sistema'
$so = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$versaoExibicao = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
$ligadoHa = (Get-Date) - $so.LastBootUpTime

$sistema = [ordered]@{
    'Computador'          = $env:COMPUTERNAME
    'Fabricante / Modelo' = "$($cs.Manufacturer) $($cs.Model)"
    'Nº de série'         = $bios.SerialNumber
    'Windows'             = "$($so.Caption) $versaoExibicao (build $($so.BuildNumber))"
    'Instalado em'        = $so.InstallDate.ToString('dd/MM/yyyy')
    'Ligado há'           = '{0} dias e {1} h' -f $ligadoHa.Days, $ligadoHa.Hours
}

if ($so.Caption -match 'Windows 10') {
    Add-Recomendacao 'alerta' 'Windows 10 sem suporte da Microsoft desde 14/10/2025. Avaliar atualização para o Windows 11 (se o hardware for compatível).'
} elseif ($so.Caption -match 'Windows (7|8)') {
    Add-Recomendacao 'critico' 'Versão do Windows sem suporte e sem atualizações de segurança.'
}
if ($ligadoHa.TotalDays -ge 7) {
    Add-Recomendacao 'info' "PC ligado há $($ligadoHa.Days) dias sem reiniciar. Reiniciar periodicamente libera memória e aplica atualizações."
}

# ---------------------------------------------------------------------------
# Processador e memória
# ---------------------------------------------------------------------------
Write-Etapa 'Processador e memória'
$cpu = @(Get-CimInstance Win32_Processor)[0]
$ramTotal = [double]$cs.TotalPhysicalMemory
$ramLivre = [double]$so.FreePhysicalMemory * 1KB
$ramUsoPct = [math]::Round((1 - $ramLivre / $ramTotal) * 100)
$pentes = @(Get-CimInstance Win32_PhysicalMemory)
$slotsTotal = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum
$tiposMemoria = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5' }
$tipoMemoria = if ($pentes.Count) { $tiposMemoria[[int]$pentes[0].SMBIOSMemoryType] } else { '' }

$hardware = [ordered]@{
    'Processador'      = '{0} ({1} núcleos / {2} threads)' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors
    'Uso da CPU agora' = "$($cpu.LoadPercentage)%"
    'Memória RAM'      = '{0} {1} - em uso: {2}%' -f (Format-GB $ramTotal), $tipoMemoria, $ramUsoPct
    'Pentes de memória' = (($pentes | ForEach-Object { '{0} {1} MHz' -f (Format-GB $_.Capacity), $_.ConfiguredClockSpeed }) -join ' + ')
    'Slots de memória' = if ($slotsTotal) { '{0} usados de {1}' -f $pentes.Count, $slotsTotal } else { "$($pentes.Count) usados" }
}

$ramGB = [math]::Round($ramTotal / 1GB)
$slotLivre = $slotsTotal -and $pentes.Count -lt $slotsTotal
if ($ramGB -lt 8) {
    $texto = "Apenas $ramGB GB de RAM. Recomendado no mínimo 8 GB para Windows 10/11."
    if ($slotLivre) { $texto += ' Há slot livre: basta adicionar um pente.' }
    else { $texto += ' Não há slot livre: será preciso trocar o pente por um maior.' }
    Add-Recomendacao 'alerta' $texto
}
if ($ramUsoPct -ge 85) {
    Add-Recomendacao 'alerta' "Memória RAM em $ramUsoPct% de uso. Feche programas pesados ou aumente a RAM."
}

# ---------------------------------------------------------------------------
# Discos
# ---------------------------------------------------------------------------
Write-Etapa 'Discos e saúde (SMART)'
$numeroDiscoSistema = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') | Get-Disk).Number
$falhaPrevista = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus |
        Where-Object { $_.PredictFailure })

$discos = foreach ($d in Get-PhysicalDisk | Sort-Object DeviceId) {
    $tipo = switch ($d.MediaType) {
        'HDD' { 'HD mecânico' }
        'SSD' { 'SSD' }
        default { if ($d.SpindleSpeed -gt 0 -and $d.SpindleSpeed -lt [uint32]::MaxValue) { 'HD mecânico' } elseif ($d.BusType -eq 'NVMe') { 'SSD' } else { 'Desconhecido' } }
    }
    $conf = $d | Get-StorageReliabilityCounter
    $ehSistema = [string]$d.DeviceId -eq [string]$numeroDiscoSistema

    $saude = switch ([string]$d.HealthStatus) {
        'Healthy'   { 'Boa' }
        'Warning'   { 'ATENÇÃO' }
        'Unhealthy' { 'RUIM' }
        default     { [string]$d.HealthStatus }
    }
    if ($saude -ne 'Boa') {
        Add-Recomendacao 'critico' "Disco '$($d.FriendlyName)' com saúde '$saude'. FAÇA BACKUP DOS DADOS e substitua o disco."
    }
    if ($conf.Wear -ge 80) {
        Add-Recomendacao 'alerta' "SSD '$($d.FriendlyName)' com $($conf.Wear)% de desgaste. Planejar a troca."
    }
    if ($conf.Temperature -ge 55) {
        Add-Recomendacao 'alerta' "Disco '$($d.FriendlyName)' a $($conf.Temperature) °C. Verificar ventilação/limpeza."
    }
    if ($ehSistema -and $tipo -eq 'HD mecânico') {
        Add-Recomendacao 'critico' 'Windows instalado em HD mecânico: é a principal causa de lentidão. Trocar por SSD (SATA ou NVMe) é o maior ganho de desempenho possível, muito acima de qualquer otimização.'
    }

    [pscustomobject]@{
        'Disco'        = $d.FriendlyName + $(if ($ehSistema) { ' (Windows)' } else { '' })
        'Tipo'         = "$tipo ($($d.BusType))"
        'Tamanho'      = Format-GB $d.Size
        'Saúde'        = $saude
        'Temperatura'  = if ($conf.Temperature) { "$($conf.Temperature) °C" } else { '-' }
        'Horas ligado' = if ($conf.PowerOnHours) { '{0:N0} h' -f $conf.PowerOnHours } else { '-' }
        'Desgaste'     = if ($null -ne $conf.Wear -and $tipo -eq 'SSD') { "$($conf.Wear)%" } else { '-' }
        'Erros leitura' = if ($null -ne $conf.ReadErrorsTotal) { $conf.ReadErrorsTotal } else { '-' }
    }
}
if ($falhaPrevista.Count -gt 0) {
    Add-Recomendacao 'critico' 'O SMART de um disco está PREVENDO FALHA. Faça backup imediatamente e substitua o disco.'
}

$volumes = foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter) {
    $livrePct = if ($v.Size) { [math]::Round($v.SizeRemaining / $v.Size * 100) } else { 0 }
    if ($livrePct -lt 15) {
        Add-Recomendacao 'alerta' "Unidade $($v.DriveLetter): com apenas $livrePct% livre. Pouco espaço deixa o Windows lento e impede atualizações."
    }
    [pscustomobject]@{
        'Unidade' = "$($v.DriveLetter):"
        'Nome'    = $v.FileSystemLabel
        'Tamanho' = Format-GB $v.Size
        'Livre'   = '{0} ({1}%)' -f (Format-GB $v.SizeRemaining), $livrePct
    }
}

# Erros de disco no Log de Eventos (sinal clássico de HD morrendo)
$errosDisco = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-30)
    } | Where-Object {
        ($_.ProviderName -eq 'disk') -or
        ($_.ProviderName -match '^(Microsoft-Windows-)?Ntfs$|^volmgr$' -and $_.Level -le 2)
    })
if ($errosDisco.Count -ge 5) {
    Add-Recomendacao 'critico' "$($errosDisco.Count) erros/avisos de disco nos últimos 30 dias no Log de Eventos. Possível falha do disco: faça backup e teste com CrystalDiskInfo."
}

# ---------------------------------------------------------------------------
# Vídeo, bateria, antivírus
# ---------------------------------------------------------------------------
Write-Etapa 'Vídeo, bateria e antivírus'
$videos = @(Get-CimInstance Win32_VideoController)
$textoVideo = ($videos | ForEach-Object {
        $data = if ($_.DriverDate) { $_.DriverDate.ToString('dd/MM/yyyy') } else { '?' }
        '{0} (driver {1} de {2})' -f $_.Name, $_.DriverVersion, $data
    }) -join '<br>'
if ($videos | Where-Object { $_.Name -match 'Basic Display|Básico|VGA' }) {
    Add-Recomendacao 'alerta' 'Placa de vídeo sem driver (usando o "Adaptador de Vídeo Básico"). Instale o driver do fabricante.'
}
$hardware['Vídeo'] = $textoVideo

$bateria = Get-CimInstance Win32_Battery
$relatorioBateria = $null
if ($bateria) {
    $hardware['Bateria'] = "$($bateria.EstimatedChargeRemaining)% de carga"
    $relatorioBateria = Join-Path $Pasta ("Bateria-{0}.html" -f $env:COMPUTERNAME)
    & powercfg.exe /batteryreport /output $relatorioBateria | Out-Null
    $full = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1
    $design = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object -First 1
    if ($full.FullChargedCapacity -and $design.DesignedCapacity) {
        $saudeBat = [math]::Round($full.FullChargedCapacity / $design.DesignedCapacity * 100)
        $hardware['Bateria'] += " - saúde: $saudeBat% da capacidade original"
        if ($saudeBat -lt 60) {
            Add-Recomendacao 'alerta' "Bateria com apenas $saudeBat% da capacidade original. Recomendar troca."
        }
    }
}

$antivirus = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct |
        Select-Object -ExpandProperty displayName -Unique)
$terceiros = @($antivirus | Where-Object { $_ -notmatch 'Windows Defender|Microsoft Defender' })
$hardware['Antivírus'] = if ($antivirus) { $antivirus -join ', ' } else { 'Nenhum detectado' }
if ($terceiros.Count -gt 1) {
    Add-Recomendacao 'critico' "Mais de um antivírus instalado ($($terceiros -join ', ')). Eles brigam entre si e deixam o PC muito lento: mantenha só um."
}
if (-not $antivirus) {
    Add-Recomendacao 'critico' 'Nenhum antivírus detectado. Ative o Microsoft Defender.'
}

# ---------------------------------------------------------------------------
# Processos e inicialização
# ---------------------------------------------------------------------------
Write-Etapa 'Processos e inicialização'
$todosProcessos = @(Get-Process)
$topRam = $todosProcessos | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{
        'Programa'  = $_.Name
        'Processos' = $_.Count
        'Memória'   = '{0:N0} MB' -f (($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
        '_bytes'    = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum
    }
} | Sort-Object _bytes -Descending | Select-Object -First 10 'Programa', 'Processos', 'Memória'

# Classe de desempenho não traduzida (Get-Counter muda de nome conforme o idioma)
$nucleos = [int]$cpu.NumberOfLogicalProcessors
$topCpu = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
    Where-Object { $_.Name -notin '_Total', 'Idle' -and $_.PercentProcessorTime -gt 0 } |
    Sort-Object PercentProcessorTime -Descending | Select-Object -First 8 |
    ForEach-Object {
        [pscustomobject]@{
            'Programa' = $_.Name -replace '#\d+$', ''
            'CPU'      = '{0:N0}%' -f ($_.PercentProcessorTime / $nucleos)
        }
    }

$inicializacao = @(Get-CimInstance Win32_StartupCommand | Select-Object @{ n = 'Programa'; e = { $_.Name } },
    @{ n = 'Local'; e = { $_.Location } }, @{ n = 'Comando'; e = { $_.Command } })
if ($inicializacao.Count -gt 8) {
    Add-Recomendacao 'alerta' "$($inicializacao.Count) programas iniciam junto com o Windows. Desative os desnecessários (Gerenciador de Tarefas > Inicialização)."
}
$sistema['Processos em execução'] = $todosProcessos.Count

# Erros críticos do sistema (telas azuis, desligamentos inesperados)
$errosCriticos = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; Level = 1; StartTime = (Get-Date).AddDays(-30)
    })
if ($errosCriticos.Count -gt 0) {
    $sistema['Erros críticos (30 dias)'] = $errosCriticos.Count
    if ($errosCriticos.Count -ge 3) {
        Add-Recomendacao 'alerta' "$($errosCriticos.Count) erros críticos nos últimos 30 dias (desligamentos inesperados ou telas azuis). Verificar fonte, temperatura, memória e drivers."
    }
}

if ($recomendacoes.Count -eq 0) {
    Add-Recomendacao 'info' 'Nenhum problema importante encontrado.'
}

# ---------------------------------------------------------------------------
# Relatório HTML
# ---------------------------------------------------------------------------
Write-Etapa 'Gerando relatório'

function ConvertTo-TabelaChaveValor($Dados) {
    $linhas = foreach ($k in $Dados.Keys) {
        # Valores de vídeo já vêm com <br>; o resto é escapado.
        $v = if ($k -eq 'Vídeo') { $Dados[$k] } else { ConvertTo-Html2 $Dados[$k] }
        "<tr><th>$(ConvertTo-Html2 $k)</th><td>$v</td></tr>"
    }
    "<table class='kv'>$($linhas -join '')</table>"
}

function ConvertTo-Tabela($Objetos) {
    $lista = @($Objetos)
    if ($lista.Count -eq 0) { return '<p class="vazio">Nada encontrado.</p>' }
    $colunas = $lista[0].PSObject.Properties.Name
    $cab = ($colunas | ForEach-Object { "<th>$(ConvertTo-Html2 $_)</th>" }) -join ''
    $corpo = foreach ($o in $lista) {
        '<tr>' + (($colunas | ForEach-Object { "<td>$(ConvertTo-Html2 $o.$_)</td>" }) -join '') + '</tr>'
    }
    "<table><thead><tr>$cab</tr></thead><tbody>$($corpo -join '')</tbody></table>"
}

$ordem = @{ 'critico' = 0; 'alerta' = 1; 'info' = 2 }
$rotulos = @{ 'critico' = 'Importante'; 'alerta' = 'Atenção'; 'info' = 'Info' }
$htmlRecomendacoes = ($recomendacoes | Sort-Object { $ordem[$_.Gravidade] } | ForEach-Object {
        "<li class='$($_.Gravidade)'><span class='tag'>$($rotulos[$_.Gravidade])</span>$(ConvertTo-Html2 $_.Texto)</li>"
    }) -join ''

$linkBateria = ''
if ($relatorioBateria -and (Test-Path $relatorioBateria)) {
    $linkBateria = "<p>Relatório detalhado da bateria: <a href='$(ConvertTo-Html2 (Split-Path $relatorioBateria -Leaf))'>abrir</a></p>"
}

$dataRelatorio = Get-Date
$html = @"
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Diagnóstico - $(ConvertTo-Html2 $env:COMPUTERNAME)</title>
<style>
  :root { --bg:#f5f6f8; --card:#fff; --txt:#1d2330; --sub:#5b6475; --borda:#e2e5eb;
          --vermelho:#c62828; --amarelo:#b26a00; --azul:#1f5fbf; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#14171c; --card:#1d2128; --txt:#e8eaee; --sub:#9aa3b2; --borda:#2c323c;
            --vermelho:#ef6b6b; --amarelo:#f0b44c; --azul:#6ea3f5; }
  }
  * { box-sizing:border-box }
  body { margin:0; background:var(--bg); color:var(--txt); font:15px/1.5 "Segoe UI",system-ui,sans-serif; }
  main { max-width:1000px; margin:0 auto; padding:24px 16px 48px; }
  h1 { margin:0 0 4px; font-size:26px } .sub { color:var(--sub); margin:0 0 24px }
  section { background:var(--card); border:1px solid var(--borda); border-radius:10px; padding:16px 20px; margin-bottom:16px; overflow-x:auto }
  h2 { font-size:17px; margin:0 0 12px }
  table { border-collapse:collapse; width:100%; font-size:14px }
  th, td { text-align:left; padding:6px 10px; border-bottom:1px solid var(--borda); vertical-align:top }
  thead th { color:var(--sub); font-weight:600 }
  table.kv th { width:220px; color:var(--sub); font-weight:600 }
  ul.rec { list-style:none; padding:0; margin:0 }
  ul.rec li { padding:10px 12px; border-left:4px solid var(--azul); margin-bottom:8px; background:var(--bg); border-radius:4px }
  ul.rec li.critico { border-color:var(--vermelho) } ul.rec li.alerta { border-color:var(--amarelo) }
  .tag { font-weight:700; margin-right:8px; font-size:12px; text-transform:uppercase }
  li.critico .tag { color:var(--vermelho) } li.alerta .tag { color:var(--amarelo) } li.info .tag { color:var(--azul) }
  .vazio { color:var(--sub) } a { color:var(--azul) }
  @media print { body { background:#fff } section { break-inside:avoid } }
</style>
</head>
<body>
<main>
  <h1>Diagnóstico do computador</h1>
  <p class="sub">$(ConvertTo-Html2 $env:COMPUTERNAME) &middot; $($dataRelatorio.ToString('dd/MM/yyyy HH:mm'))</p>

  <section><h2>Recomendações</h2><ul class="rec">$htmlRecomendacoes</ul></section>
  <section><h2>Sistema</h2>$(ConvertTo-TabelaChaveValor $sistema)</section>
  <section><h2>Hardware</h2>$(ConvertTo-TabelaChaveValor $hardware)$linkBateria</section>
  <section><h2>Discos</h2>$(ConvertTo-Tabela $discos)</section>
  <section><h2>Espaço nas unidades</h2>$(ConvertTo-Tabela $volumes)</section>
  <section><h2>Programas que mais usam memória</h2>$(ConvertTo-Tabela $topRam)</section>
  <section><h2>Programas usando CPU agora</h2>$(ConvertTo-Tabela $topCpu)</section>
  <section><h2>Programas na inicialização ($($inicializacao.Count))</h2>$(ConvertTo-Tabela $inicializacao)</section>
</main>
</body>
</html>
"@

$arquivo = Join-Path $Pasta ('Diagnostico-{0}-{1:yyyyMMdd-HHmm}.html' -f $env:COMPUTERNAME, $dataRelatorio)
Set-Content -Path $arquivo -Value $html -Encoding UTF8

# Resumo no console
Write-Host ''
Write-Host '--- Recomendações ---' -ForegroundColor Cyan
foreach ($r in $recomendacoes | Sort-Object { $ordem[$_.Gravidade] }) {
    $cor = switch ($r.Gravidade) { 'critico' { 'Red' } 'alerta' { 'Yellow' } default { 'Gray' } }
    Write-Host " - $($r.Texto)" -ForegroundColor $cor
}
Write-Host ''
Write-Host "Relatório salvo em: $arquivo" -ForegroundColor Green
if (-not $NaoAbrir) { Start-Process $arquivo }
