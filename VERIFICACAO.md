> Historical checks for an early preview. Current results are in [VERIFICATION.md](VERIFICATION.md).

# Verificação da Line

Verificações realizadas em 6 de novembro de 2026.

## Identidade Active Creators 0.3.0

- `flutter analyze`: sem problemas.
- `flutter test`: 8 testes aprovados, com os logos reais carregados nos cenários de desktop, telemóvel, receção e texto ampliado.
- As três imagens de marca em `assets/brand/` têm SHA-256 igual aos originais fornecidos.
- Capturas revistas: `test/goldens/desktop.png`, `mobile.png`, `desktop-receive.png` e `progress.png`.
- Ícones Android e Windows derivados da chama original; ícone Android 192×192 inspecionado visualmente.
- APK release 0.3.0 compilado, instalado e aberto no emulador Android API 35. Captura real em `release/Line-Android-0.3.0-AC.png`.
- Windows release 0.3.0 compilado; os 30 ficheiros extraídos do instalador coincidem por SHA-256 com o bundle. O construtor do instalador carregou os recursos AC sem erro; não foi executada a instalação no perfil Windows.

## Revisão visual 0.2.0

- `flutter test`: 8 testes aprovados, incluindo formulário, alternância rápida entre Enviar/Receber, progresso/conclusão, ficheiros em GB, layouts e texto ampliado.
- `flutter analyze`: sem problemas.
- Capturas revistas: desktop, telemóvel, receção e progresso em `test/goldens/`. Os valores apresentados na captura de progresso são apenas um cenário de teste do componente.
- Plugins Codex confirmados como instalados e ativos: Agent Skills 0.6.15 e Ponytail 5.3.3. A tentativa de instalar `tauri-skill` falhou porque essa skill não existe no repositório `openai/skills` indicado.
- Não houve alteração do protocolo de transferência nesta revisão.
- Windows release e APK release 0.2.0 compilados. Instalador Windows verificado: 27 ficheiros extraídos com SHA-256 igual ao bundle original, sem instalar no perfil do utilizador.
- APK 0.2.0 instalado e aberto no emulador Android API 35. A captura real está em `release/Line-Android-0.2.0.png`; a ação principal fica visível no primeiro ecrã desse dispositivo.

## Validação funcional inicial 0.1.0

| Verificação | Resultado |
| --- | --- |
| `flutter analyze` | Sem problemas |
| `flutter test` | 7 testes aprovados |
| `npm test` na pasta `server` | 7 testes aprovados |
| Integração WebRTC nativa Windows | Aprovada: 8 MB, SHA-256 idêntico e fingerprints coincidentes |
| Integração WebRTC nativa no emulador Android API 35 / x86_64 | Aprovada: 8 MB, SHA-256 idêntico e fingerprints coincidentes |
| Compilação Windows release | Aprovada |
| Compilação APK release | Aprovada; Android 7.0/API 24+, target API 36 |
| Instalação e arranque do APK release | Confirmados no emulador Pixel 8 / API 35 |
| Extração do instalador Windows | 27 ficheiros comparados por SHA-256 com a compilação original; todos iguais |
| Revisão visual | Capturas Flutter de desktop e telemóvel e captura do APK real no emulador |

Os testes Flutter verificam consentimento, streaming em blocos, ficheiros vazios, nomes repetidos, corrupção, cancelamento, normalização de caminhos, política TLS, formulário e layout. O layout foi exercitado em 1440×1100, 375×900, 844×390 e com texto ampliado a 170% e animação reduzida.

As capturas estão em `test/goldens/desktop.png`, `test/goldens/mobile.png` e `build/screenshots/android.png`. Os hashes das distribuições estão em `release/SHA256SUMS.txt`.

Não foram verificados: instalação/desinstalação completa do instalador no perfil do utilizador, telemóvel físico, exportação via seletor de pastas Android, transferência Windows↔Android entre dispositivos distintos, redes externas/TURN e desempenho com ficheiros de vários GB. A estrutura do protocolo limita os blocos a 16 KiB e a janela a 256 KiB; isto não substitui medições de memória e velocidade nos aparelhos alvo.

As distribuições são de pré-visualização: Windows sem assinatura comercial; APK com assinatura de desenvolvimento. Não foi publicado um servidor de salas na Internet.
