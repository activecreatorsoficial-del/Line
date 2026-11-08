# Direção visual da Line 0.9.0 — Active Creators

A Line deve levar depressa à escolha ou receção de ficheiros e pertencer visualmente à Active Creators.

## Referências fornecidas

- Logo vertical claro sobre fundo escuro: chama, letras AC e assinatura Active Creators.
- AC_Icon.png: a mesma identidade em preto sobre cinza claro.
- Banner_AC.png: composição horizontal, curvas amplas e chama em marca de água.

Os três PNG originais foram copiados sem alterações para `assets/brand/`; os hashes SHA-256 foram comparados com os ficheiros fornecidos. As imagens não contêm instruções funcionais para a aplicação.

## Aplicação à interface

- **Paleta:** preto quente, branco e cinzentos, retirados dos logos. Fundo #F6F5F3, texto #242220 e superfícies escuras #201F1D.
- **Marca (0.4.2):** o símbolo original de duas setas opostas acompanha o nome Line, agora em preto e branco. O menu escuro usa um quadrado claro com setas escuras; o cabeçalho claro usa um quadrado escuro com setas brancas. O nome Line e a assinatura Active Creators mantêm-se.
- **Banner:** imagem fornecida numa área de marca junto à partilha no PC e depois da tarefa principal no telemóvel. Mantém proporções; o enquadramento adapta-se ao espaço disponível.
- **Ícones de instalação (0.4.2):** o mesmo símbolo de duas setas, branco sobre um quadrado preto com cantos arredondados, em Windows, Android e no instalador. O gerador usa o mesmo glifo Material swap_horiz_rounded da interface e exporta cada tamanho com suavização.
- **Hierarquia:** painel branco para tarefas; identificação e contexto à parte. A marca não substitui nomes de ações, estados ou rótulos de campos.
- **Tipografia:** Inter já incluída no projeto; contraste entre títulos, controlos e informação de apoio. O texto das ações continua nativo e acessível.
- **Movimento:** Enviar/Receber conserva a transição de cor de 160 ms, interrompível e com alternativa sem animação.
- **Acesso:** controlos focáveis, nomes acessíveis, layout com texto ampliado e fluxo utilizável sem arrastar. As marcas decorativas têm texto equivalente; o banner tem descrição acessível.

As pré-visualizações estão em `test/goldens/`; o estado anterior está em `build/before-ac-brand/`. O progresso dos testes usa dados de exemplo exclusivamente no teste do componente.

A revisão conserva a implementação Flutter e os fluxos de transferência existentes.

## Revisão visual e movimento — 0.5.0

Pedido: um acabamento mais profissional, com muito mais animação. A identidade monocromática e o símbolo de duas setas continuam a ser requisitos aceites.

A composição usa títulos maiores com duas intensidades de texto, um painel de trabalho branco com relevo discreto e uma área de ligação em carvão. A ilustração vetorial mostra dois dispositivos e partículas em sentidos opostos; é decorativa e não representa o estado real da rede. O banner original da Active Creators mantém-se dentro desse painel. O progresso real passa para um cartão escuro, com números tabulares e textura apenas dentro da parte já transferida.

As recomendações da ui-ux-pro-max para clareza de ferramentas, contraste, foco e isolamento de repintura foram adaptadas à implementação Flutter. A paleta e as fontes sugeridas genericamente pela pesquisa não substituem o preto e branco e a Inter já aprovados.

| Movimento | Gatilho e comportamento |
| --- | --- |
| Entrada coordenada | Abertura: opacidade e deslocamento de 18–24 px, 620 ms com intervalos curtos; os controlos não aguardam a conclusão para responder. |
| Menu e botões | Passagem do rato e pressão: deslocamento e escala discretos em 180 ms, sem alterar o espaço ocupado. Foco e ativação permanecem nativos. |
| Enviar/receber | Seletor deslizante em 340 ms, conteúdo em 320 ms e altura em 300 ms; só existe um formulário, mesmo com cliques rápidos. |
| Ficheiros | Cartões flutuam num ciclo de 10 s e abrem em leque ao passar o rato; listas entram com intervalos limitados a 250 ms. |
| Diagrama | Dispositivos e partículas num ciclo de 8 s, isolados numa pequena RepaintBoundary. |
| Diálogos | Abertura e fecho com opacidade e escala em 280 ms; Escape e os controlos de fecho mantêm-se disponíveis. |
| Transferência | Atualização da barra em 300 ms, textura em 3 s, confirmação de ficheiro em 260 ms e transições dos títulos ligadas a estados reais. |

O controlo Pause animations/Resume animations está sempre acessível no cabeçalho ou junto ao título no telemóvel. As preferências de movimento reduzido do sistema prevalecem e apresentam os estados finais sem movimento. Os ciclos param quando o movimento é pausado ou o TickerMode fica inativo; os controladores são libertados ao sair.

Capturas estáticas usam movimento reduzido. As capturas motion-enter, motion-running e motion-hover amostram a entrada, a execução e a resposta ao rato. Os testes verificam também a pausa/retoma, a alteração da preferência do sistema durante a execução, a preservação dos campos, mudanças rápidas de separador, Escape, tablet, janela pequena, paisagem e texto ampliado. Isto não substitui medições de desempenho nos dispositivos físicos.

## Alojamento no dispositivo — 0.6.0

O visual aprovado mantém-se. A alteração funcional retira o servidor de salas externo do fluxo principal. Criar uma sala inicia o servidor temporário dentro do dispositivo anfitrião. O ecrã identifica esse alojamento, apresenta o código temporário e permite copiar o convite. O destinatário cola o convite completo, que transporta os endereços e a identidade TLS do anfitrião; o nome curto da sala serve apenas para identificação.

As definições passam a apresentar a porta de escuta e um endereço público opcional do próprio anfitrião. STUN e TURN são opções explícitas e ficam vazias por defeito. Os detalhes técnicos de ligação ficam recolhidos numa área expansível. O texto distingue uma sala criada com sucesso da possibilidade de chegar ao dispositivo através de outra rede ou operadora.

## Recuperação da ligação — 0.6.1

O destinatário pode repetir uma tentativa sem voltar a colar o convite e o código. O estado de erro mostra os detalhes de cada endereço numa área expansível e permite copiar o diagnóstico sem incluir o código ou o convite completo. A cópia do convite atualiza os endereços do anfitrião. No Android, a notificação de partilha ativa explica que a sala continua disponível ao mudar de aplicação e oferece a ação Stop sharing. O símbolo da notificação usa as mesmas duas setas monocromáticas.

## Acesso direto pela internet — 0.7.0

O painel Send apresenta Nearby / Internet em preto e branco. Nearby mantém o comportamento local existente. Internet explica a necessidade de um router compatível e de uma ligação pública antes de criar a sala; só a criação pede os acessos temporários. O anfitrião continua a ser o dispositivo que inicia a sala. A interface não apresenta este modo como uma VPN universal e comunica a recusa em redes com CGNAT. A seleção é preservada nas preferências; o destinatário continua a colar um convite e o código, sem configurar portas ou endereços.

## Texto de apoio Nearby - 0.7.1

O modo Nearby explica que os dispositivos devem estar na mesma rede local, como a mesma Wi-Fi ou hotspot. O texto aparece abaixo do seletor, com o mesmo estilo e espa?amento da explica??o de Internet.


## Internet diagnostics - 0.8.0

The approved layout, animation and two-arrow identity are retained. Internet helper text now mentions public IPv4 or IPv6. IPv6 waiting rooms explain that both devices need IPv6 and that incoming access remains subject to network filtering. Host connection details identify the selected route. IPv4 CGNAT is no longer presented as proof that the separate IPv6 route is unavailable.


## Failed session recovery - 0.8.1

The approved visual design is retained. Closing a failed session always resets the form state, and native cleanup errors cannot leave the Retry connection and Connection settings controls disabled indefinitely. The Internet hosting requirement remains explicit; unavailable public routes are not presented as successful rooms.


## Internet invitation/response - 0.9.0

The Internet selector explains the additional response and free Cloudflare STUN discovery. The sender's waiting card displays the room, 12-digit code, Copy invitation, a response field and Connect devices. The receiver's waiting card offers Copy response and explains returning it to the sender. Form errors stay beside the response so a bad paste does not discard the room. Nearby keeps its existing layout and eight-digit code. All new UI uses the existing palette, Inter, controls and spacing; security-code comparison and acceptance remain separate from signaling. Phone component previews use test-only expired/fake credentials.
