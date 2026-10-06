#Requires -Version 5.1
<#
.SYNOPSIS
    Otimização para jogos, com medição de FPS antes e depois.

.DESCRIPTION
    [1] Verificação do PC gamer: encontra o que mais rouba FPS (monitor em 60 Hz,
        XMP/EXPO desligado, memória em single channel, driver de vídeo antigo,
        notebook na bateria ou jogando na placa de vídeo integrada etc.)
    [2] Medir FPS: grava o FPS médio e o 1% low de um jogo aberto usando o
        PresentMon (ferramenta gratuita e oficial da Intel). Meça ANTES e DEPOIS.
    [3] Otimizações para jogos: Modo de Jogo, Game DVR desligado, prioridade de
        CPU/GPU para jogos, agendamento de GPU por hardware, otimização de jogos
        em janela, aceleração do mouse desligada e plano de energia.
    [4] Forçar um jogo a usar a placa de vídeo dedicada (notebooks).
    [5] Integridade de Memória (VBS/HVCI) - avançado.
    [6] Histórico de medições, com a comparação antes x depois.
    [R] Restaurar: desfaz tudo o que este script alterou.

    O backup fica em %ProgramData%\OtimizadorWindows\backup-jogos.json.

.PARAMETER Simular
    Mostra o que seria feito, sem alterar nada.

.EXAMPLE
    .\Otimizar-Jogos.ps1
#>
[CmdletBinding()]
param([switch]$Simular)

$ErrorActionPreference = 'Continue'

if ($env:OS -ne 'Windows_NT') { Write-Host 'Este script só funciona no Windows.' -ForegroundColor Red; exit 1 }

$ehAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Simular) { $argumentos += '-Simular' }
    $inicio = @{ FilePath = 'powershell.exe'; ArgumentList = $argumentos }
    if (-not $ehAdmin) { $inicio.Verb = 'RunAs' }
    Start-Process @inicio
    exit
}

$Script:DataDir     = Join-Path $env:ProgramData 'OtimizadorWindows'
$Script:BackupFile  = Join-Path $Script:DataDir 'backup-jogos.json'
$Script:FpsFile     = Join-Path $Script:DataDir 'fps-historico.json'
$Script:LogFile     = Join-Path $Script:DataDir ('jogos-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
New-Item -Path $Script:DataDir -ItemType Directory -Force | Out-Null

# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Mensagem, [ValidateSet('INFO', 'OK', 'AVISO', 'ERRO', 'TITULO')][string]$Nivel = 'INFO')
    $cor = switch ($Nivel) { 'OK' { 'Green' } 'AVISO' { 'Yellow' } 'ERRO' { 'Red' } 'TITULO' { 'Cyan' } default { 'Gray' } }
    if ($Nivel -eq 'TITULO') { Write-Host '' }
    Write-Host $Mensagem -ForegroundColor $cor
    try { Add-Content -Path $Script:LogFile -Encoding UTF8 -Value ('[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Nivel, $Mensagem) } catch { }
}

function Confirm-Acao([string]$Pergunta, [bool]$Padrao = $false) {
    $sufixo = if ($Padrao) { '[S/n]' } else { '[s/N]' }
    $r = Read-Host "$Pergunta $sufixo"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Padrao }
    return $r.Trim().ToUpper().StartsWith('S')
}

function Test-Notebook { [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) }

# Placas de vídeo físicas (ignora adaptadores virtuais de acesso remoto/streaming)
function Get-PlacasVideo {
    @(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -like 'PCI\*' })
}

# ---------------------------------------------------------------------------
# Backup e registro (guarda só o valor ORIGINAL de cada item)
# ---------------------------------------------------------------------------
$Script:Backup = New-Object System.Collections.ArrayList
$Script:BackupChaves = @{}

function Get-ChaveBackup($e) { '{0}|{1}|{2}' -f $e.Kind, $e.Path, $e.Name }

if (Test-Path $Script:BackupFile) {
    foreach ($e in @(Get-Content $Script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        [void]$Script:Backup.Add($e); $Script:BackupChaves[(Get-ChaveBackup $e)] = $true
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
    ConvertTo-Json -InputObject $Script:Backup.ToArray() -Depth 5 | Set-Content -Path $Script:BackupFile -Encoding UTF8
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value,
        [ValidateSet('DWord', 'String')][string]$Type = 'DWord')
    if ($Simular) { Write-Log "  [simulação] $Path\$Name = $Value"; return }
    try {
        $entrada = @{ Kind = 'Registry'; Path = $Path; Name = $Name; Existed = $false; Value = $null; Type = $null }
        if (Test-Path $Path) {
            $item = Get-Item -Path $Path
            if ($item.GetValueNames() -contains $Name) {
                $entrada.Existed = $true
                $entrada.Value = $item.GetValue($Name)
                $entrada.Type = $item.GetValueKind($Name).ToString()
            }
        } else {
            New-Item -Path $Path -Force | Out-Null
        }
        Add-Backup $entrada
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch {
        Write-Log "  Falha ao gravar $Path\$Name : $($_.Exception.Message)" 'ERRO'
    }
}

function Get-Reg([string]$Path, [string]$Name) {
    (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
}

# Altera uma opção dentro de DirectXUserGlobalSettings ("Chave=Valor;Chave2=Valor2;")
function Set-OpcaoDirectX([string]$Chave, [string]$Valor) {
    $caminho = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $atual = Get-Reg $caminho 'DirectXUserGlobalSettings'
    $pares = [ordered]@{}
    if ($atual) {
        foreach ($par in $atual -split ';') { if ($par -match '^(.+?)=(.*)$') { $pares[$Matches[1]] = $Matches[2] } }
    }
    $pares[$Chave] = $Valor
    $novo = (($pares.Keys | ForEach-Object { "$_=$($pares[$_])" }) -join ';') + ';'
    Set-Reg $caminho 'DirectXUserGlobalSettings' $novo 'String'
}

function New-PontoRestauracao {
    if ($Simular -or $Script:PontoCriado) { return }
    Write-Log 'Criando Ponto de Restauração do Sistema...'
    $chave = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $original = Get-Reg $chave 'SystemRestorePointCreationFrequency'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Set-ItemProperty -Path $chave -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
        Checkpoint-Computer -Description 'Antes da otimização para jogos' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Ponto de Restauração criado.' 'OK'
        $Script:PontoCriado = $true
    } catch {
        Write-Log "Não foi possível criar o Ponto de Restauração: $($_.Exception.Message)" 'AVISO'
    } finally {
        if ($null -eq $original) { Remove-ItemProperty -Path $chave -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path $chave -Name SystemRestorePointCreationFrequency -Value $original -Type DWord }
    }
}

# ---------------------------------------------------------------------------
# Taxa de atualização dos monitores (Hz atual x máximo suportado)
# ---------------------------------------------------------------------------
if (-not ('KitTela' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class KitTela {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string device, uint devNum, ref DISPLAY_DEVICE displayDevice, uint flags);

    // Cada item: nome do dispositivo, largura, altura, Hz atual, Hz máximo na mesma resolução
    public static List<object[]> Monitores() {
        var lista = new List<object[]>();
        var dd = new DISPLAY_DEVICE();
        dd.cb = Marshal.SizeOf(dd);
        for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++) {
            if ((dd.StateFlags & 1) != 0) {  // DISPLAY_DEVICE_ATTACHED_TO_DESKTOP
                var atual = new DEVMODE();
                atual.dmSize = (short)Marshal.SizeOf(atual);
                if (EnumDisplaySettings(dd.DeviceName, -1, ref atual)) {
                    int maximo = atual.dmDisplayFrequency;
                    var modo = new DEVMODE();
                    modo.dmSize = (short)Marshal.SizeOf(modo);
                    for (int m = 0; EnumDisplaySettings(dd.DeviceName, m, ref modo); m++) {
                        if (modo.dmPelsWidth == atual.dmPelsWidth && modo.dmPelsHeight == atual.dmPelsHeight
                            && modo.dmDisplayFrequency > maximo) {
                            maximo = modo.dmDisplayFrequency;
                        }
                    }
                    lista.Add(new object[] { dd.DeviceName, atual.dmPelsWidth, atual.dmPelsHeight, atual.dmDisplayFrequency, maximo });
                }
            }
            dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(dd);
        }
        return lista;
    }
}
'@
}

# ---------------------------------------------------------------------------
# [1] Verificação do PC gamer
# ---------------------------------------------------------------------------
function Invoke-Verificacao {
    Write-Log '[Verificação] Procurando o que está limitando o FPS' 'TITULO'
    $problemas = 0
    $ok = { param($t) Write-Host "  [OK]   $t" -ForegroundColor Green }
    $ruim = { param($t, $dica) Write-Host "  [!!]   $t" -ForegroundColor Yellow; if ($dica) { Write-Host "         -> $dica" -ForegroundColor Gray } }

    # Placa de vídeo e driver
    $placas = Get-PlacasVideo
    foreach ($g in $placas) {
        $idade = if ($g.DriverDate) { [int]((Get-Date) - $g.DriverDate).TotalDays } else { $null }
        $fabricante = switch -Regex ($g.Name) {
            'NVIDIA'          { 'nvidia.com.br/drivers ou o app NVIDIA'; break }
            'AMD|Radeon'      { 'amd.com/pt/support (AMD Software Adrenalin)'; break }
            'Intel'           { 'intel.com.br (Intel Driver & Support Assistant)'; break }
            default           { 'site do fabricante' }
        }
        if ($g.Name -match 'Basic Display|Básico') {
            & $ruim 'Placa de vídeo SEM driver (Adaptador de Vídeo Básico)' "Instale o driver: $fabricante"; $problemas++
        } elseif ($null -ne $idade -and $idade -gt 180) {
            & $ruim "$($g.Name): driver de $($g.DriverDate.ToString('dd/MM/yyyy')) ($idade dias)" "Atualize o driver ($fabricante). Costuma dar ganho real de FPS em jogos novos."; $problemas++
        } else {
            & $ok "$($g.Name): driver atualizado"
        }
    }

    # Monitor
    foreach ($m in [KitTela]::Monitores()) {
        $texto = '{0}: {1}x{2} a {3} Hz' -f ($m[0] -replace '^\\\\\.\\', ''), $m[1], $m[2], $m[3]
        if ($m[4] -gt $m[3]) {
            & $ruim "$texto, mas o monitor suporta $($m[4]) Hz" 'Configurações > Sistema > Tela > Tela avançada > Taxa de atualização. Confira também se o cabo é DisplayPort/HDMI 2.0 e se está ligado na PLACA DE VÍDEO, não na placa-mãe.'; $problemas++
        } else {
            & $ok "$texto (máximo suportado)"
        }
    }

    # Memória RAM: XMP/EXPO e dual channel
    $pentes = @(Get-CimInstance Win32_PhysicalMemory)
    $notebook = Test-Notebook
    if ($pentes.Count -gt 0) {
        $configurada = ($pentes | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
        $tipo = switch ([int]$pentes[0].SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } default { 'RAM' } }
        # A velocidade vendida costuma estar no código do pente (ex.: F4-3200C16, CMK16GX4M2B3600C18)
        $vendida = ($pentes | ForEach-Object {
                [regex]::Matches([string]$_.PartNumber, '(?<!\d)(2[4-9]\d\d|[3-8]\d\d\d)(?!\d)') |
                    ForEach-Object { [int]$_.Value } | Where-Object { $_ -ge 2400 -and $_ -le 8400 }
            } | Measure-Object -Maximum).Maximum

        if (-not $notebook -and $vendida -and $vendida -gt $configurada + 100) {
            & $ruim "Memória $tipo vendida para $vendida MHz rodando a $configurada MHz" 'Ative o XMP (Intel) / EXPO ou DOCP (AMD) na BIOS. Em processadores Ryzen o ganho costuma ser grande.'; $problemas++
        } elseif (-not $notebook -and (($tipo -eq 'DDR4' -and $configurada -le 2666) -or ($tipo -eq 'DDR5' -and $configurada -le 4800))) {
            & $ruim "Memória $tipo a $configurada MHz (velocidade padrão)" 'Se o pente for de gamer (3200+ DDR4 / 6000 DDR5), ative o XMP/EXPO na BIOS.'; $problemas++
        } else {
            & $ok "Memória $tipo a $configurada MHz"
        }

        if ($pentes.Count -eq 1) {
            & $ruim 'Só 1 pente de memória (single channel)' 'Com 2 pentes iguais (dual channel) a placa de vídeo integrada e muitos jogos ganham muito FPS.'; $problemas++
        } else {
            & $ok "$($pentes.Count) pentes de memória"
        }
        $ramGB = [math]::Round(($pentes | Measure-Object Capacity -Sum).Sum / 1GB)
        if ($ramGB -lt 16) { & $ruim "$ramGB GB de RAM" 'Para jogos atuais, 16 GB é o recomendado.'; $problemas++ }
    }

    # Notebook: tomada e GPU dedicada
    if ($notebook) {
        $bat = Get-CimInstance Win32_Battery | Select-Object -First 1
        # 1 = descarregando, 4/5 = bateria fraca/crítica; os demais indicam tomada
        if (@(1, 4, 5) -contains [int]$bat.BatteryStatus) {
            & $ruim 'Notebook rodando na BATERIA' 'Na bateria a placa de vídeo roda limitada. Jogue sempre na tomada.'; $problemas++
        } else {
            & $ok 'Notebook ligado na tomada'
        }
        if ($placas.Count -ge 2) {
            Write-Host '  [i]    Notebook com 2 placas de vídeo: use a opção [4] para garantir que o jogo use a dedicada.' -ForegroundColor Cyan
        }
    }

    # Plano de energia
    $plano = (& powercfg.exe /getactivescheme | Out-String).Trim()
    $nomePlano = if ($plano -match '\((.+)\)') { $Matches[1] } else { $plano }
    if ($plano -match '8c5e7fda|e9a42b02|Alto desempenho|High performance|Ultimate|Desempenho M[aá]ximo') {
        & $ok "Plano de energia: $nomePlano"
    } else {
        & $ruim "Plano de energia: $nomePlano" 'Use a opção [3] para ativar o plano de alto desempenho.'; $problemas++
    }

    # Ajustes do Windows
    $gameMode = Get-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    if ($gameMode -eq 0) { & $ruim 'Modo de Jogo desligado' 'Ativado pela opção [3].'; $problemas++ } else { & $ok 'Modo de Jogo ativo' }

    $dvr = Get-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    if ($dvr -ne 0) { & $ruim 'Gravação em segundo plano (Game DVR) ligada' 'Desligada pela opção [3].'; $problemas++ } else { & $ok 'Game DVR desligado' }

    $hags = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    if ($hags -eq 2) { & $ok 'Agendamento de GPU acelerado por hardware ativo' }
    else { Write-Host '  [i]    Agendamento de GPU por hardware desligado (pode ser ativado na opção [3])' -ForegroundColor Cyan }

    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    if ($dg -and @($dg.SecurityServicesRunning) -contains 2) {
        Write-Host '  [i]    Integridade de Memória (VBS) ativa: pode custar alguns % de FPS. Veja a opção [5].' -ForegroundColor Cyan
    }

    # Disco do sistema
    try {
        $numero = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') | Get-Disk).Number
        $fisico = Get-PhysicalDisk | Where-Object { [string]$_.DeviceId -eq [string]$numero }
        if ($fisico.MediaType -eq 'HDD') {
            & $ruim 'Windows em HD mecânico' 'Jogos em HD têm carregamento lento e travadinhas (stutter). Instale os jogos e o Windows em SSD.'; $problemas++
        }
    } catch { }

    Write-Host ''
    if ($problemas -eq 0) { Write-Log 'Nenhum problema importante encontrado.' 'OK' }
    else { Write-Log "$problemas ponto(s) para corrigir. Os itens de hardware/BIOS costumam dar MAIS FPS que qualquer ajuste do Windows." 'AVISO' }
}

# ---------------------------------------------------------------------------
# [2] Medição de FPS com PresentMon
# ---------------------------------------------------------------------------
function Get-PresentMon {
    $pastas = @($PSScriptRoot, $Script:DataDir) | Where-Object { $_ }
    $local = Get-ChildItem -Path $pastas -Filter 'PresentMon*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($local) { return $local.FullName }

    Write-Host 'Para medir o FPS é usado o PresentMon, ferramenta gratuita e oficial da Intel.' -ForegroundColor Cyan
    if (-not (Confirm-Acao 'Baixar agora do GitHub oficial (github.com/GameTechDev/PresentMon)?' $true)) { return $null }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $versao = Invoke-RestMethod -Uri 'https://api.github.com/repos/GameTechDev/PresentMon/releases/latest' `
            -Headers @{ 'User-Agent' = 'KitManutencaoWindows' } -UseBasicParsing
        $arquivo = $versao.assets | Where-Object { $_.name -match '^PresentMon-[\d.]+-x64\.exe$' } | Select-Object -First 1
        if (-not $arquivo) { throw 'arquivo da versão x64 não encontrado na última versão' }
        $destino = Join-Path $Script:DataDir 'PresentMon.exe'
        Write-Host "Baixando $($arquivo.name)..."
        Invoke-WebRequest -Uri $arquivo.browser_download_url -OutFile $destino -UseBasicParsing
        return $destino
    } catch {
        Write-Log "Não foi possível baixar o PresentMon: $($_.Exception.Message)" 'ERRO'
        Write-Host 'Baixe manualmente o "PresentMon-x.x.x-x64.exe" em github.com/GameTechDev/PresentMon/releases e coloque na mesma pasta deste script.' -ForegroundColor Yellow
        return $null
    }
}

function Select-ProcessoJogo {
    $ignorar = 'explorer', 'powershell', 'pwsh', 'WindowsTerminal', 'conhost', 'cmd', 'ApplicationFrameHost', 'TextInputHost',
        'SystemSettings', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost', 'Taskmgr', 'PresentMon'
    $janelas = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $ignorar -notcontains $_.ProcessName } |
            Sort-Object WorkingSet64 -Descending | Select-Object -First 15)
    Write-Host ''
    Write-Host 'Programas abertos (o jogo costuma ser o que mais usa memória):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $janelas.Count; $i++) {
        $p = $janelas[$i]
        Write-Host ('  [{0,2}] {1,-28} {2,6:N0} MB  {3}' -f ($i + 1), "$($p.ProcessName).exe", ($p.WorkingSet64 / 1MB), $p.MainWindowTitle)
    }
    $r = (Read-Host 'Número do jogo (ou digite o nome do .exe)').Trim()
    if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $janelas.Count) { return "$($janelas[[int]$r - 1].ProcessName).exe" }
    if ($r) { if ($r -notlike '*.exe') { $r += '.exe' }; return $r }
    return $null
}

function Get-Historico {
    if (-not (Test-Path $Script:FpsFile)) { return @() }
    return @(Get-Content $Script:FpsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Measure-Fps {
    $presentMon = Get-PresentMon
    if (-not $presentMon) { return }

    Write-Host ''
    Write-Host 'COMO MEDIR CERTO:' -ForegroundColor Yellow
    Write-Host '  - Abra o jogo e entre na partida/mapa ANTES de continuar.'
    Write-Host '  - Use SEMPRE a mesma cena, resolução e configurações gráficas no antes e no depois.'
    Write-Host '  - Desligue V-Sync e limitador de FPS, senão o FPS fica travado e não dá para comparar.'
    $exe = Select-ProcessoJogo
    if (-not $exe) { return }

    $segundos = Read-Host 'Duração da medição em segundos [60]'
    if ($segundos -notmatch '^\d+$') { $segundos = 60 }
    $historico = Get-Historico
    $padrao = if (@($historico | Where-Object Jogo -eq $exe).Count -gt 0) { 'depois' } else { 'antes' }
    $rotulo = Read-Host "Nome desta medição [$padrao]"
    if ([string]::IsNullOrWhiteSpace($rotulo)) { $rotulo = $padrao }

    $csv = Join-Path $Script:DataDir ('fps-{0}-{1:yyyyMMdd-HHmmss}.csv' -f ($exe -replace '\.exe$', ''), (Get-Date))
    Write-Host ''
    Write-Host ">> Volte para o jogo AGORA. A gravação começa em 10 segundos e dura $segundos s." -ForegroundColor Green
    & $presentMon --process_name $exe --output_file $csv --delay 10 --timed $segundos --terminate_after_timed --stop_existing_session | Out-Null
    Write-Host '>> Gravação concluída. Pode voltar para esta janela.' -ForegroundColor Green

    if (-not (Test-Path $csv)) {
        Write-Log 'Nenhum quadro foi gravado. Confira se o nome do .exe está certo e se o jogo estava em primeiro plano.' 'ERRO'
        return
    }
    $linhas = @(Import-Csv $csv)
    if ($linhas.Count -lt 10) { Write-Log 'Poucos quadros gravados; meça novamente.' 'ERRO'; return }

    # PresentMon 1.x usa "MsBetweenPresents"; o 2.x usa "FrameTime".
    $colunas = $linhas[0].PSObject.Properties.Name
    $coluna = @('MsBetweenPresents', 'FrameTime', 'msBetweenPresents') | Where-Object { $colunas -contains $_ } | Select-Object -First 1
    if (-not $coluna) { Write-Log 'Formato do arquivo do PresentMon não reconhecido.' 'ERRO'; return }

    # O jogo pode ter mais de uma "swapchain"; usa a principal (com mais quadros).
    if ($colunas -contains 'SwapChainAddress') {
        $linhas = @(($linhas | Group-Object SwapChainAddress | Sort-Object Count -Descending | Select-Object -First 1).Group)
    }
    $cultura = [Globalization.CultureInfo]::InvariantCulture
    $tempos = New-Object System.Collections.Generic.List[double]
    foreach ($l in $linhas) {
        $v = 0.0
        if ([double]::TryParse([string]$l.$coluna, [Globalization.NumberStyles]::Float, $cultura, [ref]$v) -and $v -gt 0) { $tempos.Add($v) }
    }
    if ($tempos.Count -lt 10) { Write-Log 'Poucos quadros válidos; meça novamente.' 'ERRO'; return }

    $soma = ($tempos | Measure-Object -Sum).Sum
    $ordenados = @($tempos | Sort-Object)
    $p99 = $ordenados[[math]::Min($ordenados.Count - 1, [int][math]::Floor($ordenados.Count * 0.99))]
    $resultado = [pscustomobject]@{
        Jogo    = $exe
        Rotulo  = $rotulo
        Data    = (Get-Date).ToString('dd/MM/yyyy HH:mm')
        FpsMedio = [math]::Round(1000 * $tempos.Count / $soma, 1)
        Low1    = [math]::Round(1000 / $p99, 1)
        Quadros = $tempos.Count
    }

    $novoHistorico = @($historico) + $resultado
    ConvertTo-Json -InputObject $novoHistorico -Depth 3 | Set-Content -Path $Script:FpsFile -Encoding UTF8

    Write-Host ''
    Write-Log ("{0} [{1}]: FPS médio {2}  |  1% low {3}  ({4} quadros)" -f $exe, $rotulo, $resultado.FpsMedio, $resultado.Low1, $resultado.Quadros) 'OK'
    Show-Historico -Jogo $exe
}

# ---------------------------------------------------------------------------
# [6] Histórico / comparação
# ---------------------------------------------------------------------------
function Show-Historico([string]$Jogo) {
    $historico = Get-Historico
    if ($historico.Count -eq 0) { Write-Host 'Nenhuma medição ainda. Use a opção [2].' -ForegroundColor Yellow; return }
    $grupos = $historico | Group-Object Jogo | Where-Object { -not $Jogo -or $_.Name -eq $Jogo }
    foreach ($g in $grupos) {
        Write-Log "[FPS] $($g.Name)" 'TITULO'
        $base = $g.Group[0]
        Write-Host ('  {0,-16} {1,-18} {2,10} {3,10}' -f 'Data', 'Medição', 'FPS médio', '1% low')
        foreach ($m in $g.Group) {
            $linha = '  {0,-16} {1,-18} {2,10} {3,10}' -f $m.Data, $m.Rotulo, $m.FpsMedio, $m.Low1
            if ($m -ne $base -and $base.FpsMedio -gt 0) {
                $dMedia = ($m.FpsMedio - $base.FpsMedio) / $base.FpsMedio * 100
                $dLow = ($m.Low1 - $base.Low1) / $base.Low1 * 100
                $linha += '   ({0:+0.0;-0.0}% médio, {1:+0.0;-0.0}% 1% low)' -f $dMedia, $dLow
                $cor = if ($dMedia -ge 0) { 'Green' } else { 'Yellow' }
                Write-Host $linha -ForegroundColor $cor
            } else {
                Write-Host $linha
            }
        }
    }
    Write-Host ''
    Write-Host '"1% low" = FPS nos piores momentos. Quanto mais perto do médio, menos travadinhas.' -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# [3] Otimizações para jogos
# ---------------------------------------------------------------------------
function Set-PlanoEnergiaJogos {
    $regexGuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $atual = [regex]::Match((& powercfg.exe /getactivescheme | Out-String), $regexGuid).Value
    $notebook = Test-Notebook

    if ($notebook) {
        if (-not (Confirm-Acao 'Notebook: ativar plano "Alto desempenho"? (mais FPS na tomada, gasta mais bateria)' $true)) { return }
        $alvo = '8c5e7fda-e8bf-4a96-9a85-cf2dd4252f43'
    } else {
        # Desktop: "Desempenho Máximo" (Ultimate). Reaproveita se já existir, para não duplicar.
        $lista = & powercfg.exe /list | Out-String
        $existente = ($lista -split "`r?`n" | Where-Object { $_ -match 'Ultimate Performance|Desempenho M[aá]ximo' } |
                ForEach-Object { [regex]::Match($_, $regexGuid).Value } | Select-Object -First 1)
        $alvo = $existente
        if (-not $alvo -and -not $Simular) {
            $saida = & powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-String
            $alvo = [regex]::Match($saida, $regexGuid).Value
        }
        if (-not $alvo) { $alvo = '8c5e7fda-e8bf-4a96-9a85-cf2dd4252f43' }
    }
    if ($alvo -eq $atual) { Write-Log '  - Plano de energia já otimizado'; return }
    if ($Simular) { Write-Log "  [simulação] ativar plano de energia $alvo"; return }
    if ($atual) { Add-Backup @{ Kind = 'PowerPlan'; Path = 'ativo'; Name = 'plano'; Value = $atual } }
    & powercfg.exe /setactive $alvo
    if ($LASTEXITCODE -eq 0) { Write-Log '  + Plano de energia de alto desempenho ativado' 'OK' }
    else { Write-Log '  ! Não foi possível trocar o plano de energia' 'AVISO' }
}

function Invoke-OtimizacoesJogo {
    New-PontoRestauracao
    Write-Log '[Jogos] Aplicando otimizações' 'TITULO'

    # Modo de Jogo: o Windows prioriza o jogo e segura atualizações durante a partida
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Write-Log '  + Modo de Jogo ativado' 'OK'

    # Gravação em segundo plano consome GPU e disco o tempo todo
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Write-Log '  + Game DVR (gravação em segundo plano) desligado' 'OK'

    # Prioridade de CPU/GPU para jogos (agendador multimídia do Windows)
    $perfil = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-Reg $perfil 'SystemResponsiveness' 10
    Set-Reg $perfil 'NetworkThrottlingIndex' 0xffffffff
    $games = "$perfil\Tasks\Games"
    Set-Reg $games 'GPU Priority' 8
    Set-Reg $games 'Priority' 6
    Set-Reg $games 'Scheduling Category' 'High' 'String'
    Set-Reg $games 'SFIO Priority' 'High' 'String'
    Write-Log '  + Prioridade de CPU e GPU para jogos aumentada' 'OK'

    # Otimizações para jogos em janela/sem borda (menos latência; Windows 11)
    Set-OpcaoDirectX 'SwapEffectUpgradeEnable' '1'
    Write-Log '  + Otimização de jogos em janela ativada' 'OK'

    # Agendamento de GPU acelerado por hardware (HAGS)
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    $hags = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    if ($build -ge 19041 -and $hags -ne 2) {
        if (Confirm-Acao 'Ativar "Agendamento de GPU acelerado por hardware"? (recomendado para NVIDIA GTX 1000+ / AMD RX 5000+, exige reiniciar)' $true) {
            Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
            Write-Log '  + Agendamento de GPU por hardware ativado' 'OK'
        }
    }

    # Aceleração do mouse ("Aprimorar precisão do ponteiro") atrapalha a mira
    if (Confirm-Acao 'Desligar a aceleração do mouse (mira mais precisa em jogos de tiro)?' $true) {
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
        Write-Log '  + Aceleração do mouse desligada' 'OK'
    }

    Save-Backup

    # A otimização geral roda antes do plano de energia, para não trocar o
    # "Desempenho Máximo" pelo "Alto desempenho" que ela usa.
    $geral = Join-Path $PSScriptRoot 'Otimizar-Windows.ps1'
    if ((Test-Path $geral) -and (Confirm-Acao 'Aplicar também a otimização geral do Windows (menos processos em segundo plano)?' $true)) {
        $parametros = @('-Recomendado')
        if ($Simular) { $parametros += '-Simular' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $geral @parametros
    }

    Set-PlanoEnergiaJogos
    Save-Backup
    Write-Host ''
    Write-Host 'REINICIE o PC e depois meça o FPS de novo (opção [2]) para comparar.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# [4] Forçar GPU dedicada
# ---------------------------------------------------------------------------
function Set-GpuDedicada {
    Write-Log '[GPU] Forçar jogo a usar a placa de vídeo dedicada' 'TITULO'
    $placas = Get-PlacasVideo
    Write-Host ('Placas de vídeo: ' + (($placas | ForEach-Object { $_.Name }) -join ' + '))
    if ($placas.Count -lt 2) { Write-Host 'Só existe uma placa de vídeo; esta opção é para notebooks/PCs com duas.' -ForegroundColor Yellow }

    $caminho = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialogo = New-Object System.Windows.Forms.OpenFileDialog
        $dialogo.Title = 'Escolha o executável (.exe) do jogo'
        $dialogo.Filter = 'Executáveis (*.exe)|*.exe'
        if ($dialogo.ShowDialog() -eq 'OK') { $caminho = $dialogo.FileName }
    } catch { }
    if (-not $caminho) { $caminho = (Read-Host 'Caminho completo do .exe do jogo').Trim('"', ' ') }
    if (-not $caminho -or -not (Test-Path $caminho)) { Write-Host 'Arquivo não encontrado.' -ForegroundColor Red; return }

    # GpuPreference=2 = "Alto desempenho" em Configurações > Sistema > Tela > Elementos gráficos
    Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $caminho 'GpuPreference=2;' 'String'
    Save-Backup
    Write-Log "  + $(Split-Path $caminho -Leaf) vai usar a placa de vídeo de alto desempenho" 'OK'
    Write-Host 'Feche e abra o jogo para valer. Se ele tiver launcher, repita para o .exe do jogo (não só do launcher).' -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# [5] Integridade de Memória (VBS/HVCI)
# ---------------------------------------------------------------------------
function Set-IntegridadeMemoria {
    Write-Log '[VBS] Integridade de Memória' 'TITULO'
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    $ativa = $dg -and @($dg.SecurityServicesRunning) -contains 2
    if (-not $ativa) { Write-Log 'A Integridade de Memória já está desligada.' 'OK'; return }

    Write-Host 'A Integridade de Memória é uma proteção contra malware avançado.' -ForegroundColor Yellow
    Write-Host 'Desligá-la pode dar alguns % de FPS em alguns jogos, mas REDUZ A SEGURANÇA do PC.' -ForegroundColor Yellow
    Write-Host 'Alguns jogos com anti-cheat (ex.: Valorant, FACEIT) podem exigi-la ligada.' -ForegroundColor Yellow
    if (-not (Confirm-Acao 'Desligar mesmo assim? (pode ser religada pela opção [R] ou em Segurança do Windows)' $false)) { return }
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
    Save-Backup
    Write-Log '  + Integridade de Memória desligada (vale após reiniciar)' 'OK'
}

# ---------------------------------------------------------------------------
# [R] Restaurar
# ---------------------------------------------------------------------------
function Invoke-Restaurar {
    Write-Log '[Restaurar] Revertendo as otimizações para jogos' 'TITULO'
    if (-not (Test-Path $Script:BackupFile)) { Write-Log 'Nenhum backup encontrado.' 'AVISO'; return }
    $entradas = @(Get-Content $Script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    [array]::Reverse($entradas)
    foreach ($e in $entradas) {
        try {
            switch ($e.Kind) {
                'Registry' {
                    if ($e.Existed) {
                        if (-not (Test-Path $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                        $valor = if ($e.Type -eq 'DWord') { [int]$e.Value } else { [string]$e.Value }
                        New-ItemProperty -Path $e.Path -Name $e.Name -Value $valor -PropertyType $e.Type -Force | Out-Null
                    } else {
                        Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                    }
                }
                'PowerPlan' { & powercfg.exe /setactive $e.Value }
            }
        } catch {
            Write-Log "  ! $($e.Path)\$($e.Name): $($_.Exception.Message)" 'AVISO'
        }
    }
    Move-Item -Path $Script:BackupFile -Destination (Join-Path $Script:DataDir ('backup-jogos-restaurado-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))) -Force
    $Script:Backup.Clear(); $Script:BackupChaves.Clear()
    Write-Log "Restaurado ($($entradas.Count) itens). Reinicie o computador." 'OK'
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
do {
    Clear-Host
    $placas = (Get-PlacasVideo | ForEach-Object { $_.Name }) -join ' + '
    $cpu = (@(Get-CimInstance Win32_Processor)[0].Name).Trim()
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host '                  OTIMIZAÇÃO PARA JOGOS' -ForegroundColor Cyan
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host " CPU: $cpu"
    Write-Host " GPU: $placas"
    if ($Simular) { Write-Host ' MODO SIMULAÇÃO: nenhuma alteração será feita.' -ForegroundColor Yellow }
    Write-Host '-----------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '  Passo a passo: 1 -> 2 (antes) -> 3 -> reiniciar -> 2 (depois)' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [1] Verificação do PC gamer (o que está limitando o FPS)' -ForegroundColor Green
    Write-Host '  [2] Medir FPS de um jogo'
    Write-Host '  [3] Aplicar otimizações para jogos'
    Write-Host '  [4] Forçar um jogo a usar a placa de vídeo dedicada'
    Write-Host '  [5] Integridade de Memória (VBS) - avançado'
    Write-Host '  [6] Ver histórico de FPS (antes x depois)'
    Write-Host '  [R] Restaurar configurações originais' -ForegroundColor Yellow
    Write-Host '  [0] Sair'
    Write-Host '-----------------------------------------------------------------' -ForegroundColor Cyan
    $opcao = (Read-Host 'Escolha uma opção').Trim().ToUpper()
    switch ($opcao) {
        '1' { Invoke-Verificacao }
        '2' { Measure-Fps }
        '3' { Invoke-OtimizacoesJogo }
        '4' { Set-GpuDedicada }
        '5' { Set-IntegridadeMemoria }
        '6' { Show-Historico }
        'R' { if (Confirm-Acao 'Restaurar as configurações alteradas por este script?' $false) { Invoke-Restaurar } }
        '0' { break }
        default { Write-Host 'Opção inválida.' -ForegroundColor Red }
    }
    if ($opcao -ne '0') {
        Write-Host ''
        Write-Host "Log: $Script:LogFile" -ForegroundColor DarkGray
        Read-Host 'Pressione ENTER para voltar ao menu' | Out-Null
    }
} while ($opcao -ne '0')
