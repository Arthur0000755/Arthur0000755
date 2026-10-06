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
| `Otimizar-Jogos.ps1` | Verifica o que limita o FPS, aplica ajustes para jogos e **mede o FPS antes e depois** | Sim, e é reversível |
| `Limpeza-Profunda.ps1` | Remove temporários, logs antigos, cache do Windows Update e Lixeira, com log detalhado | Sim (apaga arquivos) |

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

## PC gamer: mostrando o ganho de FPS

Passo a passo no `Otimizar-Jogos.ps1`:

1. **[1] Verificação**: aponta o que mais rouba FPS. Monitor rodando em 60 Hz sendo de 144 Hz, memória sem XMP/EXPO, um pente só (single channel), driver de vídeo antigo, notebook na bateria ou jogo na placa integrada.
2. **[2] Medir FPS (antes)**: com o jogo aberto, grava o FPS médio e o *1% low* por 60 s usando o [PresentMon](https://github.com/GameTechDev/PresentMon), ferramenta gratuita da Intel. Ele é baixado na primeira vez; para usar sem internet, coloque o `PresentMon-x.x.x-x64.exe` na pasta do kit.
3. **[3] Otimizações**: Modo de Jogo, Game DVR desligado, prioridade de CPU/GPU para jogos, agendamento de GPU por hardware, otimização de jogos em janela, mouse sem aceleração e plano de energia Desempenho Máximo.
4. Reiniciar.
5. **[2] Medir FPS (depois)**: o script mostra a diferença em % em relação ao "antes".

Para comparar de forma justa, use a mesma cena, resolução e configuração gráfica, e deixe V-Sync e limitador de FPS desligados.

Seja honesto com o cliente: os ajustes do Windows costumam dar de 0 a 10% de FPS médio, e a melhora maior aparece no *1% low*, ou seja, menos travadinhas. Os ganhos grandes vêm do que a verificação aponta:

- Monitor na taxa de atualização certa
- XMP/EXPO ativado na BIOS
- Dual channel
- Driver de vídeo atualizado
- No notebook, jogar na tomada e na placa dedicada

## Limpeza profunda

O `Limpeza-Profunda.ps1` sempre limpa:

- Temporários de todos os usuários e do Windows, só os com mais de 24 h, para não atrapalhar uma instalação em andamento
- Logs com mais de 30 dias e relatórios de erro
- Cache do Windows Update e da Otimização de Entrega
- Lixeira de todas as unidades

Ele pergunta antes de remover:

- Dumps de tela azul
- Cache dos navegadores. Não apaga senhas nem histórico, e só roda com os navegadores fechados
- Limpeza de componentes com DISM
- Pasta `Windows.old`

No fim, mostra quanto foi liberado em cada categoria. O log vai para `C:\ProgramData\OtimizadorWindows\limpeza-*.txt`.

O script não entra em atalhos de pasta (junções e links simbólicos), para nunca apagar algo fora da pasta limpa. Ele também não mexe no Prefetch nem nos Logs de Eventos.

```powershell
.\Limpeza-Profunda.ps1 -Simular                              # só calcula quanto liberaria
.\Limpeza-Profunda.ps1 -SemPerguntas -IncluirDism            # automático
.\Limpeza-Profunda.ps1 -DiasLogs 7 -HorasTemp 0 -LogDetalhado # mais agressivo, loga cada arquivo
```

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

## Busca de leads (Google Places)

O `leads/buscar_leads.py` busca comércios locais na Google Places API (New), pela Text Search, e salva Nome, Telefone, Endereço, Website e Nota em `leads_locais.csv`.

1. No Google Cloud, ative a **Places API (New)** e crie uma chave de API.
2. Instale a dependência e rode:

```bash
pip install -r leads/requirements.txt
export GOOGLE_PLACES_API_KEY="sua-chave"     # no PowerShell: $env:GOOGLE_PLACES_API_KEY="sua-chave"
python leads/buscar_leads.py "padaria em Eldorado, Contagem"
```

Sem o termo, o script pergunta. Opções: `-o arquivo.csv`, `-m 20` (máximo de resultados, até 60, o limite da API) e `--separador ,`. O CSV sai em UTF-8 com BOM e separado por `;`, para abrir direto no Excel em português.
