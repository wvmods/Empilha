# Empilha

Jogo de blocos independente para **Android** e **Windows**, com peças próprias, cascatas, modos de jogo, online, ranqueada e tudo gerado por código (sem imagens nem arquivos de áudio). Não é afiliado a nenhum jogo comercial.

## Como se joga

Encaixe as peças que caem para completar linhas horizontais. Cada linha completa some e dá pontos.

- **Tabuleiro 9x18** e **7 peças próprias de 3 e 5 blocos**: reta de 3, canto, P, V, W, cruz e U.
- **Sorteio simples:** todas as peças têm a mesma chance, mas nunca saem três iguais seguidas.
- **Linhas:** nenhuma peça tem mais de 3 blocos de altura, então o máximo de uma vez é a **TRIPLA** (3 linhas). Pontos por jogada: 90 / 260 / 520 x nível, mais bônus de combo e **TABULEIRO LIMPO** (1.500 x nível). O nível sobe a cada 8 linhas.
- **Cascata:** depois de limpar linhas, cada bloco solto cai sozinho até encostar em outro. Se isso fechar novas linhas, é uma cascata: o 1º elo vale x1, o 2º x2, o 3º x3, e assim por diante.
- **Reserva:** guarda a peça atual para usar depois (uma troca por peça).
- **Giro** com testes de parede (a peça tenta se encaixar para os lados e para cima) e **giro de 180°** em um movimento só.
- **Apoio:** mexer a peça no chão só adia a trava (até 15 vezes). Se ela perde o apoio, cai na hora.
- **Efeitos visuais:** brilho nas linhas limpas, tremor na queda rápida e na Tripla, e alerta vermelho quando a pilha fica alta (dá para desligar em Configurações).
- **Fim da partida:** mostra peças, peças por segundo, Triplas, maior cascata e maior combo.

## Modos

Infinito, Corrida 40, Relâmpago 2:00, Zen, Longa 100, Sobrevivência (o lixo sobe sem parar) e Desafio do lixo (comece com lixo e limpe tudo).
A velocidade de queda (Lenta, Normal, Rápida, Insana) e o nível inicial ficam em Configurações.

## Visual e som

- **Texturas:** Clássico (estilo 8-bit em alta definição, com cores que mudam a cada nível), Neon, Madeira, Vidro, Retrô e Gema. Ouro, Cristal e Holo são liberadas pela ranqueada.
- **Músicas:** 11 faixas de fundo em estilo 8-bit, todas originais ou de domínio público, mais a opção Aleatória. Ao terminar uma música, a próxima toca sozinha (dá para desligar).

## Controles

**Celular**
- Botões: esquerda/direita/descer (polegar esquerdo); queda rápida e girar (polegar direito); botão rosa de 180°.
- Gestos no tabuleiro: arrastar para os lados (mover), arrastar para baixo (descer), deslizar rápido para baixo (queda), deslizar rápido para cima ou tocar em RESERVA (guardar), toque (girar), segurar o dedo parado (girar 180°).
- Layout dos botões: padrão, invertido para canhotos, só gestos ou **Meu HUD**, onde você arrasta cada botão para onde quiser, muda o tamanho e esconde os que não usa.

**Teclado (Windows)**
- ←/→ ou A/D mover, ↓ ou S descer, ↑/W/X girar, Z girar ao contrário, Q ou V girar 180°, Espaço queda, C ou Shift guardar, P ou Esc pausar, R reiniciar no fim. Setas e Enter também navegam pelos menus.

**Controle (gamepad)**
- Xbox 360/One/Series e qualquer controle XInput funcionam ao conectar (USB ou Bluetooth). Controles genéricos entram por um modo de compatibilidade, e os de PlayStation funcionam melhor via Steam Input ou DS4Windows.
- Padrão: direcional ou analógico esquerdo move, A/RB gira, B gira ao contrário, X gira 180°, ↑/RT queda, Y/LB/LT guarda, Start pausa, Select reinicia no fim. Nos menus: direcional move o foco, A ativa, B volta.
- No Android, os botões do controle valem como teclas (use o direcional).

**Personalização** (Configurações): volume da música e dos efeitos, transparência, sensibilidade do deslize, vibração, o que aparece na tela (placar, próximas peças, painel lateral), **DAS** e **ARR** ajustáveis, e troca de qualquer tecla ou botão (até 3 por ação) em Configurações > Controles.

## Replays

Toda partida offline é gravada e a reprodução é idêntica à partida real. Ao terminar, toque em "Assistir replay". Na tela inicial, "Replays" guarda a última partida e o replay do recorde de cada modo, com pausa, velocidade 0,5x / 1x / 2x / 4x e barra para ir a qualquer ponto. Partidas online não são gravadas.

## Tutorial

9 passos rápidos (mover, girar, girar 180°, descer, completar linhas, Tripla, Reserva e prática final), obrigatórios só na primeira vez.

## Multiplayer online (até 10 jogadores)

Todos contra todos pela internet: o último vivo vence. Limpar 2 linhas manda 1 de lixo para um rival vivo sorteado; 3 ou mais mandam o mesmo número de linhas (até 6), contando as cascatas.

- Entre na sua conta e escolha uma sala na lista (busca por nome da sala ou do anfitrião; salas com cadeado pedem senha), ou crie a sua, aberta ou com senha, escolhendo a velocidade. Não é preciso digitar código.
- O anfitrião inicia a partida quando houver pelo menos 2 jogadores.
- No fim: Jogar de novo (revanche na mesma sala), Voltar ao lobby ou Trocar modo de jogo.

## Conta e progresso

Crie uma conta (nome único + senha) em "Entrar", no topo da tela inicial. Cada conta tem perfil (avatar, "sobre mim", pontos totais, partidas, vitórias online e recordes) visível para outros jogadores, além de amigos (busca de jogadores e pedidos de amizade). O progresso é sincronizado e segue você em outros aparelhos.

## Ranqueada

- **Temporadas:** todo jogador novo começa com 0 ponto. A cada 30 dias o rating e as vitórias da ranqueada voltam a 0. O melhor elo já alcançado nunca zera e mantém as recompensas (texturas, avatares, molduras e cores de nome).
- **Elos:** Ferro, Bronze, Prata, Ouro, Platina, Diamante, Mestre e Lenda. As 10 primeiras partidas da temporada valem mais.
- **Fair play:** resultados impossíveis não entram nos recordes nem dão pontos, e infrações repetidas bloqueiam o ranqueado por um tempo. Sair ou fechar o app no meio de uma ranqueada conta como último lugar.
