# Empilha (Flutter)

Jogo de blocos independente, feito em Flutter. Não tem relação com The Tetris Company nem com nenhum jogo comercial.

Modos: Infinito, Corrida 40, Relâmpago 2:00, Zen, Longa 100, Sobrevivência (o lixo sobe sem parar) e Desafio do lixo (comece com lixo e limpe tudo).
Velocidade de queda (Lenta, Normal, Rápida, Insana) e nível inicial em Configurações.
Texturas: Clássico (estilo 8-bit em alta definição, com cores que mudam a cada nível), Neon, Madeira, Vidro, Retrô e Gema (desenhadas por código, sem imagens), escolhidas em Configurações.
Som: 11 músicas de fundo em estilo 8-bit, todas originais ou de domínio público (Clássico 8-bit, Ode à Alegria, Für Elise, Arcade, Calma, Sinos de Natal, Neon, Chefão, Espaço, Festa e Corrida), mais a opção Aleatória. Ao terminar uma música, a próxima toca sozinha (dá para desligar em Configurações). Efeitos e músicas são gerados por código, sem arquivos de áudio.
Configurações (engrenagem no menu ou na pausa): volume da música e dos efeitos, layout dos botões
(padrão, invertido para canhotos, só gestos ou "Meu HUD", onde você arrasta cada botão para onde quiser,
muda o tamanho e esconde os que não usa), transparência, sensibilidade do deslize, vibração e o que aparece na tela
(placar, próximas peças, painel lateral).

## Controles
- Botões: esquerda/direita/descer (polegar esquerdo); queda rápida e girar (polegar direito).
- Gestos no tabuleiro: arrastar para os lados (mover), arrastar para baixo (descer),
  deslizar rápido para baixo (queda), deslizar rápido para cima ou tocar em RESERVA (guardar peça), toque (girar), segurar o dedo parado (girar 180°).
- Botão rosa de 180° ao lado do girar (dá para esconder em Configurações). No teclado: Q ou V.

## PC (Windows) e controle (1.5.0)
- **Windows:** o jogo roda como app nativo de Windows, com a mesma lógica, replays, online e ranked do celular. Na janela larga, a coluna do jogo cresce com a altura da janela. Ao perder o foco (Alt+Tab) a partida pausa sozinha.
- **Áudio no Windows:** o plugin de áudio não toca bytes da memória no Windows, então as músicas e os efeitos (gerados por código) são gravados como `.wav` na pasta temporária e tocados como arquivo. Nada muda para você.
- **Teclado (padrão):** ←/→ ou A/D mover, ↓ ou S descer, ↑/W/X girar, Z girar ao contrário, Q ou V girar 180°, Espaço queda, C ou Shift guardar, P ou Esc pausar, R reiniciar no fim. Setas e Enter também navegam pelos menus.
- **Teclas e controle** (Configurações > Controles, ou no menu de pausa): desenho do teclado e do controle com cada ação marcada, e troca de qualquer tecla ou botão (até 3 por ação; uma tecla só pode ter uma função). Predefinições: Setas + Z/X/C e WASD. As teclas ficam salvas no aparelho. DAS e ARR valem para teclado e controle.
- **Controle no Windows:** Xbox 360/One/Series e qualquer controle em modo XInput funcionam ao conectar (USB ou Bluetooth), sem instalar nada. Controles genéricos (DirectInput) entram por um modo de compatibilidade: o direcional e os botões 1 a 10 são traduzidos no estilo Xbox, e dá para ajustar na tela de Teclas e controle. Controles de PlayStation funcionam melhor via Steam Input ou DS4Windows, que os transformam em XInput.
- **Controle padrão:** direcional ou analógico esquerdo move, A/RB gira, B gira ao contrário, X gira 180°, ↑/RT queda, Y/LB/LT guardar, Start pausa, Select reinicia no fim. Nos menus: direcional move o foco, A ativa, B volta.
- **Android com controle:** os botões do controle chegam como teclas e valem as mesmas ligações (os analógicos do Android não são lidos; use o direcional).
- **Linux/macOS:** o teclado funciona igual; o controle por XInput é só do Windows.

## Regras do Empilha
- **Tabuleiro 9x18** e **7 peças próprias de 3 e 5 blocos**: reta de 3, canto, P, V, W, cruz e U. Não existe nenhuma peça de 4 blocos.
- **Sorteio simples** (sem "saco" de peças): todas têm a mesma chance, mas nunca saem três iguais seguidas.
- **Linhas:** nenhuma peça tem mais de 3 blocos de altura, então o máximo é a **TRIPLA** (3 linhas de uma vez). Pontos por jogada: 90 / 260 / 520 x nível, mais bônus de combo e **TABULEIRO LIMPO** (1.500 x nível). O nível sobe a cada 8 linhas.
- **Cascata:** depois de limpar linhas, cada bloco solto cai sozinho até encostar em outro (coluna por coluna). Se isso fechar novas linhas, é uma cascata: o 1º elo vale x1, o 2º x2, o 3º x3, e assim por diante. O anti-cheat continua valendo (linhas x colunas nunca passa dos blocos postos).
- **Giro com testes de parede** simples (no lugar, para os lados e para cima). Não há T-spin nem back-to-back.
- **Reserva:** guarda a peça atual (uma troca por peça).
- **Online:** limpar 2 linhas manda 1 de lixo; 3 ou mais mandam o mesmo número (até 6), contando as cascatas (nunca mais que as linhas limpas, então o anti-cheat continua valendo).
- **Efeitos visuais:** brilho nas linhas limpas, tremor leve na queda rápida e forte na Tripla, e alerta vermelho pulsando no topo quando a pilha fica alta. Dá para desligar em Configurações > Efeitos visuais.
- **Fim da partida:** mostra peças, peças por segundo, Triplas, maior cascata e maior combo.

## Segunda leva (1.4.0)
- **Giro de 180°:** um movimento só, com testes de parede próprios. Botão rosa na tela (opcional, também disponível como botão do HUD próprio), tecla Q/V no PC e, no modo só gestos, segurar o dedo parado no tabuleiro.
- **DAS e ARR ajustáveis** (Configurações): DAS é quanto tempo você segura até a peça começar a repetir (60 a 300 ms); ARR é o intervalo entre as repetições (0 = a peça corre direto até a parede). Valem para os botões esquerda/direita e para o teclado. Padrão: 170 ms e 50 ms, igual ao de antes.
- **Replay:** toda partida offline é gravada (sementes + ações + tempo de cada quadro), então a reprodução é idêntica à partida real. Ao terminar, toque em "Assistir replay". Na tela inicial, "Replays" guarda a última partida e o replay do recorde de cada modo. Dá para pausar, escolher 0,5x / 1x / 2x / 4x e arrastar a barra para qualquer ponto. Partidas online não são gravadas. Replays com mais de ~60 mil eventos (cerca de 15 minutos) não são salvos.
- **Tutorial (9 passos):** mover, girar, girar 180°, descer, completar linhas, Tripla, Reserva e prática final.

## Queda ao sair do apoio (1.4.1)
Gravidade e atraso de trava agora são contados separadamente, como nos jogos de blocos clássicos: mexer a peça no chão só adia a trava (até 15 vezes), mas não atrasa a queda. Se você desliza a peça para fora de uma borda ou gira para um vão, o jogo detecta que ela perdeu o apoio e ela cai para a linha de baixo na hora, em vez de ficar parada no ar. O tempo para travar continua o mesmo de antes (o intervalo de queda do nível).

## Gerar o app de Windows
- Pelo GitHub: abra Actions > "Build Windows" > Run workflow e baixe o `Empilha-Windows.zip` em Artifacts (ao criar uma tag `v1.5.0`, vira um Release junto com o APK). Descompacte e abra `empilha.exe` (não separe o .exe das DLLs e da pasta `data`).
- Local (precisa do Flutter e do Visual Studio com "Desktop development with C++"): `flutter create --platforms=windows --org com.example --project-name empilha_game .`, `python tools/setup_windows.py` (nome "Empilha", janela 900x1000, metadados do .exe e ícone próprio), `flutter pub get` e `flutter build windows --release`. O resultado fica em `build/windows/x64/runner/Release/`.

## Gerar o APK
- Pelo GitHub: suba o projeto, abra Actions > "Build APK" > Run workflow
  e baixe o APK em Artifacts. Ao criar uma tag `v1.0.0`, ele vira um Release.
  O workflow define o nome do app ("Empilha") e o ícone automaticamente.
- Local: `flutter create --platforms=android --org com.example --project-name empilha_game .`,
  `python3 tools/make_icon.py android/app/src/main/res`, ajuste `android:label` no
  `AndroidManifest.xml`, depois `flutter pub get` e `flutter build apk --release`.

## Multiplayer online (até 10 jogadores)
Todos contra todos pela internet: o último vivo vence. Limpar 2, 3 ou 4 linhas manda 1, 2 ou 4 linhas
de lixo para um rival vivo sorteado. Cada jogador tem um nome de usuário único.

O servidor é o Firebase Realtime Database (gratuito), acessado por REST. O endereço fica na constante
`kServer` do `lib/main.dart`. As regras do banco precisam permitir leitura e escrita em "rooms":
```json
{ "rules": { "rooms": { ".read": true, ".write": true } } }
```
Como jogar: entre na sua conta e escolha uma sala na lista (busca por nome da sala ou do anfitrião; salas com cadeado pedem senha). Ou crie a sua, aberta ou com senha, escolhendo a velocidade. Não é preciso digitar código.
O anfitrião inicia a partida quando houver pelo menos 2 jogadores.
Ao fim da partida: Jogar de novo (revanche na mesma sala, com o anfitrião reiniciando), Voltar ao lobby ou Trocar modo de jogo.

Atenção: com essas regras, qualquer pessoa que souber o endereço do banco consegue ler e escrever nele.

## Conta e progresso
Crie uma conta (nome único + senha) em "Entrar", no topo da tela inicial. Cada conta tem perfil (avatar, "sobre mim",
pontos totais, partidas, vitórias online e recordes) que outros jogadores podem ver, além de amigos (busca de jogadores,
pedidos de amizade). O progresso é sincronizado com a nuvem e segue você em outros aparelhos. A senha é guardada só como hash com sal, mas
a conta é um sistema simples do app (não usa o Firebase Auth): com as regras abertas, quem souber o endereço
do banco consegue ler esses hashes. Para algo mais seguro, o próximo passo é migrar para o Firebase Auth.

## Ranked: temporadas e anti-cheat
**Temporadas.** Todo jogador novo começa com 0 ponto na ranqueada. A cada 30 dias (contados pelo relógio do
servidor, não do aparelho) o rating e as vitórias da ranqueada voltam a 0 para todo mundo. O melhor elo já
alcançado nunca zera: ele mantém as recompensas (texturas Ouro, Cristal e Holo, avatares, molduras e cores de
nome) liberadas para sempre. A 1ª temporada começa em `Season.epochMs` (`lib/main.dart`); não mude essa data
depois de publicar. Faixas dos elos: Ferro 0, Bronze 60, Prata 150, Ouro 280, Platina 450, Diamante 650,
Mestre 900, Lenda 1200 (lista `Elo.tiers`). As 10 primeiras partidas da temporada valem mais (K=48, depois 32).

**Anti-cheat (no aparelho).**
- Os dados do ranked são assinados (HMAC) no aparelho e na nuvem. Dado editado à mão não vale: no aparelho zera
  o ranked e conta uma infração; na nuvem é ignorado, e no placar e no cálculo do Elo vira rating 0.
- Resultados impossíveis (peças por segundo, linhas demais para as peças, pontuação acima do possível) não entram
  nos recordes nem dão pontos, e contam infração. Três infrações bloqueiam o ranqueado por 7 dias.
- O lixo recebido de um rival é limitado ao que as linhas dele permitem; rivais suspeitos são registrados em
  `rooms/_flags` (só para consulta, não punem sozinhos).
- Sair, cair da conexão ou fechar o app no meio de uma ranqueada conta como último lugar.
- Vitória em menos de 25 s não dá pontos. Duas contas do mesmo aparelho não entram na mesma sala ranqueada.
- Para trocar a chave da assinatura: `flutter build apk --dart-define=AC_KEY=sua-chave-secreta`.

**Limite importante.** Sem servidor próprio, essas defesas só dificultam: quem desmonta o app e extrai a chave
ainda consegue forjar dados. Para valer de verdade, o próximo passo é Firebase Auth + regras do banco que
validem o rating (faixa de variação por partida e quem pode escrever em cada conta).
