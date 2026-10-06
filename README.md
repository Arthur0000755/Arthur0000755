# Kit de Manutenção do Windows

Scripts em PowerShell para técnicos otimizarem, diagnosticarem e repararem PCs com Windows 10 e 11, inclusive máquinas antigas com HD mecânico.

## Como usar

1. Copie a pasta inteira para um pendrive.
2. No PC do cliente, dê dois cliques em **`Iniciar.bat`**.
3. Escolha o script no menu. Cada um pede permissão de administrador sozinho.

Também dá para rodar um script direto:

```powershell
powershell -ExecutionPolicy Bypass -File .\Otimizar-Windows.ps1
```

## Scripts

| Script | Para que serve | Altera o sistema? |
|---|---|---|
| `Diagnostico-PC.ps1` | Gera um relatório HTML com hardware, saúde dos discos, RAM, programas pesados e recomendações | Não |
| `Otimizar-Windows.ps1` | Deixa o Windows mais leve: serviços, telemetria, bloatware, efeitos visuais, disco | Sim, e é reversível |
| `Reparar-Windows.ps1` | DISM + SFC, CHKDSK, reset do Windows Update, reset de rede e troca de DNS | Sim |
| `Pos-Formatacao.ps1` | Instala programas pelo winget e atualiza todos de uma vez | Sim |

### Fluxo sugerido para um cliente

1. **Diagnóstico**: mostra ao cliente o que está deixando o PC lento.
2. **Reparo** (opção 1): se o Windows estiver travando ou com erros.
3. **Otimizar** (opção 1, "Recomendada").
4. Reiniciar.
5. **Diagnóstico** de novo, se quiser comparar o antes e o depois.

## HD mecânico

O `Otimizar-Windows.ps1` detecta se o Windows está em HD ou SSD e se adapta:

- **HD:** mantém o SysMain/Prefetch ligados (eles aceleram a abertura de programas no HD), sugere desligar a indexação de pesquisa (causa comum de "disco em 100%") e desfragmenta.
- **SSD:** garante que o TRIM está ligado e executa o TRIM em vez de desfragmentar.

O diagnóstico marca o HD mecânico como a principal causa de lentidão. Trocar por SSD é o maior ganho possível, muito acima de qualquer script. O relatório também avisa sobre sinais de HD falhando: saúde SMART ruim, falha prevista e erros de disco no Log de Eventos.

## Segurança e como desfazer

- O `Otimizar-Windows.ps1` cria um **Ponto de Restauração** e guarda o valor original de tudo o que muda em `C:\ProgramData\OtimizadorWindows\backup.json`.
- A opção **[R]** do menu, ou `-Restaurar`, desfaz as alterações. Os aplicativos removidos voltam pela Microsoft Store.
- Use `-Simular` para ver o que seria feito sem mudar nada.
- Os logs de todos os scripts ficam em `C:\ProgramData\OtimizadorWindows`.
- Nenhum script desativa o Windows Update, o Defender ou o Firewall.

## Parâmetros úteis

```powershell
.\Otimizar-Windows.ps1 -Simular                    # só mostra o que faria
.\Otimizar-Windows.ps1 -Recomendado                # aplica tudo sem perguntas
.\Otimizar-Windows.ps1 -Recomendado -RemoverApps   # também remove os apps
.\Otimizar-Windows.ps1 -Restaurar                  # desfaz
.\Diagnostico-PC.ps1 -Pasta E:\Relatorios          # salva o relatório no pendrive
.\Reparar-Windows.ps1 -Completo                    # DISM + SFC + CHKDSK sem perguntas
.\Pos-Formatacao.ps1 -Basico                       # instala o pacote básico
```

## Observações

- As listas de serviços, aplicativos removidos e programas do pós-formatação ficam no início de cada script e podem ser editadas.
- As alterações de usuário (efeitos visuais, anúncios etc.) valem para a conta que confirmou a permissão de administrador. Rode logado na conta do cliente.
- Com a indexação desativada, a busca do Outlook fica mais lenta. Se o cliente depende disso, responda "N" na pergunta.
