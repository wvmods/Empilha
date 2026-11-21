// Empilha — arquivo único (game + painter + storage + áudio + telas)
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Directory, File, Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart'
    show
        AudioContext,
        AudioContextConfig,
        AudioContextConfigFocus,
        AudioPlayer,
        BytesSource,
        DeviceFileSource,
        ReleaseMode,
        Source;
import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:ffi/ffi.dart' as pkg;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ===== game.dart =====

const int kCols = 9;
const int kRows = 18;

/// Windows / Linux / macOS: teclado em vez de botões na tela.
bool get kDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Windows: áudio por arquivo temporário, controle via XInput.
bool get kWindows => defaultTargetPlatform == TargetPlatform.windows;

enum GameMode { classic, sprint, ultra, zen, marathon, survival, cheese }

extension GameModeInfo on GameMode {
  String get title {
    switch (this) {
      case GameMode.classic:
        return 'Infinito';
      case GameMode.sprint:
        return 'Corrida 40';
      case GameMode.ultra:
        return 'Relâmpago 2:00';
      case GameMode.zen:
        return 'Zen';
      case GameMode.marathon:
        return 'Longa 100';
      case GameMode.survival:
        return 'Sobrevivência';
      case GameMode.cheese:
        return 'Desafio do lixo';
    }
  }

  String get description {
    switch (this) {
      case GameMode.classic:
        return 'Sem fim: a velocidade aumenta a cada 8 linhas.';
      case GameMode.sprint:
        return 'Limpe 40 linhas o mais rápido possível.';
      case GameMode.ultra:
        return 'Faça a maior pontuação em 2 minutos.';
      case GameMode.zen:
        return 'Relaxe: velocidade fixa e sem game over.';
      case GameMode.marathon:
        return 'Limpe 100 linhas somando o máximo de pontos.';
      case GameMode.survival:
        return 'Linhas de lixo sobem sem parar. Aguente o máximo.';
      case GameMode.cheese:
        return 'Comece com lixo no tabuleiro e limpe tudo rápido.';
    }
  }

  /// Ranking por menor tempo (os demais, por maior pontuação).
  bool get timeBased => this == GameMode.sprint || this == GameMode.cheese;

  int? get lineGoal {
    if (this == GameMode.sprint) return 40;
    if (this == GameMode.marathon) return 100;
    return null;
  }

  bool get hasGoal =>
      this == GameMode.sprint ||
      this == GameMode.marathon ||
      this == GameMode.cheese;

  bool get savesOnExit =>
      this == GameMode.classic ||
      this == GameMode.zen ||
      this == GameMode.survival ||
      this == GameMode.marathon;
}

String fmtTime(int ms) {
  if (ms < 0) ms = 0;
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final c = (ms % 1000) ~/ 10;
  return '$m:${s.toString().padLeft(2, '0')}.${c.toString().padLeft(2, '0')}';
}

String fmtScore(int n) => n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.');

// Índice 0..6 -> tipo 1..7 (I, O, T, S, Z, J, L)
const List<List<List<int>>> kShapes = [
  [
    [0, 0, 0, 0],
    [1, 1, 1, 1],
    [0, 0, 0, 0],
    [0, 0, 0, 0],
  ],
  [
    [1, 1],
    [1, 1],
  ],
  [
    [0, 1, 0],
    [1, 1, 1],
    [0, 0, 0],
  ],
  [
    [0, 1, 1],
    [1, 1, 0],
    [0, 0, 0],
  ],
  [
    [1, 1, 0],
    [0, 1, 1],
    [0, 0, 0],
  ],
  [
    [1, 0, 0],
    [1, 1, 1],
    [0, 0, 0],
  ],
  [
    [0, 0, 1],
    [1, 1, 1],
    [0, 0, 0],
  ],
];

class Piece {
  final int type; // 1..7
  List<List<int>> shape;
  int x;
  int y;
  int rot = 0; // 0 = nascimento, 1 = direita, 2 = invertida, 3 = esquerda

  Piece(this.type, this.shape, this.x, this.y);

  factory Piece.spawn(int type) {
    final s = kShapes[type - 1].map((r) => List<int>.from(r)).toList();
    return Piece(type, s, (kCols - s.length) ~/ 2, 0);
  }

  List<List<int>> rotated(bool cw) {
    final n = shape.length;
    final out = List.generate(n, (_) => List<int>.filled(n, 0));
    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        out[r][c] = cw ? shape[n - 1 - c][r] : shape[c][n - 1 - r];
      }
    }
    return out;
  }
}

class StackGame {
  final GameMode mode;
  final Random _rng;
  final Random _garbageRng;
  final int? seed;

  /// Gravação para o replay: números positivos = milissegundos de cada
  /// atualização; negativos = ações (-1 esq, -2 dir, -3 descer, -4 girar,
  /// -5 girar anti-horário, -6 girar 180°, -7 queda, -8 hold).
  List<int>? rec;
  final bool versus;
  final int startLevel;
  final double speedMul;
  double survAcc = 0;
  int sentTotal = 0;
  int pendingGarbage = 0;
  final List<int> _queue = [];

  List<List<int>> board = _emptyBoard();
  late Piece current;
  int? holdType;
  bool canHold = true;

  int score = 0;
  int lines = 0;
  int combo = -1;
  int elapsedMs = 0;
  bool gameOver = false;
  bool finished = false;

  double dropAcc = 0; // acumulador da gravidade
  double lockAcc = 0; // tempo apoiado no chão (atraso para travar)
  int lockResets = 0;
  int lockCount = 0;
  int lastCleared = 0;

  // Técnica e estatísticas da partida
  bool _lastRotate = false; // o último movimento da peça foi um giro?
  int _lastKick = 0; // qual teste de parede o giro usou
  int maxCombo = 0;
  int maxChain = 0;
  int lastChain = 0;
  int triples = 0;

  // Efeitos visuais (só desenho, não mudam a regra do jogo)
  List<int> flashRows = [];
  int flashMs = 0;
  int shakeMs = 0;
  double shakePower = 0;

  String? banner;
  int bannerMs = 0;

  StackGame(
    this.mode, {
    this.seed,
    int? garbageSeed,
    this.versus = false,
    this.startLevel = 1,
    this.speedMul = 1.0,
  })  : _rng = Random(seed),
        _garbageRng = garbageSeed == null ? Random() : Random(garbageSeed) {
    current = Piece.spawn(_nextType());
    if (mode == GameMode.cheese) {
      for (int i = 0; i < 7; i++) {
        final row = List<int>.filled(kCols, 8);
        row[_garbageRng.nextInt(kCols)] = 0;
        board[kRows - 1 - i] = row;
      }
    }
  }

  static List<List<int>> _emptyBoard() =>
      List.generate(kRows, (_) => List<int>.filled(kCols, 0));

  bool get over => gameOver || finished;

  int get level => mode == GameMode.zen ? 1 : startLevel + lines ~/ 8;

  double get gravityMs {
    if (mode == GameMode.zen) return 900 / speedMul;
    return max(40.0, 700 * pow(0.87, level - 1).toDouble() / speedMul);
  }

  /// Sorteio simples: cada peça tem a mesma chance, mas nunca saem três
  /// iguais seguidas.
  void _fillQueue() {
    while (_queue.length < 7) {
      var t = _rng.nextInt(7) + 1;
      while (_queue.length >= 2 &&
          _queue[_queue.length - 1] == t &&
          _queue[_queue.length - 2] == t) {
        t = _rng.nextInt(7) + 1;
      }
      _queue.add(t);
    }
  }

  int _nextType() {
    _fillQueue();
    return _queue.removeAt(0);
  }

  List<int> get preview {
    _fillQueue();
    return _queue.take(3).toList();
  }

  /// Só para o tutorial: define quais serão as próximas peças.
  void forceQueue(List<int> types) {
    _queue
      ..clear()
      ..addAll(types);
  }

  bool collides(Piece p, {int dx = 0, int dy = 0, List<List<int>>? shape}) {
    final s = shape ?? p.shape;
    for (int r = 0; r < s.length; r++) {
      for (int c = 0; c < s.length; c++) {
        if (s[r][c] == 0) continue;
        final bx = p.x + c + dx;
        final by = p.y + r + dy;
        if (bx < 0 || bx >= kCols || by >= kRows) return true;
        if (by >= 0 && board[by][bx] != 0) return true;
      }
    }
    return false;
  }

  int get ghostY {
    var d = 0;
    while (!collides(current, dy: d + 1)) {
      d++;
    }
    return current.y + d;
  }

  bool get _grounded => collides(current, dy: 1);

  void _onMoved() {
    if (_grounded) {
      // Ainda apoiada: o atraso para travar recomeça (no máximo 15 vezes).
      if (lockResets < 15) {
        lockAcc = 0;
        lockResets++;
      }
    } else {
      // Saiu do apoio (deslizou para fora da borda ou girou para um vão):
      // a gravidade já vale, então a peça cai para a linha de baixo logo em
      // seguida em vez de ficar parada no ar.
      lockAcc = 0;
    }
  }

  bool move(int dx) {
    if (over) return false;
    rec?.add(dx < 0 ? -1 : -2);
    if (collides(current, dx: dx)) return false;
    current.x += dx;
    _lastRotate = false;
    _onMoved();
    return true;
  }

  // Testes de parede: tenta no lugar, depois para os lados e para cima.
  // (dy negativo = para cima)
  static List<List<int>> _kicks(int type, int from, int to) => const [
        [0, 0],
        [1, 0],
        [-1, 0],
        [0, -1],
        [2, 0],
        [-2, 0],
        [1, -1],
        [-1, -1],
      ];

  bool rotate(bool cw) {
    if (over) return false;
    rec?.add(cw ? -4 : -5);
    final from = current.rot;
    final to = (from + (cw ? 1 : 3)) % 4;
    final ns = current.rotated(cw);
    final kicks = _kicks(current.type, from, to);
    for (int i = 0; i < kicks.length; i++) {
      final k = kicks[i];
      if (!collides(current, dx: k[0], dy: k[1], shape: ns)) {
        current.shape = ns;
        current.x += k[0];
        current.y += k[1];
        current.rot = to;
        _lastRotate = true;
        _lastKick = i;
        _onMoved();
        return true;
      }
    }
    return false;
  }

  bool rotate180() {
    if (over) return false;
    rec?.add(-6);
    final from = current.rot;
    final to = (from + 2) % 4;
    final ns = Piece(current.type, current.rotated(true), 0, 0).rotated(true);
    final kicks = _kicks(current.type, from, to);
    for (final k in kicks) {
      if (!collides(current, dx: k[0], dy: k[1], shape: ns)) {
        current.shape = ns;
        current.x += k[0];
        current.y += k[1];
        current.rot = to;
        _lastRotate = true;
        _lastKick = 0; // 180° nunca conta como o último teste (vira mini)
        _onMoved();
        return true;
      }
    }
    return false;
  }

  bool softDrop() {
    if (over) return false;
    rec?.add(-3);
    if (collides(current, dy: 1)) return false;
    current.y++;
    _lastRotate = false;
    score += 1;
    dropAcc = 0;
    lockAcc = 0;
    return true;
  }

  void hardDrop() {
    if (over) return;
    rec?.add(-7);
    final dist = ghostY - current.y;
    current.y = ghostY;
    if (dist > 0) _lastRotate = false;
    score += 2 * dist;
    if (shakeMs <= 0) {
      shakeMs = 80;
      shakePower = 1.6;
    }
    _lock();
  }

  void hold() {
    if (over || !canHold) return;
    rec?.add(-8);
    final t = current.type;
    if (holdType == null) {
      holdType = t;
      current = Piece.spawn(_nextType());
    } else {
      final h = holdType!;
      holdType = t;
      current = Piece.spawn(h);
    }
    canHold = false;
    dropAcc = 0;
    lockAcc = 0;
    lockResets = 0;
    _lastRotate = false;
    if (collides(current)) _topOut();
  }

  void _topOut() {
    if (mode == GameMode.zen) {
      board = _emptyBoard();
    } else {
      gameOver = true;
    }
  }

  void _lock() {
    lockCount++;
    final s = current.shape;
    for (int r = 0; r < s.length; r++) {
      for (int c = 0; c < s.length; c++) {
        if (s[r][c] == 0) continue;
        final by = current.y + r;
        final bx = current.x + c;
        if (by >= 0 && by < kRows && bx >= 0 && bx < kCols) {
          board[by][bx] = current.type;
        }
      }
    }
    _clearLines();
    if (versus && lastCleared == 0 && pendingGarbage > 0) {
      _addGarbage(pendingGarbage);
      pendingGarbage = 0;
    }
    canHold = true;
    lockResets = 0;
    dropAcc = 0;
    lockAcc = 0;
    _checkEnd();
    if (over) return;
    current = Piece.spawn(_nextType());
    _lastRotate = false;
    if (collides(current)) _topOut();
  }

  /// Gravidade em cascata: depois de limpar linhas, cada bloco solto cai
  /// sozinho até encostar em outro bloco ou no fundo (coluna por coluna).
  void _settle() {
    for (int c = 0; c < kCols; c++) {
      var w = kRows - 1;
      for (int r = kRows - 1; r >= 0; r--) {
        final v = board[r][c];
        if (v == 0) continue;
        if (w != r) {
          board[w][c] = v;
          board[r][c] = 0;
        }
        w--;
      }
    }
  }

  void _clearLines() {
    final lvl = level;
    var total = 0;
    var chain = 0;
    var flash = <int>[];
    while (true) {
      final fullRows = <int>[
        for (int r = 0; r < kRows; r++)
          if (board[r].every((v) => v != 0)) r
      ];
      final n = fullRows.length;
      if (n == 0) break;
      if (chain == 0) flash = fullRows;
      board.removeWhere((row) => row.every((v) => v != 0));
      for (int i = 0; i < n; i++) {
        board.insert(0, List<int>.filled(kCols, 0));
      }
      _settle();
      chain++;
      total += n;
      if (n >= 3) triples++;
      // Cada elo da cascata vale mais: x1, x2, x3...
      score += const [0, 90, 260, 520, 900][min(n, 4)] * lvl * chain;
    }
    lastCleared = total;
    lastChain = chain;
    if (chain > maxChain) maxChain = chain;

    if (versus && total > 0) {
      // Nunca passa do total de linhas limpas, então o anti-cheat do online
      // continua valendo.
      final atk = total == 1 ? 0 : min(total, 6);
      final cancel = min(atk, pendingGarbage);
      pendingGarbage -= cancel;
      sentTotal += atk - cancel;
    }

    if (total == 0) {
      combo = -1;
      return;
    }

    combo++;
    if (combo > 0) score += 40 * combo * lvl;
    if (combo + 1 > maxCombo) maxCombo = combo + 1;
    lines += total;

    String name;
    if (chain > 1) {
      name = 'CASCATA x$chain';
    } else if (total >= 4) {
      name = 'QUADRA!';
    } else if (total == 3) {
      name = 'TRIPLA!';
    } else if (combo > 0) {
      name = 'COMBO x${combo + 1}';
    } else {
      name = '$total linha${total > 1 ? 's' : ''}';
    }
    _showBanner(name);

    if (board.every((row) => row.every((v) => v == 0))) {
      score += 1500 * lvl;
      _showBanner('TABULEIRO LIMPO!');
    }

    // Efeitos: brilho nas linhas limpas e tremor nas jogadas grandes.
    flashRows = flash;
    flashMs = 260;
    if (total >= 3 || chain > 1) {
      shakeMs = 260;
      shakePower = 5;
    }
  }

  void _addGarbage(int n) {
    for (int i = 0; i < n; i++) {
      final top = board.removeAt(0);
      if (top.any((v) => v != 0)) gameOver = true;
      final row = List<int>.filled(kCols, 8);
      row[_garbageRng.nextInt(kCols)] = 0;
      board.add(row);
    }
  }

  void _showBanner(String text) {
    banner = text;
    bannerMs = 1100;
  }

  void _checkEnd() {
    final goal = mode.lineGoal;
    if (goal != null && lines >= goal) finished = true;
    if (mode == GameMode.cheese && !board.any((row) => row.contains(8))) {
      finished = true;
    }
    if (mode == GameMode.ultra && elapsedMs >= 120000) {
      elapsedMs = 120000;
      finished = true;
    }
  }

  void update(int dtMs) {
    if (over) return;
    rec?.add(dtMs);
    elapsedMs += dtMs;
    if (bannerMs > 0) bannerMs -= dtMs;
    if (flashMs > 0) flashMs -= dtMs;
    if (shakeMs > 0) shakeMs -= dtMs;
    _checkEnd();
    if (over) return;
    if (mode == GameMode.survival) {
      survAcc += dtMs;
      final interval = max(3500.0, 11000 - elapsedMs / 12);
      if (survAcc >= interval) {
        survAcc = 0;
        _addGarbage(1);
        while (!gameOver && collides(current) && current.y > -2) {
          current.y--;
        }
        if (!gameOver && collides(current)) gameOver = true;
        if (over) return;
      }
    }
    // Gravidade e atraso de trava são contados separadamente: mexer a peça
    // no chão só adia a trava, nunca atrasa a queda. Assim, no instante em
    // que ela deixa de ter apoio, cai para a linha de baixo.
    dropAcc += dtMs;
    final g = gravityMs;
    var guard = 0;
    while (dropAcc >= g && !over && guard++ < 40) {
      if (_grounded) {
        dropAcc = g; // apoiada: fica "armada" para cair se o apoio sumir
        break;
      }
      dropAcc -= g;
      current.y++;
      _lastRotate = false;
    }
    if (!over && _grounded) {
      lockAcc += dtMs;
      if (lockAcc >= g) _lock();
    } else {
      lockAcc = 0;
    }
  }
}

// ===== painter.dart =====

enum BlockTheme { nes, neon, madeira, vidro, retro, gema, ouro, cristal, holo, bichinhos, geleia }

extension BlockThemeInfo on BlockTheme {
  String get label {
    switch (this) {
      case BlockTheme.nes:
        return 'Infinito';
      case BlockTheme.neon:
        return 'Neon';
      case BlockTheme.madeira:
        return 'Madeira';
      case BlockTheme.vidro:
        return 'Vidro';
      case BlockTheme.retro:
        return 'Retrô';
      case BlockTheme.gema:
        return 'Gema';
      case BlockTheme.ouro:
        return 'Ouro';
      case BlockTheme.cristal:
        return 'Cristal';
      case BlockTheme.holo:
        return 'Holo';
      case BlockTheme.bichinhos:
        return 'Bichinhos';
      case BlockTheme.geleia:
        return 'Geleia';
    }
  }

  List<Color> get bg {
    switch (this) {
      case BlockTheme.nes:
        return const [Color(0xFF07070D), Color(0xFF15151F)];
      case BlockTheme.neon:
        return const [Color(0xFF0B0B1E), Color(0xFF1A0B33)];
      case BlockTheme.madeira:
        return const [Color(0xFF2B1B10), Color(0xFF4A3220)];
      case BlockTheme.vidro:
        return const [Color(0xFF0F2027), Color(0xFF2C5364)];
      case BlockTheme.retro:
        return const [Color(0xFF1B1B1B), Color(0xFF2D2D2D)];
      case BlockTheme.gema:
        return const [Color(0xFF1A0F2E), Color(0xFF0F2E2E)];
      case BlockTheme.ouro:
        return const [Color(0xFF1F1708), Color(0xFF3A2C0A)];
      case BlockTheme.cristal:
        return const [Color(0xFF06202E), Color(0xFF0D3B52)];
      case BlockTheme.holo:
        return const [Color(0xFF14081F), Color(0xFF082A2F)];
      case BlockTheme.bichinhos:
        return const [Color(0xFF5B4B8A), Color(0xFF8A6FB5)];
      case BlockTheme.geleia:
        return const [Color(0xFF2B1A4A), Color(0xFF4A2A6B)];
    }
  }
}

const List<Color> kPieceColors = [
  Colors.transparent,
  Color(0xFF26C6DA), // peça 1 (I)           - turquesa
  Color(0xFFFFB300), // peça 2 (O)           - âmbar
  Color(0xFFEC407A), // peça 3 (T)           - rosa
  Color(0xFF9CCC65), // peça 4 (S)           - lima
  Color(0xFFEF6C00), // peça 5 (Z)           - laranja queimado
  Color(0xFF5C6BC0), // peça 6 (J)           - índigo
  Color(0xFF8D6E63), // peça 7 (L)           - cacau
  Color(0xFF8D8D8D), // lixo (multiplayer)
];

Color shade(Color c, double amount) {
  final hsl = HSLColor.fromColor(c);
  final l = (hsl.lightness + amount).clamp(0.0, 1.0).toDouble();
  return hsl.withLightness(l).toColor();
}

void drawBlock(Canvas canvas, Rect rect, Color base, BlockTheme theme) {
  final r = rect.deflate(rect.width * 0.04);
  final rr = RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.18));
  switch (theme) {
    case BlockTheme.nes:
      _nes(canvas, r, base);
      break;
    case BlockTheme.neon:
      _neon(canvas, r, rr, base);
      break;
    case BlockTheme.madeira:
      _wood(canvas, r, rr, base);
      break;
    case BlockTheme.vidro:
      _glass(canvas, r, rr, base);
      break;
    case BlockTheme.retro:
      _retro(canvas, r, base);
      break;
    case BlockTheme.gema:
      _gem(canvas, r, rr, base);
      break;
    case BlockTheme.ouro:
      _gold(canvas, r, rr, base);
      break;
    case BlockTheme.cristal:
      _crystal(canvas, r, rr, base);
      break;
    case BlockTheme.holo:
      _holo(canvas, r, rr, base);
      break;
    case BlockTheme.bichinhos:
      _pets(canvas, r, rr, base);
      break;
    case BlockTheme.geleia:
      _jelly(canvas, r, rr, base);
      break;
  }
}

/// Bichinhos fofos (estilo kawaii): cada tipo de peça é um animalzinho com
/// a sua própria cor: gatinho laranja, pintinho amarelo, porquinho rosa,
/// sapinho verde, pandinha, coelhinho lilás e ursinho marrom.
void _pets(Canvas canvas, Rect r, RRect rr, Color base) {
  final t = kPieceColors.indexOf(base);
  final w = r.width;
  final cx = r.center.dx;
  const dark = Color(0xFF3A2A3F);

  // peça fantasma (cor com transparência): só um contorno suave
  if (t < 1 || t > 8) {
    canvas.drawRRect(rr, Paint()..color = base.withAlpha(base.alpha ~/ 2));
    canvas.drawRRect(
        rr.deflate(w * 0.04),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.06
          ..color = base);
    return;
  }

  // cor do corpo de cada bichinho
  const bodies = <int, Color>{
    1: Color(0xFFFFB067), // gatinho laranja
    2: Color(0xFFFFE066), // pintinho amarelo
    3: Color(0xFFFFA6C4), // porquinho rosa
    4: Color(0xFF9BE08A), // sapinho verde
    5: Color(0xFFF6F3FA), // pandinha
    6: Color(0xFFD7C2FF), // coelhinho lilás
    7: Color(0xFFC8946A), // ursinho marrom
    8: Color(0xFFC9C9D6), // nuvenzinha (lixo)
  };
  final body = bodies[t]!;
  final edge = shade(body, -0.16);
  final inner = const Color(0xFFFFC4D6);

  // orelhas (desenhadas antes para ficarem atrás do rosto)
  void pointy(Color c) {
    for (final side in [-1.0, 1.0]) {
      final x0 = cx + side * w * 0.3;
      final p = Path()
        ..moveTo(x0 - side * w * 0.2, r.top + w * 0.34)
        ..lineTo(x0 + side * w * 0.04, r.top + w * 0.0)
        ..lineTo(x0 + side * w * 0.2, r.top + w * 0.34)
        ..close();
      canvas.drawPath(p, Paint()..color = c);
      final q = Path()
        ..moveTo(x0 - side * w * 0.09, r.top + w * 0.3)
        ..lineTo(x0 + side * w * 0.04, r.top + w * 0.1)
        ..lineTo(x0 + side * w * 0.14, r.top + w * 0.3)
        ..close();
      canvas.drawPath(q, Paint()..color = inner);
    }
  }

  void round(Color c, {bool withInner = true}) {
    for (final side in [-1.0, 1.0]) {
      final o = Offset(cx + side * w * 0.33, r.top + w * 0.17);
      canvas.drawCircle(o, w * 0.15, Paint()..color = c);
      if (withInner) canvas.drawCircle(o, w * 0.075, Paint()..color = inner);
    }
  }

  switch (t) {
    case 1:
      pointy(edge);
      break;
    case 3:
      round(edge);
      break;
    case 5:
      round(const Color(0xFF3A3340), withInner: false);
      break;
    case 7:
      round(edge);
      break;
    case 6:
      for (final side in [-1.0, 1.0]) {
        final e = Rect.fromCenter(
            center: Offset(cx + side * w * 0.2, r.top + w * 0.14),
            width: w * 0.17,
            height: w * 0.3);
        canvas.drawOval(e, Paint()..color = edge);
        canvas.drawOval(e.deflate(w * 0.04), Paint()..color = inner);
      }
      break;
    case 4:
      for (final side in [-1.0, 1.0]) {
        final o = Offset(cx + side * w * 0.26, r.top + w * 0.17);
        canvas.drawCircle(o, w * 0.14, Paint()..color = edge);
        canvas.drawCircle(o, w * 0.1, Paint()..color = body);
      }
      break;
  }

  // corpinho fofo (gordinho e brilhante)
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.5),
          radius: 1.2,
          colors: [shade(body, 0.1), body, shade(body, -0.1)],
          stops: const [0, 0.55, 1],
        ).createShader(r));
  canvas.drawRRect(
      rr.deflate(w * 0.025),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.05
        ..color = edge);

  // manchinhas do rosto
  if (t == 5) {
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(
          Rect.fromCenter(center: Offset(cx + side * w * 0.2, r.top + w * 0.46), width: w * 0.24, height: w * 0.3),
          Paint()..color = const Color(0xFF3A3340));
    }
  }
  if (t == 1) {
    // listrinhas de gato laranja
    final stripe = Paint()
      ..color = shade(body, -0.14)
      ..strokeWidth = w * 0.04
      ..strokeCap = StrokeCap.round;
    for (final dx in [-0.08, 0.0, 0.08]) {
      canvas.drawLine(Offset(cx + dx * w, r.top + w * 0.1), Offset(cx + dx * w, r.top + w * 0.2), stripe);
    }
  }
  if (t == 2) {
    final tuft = Path()
      ..moveTo(cx - w * 0.07, r.top + w * 0.14)
      ..quadraticBezierTo(cx - w * 0.04, r.top + w * 0.02, cx, r.top + w * 0.07)
      ..quadraticBezierTo(cx + w * 0.03, r.top + w * 0.0, cx + w * 0.08, r.top + w * 0.14)
      ..close();
    canvas.drawPath(tuft, Paint()..color = const Color(0xFFFFB300));
  }

  // olhos grandes e brilhantes
  final eyeY = r.top + w * 0.47;
  for (final side in [-1.0, 1.0]) {
    final c = Offset(cx + side * w * 0.2, eyeY);
    if (t == 8) {
      canvas.drawArc(Rect.fromCenter(center: c, width: w * 0.17, height: w * 0.1), 0, pi, false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * 0.045
            ..strokeCap = StrokeCap.round
            ..color = dark);
    } else {
      final eyeCol = t == 5 ? Colors.black : dark;
      canvas.drawOval(Rect.fromCenter(center: c, width: w * 0.16, height: w * 0.21), Paint()..color = eyeCol);
      canvas.drawCircle(c.translate(-w * 0.025, -w * 0.045), w * 0.036, Paint()..color = Colors.white);
      canvas.drawCircle(c.translate(w * 0.025, w * 0.04), w * 0.016, Paint()..color = Colors.white70);
    }
  }

  // bochechinhas rosadas
  final blush = Paint()..color = const Color(0x80FF7A9C);
  for (final side in [-1.0, 1.0]) {
    canvas.drawOval(
        Rect.fromCenter(center: Offset(cx + side * w * 0.34, r.top + w * 0.63), width: w * 0.15, height: w * 0.09),
        blush);
  }

  // focinho / bico / boquinha
  final mouth = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w * 0.04
    ..strokeCap = StrokeCap.round
    ..color = dark;
  final my = r.top + w * 0.66;
  switch (t) {
    case 2:
      final beak = Path()
        ..moveTo(cx - w * 0.07, my - w * 0.035)
        ..lineTo(cx + w * 0.07, my - w * 0.035)
        ..lineTo(cx, my + w * 0.07)
        ..close();
      canvas.drawPath(beak, Paint()..color = const Color(0xFFFF8F00));
      break;
    case 3:
      canvas.drawOval(Rect.fromCenter(center: Offset(cx, my), width: w * 0.3, height: w * 0.19), Paint()..color = const Color(0xFFFF8FB3));
      canvas.drawCircle(Offset(cx - w * 0.05, my), w * 0.022, Paint()..color = dark);
      canvas.drawCircle(Offset(cx + w * 0.05, my), w * 0.022, Paint()..color = dark);
      break;
    case 7:
      canvas.drawOval(Rect.fromCenter(center: Offset(cx, my), width: w * 0.28, height: w * 0.2), Paint()..color = const Color(0xFFF3DCC8));
      canvas.drawCircle(Offset(cx, my - w * 0.035), w * 0.035, Paint()..color = dark);
      break;
    case 4:
      canvas.drawArc(Rect.fromCenter(center: Offset(cx, my - w * 0.05), width: w * 0.42, height: w * 0.22), 0.2, pi - 0.4, false, mouth);
      break;
    default:
      // sorrisinho em "w" (gato, panda, coelho e nuvem)
      final m = Path()
        ..moveTo(cx - w * 0.09, my - w * 0.02)
        ..quadraticBezierTo(cx - w * 0.045, my + w * 0.07, cx, my - w * 0.005)
        ..quadraticBezierTo(cx + w * 0.045, my + w * 0.07, cx + w * 0.09, my - w * 0.02);
      canvas.drawPath(m, mouth);
  }

  // brilho de plush no cantinho
  canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(r.left + w * 0.12, r.top + w * 0.28, w * 0.1, w * 0.045), Radius.circular(w * 0.03)),
      Paint()..color = Colors.white.withAlpha(110));
}

/// Geleia: blocos gordinhos, brilhantes e translúcidos, com sombra colorida.
void _jelly(Canvas canvas, Rect r, RRect rr, Color base) {
  final w = r.width;
  final jelly = Color.lerp(base, Colors.white, 0.12)!;
  // sombrinha colorida embaixo
  canvas.drawRRect(rr.shift(Offset(0, w * 0.05)), Paint()..color = shade(base, -0.3).withAlpha(140));
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.15,
          colors: [shade(jelly, 0.2), jelly, shade(jelly, -0.12)],
          stops: const [0, 0.5, 1],
        ).createShader(r));
  canvas.drawRRect(
      rr.deflate(w * 0.03),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.05
        ..color = shade(jelly, 0.25).withAlpha(150));
  // brilho comprido e pontinho de luz
  canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(r.left + w * 0.16, r.top + w * 0.12, w * 0.5, w * 0.15), Radius.circular(w * 0.08)),
      Paint()..color = Colors.white.withAlpha(170));
  canvas.drawCircle(Offset(r.left + w * 0.76, r.top + w * 0.2), w * 0.04, Paint()..color = Colors.white.withAlpha(190));
  // reflexo inferior
  canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(r.left + w * 0.2, r.bottom - w * 0.2, w * 0.6, w * 0.07), Radius.circular(w * 0.04)),
      Paint()..color = shade(jelly, 0.3).withAlpha(90));
}

void _neon(Canvas canvas, Rect r, RRect rr, Color base) {
  canvas.drawRRect(
      rr,
      Paint()
        ..color = base.withAlpha(140)
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 5));
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [shade(base, -0.28), shade(base, -0.42)],
        ).createShader(r));
  canvas.drawRRect(
      rr.deflate(r.width * 0.07),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width * 0.1
        ..color = shade(base, 0.12));
  canvas.drawRRect(rr.deflate(r.width * 0.3), Paint()..color = base.withAlpha(90));
}

void _wood(Canvas canvas, Rect r, RRect rr, Color base) {
  final wood = Color.lerp(base, const Color(0xFF8B5A2B), 0.6)!;
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [shade(wood, 0.08), shade(wood, -0.1)],
        ).createShader(r));

  // veios da madeira (variam conforme a posição do bloco)
  canvas.save();
  canvas.clipRRect(rr);
  final seed = (rect_hash(r)).abs();
  final grain = Paint()
    ..color = const Color(0x33000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  for (int i = 0; i < 4; i++) {
    final y = r.top + r.height * (0.15 + 0.22 * i) + ((seed + i * 5) % 5 - 2);
    final path = Path()
      ..moveTo(r.left, y)
      ..quadraticBezierTo(r.center.dx, y + ((seed + i) % 7 - 3), r.right, y);
    canvas.drawPath(path, grain);
  }
  canvas.restore();

  // "inlay" com a cor da peça para manter a identidade
  final inlay = RRect.fromRectAndRadius(
      r.deflate(r.width * 0.24), Radius.circular(r.width * 0.08));
  canvas.drawRRect(inlay, Paint()..color = base.withAlpha(150));
  canvas.drawRRect(
      inlay,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x55000000));

  canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width * 0.07
        ..color = shade(wood, -0.2));
  canvas.drawLine(
      r.topLeft + Offset(r.width * 0.12, r.width * 0.06),
      r.topRight + Offset(-r.width * 0.12, r.width * 0.06),
      Paint()
        ..color = const Color(0x44FFFFFF)
        ..strokeWidth = 1.5);
}

int rect_hash(Rect r) => (r.left * 7 + r.top * 13).toInt();

/// Textura Ouro (recompensa do elo Ouro).
void _gold(Canvas canvas, Rect r, RRect rr, Color base) {
  final gold = Color.lerp(base, const Color(0xFFFFC107), 0.6)!;
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [shade(gold, 0.3), gold, shade(gold, -0.25)],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(r));
  canvas.save();
  canvas.clipRRect(rr);
  canvas.drawPath(
      Path()
        ..moveTo(r.left + r.width * 0.05, r.top + r.height * 0.6)
        ..lineTo(r.left + r.width * 0.6, r.top + r.height * 0.05)
        ..lineTo(r.left + r.width * 0.78, r.top + r.height * 0.05)
        ..lineTo(r.left + r.width * 0.05, r.top + r.height * 0.78)
        ..close(),
      Paint()..color = const Color(0x55FFFFFF));
  canvas.restore();
  final inlay = RRect.fromRectAndRadius(
      r.deflate(r.width * 0.32), Radius.circular(r.width * 0.06));
  canvas.drawRRect(inlay, Paint()..color = base.withAlpha(200));
  canvas.drawRRect(
      inlay,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x66000000));
  canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width * 0.07
        ..color = shade(gold, -0.38));
}

/// Textura Cristal (recompensa do elo Diamante).
void _crystal(Canvas canvas, Rect r, RRect rr, Color base) {
  final ice = Color.lerp(base, const Color(0xFFB3E5FC), 0.45)!;
  canvas.save();
  canvas.clipRRect(rr);
  canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [shade(ice, 0.25), ice, shade(ice, -0.25)],
        ).createShader(r));
  final c = r.center;
  final facet = Paint()
    ..color = const Color(0x55FFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  canvas.drawLine(r.topLeft, c, facet);
  canvas.drawLine(r.topRight, c, facet);
  canvas.drawLine(r.bottomLeft, c, facet);
  canvas.drawLine(r.bottomRight, c, facet);
  canvas.drawPath(
      Path()
        ..moveTo(r.left, r.top)
        ..lineTo(r.right, r.top)
        ..lineTo(c.dx, c.dy)
        ..close(),
      Paint()..color = const Color(0x44FFFFFF));
  canvas.restore();
  canvas.drawCircle(Offset(r.left + r.width * 0.28, r.top + r.height * 0.28),
      r.width * 0.07, Paint()..color = const Color(0xDDFFFFFF));
  canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = shade(ice, -0.4));
}

/// Textura Holo (recompensa do elo Lenda): cores iridescentes.
void _holo(Canvas canvas, Rect r, RRect rr, Color base) {
  final h = (rect_hash(r).abs() * 23 % 360).toDouble();
  final a = HSVColor.fromAHSV(1, h, 0.55, 1.0).toColor();
  final b = HSVColor.fromAHSV(1, (h + 90) % 360, 0.6, 0.95).toColor();
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(base, a, 0.6)!, Color.lerp(base, b, 0.6)!],
        ).createShader(r));
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(r.left + r.width * 0.08, r.top + r.height * 0.06,
              r.width * 0.84, r.height * 0.32),
          Radius.circular(r.width * 0.14)),
      Paint()..color = const Color(0x44FFFFFF));
  canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = const Color(0xCCFFFFFF));
}

void _glass(Canvas canvas, Rect r, RRect rr, Color base) {
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base.withAlpha(235), shade(base, -0.2).withAlpha(170)],
        ).createShader(r));
  final hl = RRect.fromRectAndRadius(
      Rect.fromLTWH(r.left + r.width * 0.08, r.top + r.height * 0.06,
          r.width * 0.84, r.height * 0.38),
      Radius.circular(r.width * 0.14));
  canvas.drawRRect(
      hl,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xAAFFFFFF), Color(0x11FFFFFF)],
        ).createShader(hl.outerRect));
  canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0x99FFFFFF));
}

void _retro(Canvas canvas, Rect r, Color base) {
  final b = r.width * 0.18;
  canvas.drawRect(r, Paint()..color = base);
  final light = Path()
    ..moveTo(r.left, r.top)
    ..lineTo(r.right, r.top)
    ..lineTo(r.right - b, r.top + b)
    ..lineTo(r.left + b, r.top + b)
    ..lineTo(r.left + b, r.bottom - b)
    ..lineTo(r.left, r.bottom)
    ..close();
  final dark = Path()
    ..moveTo(r.right, r.bottom)
    ..lineTo(r.left, r.bottom)
    ..lineTo(r.left + b, r.bottom - b)
    ..lineTo(r.right - b, r.bottom - b)
    ..lineTo(r.right - b, r.top + b)
    ..lineTo(r.right, r.top)
    ..close();
  canvas.drawPath(light, Paint()..color = shade(base, 0.2));
  canvas.drawPath(dark, Paint()..color = shade(base, -0.2));
  canvas.drawRect(
      Rect.fromLTWH(r.left + b * 1.6, r.top + b * 1.6, b, b),
      Paint()..color = const Color(0x66FFFFFF));
  canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xAA000000));
}

void _gem(Canvas canvas, Rect r, RRect rr, Color base) {
  canvas.save();
  canvas.clipRRect(rr);
  final c = r.center;
  void tri(Offset a, Offset b, Color col) {
    canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..lineTo(c.dx, c.dy)
          ..close(),
        Paint()..color = col);
  }

  tri(r.topLeft, r.topRight, shade(base, 0.22));
  tri(r.topLeft, r.bottomLeft, shade(base, 0.06));
  tri(r.topRight, r.bottomRight, shade(base, -0.1));
  tri(r.bottomLeft, r.bottomRight, shade(base, -0.26));
  canvas.drawRect(
      r.deflate(r.width * 0.28),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [shade(base, 0.3), shade(base, -0.05)],
        ).createShader(r));
  canvas.restore();
  canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = shade(base, -0.35));
}

/// Nível atual (0 = primeiro) usado pela textura Clássico para trocar as cores.
int gNesLevel = 0;

/// Paletas de cada nível, no estilo do console 8-bit: [cor 1, cor 2].
const List<List<Color>> kNesPalettes = [
  [Color(0xFF0058F8), Color(0xFF3CBCFC)],
  [Color(0xFF00A800), Color(0xFFB8F818)],
  [Color(0xFFD800CC), Color(0xFF6844FC)],
  [Color(0xFF0058F8), Color(0xFF58D854)],
  [Color(0xFFE40058), Color(0xFF58F898)],
  [Color(0xFF58F898), Color(0xFF6888FC)],
  [Color(0xFFF83800), Color(0xFF7C7C7C)],
  [Color(0xFF6844FC), Color(0xFFA80020)],
  [Color(0xFF0058F8), Color(0xFFF83800)],
  [Color(0xFFFCA044), Color(0xFFF83800)],
];

/// Bloco "clássico" em alta definição: contorno preto, brilho branco no canto
/// e cores que mudam a cada nível (ou seja, a cada aumento de velocidade).
void _nes(Canvas canvas, Rect r, Color base) {
  final idx = kPieceColors.indexOf(base);
  final pal = kNesPalettes[gNesLevel % kNesPalettes.length];
  final u = r.width / 8;
  const white = Color(0xFFFCFCFC);
  canvas.drawRect(r, Paint()..color = const Color(0xFF000000));
  final inner = r.deflate(u * 0.55);

  void fillGradient(Rect rect, Color c) {
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [shade(c, 0.07), shade(c, -0.1)],
          ).createShader(rect));
  }

  if (idx == 1 || idx == 2 || idx == 7) {
    // estilo "branco": anel colorido com miolo claro
    fillGradient(inner, pal[0]);
    final core = inner.deflate(u * 1.2);
    canvas.drawRect(
        core,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [white, Color(0xFFD4D4D4)],
          ).createShader(core));
  } else {
    final fill = idx == 8
        ? const Color(0xFF9E9E9E)
        : (idx == 3 || idx == 5 ? pal[0] : pal[1]);
    fillGradient(inner, fill);
    canvas.drawRect(
        Rect.fromLTWH(inner.left, inner.bottom - u * 0.8, inner.width, u * 0.8),
        Paint()..color = const Color(0x33000000));
    canvas.drawRect(
        Rect.fromLTWH(inner.right - u * 0.8, inner.top, u * 0.8, inner.height),
        Paint()..color = const Color(0x22000000));
  }
  canvas.drawRect(Rect.fromLTWH(inner.left, inner.top, inner.width, u * 0.45),
      Paint()..color = const Color(0x55FFFFFF));
  canvas.drawRect(Rect.fromLTWH(inner.left, inner.top, u * 0.45, inner.height),
      Paint()..color = const Color(0x33FFFFFF));
  canvas.drawRect(
      Rect.fromLTWH(inner.left + u * 0.9, inner.top + u * 0.9, u * 1.5, u * 1.5),
      Paint()..color = white);
}

class BoardPainter extends CustomPainter {
  final StackGame game;
  final BlockTheme theme;

  BoardPainter(this.game, this.theme);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / kCols;
    final full = Offset.zero & size;
    final frame = RRect.fromRectAndRadius(full, const Radius.circular(10));

    canvas.save();
    canvas.clipRRect(frame);
    canvas.drawRect(
        full,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: theme.bg,
          ).createShader(full));

    final grid = Paint()
      ..color = const Color(0x14FFFFFF)
      ..strokeWidth = 1;
    for (int i = 1; i < kCols; i++) {
      canvas.drawLine(Offset(i * cell, 0), Offset(i * cell, size.height), grid);
    }
    for (int j = 1; j < kRows; j++) {
      canvas.drawLine(Offset(0, j * cell), Offset(size.width, j * cell), grid);
    }

    final fx = Settings.fx.value && !game.over;
    canvas.save();
    if (fx && game.shakeMs > 0) {
      final amp = game.shakePower * min(1.0, game.shakeMs / 120);
      canvas.translate(sin(game.elapsedMs * 0.9) * amp,
          cos(game.elapsedMs * 1.3) * amp);
    }

    for (int r = 0; r < kRows; r++) {
      for (int c = 0; c < kCols; c++) {
        final v = game.board[r][c];
        if (v == 0) continue;
        drawBlock(canvas, Rect.fromLTWH(c * cell, r * cell, cell, cell),
            kPieceColors[v], theme);
      }
    }

    if (!game.over) {
      final p = game.current;
      final gy = game.ghostY;
      final ghost = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = kPieceColors[p.type].withAlpha(150);
      for (int r = 0; r < p.shape.length; r++) {
        for (int c = 0; c < p.shape.length; c++) {
          if (p.shape[r][c] == 0) continue;
          final rect = Rect.fromLTWH((p.x + c) * cell, (gy + r) * cell, cell, cell)
              .deflate(cell * 0.1);
          canvas.drawRRect(
              RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.15)), ghost);
        }
      }
      for (int r = 0; r < p.shape.length; r++) {
        for (int c = 0; c < p.shape.length; c++) {
          if (p.shape[r][c] == 0) continue;
          final y = p.y + r;
          if (y < 0) continue;
          drawBlock(
              canvas,
              Rect.fromLTWH((p.x + c) * cell, y * cell, cell, cell),
              kPieceColors[p.type],
              theme);
        }
      }
    }
    // Brilho nas linhas que acabaram de ser limpas.
    if (fx && game.flashMs > 0) {
      final a = (game.flashMs / 260).clamp(0.0, 1.0);
      final flash = Paint()..color = Color.fromARGB((a * 200).round(), 255, 255, 255);
      for (final r in game.flashRows) {
        canvas.drawRect(Rect.fromLTWH(0, r * cell, size.width, cell), flash);
      }
    }
    canvas.restore(); // fim do tremor

    // Alerta de perigo: o topo fica vermelho e pulsa quando a pilha está alta.
    if (fx) {
      var top = kRows;
      for (int r = 0; r < kRows; r++) {
        if (game.board[r].any((v) => v != 0)) {
          top = r;
          break;
        }
      }
      if (top <= 5) {
        final t = (6 - top) / 6;
        final pulse = 0.5 + 0.5 * sin(game.elapsedMs / 160);
        final alpha = (35 + 95 * t * pulse).round();
        final zone = Rect.fromLTWH(0, 0, size.width, cell * 5);
        canvas.drawRect(
            zone,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.fromARGB(alpha, 255, 23, 68),
                  const Color(0x00FF1744),
                ],
              ).createShader(zone));
      }
    }
    canvas.restore();

    canvas.drawRRect(
        frame,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0x55FFFFFF));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class PiecePainter extends CustomPainter {
  final int? type;
  final BlockTheme theme;
  final bool dim;

  PiecePainter(this.type, this.theme, {this.dim = false});

  @override
  void paint(Canvas canvas, Size size) {
    if (type == null) return;
    final shape = kShapes[type! - 1];
    var minR = 99, maxR = -1, minC = 99, maxC = -1;
    for (int r = 0; r < shape.length; r++) {
      for (int c = 0; c < shape.length; c++) {
        if (shape[r][c] == 0) continue;
        minR = min(minR, r);
        maxR = max(maxR, r);
        minC = min(minC, c);
        maxC = max(maxC, c);
      }
    }
    final cell = min(size.width / 4.4, size.height / 2.6);
    final w = (maxC - minC + 1) * cell;
    final h = (maxR - minR + 1) * cell;
    final ox = (size.width - w) / 2;
    final oy = (size.height - h) / 2;

    if (dim) {
      canvas.saveLayer(Offset.zero & size,
          Paint()..color = const Color.fromRGBO(0, 0, 0, 0.35));
    }
    for (int r = minR; r <= maxR; r++) {
      for (int c = minC; c <= maxC; c++) {
        if (shape[r][c] == 0) continue;
        drawBlock(
            canvas,
            Rect.fromLTWH(ox + (c - minC) * cell, oy + (r - minR) * cell, cell, cell),
            kPieceColors[type!],
            theme);
      }
    }
    if (dim) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Amostra 2x2 usada no seletor de textura do menu.
class ThemeSamplePainter extends CustomPainter {
  final BlockTheme theme;
  ThemeSamplePainter(this.theme);

  @override
  void paint(Canvas canvas, Size size) {
    final saved = gNesLevel;
    gNesLevel = 0;
    final cell = size.width / 2;
    const types = [1, 3, 5, 7];
    for (int i = 0; i < 4; i++) {
      drawBlock(
          canvas,
          Rect.fromLTWH((i % 2) * cell, (i ~/ 2) * cell, cell, cell),
          kPieceColors[types[i]],
          theme);
    }
    gNesLevel = saved;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ===== storage.dart =====

class Storage {
  static Future<int?> best(GameMode m) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('best_${m.name}');
  }

  static Future<void> mergeBest(GameMode m, int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('best_${m.name}', v);
  }

  /// Retorna true se bateu o recorde.
  /// Sprint: menor tempo (só conta se concluiu). Demais: maior pontuação.
  static Future<bool> submit(GameMode m, StackGame g) async {
    final p = await SharedPreferences.getInstance();
    final key = 'best_${m.name}';
    final old = p.getInt(key);
    if (m.timeBased) {
      if (!g.finished) return false;
      if (old == null || g.elapsedMs < old) {
        await p.setInt(key, g.elapsedMs);
        return true;
      }
      return false;
    }
    if (g.score <= 0) return false;
    if (old == null || g.score > old) {
      await p.setInt(key, g.score);
      return true;
    }
    return false;
  }

  static Future<BlockTheme> loadTheme() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString('theme');
    return BlockTheme.values.firstWhere(
      (t) => t.name == name,
      orElse: () => BlockTheme.neon,
    );
  }

  static Future<void> saveTheme(BlockTheme t) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('theme', t.name);
  }

  static Future<void> saveReplay(String key, ReplayData d) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(d.toJson()));
    } catch (_) {}
  }

  static Future<ReplayData?> loadReplay(String key) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(key);
      if (raw == null) return null;
      return ReplayData.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}

// ===== audio.dart =====

enum PadLayout { standard, mirrored, gestures, custom }

/// Um botão do HUD personalizado: posição (fração da tela), tamanho e se aparece.
class PadItem {
  double x;
  double y;
  double size;
  bool on;
  PadItem(this.x, this.y, this.size, this.on);
}

/// Preferências do jogador (textura, volume, HUD e controles).
class Settings {
  static final ValueNotifier<BlockTheme> theme =
      ValueNotifier<BlockTheme>(BlockTheme.neon);
  static final ValueNotifier<double> musicVol = ValueNotifier<double>(0.6);
  static final ValueNotifier<int> musicTrack = ValueNotifier<int>(0);
  static final ValueNotifier<bool> musicAuto = ValueNotifier<bool>(true);
  static final ValueNotifier<double> sfxVol = ValueNotifier<double>(0.8);
  static final ValueNotifier<PadLayout> layout =
      ValueNotifier<PadLayout>(PadLayout.standard);
  static final ValueNotifier<double> padScale = ValueNotifier<double>(1.0);
  static final ValueNotifier<double> padOpacity = ValueNotifier<double>(1.0);
  static final ValueNotifier<double> swipeSens = ValueNotifier<double>(1.0);
  static final ValueNotifier<bool> haptics = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> fx = ValueNotifier<bool>(true);
  /// DAS: tempo (ms) segurando até começar a repetir. ARR: intervalo (ms)
  /// entre repetições; 0 = a peça vai direto até a parede.
  static final ValueNotifier<double> das = ValueNotifier<double>(170);
  static final ValueNotifier<double> arr = ValueNotifier<double>(50);
  static final ValueNotifier<bool> flipBtn = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> showScore = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> showNext = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> showSide = ValueNotifier<bool>(true);
  static Map<String, PadItem> custom = defaultCustom();
  static String serverUrl = '';
  static String username = '';
  static String deviceId = '';
  static String passHash = '';
  static int games = 0;
  static int owins = 0;
  static int ogames = 0;
  static int points = 0;
  static int rating = kStartRating;
  static int rw = 0;
  static int rg = 0;
  static int avatar = 0;

  /// Melhor elo (índice) já alcançado em qualquer temporada: nunca zera.
  /// É ele que mantém texturas, avatares, molduras e cores liberados.
  static int peakTier = 0;

  /// Temporada do rating atual (-1 = ainda não validada com o servidor).
  static int season = -1;

  /// Anti-cheat: infrações acumuladas e fim do bloqueio do ranqueado
  /// (hora do servidor, em ms).
  static int acStrikes = 0;
  static int acBanUntil = 0;
  static int frame = -1;
  static int nameColor = -1;
  static bool tutorialDone = false;
  static String bio = '';
  static final ValueNotifier<double> speedMul = ValueNotifier<double>(1.0);
  static final ValueNotifier<int> startLevel = ValueNotifier<int>(1);

  static bool get loggedIn => username.isNotEmpty && passHash.isNotEmpty;

  static Future<void> saveLogin(String name, String hash) async {
    username = name;
    passHash = hash;
    final p = await SharedPreferences.getInstance();
    await p.setString('acc_name', name);
    await p.setString('acc_hash', hash);
    Presence.start();
  }

  static Future<void> logout() async {
    // Sair no meio de uma ranqueada não livra da derrota.
    await AntiCheat.settlePending();
    final oldKey = username.toLowerCase();
    Presence.stop();
    if (oldKey.isNotEmpty) {
      Net.delete(kServer, 'rooms/_presence/$oldKey').catchError((_) {});
    }
    rating = kStartRating;
    peakTier = 0;
    season = -1;
    rw = 0;
    rg = 0;
    frame = -1;
    nameColor = -1;
    await saveRank();
    await saveCosmetics();
    username = '';
    passHash = '';
    final p = await SharedPreferences.getInstance();
    avatar = 0;
    bio = '';
    await p.remove('acc_name');
    await p.remove('acc_hash');
    await p.remove('acc_avatar');
    await p.remove('acc_bio');
    Elo.sanitize();
  }

  static Future<void> _saveStats() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('stat_games', games);
    await p.setInt('stat_owins', owins);
    await p.setInt('stat_ogames', ogames);
    await p.setInt('stat_points', points);
  }

  static Future<void> setStats(int g, int w, int og, int pts) async {
    games = g;
    owins = w;
    ogames = og;
    points = pts;
    await _saveStats();
  }

  static Future<void> saveRank() async {
    final p = await SharedPreferences.getInstance();
    final idx = Elo.indexFor(rating);
    if (idx > peakTier) peakTier = idx;
    await p.setInt('rk_peakt', peakTier);
    await p.setInt('rk_season', season);
    await p.setInt('rk_rating', rating);
    await p.setInt('rk_rw', rw);
    await p.setInt('rk_rg', rg);
    await p.setString('rk_sig', AntiCheat.localRankSig());
    await p.setInt('ac_strikes', acStrikes);
    await p.setInt('ac_ban', acBanUntil);
  }

  /// Vira a temporada: rating e vitórias do ranked voltam ao início.
  /// O melhor elo (e as recompensas dele, como texturas) fica.
  static Future<void> ensureSeason() async {
    if (!Season.synced) return;
    final cur = Season.current;
    if (cur <= season) return;
    season = cur;
    rating = kStartRating;
    rw = 0;
    rg = 0;
    await saveRank();
  }

  static Future<void> saveCosmetics() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('cos_frame', frame);
    await p.setInt('cos_name', nameColor);
  }

  static Future<void> setTutorialDone({bool push = true}) async {
    tutorialDone = true;
    final p = await SharedPreferences.getInstance();
    await p.setBool('tut_done', true);
    if (push) Account.sync();
  }

  static Future<void> saveProfileLocal() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('acc_avatar', avatar);
    await p.setString('acc_bio', bio);
  }

  static Future<void> addGame(int score) async {
    games++;
    points += score;
    await _saveStats();
  }

  static Future<void> addOnline(bool won, int score) async {
    ogames++;
    games++;
    points += score;
    if (won) owins++;
    await _saveStats();
    Account.sync();
  }


  static Future<void> saveServer(String u) async {
    serverUrl = u;
    final p = await SharedPreferences.getInstance();
    await p.setString('server_url', u);
  }

  static Map<String, PadItem> defaultCustom() => {
        'left': PadItem(0.12, 0.92, 58, true),
        'down': PadItem(0.30, 0.92, 58, true),
        'right': PadItem(0.48, 0.92, 58, true),
        'drop': PadItem(0.70, 0.92, 58, true),
        'rotate': PadItem(0.88, 0.91, 76, true),
        'hold': PadItem(0.88, 0.78, 50, false),
        'flip': PadItem(0.70, 0.80, 50, false),
      };

  /// Espaço que o tabuleiro deixa livre embaixo para os botões do HUD próprio.
  static double bottomReserve(double w, double h) {
    var r = 6.0;
    for (final it in custom.values) {
      if (!it.on || it.y < 0.7) continue;
      final top = it.y * h - it.size / 2;
      r = max(r, h - top + 6);
    }
    return min(r, h * 0.4);
  }

  static String _encodeCustom() => custom.entries
      .map((e) =>
          '${e.key}:${e.value.x.toStringAsFixed(4)},${e.value.y.toStringAsFixed(4)},${e.value.size.toStringAsFixed(1)},${e.value.on ? 1 : 0}')
      .join(';');

  static void _decodeCustom(String? raw) {
    final m = defaultCustom();
    if (raw != null) {
      try {
        for (final part in raw.split(';')) {
          final kv = part.split(':');
          if (kv.length != 2 || !m.containsKey(kv[0])) continue;
          final v = kv[1].split(',');
          if (v.length != 4) continue;
          m[kv[0]] = PadItem(double.parse(v[0]), double.parse(v[1]),
              double.parse(v[2]), v[3] == '1');
        }
      } catch (_) {}
    }
    custom = m;
  }

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final tn = p.getString('theme');
    theme.value = BlockTheme.values.firstWhere(
      (t) => t.name == tn,
      orElse: () => BlockTheme.neon,
    );
    musicVol.value = p.getDouble('music_vol') ?? 0.6;
    musicTrack.value = p.getInt('music_track') ?? 0;
    musicAuto.value = p.getBool('music_auto') ?? true;
    sfxVol.value = p.getDouble('sfx_vol') ?? 0.8;
    final name = p.getString('pad_layout');
    layout.value = PadLayout.values.firstWhere(
      (l) => l.name == name,
      orElse: () => PadLayout.standard,
    );
    padScale.value = p.getDouble('pad_scale') ?? 1.0;
    padOpacity.value = p.getDouble('pad_opacity') ?? 1.0;
    swipeSens.value = p.getDouble('swipe_sens') ?? 1.0;
    haptics.value = p.getBool('haptics') ?? true;
    fx.value = p.getBool('fx') ?? true;
    das.value = p.getDouble('das') ?? 170;
    arr.value = p.getDouble('arr') ?? 50;
    flipBtn.value = p.getBool('flip_btn') ?? true;
    showScore.value = p.getBool('show_score') ?? true;
    showNext.value = p.getBool('show_next') ?? true;
    showSide.value = p.getBool('show_side') ?? true;
    _decodeCustom(p.getString('pad_custom'));
    serverUrl = p.getString('server_url') ?? '';
    username = p.getString('acc_name') ?? '';
    passHash = p.getString('acc_hash') ?? '';
    games = p.getInt('stat_games') ?? 0;
    owins = p.getInt('stat_owins') ?? 0;
    ogames = p.getInt('stat_ogames') ?? 0;
    points = p.getInt('stat_points') ?? 0;
    rating = p.getInt('rk_rating') ?? kStartRating;
    rw = p.getInt('rk_rw') ?? 0;
    rg = p.getInt('rk_rg') ?? 0;
    avatar = p.getInt('acc_avatar') ?? 0;
    bio = p.getString('acc_bio') ?? '';
    season = p.getInt('rk_season') ?? -1;
    acStrikes = p.getInt('ac_strikes') ?? 0;
    acBanUntil = p.getInt('ac_ban') ?? 0;
    final legacyPeak = p.getInt('rk_peak');
    peakTier = p.getInt('rk_peakt') ??
        (legacyPeak != null ? Elo.legacyIndexFor(legacyPeak) : 0);
    if (p.getInt('rk_season') == null) {
      // Dados da escala antiga (começava em 1000): o ranked recomeça do 0.
      rating = kStartRating;
      rw = 0;
      rg = 0;
      await saveRank();
    } else if (p.getString('rk_sig') != AntiCheat.localRankSig()) {
      // Ranked alterado fora do app: zera e conta uma infração.
      rating = kStartRating;
      rw = 0;
      rg = 0;
      peakTier = 0;
      acStrikes++;
      await saveRank();
    }
    frame = p.getInt('cos_frame') ?? -1;
    nameColor = p.getInt('cos_name') ?? -1;
    // Quem já jogava antes do tutorial existir não precisa refazê-lo.
    final legacy = games > 0 ||
        ogames > 0 ||
        username.isNotEmpty ||
        p.getKeys().any((k) => k.startsWith('best_'));
    final tut = p.getBool('tut_done');
    tutorialDone = tut ?? legacy;
    if (tut == null && legacy) await p.setBool('tut_done', true);
    speedMul.value = p.getDouble('speed_mul') ?? 1.0;
    startLevel.value = p.getInt('start_level') ?? 1;
    var id = p.getString('device_id') ?? '';
    if (id.isEmpty) {
      final rnd = Random();
      id = List.generate(16, (_) => rnd.nextInt(36).toRadixString(36)).join();
      await p.setString('device_id', id);
    }
    deviceId = id;
    Elo.sanitize();
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('music_vol', musicVol.value);
    await p.setDouble('sfx_vol', sfxVol.value);
    await p.setString('pad_layout', layout.value.name);
    await p.setDouble('pad_scale', padScale.value);
    await p.setDouble('pad_opacity', padOpacity.value);
    await p.setDouble('swipe_sens', swipeSens.value);
    await p.setBool('haptics', haptics.value);
    await p.setBool('fx', fx.value);
    await p.setDouble('das', das.value);
    await p.setDouble('arr', arr.value);
    await p.setBool('flip_btn', flipBtn.value);
    await p.setBool('show_score', showScore.value);
    await p.setBool('show_next', showNext.value);
    await p.setBool('show_side', showSide.value);
    await p.setString('pad_custom', _encodeCustom());
    await p.setDouble('speed_mul', speedMul.value);
    await p.setInt('start_level', startLevel.value);
  }

  static void resetDefaults() {
    musicVol.value = 0.6;
    musicTrack.value = 0;
    musicAuto.value = true;
    speedMul.value = 1.0;
    startLevel.value = 1;
    sfxVol.value = 0.8;
    layout.value = PadLayout.standard;
    padScale.value = 1.0;
    padOpacity.value = 1.0;
    swipeSens.value = 1.0;
    haptics.value = true;
    fx.value = true;
    das.value = 170;
    arr.value = 50;
    flipBtn.value = true;
    showScore.value = true;
    showNext.value = true;
    showSide.value = true;
    custom = defaultCustom();
  }

  static void selection() {
    if (haptics.value) HapticFeedback.selectionClick();
  }

  static void light() {
    if (haptics.value) HapticFeedback.lightImpact();
  }

  static void medium() {
    if (haptics.value) HapticFeedback.mediumImpact();
  }
}

Uint8List _wavBytes(Float64List buf, int sr, {double smooth = 0.6}) {
  final total = buf.length;
  final data = ByteData(44 + total * 2);
  void str(int o, String s) {
    for (int i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + total * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sr, Endian.little);
  data.setUint32(28, sr * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, total * 2, Endian.little);
  var y = 0.0;
  for (int i = 0; i < total; i++) {
    y += smooth * (buf[i] - y);
    final v = (y.clamp(-1.0, 1.0) * 30000).round();
    data.setInt16(44 + i * 2, v, Endian.little);
  }
  return data.buffer.asUint8List();
}

void _addTone(
  Float64List buf,
  int sr,
  double f,
  double startSec,
  double durSec,
  double amp, {
  bool square = true,
  double? f2,
}) {
  final start = (startSec * sr).round();
  final len = (durSec * sr).round();
  final atk = (0.004 * sr).round();
  final rel = min((0.03 * sr).round(), len ~/ 2);
  var phase = 0.0;
  for (int i = 0; i < len; i++) {
    final idx = start + i;
    if (idx >= buf.length) break;
    final fr = f2 == null ? f : f + (f2 - f) * (i / len);
    phase += fr / sr;
    final ph = phase % 1.0;
    final w = square ? (ph < 0.4 ? 1.0 : -1.0) : (4 * (ph - 0.5).abs() - 1);
    var env = 1 - 0.35 * (i / len);
    if (i < atk) env *= i / atk;
    if (len - i < rel) env *= (len - i) / rel;
    buf[idx] += w * amp * env;
  }
}

double _midiFreq(num midi) => 440.0 * pow(2, (midi - 69) / 12).toDouble();

/// Canal de pulso estilo 8-bit (duty 12,5/25/50%), envelope rápido e vibrato nas notas longas.
void _pulse(Float64List buf, int sr, double f, double startSec, double durSec,
    double amp, double duty,
    {bool vibrato = false}) {
  final start = (startSec * sr).round();
  final len = (durSec * sr).round();
  final atk = (0.002 * sr).round();
  final rel = min((0.025 * sr).round(), len ~/ 2);
  var phase = 0.0;
  for (int i = 0; i < len; i++) {
    final idx = start + i;
    if (idx >= buf.length) break;
    final t = i / sr;
    var fr = f;
    if (vibrato && t > 0.14) {
      fr *= 1 + 0.006 * sin(2 * pi * 5.5 * (t - 0.14));
    }
    phase += fr / sr;
    final w = (phase % 1.0) < duty ? 1.0 : -1.0;
    var env = 0.62 + 0.38 * exp(-t * 14);
    env = (env * 15).round() / 15;
    if (i < atk) env *= i / atk;
    if (len - i < rel) env *= (len - i) / rel;
    buf[idx] += w * amp * env;
  }
}

/// Canal triangular 8-bit (4 bits, sem controle de volume).
void _triangle(Float64List buf, int sr, double f, double startSec,
    double durSec, double amp) {
  final start = (startSec * sr).round();
  final len = (durSec * sr).round();
  final atk = (0.003 * sr).round();
  final rel = min((0.015 * sr).round(), len ~/ 2);
  var phase = 0.0;
  for (int i = 0; i < len; i++) {
    final idx = start + i;
    if (idx >= buf.length) break;
    phase += f / sr;
    final ph = phase % 1.0;
    var w = 4 * (ph - 0.5).abs() - 1;
    w = (w * 7.5).round() / 7.5;
    var env = 1.0;
    if (i < atk) env = i / atk;
    if (len - i < rel) env *= (len - i) / rel;
    buf[idx] += w * amp * env;
  }
}

/// Canal de ruído (LFSR de 15 bits) para bumbo, caixa e chimbal.
void _noise(Float64List buf, int sr, double startSec, double durSec,
    double amp, int hold, double decay) {
  final start = (startSec * sr).round();
  final len = (durSec * sr).round();
  var lfsr = 0x7FFF;
  var v = 1.0;
  for (int i = 0; i < len; i++) {
    final idx = start + i;
    if (idx >= buf.length) break;
    if (i % hold == 0) {
      final bit = (lfsr ^ (lfsr >> 1)) & 1;
      lfsr = (lfsr >> 1) | (bit << 14);
      v = (lfsr & 1) == 0 ? 1.0 : -1.0;
    }
    buf[idx] += v * amp * exp(-(i / sr) * decay);
  }
}

const List<String> kTrackNames = [
  'Clássico 8-bit (original)',
  'Ode à Alegria',
  'Für Elise',
  'Arcade',
  'Calma',
  'Sinos de Natal',
  'Neon',
  'Chefão',
  'Espaço',
  'Festa',
  'Corrida',
];

List<List<num>> _altBass(List<List<int>> bars,
    {double step = 1.0, double beatsPerBar = 4}) {
  final out = <List<num>>[];
  final n = (beatsPerBar / step).round();
  for (final pair in bars) {
    for (int i = 0; i < n; i++) {
      out.add([pair[i % 2], step]);
    }
  }
  return out;
}

List<List<num>> _withDuty(List<List<num>> l, double duty) =>
    [for (final n in l) [n[0], n[1], duty]];

/// Notas curtas (colcheias) repetindo a nota-base de cada compasso.
List<List<num>> _pulseRoots(List<int> roots,
    {int shift = 0, double duty = 0.5}) {
  final out = <List<num>>[];
  for (final r in roots) {
    for (int i = 0; i < 8; i++) {
      out.add([r + shift, .5, duty]);
    }
  }
  return out;
}

/// Uma lista de notas por compasso, todas com a mesma duração.
List<List<num>> _beatsFrom(List<List<int>> bars,
    {double step = 1, double duty = 0.5}) {
  final out = <List<num>>[];
  for (final bar in bars) {
    for (final n in bar) {
      out.add([n, step, duty]);
    }
  }
  return out;
}

/// Arpejos de colcheias: 4 notas repetidas 2x = 4 tempos por acorde.
List<List<num>> _arp(List<List<int>> chords, int shift, double duty) {
  final out = <List<num>>[];
  for (final ch in chords) {
    for (int rep = 0; rep < 2; rep++) {
      for (final n in ch) {
        out.add([n + shift, .5, duty]);
      }
    }
  }
  return out;
}

Uint8List _renderTrack({
  required double bpm,
  required List<List<num>> lead,
  required List<List<num>> bass,
  List<List<num>> lead2 = const [],
  bool drums = false,
  double leadAmp = 0.13,
  double lead2Amp = 0.07,
  double leadDuty = 0.25,
}) {
  const sr = 32000;
  final beat = 60 / bpm;
  var total = 0.0;
  for (final n in lead) {
    total += n[1];
  }
  final buf = Float64List((total * beat * sr).round());
  var cur = 0.0;
  for (final n in lead) {
    final d = n[1].toDouble();
    if (n[0] > 0) {
      final duty = n.length > 2 ? n[2].toDouble() : leadDuty;
      _pulse(buf, sr, _midiFreq(n[0]), cur * beat, d * beat * 0.92, leadAmp,
          duty,
          vibrato: d >= 1.5);
    }
    cur += d;
  }
  cur = 0.0;
  for (final n in lead2) {
    final d = n[1].toDouble();
    if (n[0] > 0) {
      final duty = n.length > 2 ? n[2].toDouble() : 0.5;
      _pulse(buf, sr, _midiFreq(n[0]), cur * beat, d * beat * 0.9, lead2Amp,
          duty);
    }
    cur += d;
  }
  cur = 0.0;
  for (final n in bass) {
    final d = n[1].toDouble();
    if (n[0] > 0) {
      _triangle(buf, sr, _midiFreq(n[0]), cur * beat, d * beat * 0.88, 0.17);
    }
    cur += d;
  }
  if (drums) {
    final beats = total.floor();
    for (int b = 0; b < beats; b++) {
      final t = b * beat;
      if (b % 2 == 0) {
        _noise(buf, sr, t, 0.10, 0.08, 14, 35);
      } else {
        _noise(buf, sr, t, 0.12, 0.06, 3, 25);
      }
      _noise(buf, sr, t, 0.05, 0.025, 1, 120);
      _noise(buf, sr, t + beat / 2, 0.05, 0.02, 1, 120);
    }
  }
  return _wavBytes(buf, sr, smooth: 0.85);
}

/// "Clássico 8-bit": composição original em estilo de console antigo.
Uint8List _trackClassic() {
  const a = <List<num>>[
    [69, 1], [72, .5], [76, .5], [81, 1], [79, 1],
    [77, 1], [76, .5], [74, .5], [72, 2],
    [74, 1], [77, .5], [81, .5], [79, 1], [77, 1],
    [76, 1.5], [74, .5], [76, 2],
    [69, 1], [72, .5], [76, .5], [81, 1], [83, 1],
    [84, 1.5], [83, .5], [81, 1], [79, 1],
    [77, 1], [76, 1], [74, 1], [79, 1],
    [81, 3], [0, 1],
  ];
  const b = <List<num>>[
    [72, .5], [76, .5], [79, .5], [76, .5], [72, .5], [76, .5], [79, .5], [84, .5],
    [71, .5], [74, .5], [79, .5], [74, .5], [71, .5], [74, .5], [79, .5], [83, .5],
    [69, .5], [72, .5], [76, .5], [72, .5], [69, .5], [72, .5], [76, .5], [81, .5],
    [67, .5], [71, .5], [74, .5], [71, .5], [76, 2],
    [77, 1], [81, 1], [84, 1], [81, 1],
    [76, 1], [79, 1], [83, 1], [79, 1],
    [74, 1], [77, 1], [81, 1], [77, 1],
    [76, 1], [72, 1], [69, 2],
  ];
  const am = <int>[45, 52];
  const f = <int>[41, 48];
  const dm = <int>[38, 45];
  const e = <int>[40, 47];
  const c = <int>[48, 55];
  const g = <int>[43, 50];
  return _renderTrack(
    bpm: 140,
    lead: [..._withDuty(a, 0.25), ..._withDuty(b, 0.5)],
    bass: _altBass([
      am, f, dm, e, am, c, g, am,
      c, g, am, g, f, e, dm, am,
    ]),
    drums: true,
  );
}

/// Ode à Alegria (Beethoven, domínio público).
Uint8List _trackOde() {
  const p1 = <List<num>>[
    [76, 1], [76, 1], [77, 1], [79, 1],
    [79, 1], [77, 1], [76, 1], [74, 1],
    [72, 1], [72, 1], [74, 1], [76, 1],
    [76, 1.5], [74, .5], [74, 2],
  ];
  const p2 = <List<num>>[
    [76, 1], [76, 1], [77, 1], [79, 1],
    [79, 1], [77, 1], [76, 1], [74, 1],
    [72, 1], [72, 1], [74, 1], [76, 1],
    [74, 1.5], [72, .5], [72, 2],
  ];
  const p3 = <List<num>>[
    [74, 1], [74, 1], [76, 1], [72, 1],
    [74, 1], [76, .5], [77, .5], [76, 1], [72, 1],
    [74, 1], [76, .5], [77, .5], [76, 1], [74, 1],
    [72, 1], [74, 1], [67, 2],
  ];
  const c = <int>[48, 55];
  const g = <int>[43, 50];
  return _renderTrack(
    bpm: 132,
    lead: [...p1, ...p2, ...p3, ...p2],
    bass: _altBass([
      c, g, c, g, c, g, c, c,
      g, g, g, c, c, g, c, c,
    ]),
    leadDuty: 0.5,
    leadAmp: 0.14,
  );
}

/// Für Elise (Beethoven, domínio público).
Uint8List _trackElise() {
  const once = <List<num>>[
    [76, .25], [75, .25],
    [76, .25], [75, .25], [76, .25], [71, .25], [74, .25], [72, .25],
    [69, .5], [0, .25], [60, .25], [64, .25], [69, .25],
    [71, .5], [0, .25], [64, .25], [68, .25], [71, .25],
    [72, .5], [0, .25], [64, .25], [76, .25], [75, .25],
    [76, .25], [75, .25], [76, .25], [71, .25], [74, .25], [72, .25],
    [69, .5], [0, .25], [60, .25], [64, .25], [69, .25],
    [71, .5], [0, .25], [64, .25], [72, .25], [71, .25],
    [69, 1.5],
  ];
  const a = <int>[45, 52];
  const e = <int>[40, 47];
  final bassOnce = <List<num>>[
    [0, .5],
    ..._altBass([a, a, e, a, a, a, e, a], step: .75, beatsPerBar: 1.5),
  ];
  return _renderTrack(
    bpm: 112,
    lead: [...once, ...once],
    bass: [...bassOnce, ...bassOnce],
    leadDuty: 0.5,
    leadAmp: 0.14,
  );
}

/// "Arcade": composição original em estilo chiptune.
Uint8List _trackArcade() {
  const am = <int>[69, 72, 76, 72];
  const f = <int>[65, 69, 72, 69];
  const c = <int>[72, 76, 79, 76];
  const g = <int>[67, 71, 74, 71];
  const prog = <List<int>>[am, f, c, g, am, f, c, g];
  const roots = <List<int>>[
    [45, 57], [41, 53], [48, 60], [43, 55],
  ];
  return _renderTrack(
    bpm: 160,
    lead: [..._arp(prog, 0, 0.25), ..._arp(prog, 12, 0.5)],
    bass: _altBass([...roots, ...roots, ...roots, ...roots]),
    drums: true,
    leadAmp: 0.12,
  );
}

/// "Calma": composição original, andamento lento.
Uint8List _trackCalm() {
  const lead = <List<num>>[
    [76, 1], [79, 1], [76, 1], [72, 1],
    [74, 1], [79, 1], [71, 1], [74, 1],
    [76, 1], [72, 1], [69, 1], [72, 1],
    [69, 1], [72, 1], [77, 2],
    [79, 1], [76, 1], [72, 1], [76, 1],
    [74, 2], [71, 1], [74, 1],
    [72, 1], [69, 1], [72, 1], [76, 1],
    [77, 1], [76, 1], [72, 2],
  ];
  const cm = <int>[48, 55];
  const gm = <int>[43, 50];
  const am = <int>[45, 52];
  const fm = <int>[41, 48];
  return _renderTrack(
    bpm: 96,
    lead: lead,
    bass: _altBass([cm, gm, am, fm, cm, gm, am, fm], step: 2),
    leadDuty: 0.5,
    leadAmp: 0.12,
  );
}

/// Jingle Bells (James Lord Pierpont, 1857, domínio público).
Uint8List _trackJingle() {
  const a = <List<num>>[
    [76, 1], [76, 1], [76, 2],
    [76, 1], [76, 1], [76, 2],
    [76, 1], [79, 1], [72, 1.5], [74, .5],
    [76, 4],
  ];
  const b = <List<num>>[
    [77, 1], [77, 1], [77, 1.5], [77, .5],
    [77, 1], [76, 1], [76, 1], [76, .5], [76, .5],
    [76, 1], [74, 1], [74, 1], [76, 1],
    [74, 2], [79, 2],
  ];
  const end = <List<num>>[
    [77, 1], [77, 1], [77, 1.5], [77, .5],
    [77, 1], [76, 1], [76, 1], [76, .5], [76, .5],
    [79, 1], [79, 1], [77, 1], [74, 1],
    [72, 4],
  ];
  const c = <int>[48, 55];
  const f = <int>[41, 48];
  const g = <int>[43, 50];
  return _renderTrack(
    bpm: 150,
    lead: [...a, ...b, ...a, ...end],
    bass: _altBass([
      c, c, c, c, f, c, g, g,
      c, c, c, c, f, c, g, c,
    ]),
    drums: true,
    leadDuty: 0.5,
    leadAmp: 0.13,
  );
}

/// "Neon": composição original, clima de synthwave.
Uint8List _trackNeon() {
  const am = <int>[57, 60, 64, 60];
  const f = <int>[53, 57, 60, 57];
  const c = <int>[60, 64, 67, 64];
  const g = <int>[55, 59, 62, 59];
  const prog = <List<int>>[
    am, f, c, g, am, f, c, g, am, f, c, g, am, f, c, g,
  ];
  const melody = <List<num>>[
    [76, 4], [72, 4], [79, 4], [74, 4], [81, 4], [81, 4], [79, 4], [83, 4],
  ];
  const roots = <List<int>>[
    [45, 57], [41, 53], [48, 60], [43, 55],
  ];
  return _renderTrack(
    bpm: 110,
    lead: [
      ..._arp(prog.sublist(0, 8), 12, 0.125),
      ..._arp(prog.sublist(8), 12, 0.25),
    ],
    lead2: [...melody, ...melody],
    lead2Amp: 0.08,
    bass: _altBass([...roots, ...roots, ...roots, ...roots]),
    drums: true,
    leadAmp: 0.11,
  );
}

/// "Chefão": composição original, tensa e acelerada.
Uint8List _trackBoss() {
  const em = <int>[64, 67, 71, 67];
  const c = <int>[60, 64, 67, 64];
  const g = <int>[67, 71, 74, 71];
  const d = <int>[62, 66, 69, 66];
  const prog = <List<int>>[
    em, c, g, d, em, c, g, d, em, c, g, d, em, c, g, d,
  ];
  const roots = <int>[52, 48, 55, 50];
  const pairs = <List<int>>[
    [40, 47], [36, 43], [43, 50], [38, 45],
  ];
  return _renderTrack(
    bpm: 170,
    lead: [
      ..._arp(prog.sublist(0, 8), 12, 0.25),
      ..._arp(prog.sublist(8), 24, 0.5),
    ],
    lead2: _pulseRoots([...roots, ...roots, ...roots, ...roots], duty: 0.125),
    lead2Amp: 0.07,
    bass: _altBass([...pairs, ...pairs, ...pairs, ...pairs]),
    drums: true,
    leadAmp: 0.11,
  );
}

/// "Espaço": composição original, calma e flutuante.
Uint8List _trackSpace() {
  const lead = <List<num>>[
    [76, 4], [74, 4], [72, 4], [74, 2], [76, 2],
    [79, 4], [76, 4], [74, 4], [72, 4],
    [69, 4], [72, 4], [71, 4], [72, 2], [74, 2],
    [76, 4], [74, 2], [72, 2], [71, 4], [72, 4],
  ];
  const c = <int>[72, 76, 79, 76];
  const g = <int>[67, 71, 74, 71];
  const am = <int>[69, 72, 76, 72];
  const f = <int>[65, 69, 72, 69];
  const bc = <int>[48, 55];
  const bg = <int>[43, 50];
  const ba = <int>[45, 52];
  const bf = <int>[41, 48];
  return _renderTrack(
    bpm: 72,
    lead: lead,
    lead2: _beatsFrom(<List<int>>[
      c, g, am, f,
      c, am, g, c,
      am, f, g, c,
      c, g, g, c,
    ]),
    lead2Amp: 0.06,
    bass: _altBass(<List<int>>[
      bc, bg, ba, bf,
      bc, ba, bg, bc,
      ba, bf, bg, bc,
      bc, bg, bg, bc,
    ], step: 2),
    leadDuty: 0.5,
    leadAmp: 0.12,
  );
}

/// "Festa": composição original, alegre e dançante.
Uint8List _trackParty() {
  const c = <int>[72, 76, 79, 76];
  const f = <int>[69, 72, 77, 72];
  const g = <int>[71, 74, 79, 74];
  const prog = <List<int>>[
    c, f, g, c, c, f, g, c, c, f, g, c, c, f, g, c,
  ];
  const roots = <int>[48, 53, 55, 48];
  const pairs = <List<int>>[
    [48, 55], [41, 48], [43, 50], [48, 55],
  ];
  return _renderTrack(
    bpm: 140,
    lead: [
      ..._arp(prog.sublist(0, 8), 0, 0.25),
      ..._arp(prog.sublist(8), 12, 0.5),
    ],
    lead2: _pulseRoots([...roots, ...roots, ...roots, ...roots],
        shift: 12, duty: 0.25),
    lead2Amp: 0.06,
    bass: _altBass([...pairs, ...pairs, ...pairs, ...pairs]),
    drums: true,
    leadAmp: 0.12,
  );
}

/// "Corrida": composição original, muito rápida.
Uint8List _trackRace() {
  const dm = <int>[62, 65, 69, 65];
  const bb = <int>[58, 62, 65, 62];
  const f = <int>[65, 69, 72, 69];
  const c = <int>[60, 64, 67, 64];
  const prog = <List<int>>[
    dm, bb, f, c, dm, bb, f, c, dm, bb, f, c, dm, bb, f, c,
  ];
  const roots = <int>[50, 46, 53, 48];
  const pairs = <List<int>>[
    [38, 45], [34, 41], [41, 48], [36, 43],
  ];
  return _renderTrack(
    bpm: 185,
    lead: _arp(prog, 12, 0.125),
    lead2: _pulseRoots([...roots, ...roots, ...roots, ...roots], duty: 0.5),
    lead2Amp: 0.06,
    bass: _altBass([...pairs, ...pairs, ...pairs, ...pairs]),
    drums: true,
    leadAmp: 0.11,
  );
}

Uint8List _buildTrackIso(int track) {
  switch (track) {
    case 1:
      return _trackOde();
    case 2:
      return _trackElise();
    case 3:
      return _trackArcade();
    case 4:
      return _trackCalm();
    case 5:
      return _trackJingle();
    case 6:
      return _trackNeon();
    case 7:
      return _trackBoss();
    case 8:
      return _trackSpace();
    case 9:
      return _trackParty();
    case 10:
      return _trackRace();
    default:
      return _trackClassic();
  }
}

Map<String, Uint8List> _buildSfx() {
  const sr = 22050;
  Uint8List make(double dur, void Function(Float64List b) fill) {
    final b = Float64List((dur * sr).round());
    fill(b);
    return _wavBytes(b, sr);
  }

  void arp(Float64List b, List<double> notes, double step, double amp) {
    for (int i = 0; i < notes.length; i++) {
      _addTone(b, sr, notes[i], i * step, step * 1.4, amp);
    }
  }

  return {
    'rotate': make(0.07, (b) => _addTone(b, sr, 900, 0, 0.05, 0.25)),
    'drop': make(
        0.16, (b) => _addTone(b, sr, 160, 0, 0.12, 0.6, square: false, f2: 70)),
    'clear': make(0.45, (b) => arp(b, [523, 659, 784], 0.07, 0.22)),
    'quad':
        make(0.65, (b) => arp(b, [523, 659, 784, 1047, 1319], 0.085, 0.24)),
    'over': make(
        0.9,
        (b) => arp(b, [392, 330, 262, 196], 0.18, 0.28)),
  };
}

/// Música de fundo + efeitos sonoros (tudo gerado por código, sem arquivos).
class Audio {
  static final ValueNotifier<bool> music = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> sfx = ValueNotifier<bool>(true);
  static final AudioPlayer _bg = AudioPlayer();
  static final Map<String, AudioPlayer> _fx = {};
  static final Map<String, Source> _fxSrc = {};
  static final Map<int, Uint8List> _cache = {};
  static bool _dirty = false;
  static bool _started = false;

  static AudioContext get _ctx =>
      AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build();

  /// AudioContext só existe no Android e no iOS.
  static bool get _useCtx =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static Future<void> _setCtx(AudioPlayer p) async {
    if (!_useCtx) return;
    try {
      await p.setAudioContext(_ctx);
    } catch (_) {}
  }

  /// No Windows o audioplayers não toca bytes da memória: grava um .wav
  /// temporário e toca como arquivo.
  static String _tmp(String name) =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}$name';

  static Source _fxSource(String name, Uint8List bytes) {
    if (kWindows) {
      try {
        final f = File(_tmp('empilha_sfx_$name.wav'));
        f.writeAsBytesSync(bytes, flush: true);
        return DeviceFileSource(f.path, mimeType: 'audio/wav');
      } catch (_) {}
    }
    return BytesSource(bytes, mimeType: 'audio/wav');
  }

  static Future<Source> _musicSource(int t, Uint8List bytes) async {
    if (kWindows) {
      try {
        final f = File(_tmp('empilha_bgm_$t.wav'));
        if (!f.existsSync() || f.lengthSync() != bytes.length) {
          await f.writeAsBytes(bytes, flush: true);
        }
        return DeviceFileSource(f.path, mimeType: 'audio/wav');
      } catch (_) {}
    }
    return BytesSource(bytes, mimeType: 'audio/wav');
  }

  static StreamSubscription<void>? _sub;
  static int _current = 0;
  static int? _queued;
  static final Set<int> _inflight = {};

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    music.value = p.getBool('music_on') ?? true;
    sfx.value = p.getBool('sfx_on') ?? true;
    try {
      _buildSfx().forEach((k, v) {
        _fxSrc[k] = _fxSource(k, v);
        _fx[k] = AudioPlayer();
      });
      for (final pl in _fx.values) {
        await _setCtx(pl);
        try {
          await pl.setReleaseMode(ReleaseMode.stop);
        } catch (_) {}
      }
    } catch (_) {}
    _sub ??= _bg.onPlayerComplete.listen((_) => _onComplete());
    if (music.value) await _startMusic();
  }

  /// Próxima música: a seguinte da lista (ou sorteada, no modo Aleatória).
  static int _pickNext() {
    final n = kTrackNames.length;
    if (Settings.musicTrack.value >= n) {
      if (n <= 1) return 0;
      var t = Random().nextInt(n);
      while (t == _current) {
        t = Random().nextInt(n);
      }
      return t;
    }
    return (_current + 1) % n;
  }

  /// Prepara a próxima música em segundo plano para não haver pausa.
  static Future<void> _prefetch(int t) async {
    if (_cache.containsKey(t) || _inflight.contains(t)) return;
    _inflight.add(t);
    try {
      _cache[t] = await compute<int, Uint8List>(_buildTrackIso, t);
    } catch (_) {}
    _inflight.remove(t);
  }

  static Future<void> _onComplete() async {
    if (!music.value || !Settings.musicAuto.value) return;
    await _playTrack(_queued ?? _pickNext());
  }

  static Future<void> _startMusic() async {
    var t = Settings.musicTrack.value;
    if (t < 0 || t >= kTrackNames.length) {
      t = Random().nextInt(kTrackNames.length);
    }
    await _playTrack(t);
  }

  static Future<void> _playTrack(int t) async {
    try {
      _current = t;
      final bytes =
          _cache[t] ??= await compute<int, Uint8List>(_buildTrackIso, t);
      await _setCtx(_bg);
      await _bg.setReleaseMode(
          Settings.musicAuto.value ? ReleaseMode.stop : ReleaseMode.loop);
      await _bg.setVolume(Settings.musicVol.value);
      await _bg.play(await _musicSource(t, bytes));
      _started = true;
      _dirty = false;
      _queued = _pickNext();
      _prefetch(_queued!);
    } catch (_) {
      _started = false;
    }
  }

  static Future<void> setAuto(bool v) async {
    Settings.musicAuto.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('music_auto', v);
    try {
      await _bg.setReleaseMode(v ? ReleaseMode.stop : ReleaseMode.loop);
    } catch (_) {}
  }

  static Future<void> toggleMusic() async {
    music.value = !music.value;
    final p = await SharedPreferences.getInstance();
    await p.setBool('music_on', music.value);
    try {
      if (music.value) {
        if (_started && !_dirty) {
          await _bg.resume();
        } else {
          await _startMusic();
        }
      } else {
        await _bg.pause();
      }
    } catch (_) {}
  }

  static Future<void> changeTrack(int idx) async {
    Settings.musicTrack.value = idx;
    final p = await SharedPreferences.getInstance();
    await p.setInt('music_track', idx);
    if (music.value) {
      try {
        await _bg.stop();
      } catch (_) {}
      await _startMusic();
    } else {
      _dirty = true;
    }
  }

  static Future<void> setMusicVolume(double v) async {
    Settings.musicVol.value = v;
    try {
      await _bg.setVolume(v);
    } catch (_) {}
  }

  static Future<void> toggleSfx() async {
    sfx.value = !sfx.value;
    final p = await SharedPreferences.getInstance();
    await p.setBool('sfx_on', sfx.value);
  }

  static Future<void> play(String name) async {
    if (!sfx.value) return;
    final p = _fx[name];
    final s = _fxSrc[name];
    if (p == null || s == null) return;
    try {
      await p.stop();
      await p.play(s, volume: Settings.sfxVol.value);
    } catch (_) {}
  }

  static Future<void> pauseForBackground() async {
    try {
      if (_started) await _bg.pause();
    } catch (_) {}
  }

  static Future<void> resumeFromBackground() async {
    try {
      if (music.value && _started) await _bg.resume();
    } catch (_) {}
  }
}

/// Botões de música e efeitos (usados no menu e no jogo).
class SoundButtons extends StatelessWidget {
  const SoundButtons({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: Audio.music,
          builder: (_, on, __) => IconButton(
            tooltip: on ? 'Desligar música' : 'Ligar música',
            icon: Icon(on ? Icons.music_note : Icons.music_off,
                color: on ? Colors.white70 : Colors.white30),
            onPressed: Audio.toggleMusic,
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: Audio.sfx,
          builder: (_, on, __) => IconButton(
            tooltip: on ? 'Desligar efeitos' : 'Ligar efeitos',
            icon: Icon(on ? Icons.volume_up : Icons.volume_off,
                color: on ? Colors.white70 : Colors.white30),
            onPressed: Audio.toggleSfx,
          ),
        ),
      ],
    );
  }
}

// ===== game_screen.dart =====

class GameScreen extends StatefulWidget {
  final GameMode mode;
  final BlockTheme theme;
  final OnlineSession? session;

  const GameScreen({
    super.key,
    required this.mode,
    required this.theme,
    this.session,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late StackGame game;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  bool paused = false;
  bool _saved = false;
  bool _record = false;
  int? _best;
  int _lastLines = 0;
  int _lastLocks = 0;
  bool _overPlayed = false;
  double _dragX = 0;
  double _dragY = 0;

  // ---- teclado e controle (ver InputRouter)
  late final InputRouter _router;

  void _onAction(GameAction a) {
    switch (a) {
      case GameAction.pause:
        if (!online && !game.over) {
          _router.releaseAll();
          setState(() => paused = !paused);
        }
        break;
      case GameAction.restart:
        if (!online && game.over) _restart();
        break;
      case GameAction.rotateCw:
        _rotate();
        break;
      case GameAction.rotateCcw:
        _act(() => game.rotate(false));
        Audio.play('rotate');
        break;
      case GameAction.flip:
        _flip();
        break;
      case GameAction.hardDrop:
        _hardDrop();
        break;
      case GameAction.hold:
        _doHold();
        break;
      case GameAction.left:
      case GameAction.right:
      case GameAction.down:
        break;
    }
  }

  /// Botão B do controle nos menus da partida: continua ou sai.
  void _onBack() {
    if (paused && !game.over) {
      setState(() => paused = false);
    } else if (game.over || _won || _netLost || _raceLost) {
      _exit();
    }
  }

  // ---- multiplayer online
  Timer? _netTimer;
  bool _netBusy = false;
  int _netFails = 0;
  int _tickN = 0;
  final Map<String, _Opp> _opps = {};
  final Map<String, int> _outTo = {};
  int _sentAssigned = 0;
  final Random _targetRng = Random();
  bool _won = false;
  bool _netLost = false;
  int _place = 0;
  bool _raceLost = false;
  bool _rankedDone = false;
  int? _rankDelta;
  EloTier? _tierUp;
  bool _invalid = false;

  bool get _race =>
      widget.session?.kind == 'race' || widget.session?.kind == 'cheese';

  bool get _ultra => widget.session?.kind == 'ultra';

  bool _ultraDone = false;

  bool get online => widget.session != null;

  StackGame _newGame() {
    // Offline a semente é sorteada aqui e guardada: é ela que permite
    // reproduzir a partida inteira no replay.
    final seed = widget.session?.seed ?? Random().nextInt(0x7fffffff);
    final g = StackGame(
      widget.mode,
      seed: seed,
      garbageSeed: online ? null : seed ^ 0x2f6a1c,
      versus: online,
      startLevel: online ? 1 : Settings.startLevel.value,
      speedMul: online ? widget.session!.speed : Settings.speedMul.value,
    );
    if (!online) g.rec = <int>[];
    return g;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    game = _newGame();
    _router = InputRouter(
      isCurrent: () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
      playing: () => !paused && !game.over && !_won && !_netLost && !_raceLost,
      onLeft: () => _act(() => game.move(-1)),
      onRight: () => _act(() => game.move(1)),
      onDown: () => _act(() => game.softDrop()),
      onPress: _onAction,
      onBack: _onBack,
    )..attach();
    _loadBest();
    _ticker = createTicker(_tick)..start();
    final sess = widget.session;
    if (sess != null) {
      Presence.room = sess.code;
      Presence.roomName = sess.roomName;
      Presence.roomWaiting = false;
      for (final k in sess.roster) {
        if (k != sess.myKey) _opps[k] = _Opp(sess.names[k] ?? k);
      }
      // Anti-dodge: se o app fechar no meio da ranqueada, conta como derrota.
      if (sess.kind == 'ranked') AntiCheat.markRankedStart(sess);
      _netTimer = Timer.periodic(
          const Duration(milliseconds: 500), (_) => _netTick());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.detach();
    _ticker.dispose();
    _netTimer?.cancel();
    _forfeitRanked();
    if (online) {
      Presence.room = null;
      Presence.roomName = null;
      Presence.roomWaiting = false;
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _router.releaseAll();
    if (!online && state != AppLifecycleState.resumed && !game.over && mounted) {
      setState(() => paused = true);
    }
  }

  Future<void> _loadBest() async {
    final b = await Storage.best(widget.mode);
    if (mounted) setState(() => _best = b);
  }

  void _afterChange() {
    if (game.lockCount != _lastLocks) {
      _lastLocks = game.lockCount;
      if (game.lastCleared >= 3 || game.lastChain > 1) {
        Audio.play('quad');
      } else if (game.lastCleared > 0) {
        Audio.play('clear');
      } else {
        Audio.play('drop');
      }
    }
    if (game.gameOver && !_overPlayed) {
      _overPlayed = true;
      Audio.play('over');
    }
  }

  void _tick(Duration elapsed) {
    var dt = (elapsed - _last).inMilliseconds;
    _last = elapsed;
    _router.poke();
    if (paused || game.over || _won || _netLost || _raceLost) return;
    if (dt <= 0) return;
    if (dt > 100) dt = 100;
    game.update(dt);
    if (game.lines != _lastLines) {
      _lastLines = game.lines;
      Settings.medium();
    }
    _afterChange();
    if (game.over && !_saved) {
      _saved = true;
      _saveScore();
    }
    setState(() {});
  }

  ReplayData? _replayData() {
    final r = game.rec;
    final s = game.seed;
    if (online || r == null || r.isEmpty || s == null) return null;
    return ReplayData(
      mode: widget.mode,
      seed: s,
      gseed: s ^ 0x2f6a1c,
      startLevel: game.startLevel,
      speed: game.speedMul,
      score: game.score,
      lines: game.lines,
      ms: game.elapsedMs,
      finished: game.finished,
      at: DateTime.now().millisecondsSinceEpoch,
      rec: List<int>.from(r),
    );
  }

  void _watchReplay() {
    final d = _replayData();
    if (d == null) return;
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => ReplayScreen(data: d)));
  }

  Future<void> _saveScore() async {
    if (online) return;
    final bad = AntiCheat.checkGame(game);
    if (bad != null) {
      await AntiCheat.strike(bad);
      if (mounted) setState(() => _invalid = true);
      return;
    }
    final rec = await Storage.submit(widget.mode, game);
    final rd = _replayData();
    if (rd != null && rd.rec.length <= 60000) {
      Storage.saveReplay('replay_last', rd);
      if (rec) Storage.saveReplay('replay_best_${widget.mode.name}', rd);
    }
    final b = await Storage.best(widget.mode);
    await Settings.addGame(game.score);
    Account.sync();
    if (mounted) {
      setState(() {
        _record = rec;
        _best = b;
      });
    }
  }

  void _act(VoidCallback f) {
    if (paused || game.over || _won || _netLost || _raceLost) return;
    setState(f);
    _afterChange();
    if (game.over && !_saved) {
      _saved = true;
      _saveScore();
    }
  }

  void _rotate() {
    _act(() => game.rotate(true));
    Settings.selection();
    Audio.play('rotate');
  }

  void _flip() {
    _act(() => game.rotate180());
    Settings.selection();
    Audio.play('rotate');
  }

  void _hardDrop() {
    _act(game.hardDrop);
    Settings.light();
  }

  void _doHold() {
    _act(game.hold);
    Settings.selection();
  }

  void _restart() {
    setState(() {
      game = _newGame();
      paused = false;
      _saved = false;
      _record = false;
      _invalid = false;
      _lastLines = 0;
      _lastLocks = 0;
      _overPlayed = false;
    });
  }

  Future<void> _exit() async {
    if (online) _leaveRoom();
    final canSave = !online && widget.mode.savesOnExit;
    if (!_saved && canSave && !game.over) {
      _saved = true;
      if (AntiCheat.checkGame(game) == null) {
        await Storage.submit(widget.mode, game);
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final custom = Settings.layout.value == PadLayout.custom;
            return Stack(
              children: [
                Column(
                  children: [
                    _topBar(),
                    if (Settings.showScore.value)
                      _scoreboard()
                    else
                      const SizedBox(height: 4),
                    if (online) _oppStrip(),
                    Expanded(child: LayoutBuilder(builder: _playfield)),
                    if (kDesktop)
                      _keyHint()
                    else if (custom)
                      SizedBox(
                        height:
                            Settings.bottomReserve(box.maxWidth, box.maxHeight),
                      )
                    else
                      _controls(),
                  ],
                ),
                if (custom && !kDesktop)
                  CustomPad(
                    w: box.maxWidth,
                    h: box.maxHeight,
                    actions: <String, VoidCallback>{
                      'left': () => _act(() => game.move(-1)),
                      'right': () => _act(() => game.move(1)),
                      'down': () => _act(() => game.softDrop()),
                      'rotate': _rotate,
                      'flip': _flip,
                      'drop': _hardDrop,
                      'hold': _doHold,
                    },
                  ),
                if (paused && !game.over) _pauseOverlay(),
                if (game.over || _won || _netLost || _raceLost) _endOverlay(),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _keyHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: ValueListenableBuilder<String?>(
        valueListenable: Gamepad.name,
        builder: (_, pad, __) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Controls.hint(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
            if (pad != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('🎮 ${Controls.padHint()}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.cyanAccent.withAlpha(150),
                        fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white70),
            onPressed: _exit,
          ),
          Text(online ? 'Online · ${widget.session!.code}' : widget.mode.title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const Spacer(),
          const SoundButtons(),
          if (!online)
            IconButton(
              icon: Icon(paused ? Icons.play_arrow : Icons.pause,
                  color: Colors.white70),
              onPressed: () => setState(() => paused = !paused),
            ),
        ],
      ),
    );
  }

  /// Placar grande no topo: pontos atuais + recorde.
  Widget _scoreboard() {
    final sprint = widget.mode.timeBased;
    String bestText;
    if (sprint) {
      bestText = _best == null ? '—' : fmtTime(_best!);
    } else {
      bestText = fmtScore(max(_best ?? 0, game.score));
    }
    if (online) bestText = '$_aliveCount/${widget.session!.roster.length}';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PONTOS',
                    style: TextStyle(
                        color: Colors.white54, fontSize: 10, letterSpacing: 1)),
                Text(fmtScore(game.score),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w900)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(online ? 'VIVOS' : (sprint ? 'MELHOR TEMPO' : 'RECORDE'),
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 10, letterSpacing: 1)),
              Text(bestText,
                  style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _playfield(BuildContext context, BoxConstraints c) {
    gNesLevel = game.level - 1;
    const sideW = 58.0;
    final showSide = Settings.showSide.value;
    final showNext = Settings.showNext.value || online;
    final cell = min(
        (c.maxWidth - (showSide ? sideW : 0) - (showNext ? sideW : 0) - 24) /
            kCols,
        c.maxHeight / kRows);
    final boardW = cell * kCols;
    final boardH = cell * kRows;
    final g = game;

    final left = SizedBox(
      width: sideW,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('RESERVA'),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _doHold,
            child: _pieceBox(g.holdType, dim: !g.canHold, hint: true),
          ),
          const SizedBox(height: 10),
          _stat(
              'LINHAS',
              widget.mode.lineGoal != null
                  ? '${g.lines}/${widget.mode.lineGoal}'
                  : '${g.lines}'),
          _objective(),
        ],
      ),
    );

    final next = g.preview;
    final right = SizedBox(
      width: sideW,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('NEXT'),
          for (final t in next) _pieceBox(t),
          if (online) ...[
            const SizedBox(height: 6),
            if (game.pendingGarbage > 0)
              Text('+${game.pendingGarbage}',
                  style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            if (_netFails >= 3)
              const Text('sem rede…',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 10)),
          ],
        ],
      ),
    );

    final board = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _rotate,
      onLongPress: Settings.layout.value == PadLayout.gestures ? _flip : null,
      onPanStart: (_) {
        _dragX = 0;
        _dragY = 0;
      },
      onPanUpdate: (d) {
        final step = cell * 0.9 / Settings.swipeSens.value;
        _dragX += d.delta.dx;
        _dragY += d.delta.dy;
        if (_dragY < 0) _dragY = 0;
        while (_dragX > step) {
          _act(() => game.move(1));
          _dragX -= step;
        }
        while (_dragX < -step) {
          _act(() => game.move(-1));
          _dragX += step;
        }
        while (_dragY > step) {
          _act(() => game.softDrop());
          _dragY -= step;
        }
      },
      onPanEnd: (d) {
        final v = d.velocity.pixelsPerSecond;
        if (v.dy > 1400 && v.dy.abs() > v.dx.abs() * 2) {
          _hardDrop();
        } else if (v.dy < -1000 && v.dy.abs() > v.dx.abs() * 2) {
          _doHold();
        }
      },
      child: SizedBox(
        width: boardW,
        height: boardH,
        child: Stack(
          children: [
            CustomPaint(
              size: Size(boardW, boardH),
              painter: BoardPainter(game, Settings.theme.value),
            ),
            if (game.bannerMs > 0 && game.banner != null)
              Positioned.fill(
                child: Center(
                  child: Text(
                    game.banner!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSide) ...[left, const SizedBox(width: 6)],
          board,
          if (showNext) ...[const SizedBox(width: 6), right],
        ],
      ),
    );
  }

  Widget _objective() {
    switch (widget.mode) {
      case GameMode.classic:
        return _stat('NÍVEL', '${game.level}');
      case GameMode.sprint:
        return _stat('TEMPO', fmtTime(game.elapsedMs));
      case GameMode.ultra:
        return _stat('RESTA', fmtTime(120000 - game.elapsedMs));
      case GameMode.zen:
        return _stat('TEMPO', fmtTime(game.elapsedMs));
      case GameMode.marathon:
        return _stat('NÍVEL', '${game.level}');
      case GameMode.survival:
        return _stat('TEMPO', fmtTime(game.elapsedMs));
      case GameMode.cheese:
        return _stat(
            'LIXO', '${game.board.where((r) => r.contains(8)).length}');
    }
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t,
            style: const TextStyle(
                color: Colors.white54, fontSize: 10, letterSpacing: 1)),
      );

  Widget _pieceBox(int? type, {bool dim = false, bool hint = false}) {
    return Container(
      width: 56,
      height: 42,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: (type == null && hint)
          ? const Center(
              child: Icon(Icons.swap_vert, color: Colors.white24, size: 22))
          : CustomPaint(painter: PiecePainter(type, Settings.theme.value, dim: dim)),
    );
  }

  Widget _stat(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 10, letterSpacing: 1)),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      );

  /// Controles configuráveis em Configurações (layout, tamanho ou só gestos).
  Widget _controls() {
    return ControlPad(
      layout: Settings.layout.value,
      scale: Settings.padScale.value,
      onLeft: () => _act(() => game.move(-1)),
      onRight: () => _act(() => game.move(1)),
      onDown: () => _act(() => game.softDrop()),
      onRotate: _rotate,
      onDrop: _hardDrop,
      onFlip: _flip,
    );
  }

  Widget _overlay(String title, List<Widget> children) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withAlpha(190),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w900)),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn(String text, VoidCallback onTap, {bool autofocus = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: SizedBox(
          width: 220,
          child: FilledButton(
              autofocus: autofocus, onPressed: onTap, child: Text(text)),
        ),
      );

  Widget _pauseOverlay() => _overlay('Pausado', [
        _btn('Continuar', () => setState(() => paused = false),
            autofocus: true),
        _btn(Audio.music.value ? 'Música: ligada' : 'Música: desligada',
            () async {
          await Audio.toggleMusic();
          if (mounted) setState(() {});
        }),
        _btn(Audio.sfx.value ? 'Efeitos: ligados' : 'Efeitos: desligados',
            () async {
          await Audio.toggleSfx();
          if (mounted) setState(() {});
        }),
        _btn('Configurações', () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const SettingsScreen()),
          );
          if (mounted) setState(() {});
        }),
        _btn('Teclas e controle', () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ControlsScreen()),
          );
          if (mounted) setState(() {});
        }),
        _btn('Reiniciar', _restart),
        _btn('Menu', _exit),
      ]);

  String _encodeBoard() {
    final rows = game.board.map((r) => List<int>.from(r)).toList();
    final cur = game.current;
    for (int r = 0; r < cur.shape.length; r++) {
      for (int c = 0; c < cur.shape.length; c++) {
        if (cur.shape[r][c] == 0) continue;
        final by = cur.y + r;
        final bx = cur.x + c;
        if (by >= 0 && by < kRows && bx >= 0 && bx < kCols) {
          rows[by][bx] = cur.type;
        }
      }
    }
    return rows.expand((r) => r).join();
  }

  int get _aliveCount =>
      (game.gameOver ? 0 : 1) + _opps.values.where((o) => o.alive).length;

  Widget _oppStrip() {
    return SizedBox(
      height: 58,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final o in _opps.values)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Column(
                children: [
                  SizedBox(
                    width: 22,
                    height: 44,
                    child: CustomPaint(
                        painter: MiniBoardPainter(o.board, dim: !o.alive)),
                  ),
                  SizedBox(
                    width: 34,
                    child: Text(
                      o.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 9,
                        color: o.alive ? Colors.white70 : Colors.white30,
                        decoration: o.alive ? null : TextDecoration.lineThrough,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _netTick() async {
    final s = widget.session;
    if (s == null || _netBusy || !mounted) return;
    _netBusy = true;
    try {
      // Ataque novo desde o último envio: vai para um rival vivo sorteado.
      final delta = game.sentTotal - _sentAssigned;
      if (delta > 0) {
        final alive = _opps.entries
            .where((e) => e.value.alive)
            .map((e) => e.key)
            .toList();
        if (alive.isNotEmpty) {
          final target = alive[_targetRng.nextInt(alive.length)];
          _outTo[target] = (_outTo[target] ?? 0) + delta;
        }
        _sentAssigned = game.sentTotal;
      }
      await Net.put(s.base, 'rooms/${s.code}/s/${s.myKey}', {
        'b': _encodeBoard(),
        'score': game.score,
        'over': game.gameOver,
        'fin': game.finished,
        'lines': game.lines,
        'n': _tickN++,
        'to': _outTo,
      });
      if (s.host && _tickN % 16 == 1) {
        Net.put(s.base, 'rooms/_public/${s.code}', {
          'name': s.roomName.isEmpty ? s.code : s.roomName,
          'host': Settings.username,
          'private': s.priv,
          'av': Settings.avatar,
          'count': s.roster.length,
          'max': s.maxP,
          'kind': s.kind,
          'speed': s.speed,
          'state': 'playing',
          't': {'.sv': 'timestamp'},
        }).catchError((_) {});
      }
      final all = await Net.get(s.base, 'rooms/${s.code}/s');
      for (final e in _opps.entries) {
        final o = all is Map ? all[e.key] : null;
        final opp = e.value;
        if (o is Map) {
          opp.board = (o['b'] as String?) ?? '';
          opp.score = (o['score'] as num?)?.toInt() ?? 0;
          if (o['over'] == true) opp.over = true;
          if (o['fin'] == true) opp.fin = true;
          opp.lines = (o['lines'] as num?)?.toInt() ?? 0;
          final n = (o['n'] as num?)?.toInt() ?? -1;
          if (n != opp.n) {
            opp.n = n;
            opp.stale = 0;
          } else {
            opp.stale++;
          }
          final to = o['to'];
          if (to is Map) {
            var got = (to[s.myKey] as num?)?.toInt() ?? 0;
            // Lixo acima do que as linhas do rival permitem é ignorado.
            final cap = AntiCheat.maxAttack(opp.lines, game.elapsedMs);
            if (got > cap) {
              opp.suspect++;
              got = cap;
              if (opp.suspect == 3) {
                AntiCheat.report(s, e.key, 'ataque acima do limite possível');
              }
            }
            if (got > opp.seenAtk) {
              game.pendingGarbage += got - opp.seenAtk;
              opp.seenAtk = got;
            }
          }
        } else {
          opp.stale++;
        }
      }
      _netFails = 0;
    } catch (_) {
      _netFails++;
    }
    _netBusy = false;
    if (!mounted) return;
    final aliveOpps = _opps.values.where((o) => o.alive).length;
    if (_race && game.finished && !_won && !_raceLost) {
      _won = true;
      Audio.play('clear');
      Settings.addOnline(true, game.score);
    } else if (_race &&
        !game.finished &&
        !_won &&
        !_raceLost &&
        _opps.values.any((o) => o.fin)) {
      _raceLost = true;
      Settings.addOnline(false, game.score);
    }
    if (game.gameOver && _place == 0) {
      _place = aliveOpps + 1;
      Settings.addOnline(false, game.score);
    }
    if (!game.over && !_won && !_netLost && !_raceLost) {
      if (aliveOpps == 0) {
        _won = true;
        Audio.play('clear');
        if (!_race) _netTimer?.cancel();
        Settings.addOnline(true, game.score);
      } else if (_netFails >= 30) {
        _netLost = true;
      }
    }
    if (_ultra && game.finished && !_ultraDone && !_won && !_netLost) {
      final pending = _opps.values.any((o) => o.alive && !o.fin);
      if (!pending) {
        _ultraDone = true;
        final ahead = _opps.values
            .where((o) =>
                o.alive &&
                o.fin &&
                (o.score > game.score ||
                    (o.score == game.score && o.lines > game.lines)))
            .length;
        if (ahead == 0) {
          _won = true;
          Audio.play('clear');
          Settings.addOnline(true, game.score);
        } else {
          _place = ahead + 1;
          Settings.addOnline(false, game.score);
        }
      }
    }
    _applyRanked();
    setState(() {});
  }

  /// Sair de uma ranqueada em andamento conta como derrota (anti-dodge).
  void _forfeitRanked() {
    final s = widget.session;
    if (s == null || s.kind != 'ranked' || _rankedDone) return;
    _rankedDone = true;
    final alive = _opps.values.where((o) => o.alive).length;
    final int place;
    if (_won) {
      place = 1;
    } else if (_place > 0) {
      place = _place;
    } else if (game.gameOver) {
      place = alive + 1;
    } else {
      place = s.roster.length;
    }
    Account.applyRanked(s, place,
        elapsedMs: game.elapsedMs,
        suspicious: AntiCheat.checkGame(game, versus: true) != null);
  }

  void _leaveRoom() {
    final s = widget.session;
    if (s == null) return;
    _forfeitRanked();
    _netTimer?.cancel();
    if (s.host) {
      Net.delete(s.base, 'rooms/${s.code}').catchError((_) {});
      Net.delete(s.base, 'rooms/_public/${s.code}').catchError((_) {});
    } else {
      Net.patch(s.base, 'rooms/${s.code}/s/${s.myKey}', {'over': true})
          .catchError((_) {});
      Net.delete(s.base, 'rooms/${s.code}/players/${s.myKey}')
          .catchError((_) {});
    }
  }

  void _rematch() {
    final s = widget.session!;
    _netTimer?.cancel();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => OnlineWaitScreen(
            code: s.code, host: s.host, afterRound: s.round),
      ),
    );
  }

  Future<void> _nextRanked() async {
    _leaveRoom();
    try {
      final (code, host) = await Rooms.quickMatch();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => OnlineWaitScreen(code: code, host: host)),
      );
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  void _changeMode() {
    _leaveRoom();
    Navigator.popUntil(context, (r) => r.isFirst);
  }

  Widget _blueBtn(String text, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: SizedBox(
          width: 250,
          child: FilledButton(
            style: kBlueOutline,
            onPressed: onTap,
            child: Text(text),
          ),
        ),
      );

  void _applyRanked() {
    final sess = widget.session;
    if (sess == null || sess.kind != 'ranked' || _rankedDone) return;
    int? place;
    if (_won) {
      place = 1;
    } else if (_place > 0) {
      place = _place;
    } else if (_netLost) {
      place = sess.roster.length; // caiu da partida: conta como último lugar
    }
    if (place == null) return;
    _rankedDone = true;
    final before = Elo.peakIndex;
    final bad = AntiCheat.checkGame(game, versus: true);
    Account.applyRanked(sess, place,
            elapsedMs: game.elapsedMs, suspicious: bad != null)
        .then((d) {
      if (!mounted) return;
      setState(() {
        _rankDelta = d;
        if (Elo.peakIndex > before) _tierUp = Elo.tiers[Elo.peakIndex];
      });
    });
  }

  void _watch() {
    final sess = widget.session!;
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => SpectatorScreen(code: sess.code, register: false)),
    );
  }

  Widget _onlineEnd() {
    final sess = widget.session!;
    final total = sess.roster.length;
    final done = _won ||
        _netLost ||
        _raceLost ||
        _ultraDone ||
        _opps.values.every((o) => !o.alive);
    String title;
    if (_netLost) {
      title = 'Conexão perdida';
    } else if (_won) {
      title = _race ? 'Você venceu a corrida!' : 'Você venceu!';
    } else if (_raceLost) {
      title = 'Alguém terminou primeiro';
    } else if (_ultra && game.finished && !_ultraDone) {
      title = 'Tempo esgotado!';
    } else {
      title = 'Você ficou em #${_place == 0 ? total : _place} de $total';
    }
    return _overlay(title, [
      Text('Seus pontos: ${fmtScore(game.score)}',
          style: const TextStyle(color: Colors.white, fontSize: 20)),
      if (sess.kind == 'ranked' && _rankDelta != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
              'Rating: ${Settings.rating} (${_rankDelta! >= 0 ? '+' : ''}$_rankDelta)',
              style: TextStyle(
                  color: _rankDelta! >= 0 ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ),
      if (sess.kind == 'ranked' && _rankDelta != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: EloBadge(tier: Elo.tierFor(Settings.rating)),
        ),
      if (_tierUp != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
              'Você subiu para ${_tierUp!.name}!\nNovas recompensas liberadas em "Elos e recompensas".',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _tierUp!.color,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ),
      if (!done)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Aguardando o fim da partida… ($_aliveCount vivos)',
              style: const TextStyle(color: Colors.white70)),
        ),
      if (done && !sess.host && sess.kind != 'ranked')
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Volte para a sala e espere o anfitrião iniciar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70)),
        ),
      if (done && sess.host && sess.kind != 'ranked')
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Volte para a sala e inicie quando todos estiverem de volta.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70)),
        ),
      const SizedBox(height: 16),
      if (!done) _blueBtn('Assistir a partida', _watch),
      if (done && sess.kind == 'ranked')
        _blueBtn('Nova ranqueada', _nextRanked)
      else if (done)
        _blueBtn('Voltar para a sala', _rematch),
      _blueBtn('Voltar ao lobby', _exit),
      _blueBtn('Trocar modo de jogo', _changeMode),
    ]);
  }

  Widget _endOverlay() {
    if (online) return _onlineEnd();
    String title;
    if (widget.mode.hasGoal && game.finished) {
      title = 'Concluído!';
    } else if (game.finished) {
      title = 'Tempo esgotado!';
    } else {
      title = 'Fim de jogo';
    }
    return _overlay(title, [
      Text('Pontos: ${fmtScore(game.score)}',
          style: const TextStyle(color: Colors.white, fontSize: 20)),
      Text('Linhas: ${game.lines}   Tempo: ${fmtTime(game.elapsedMs)}',
          style: const TextStyle(color: Colors.white70, fontSize: 14)),
      Text(
          'Peças: ${game.lockCount}   Peças/s: ${(game.lockCount / max(1.0, game.elapsedMs / 1000)).toStringAsFixed(2).replaceAll('.', ',')}',
          style: const TextStyle(color: Colors.white70, fontSize: 14)),
      if (game.triples > 0 ||
          game.maxChain > 1 ||
          game.maxCombo > 1)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
              [
                if (game.triples > 0) 'Triplas ou mais: ${game.triples}',
                if (game.maxChain > 1) 'Maior cascata: x${game.maxChain}',
                if (game.maxCombo > 1) 'Maior combo: x${game.maxCombo}',
              ].join('   '),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.amber, fontSize: 14)),
        ),
      if (_invalid)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Resultado inválido: pontuação não registrada.',
              style: TextStyle(color: Colors.redAccent, fontSize: 14)),
        ),
      if (_record)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Novo recorde!',
              style: TextStyle(
                  color: Colors.amber,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ),
      const SizedBox(height: 16),
      if (game.rec != null && game.rec!.isNotEmpty)
        _btn('Assistir replay', _watchReplay),
      _btn('Jogar de novo', _restart, autofocus: true),
      _btn('Menu', _exit),
    ]);
  }
}

/// Repetição ao segurar (botão ou tecla): espera [dasMs] e então repete a
/// cada [arrMs]. Com arrMs = 0 a peça corre direto até a parede.
class AutoRepeat {
  Timer? _t;

  void start(VoidCallback f, {required int dasMs, required int arrMs}) {
    stop();
    _t = Timer(Duration(milliseconds: dasMs), () {
      if (arrMs <= 0) {
        void burst() {
          for (int i = 0; i < kCols; i++) {
            f();
          }
        }

        burst();
        _t = Timer.periodic(const Duration(milliseconds: 33), (_) => burst());
      } else {
        _t = Timer.periodic(Duration(milliseconds: arrMs), (_) => f());
      }
    });
  }

  void stop() {
    _t?.cancel();
    _t = null;
  }
}

class ControlPad extends StatelessWidget {
  final PadLayout layout;
  final double scale;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onDown;
  final VoidCallback onRotate;
  final VoidCallback onDrop;
  final VoidCallback? onFlip;
  final bool forceFlip;

  const ControlPad({
    super.key,
    required this.layout,
    required this.scale,
    required this.onLeft,
    required this.onRight,
    required this.onDown,
    required this.onRotate,
    required this.onDrop,
    this.onFlip,
    this.forceFlip = false,
  });

  @override
  Widget build(BuildContext context) {
    if (layout == PadLayout.gestures) return const SizedBox(height: 6);
    return LayoutBuilder(builder: (context, c) {
      final flipOn = onFlip != null && (forceFlip || Settings.flipBtn.value);
      final fit = (c.maxWidth - 32 - 24 - 8 - (flipOn ? 8 : 0)) /
          (5.3 + (flipOn ? 0.8 : 0));
      final u = min(fit, 84.0) * scale;
      final moves = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PadButton(
              icon: Icons.chevron_left,
              size: u,
              repeat: true,
              dasRepeat: true,
              onPress: onLeft),
          const SizedBox(width: 8),
          _PadButton(
              icon: Icons.keyboard_arrow_down,
              size: u,
              repeat: true,
              repeatMs: 35,
              onPress: onDown),
          const SizedBox(width: 8),
          _PadButton(
              icon: Icons.chevron_right,
              size: u,
              repeat: true,
              dasRepeat: true,
              onPress: onRight),
        ],
      );
      final drop = _PadButton(
          icon: Icons.vertical_align_bottom,
          size: u,
          accent: Colors.amber,
          onPress: onDrop);
      final rotate = _PadButton(
          icon: Icons.rotate_right,
          size: u * 1.3,
          accent: Colors.cyanAccent,
          onPress: onRotate);
      final flip = flipOn
          ? _PadButton(
              icon: Icons.sync,
              size: u * 0.8,
              accent: Colors.pinkAccent,
              onPress: onFlip!)
          : null;
      final mirrored = layout == PadLayout.mirrored;
      final actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: mirrored
            ? [
                rotate,
                const SizedBox(width: 8),
                if (flip != null) ...[flip, const SizedBox(width: 8)],
                drop,
              ]
            : [
                drop,
                const SizedBox(width: 8),
                if (flip != null) ...[flip, const SizedBox(width: 8)],
                rotate,
              ],
      );
      return Opacity(
        opacity: Settings.padOpacity.value,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: mirrored ? [actions, moves] : [moves, actions],
          ),
        ),
      );
    });
  }
}

_PadButton _padFor(String key, double size, VoidCallback onPress) {
  switch (key) {
    case 'left':
      return _PadButton(
          icon: Icons.chevron_left,
          size: size,
          repeat: true,
          dasRepeat: true,
          onPress: onPress);
    case 'right':
      return _PadButton(
          icon: Icons.chevron_right,
          size: size,
          repeat: true,
          dasRepeat: true,
          onPress: onPress);
    case 'down':
      return _PadButton(
          icon: Icons.keyboard_arrow_down,
          size: size,
          repeat: true,
          repeatMs: 35,
          onPress: onPress);
    case 'drop':
      return _PadButton(
          icon: Icons.vertical_align_bottom,
          size: size,
          accent: Colors.amber,
          onPress: onPress);
    case 'rotate':
      return _PadButton(
          icon: Icons.rotate_right,
          size: size,
          accent: Colors.cyanAccent,
          onPress: onPress);
    case 'flip':
      return _PadButton(
          icon: Icons.sync,
          size: size,
          accent: Colors.pinkAccent,
          onPress: onPress);
    default:
      return _PadButton(
          icon: Icons.swap_vert,
          size: size,
          accent: Colors.purpleAccent,
          onPress: onPress);
  }
}

/// Botões do HUD personalizado, posicionados livremente sobre a tela do jogo.
class CustomPad extends StatelessWidget {
  final double w;
  final double h;
  final Map<String, VoidCallback> actions;

  const CustomPad({
    super.key,
    required this.w,
    required this.h,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    Settings.custom.forEach((key, it) {
      final act = actions[key];
      if (!it.on || act == null) return;
      items.add(Positioned(
        left: (it.x * w - it.size / 2)
            .clamp(0.0, max(0.0, w - it.size))
            .toDouble(),
        top: (it.y * h - it.size / 2)
            .clamp(0.0, max(0.0, h - it.size))
            .toDouble(),
        child: Opacity(
          opacity: Settings.padOpacity.value,
          child: _padFor(key, it.size, act),
        ),
      ));
    });
    return SizedBox(width: w, height: h, child: Stack(children: items));
  }
}

class _PadButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPress;
  final double size;
  final bool repeat;
  final int repeatMs;
  final bool dasRepeat; // usa o DAS/ARR das configurações (esquerda/direita)
  final Color? accent;

  const _PadButton({
    required this.icon,
    required this.onPress,
    required this.size,
    this.repeat = false,
    this.repeatMs = 55,
    this.dasRepeat = false,
    this.accent,
  });

  @override
  State<_PadButton> createState() => _PadButtonState();
}

class _PadButtonState extends State<_PadButton> {
  final AutoRepeat _rep = AutoRepeat();
  bool _down = false;

  void _start() {
    setState(() => _down = true);
    widget.onPress();
    if (!widget.repeat) return;
    _rep.start(
      widget.onPress,
      dasMs: widget.dasRepeat ? Settings.das.value.round() : 170,
      arrMs: widget.dasRepeat ? Settings.arr.value.round() : widget.repeatMs,
    );
  }

  void _stop() {
    _rep.stop();
    if (mounted && _down) setState(() => _down = false);
  }

  @override
  void dispose() {
    _rep.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final base = accent ?? Colors.white;
    final fill = accent != null ? (_down ? 150 : 70) : (_down ? 70 : 30);
    return Listener(
      onPointerDown: (_) => _start(),
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: AnimatedScale(
        scale: _down ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 60),
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: base.withAlpha(fill),
            borderRadius: BorderRadius.circular(widget.size * 0.3),
            border: Border.all(
                color: base.withAlpha(_down ? 230 : 120), width: 1.5),
          ),
          child: Icon(widget.icon, color: Colors.white, size: widget.size * 0.6),
        ),
      ),
    );
  }
}

// ===== input.dart: teclas, controle (gamepad) e navegação por controle =====

/// Ações do jogo que podem ser ligadas a teclas e a botões do controle.
enum GameAction {
  left,
  right,
  down,
  rotateCw,
  rotateCcw,
  flip,
  hardDrop,
  hold,
  pause,
  restart,
}

extension GameActionInfo on GameAction {
  String get label => switch (this) {
        GameAction.left => 'Mover à esquerda',
        GameAction.right => 'Mover à direita',
        GameAction.down => 'Descer (queda suave)',
        GameAction.rotateCw => 'Girar (horário)',
        GameAction.rotateCcw => 'Girar (anti-horário)',
        GameAction.flip => 'Girar 180°',
        GameAction.hardDrop => 'Queda rápida',
        GameAction.hold => 'Guardar peça (RESERVA)',
        GameAction.pause => 'Pausar / continuar',
        GameAction.restart => 'Reiniciar (no fim de jogo)',
      };

  /// Nome curto, usado nos desenhos do teclado e do controle.
  String get tag => switch (this) {
        GameAction.left => 'Esq',
        GameAction.right => 'Dir',
        GameAction.down => 'Desc',
        GameAction.rotateCw => 'Gira',
        GameAction.rotateCcw => 'Gira←',
        GameAction.flip => '180°',
        GameAction.hardDrop => 'Queda',
        GameAction.hold => 'Reserva',
        GameAction.pause => 'Pausa',
        GameAction.restart => 'Novo',
      };

  /// Texto da dica em minúsculas (barra embaixo do tabuleiro).
  String get hintName => switch (this) {
        GameAction.left => 'mover ←',
        GameAction.right => 'mover →',
        GameAction.down => 'descer',
        GameAction.rotateCw => 'girar',
        GameAction.rotateCcw => 'girar ←',
        GameAction.flip => 'girar 180°',
        GameAction.hardDrop => 'queda',
        GameAction.hold => 'guardar',
        GameAction.pause => 'pausar',
        GameAction.restart => 'reiniciar',
      };

  IconData get icon => switch (this) {
        GameAction.left => Icons.arrow_back,
        GameAction.right => Icons.arrow_forward,
        GameAction.down => Icons.arrow_downward,
        GameAction.rotateCw => Icons.rotate_right,
        GameAction.rotateCcw => Icons.rotate_left,
        GameAction.flip => Icons.flip,
        GameAction.hardDrop => Icons.vertical_align_bottom,
        GameAction.hold => Icons.swap_vert,
        GameAction.pause => Icons.pause,
        GameAction.restart => Icons.refresh,
      };

  Color get color => switch (this) {
        GameAction.left => Colors.cyanAccent,
        GameAction.right => Colors.cyanAccent,
        GameAction.down => Colors.lightBlueAccent,
        GameAction.rotateCw => Colors.amber,
        GameAction.rotateCcw => Colors.orangeAccent,
        GameAction.flip => Colors.pinkAccent,
        GameAction.hardDrop => Colors.greenAccent,
        GameAction.hold => Colors.purpleAccent,
        GameAction.pause => Colors.white70,
        GameAction.restart => Colors.redAccent,
      };
}

/// Botões de um controle (layout de Xbox; em outros controles o jogo traduz).
enum PadBtn {
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
  a,
  b,
  x,
  y,
  lb,
  rb,
  lt,
  rt,
  back,
  start,
  ls,
  rs,
}

extension PadBtnInfo on PadBtn {
  String get glyph => switch (this) {
        PadBtn.dpadUp => '↑',
        PadBtn.dpadDown => '↓',
        PadBtn.dpadLeft => '←',
        PadBtn.dpadRight => '→',
        PadBtn.a => 'A',
        PadBtn.b => 'B',
        PadBtn.x => 'X',
        PadBtn.y => 'Y',
        PadBtn.lb => 'LB',
        PadBtn.rb => 'RB',
        PadBtn.lt => 'LT',
        PadBtn.rt => 'RT',
        PadBtn.back => 'Select',
        PadBtn.start => 'Start',
        PadBtn.ls => 'L3',
        PadBtn.rs => 'R3',
      };
}

/// Nome legível de uma tecla (não depende de debugName, que some no release).
String keyCapLabel(LogicalKeyboardKey k) {
  final s = Controls._special[k.keyId];
  if (s != null) return s;
  final l = k.keyLabel;
  if (l.isNotEmpty) return l.length == 1 ? l.toUpperCase() : l;
  return 'Tecla ${k.keyId.toRadixString(16)}';
}

/// Teclas e botões de cada ação (até [kSlots] por ação), salvos no aparelho.
class Controls {
  static const int kSlots = 3;

  static Map<GameAction, List<LogicalKeyboardKey?>> keys = defaultKeys();
  static Map<GameAction, List<PadBtn?>> pad = defaultPad();

  static final Map<int, String> _special = <int, String>{
    LogicalKeyboardKey.arrowLeft.keyId: '←',
    LogicalKeyboardKey.arrowRight.keyId: '→',
    LogicalKeyboardKey.arrowUp.keyId: '↑',
    LogicalKeyboardKey.arrowDown.keyId: '↓',
    LogicalKeyboardKey.space.keyId: 'Espaço',
    LogicalKeyboardKey.enter.keyId: 'Enter',
    LogicalKeyboardKey.numpadEnter.keyId: 'Enter (num)',
    LogicalKeyboardKey.escape.keyId: 'Esc',
    LogicalKeyboardKey.tab.keyId: 'Tab',
    LogicalKeyboardKey.backspace.keyId: 'Backspace',
    LogicalKeyboardKey.delete.keyId: 'Del',
    LogicalKeyboardKey.insert.keyId: 'Ins',
    LogicalKeyboardKey.home.keyId: 'Home',
    LogicalKeyboardKey.end.keyId: 'End',
    LogicalKeyboardKey.pageUp.keyId: 'PgUp',
    LogicalKeyboardKey.pageDown.keyId: 'PgDn',
    LogicalKeyboardKey.shiftLeft.keyId: 'Shift esq.',
    LogicalKeyboardKey.shiftRight.keyId: 'Shift dir.',
    LogicalKeyboardKey.controlLeft.keyId: 'Ctrl esq.',
    LogicalKeyboardKey.controlRight.keyId: 'Ctrl dir.',
    LogicalKeyboardKey.altLeft.keyId: 'Alt esq.',
    LogicalKeyboardKey.altRight.keyId: 'Alt dir.',
    LogicalKeyboardKey.capsLock.keyId: 'Caps',
    LogicalKeyboardKey.numpad0.keyId: 'Num 0',
    LogicalKeyboardKey.numpad1.keyId: 'Num 1',
    LogicalKeyboardKey.numpad2.keyId: 'Num 2',
    LogicalKeyboardKey.numpad3.keyId: 'Num 3',
    LogicalKeyboardKey.numpad4.keyId: 'Num 4',
    LogicalKeyboardKey.numpad5.keyId: 'Num 5',
    LogicalKeyboardKey.numpad6.keyId: 'Num 6',
    LogicalKeyboardKey.numpad7.keyId: 'Num 7',
    LogicalKeyboardKey.numpad8.keyId: 'Num 8',
    LogicalKeyboardKey.numpad9.keyId: 'Num 9',
  };

  static List<LogicalKeyboardKey?> _k(List<LogicalKeyboardKey> l) =>
      List<LogicalKeyboardKey?>.generate(
          kSlots, (i) => i < l.length ? l[i] : null);

  static List<PadBtn?> _p(List<PadBtn> l) =>
      List<PadBtn?>.generate(kSlots, (i) => i < l.length ? l[i] : null);

  /// Padrão: setas + Z/X/C (e WASD), igual ao que o jogo já tinha.
  static Map<GameAction, List<LogicalKeyboardKey?>> defaultKeys() => {
        GameAction.left: _k([LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.keyA]),
        GameAction.right: _k([LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.keyD]),
        GameAction.down: _k([LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.keyS]),
        GameAction.rotateCw: _k([
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.keyX,
        ]),
        GameAction.rotateCcw: _k([LogicalKeyboardKey.keyZ]),
        GameAction.flip: _k([LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyV]),
        GameAction.hardDrop: _k([LogicalKeyboardKey.space]),
        GameAction.hold: _k([
          LogicalKeyboardKey.keyC,
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight,
        ]),
        GameAction.pause: _k([LogicalKeyboardKey.keyP, LogicalKeyboardKey.escape]),
        GameAction.restart: _k([LogicalKeyboardKey.keyR]),
      };

  /// Predefinição só com WASD (mão esquerda) + espaço.
  static Map<GameAction, List<LogicalKeyboardKey?>> wasdKeys() => {
        GameAction.left: _k([LogicalKeyboardKey.keyA]),
        GameAction.right: _k([LogicalKeyboardKey.keyD]),
        GameAction.down: _k([LogicalKeyboardKey.keyS]),
        GameAction.rotateCw: _k([LogicalKeyboardKey.keyW, LogicalKeyboardKey.arrowUp]),
        GameAction.rotateCcw: _k([LogicalKeyboardKey.keyQ]),
        GameAction.flip: _k([LogicalKeyboardKey.keyE]),
        GameAction.hardDrop: _k([LogicalKeyboardKey.space]),
        GameAction.hold: _k([LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.keyC]),
        GameAction.pause: _k([LogicalKeyboardKey.keyP, LogicalKeyboardKey.escape]),
        GameAction.restart: _k([LogicalKeyboardKey.keyR]),
      };

  /// Padrão do controle: direcional/analógico move, A/RB gira, Y/LB guarda.
  static Map<GameAction, List<PadBtn?>> defaultPad() => {
        GameAction.left: _p([PadBtn.dpadLeft]),
        GameAction.right: _p([PadBtn.dpadRight]),
        GameAction.down: _p([PadBtn.dpadDown]),
        GameAction.rotateCw: _p([PadBtn.a, PadBtn.rb]),
        GameAction.rotateCcw: _p([PadBtn.b]),
        GameAction.flip: _p([PadBtn.x]),
        GameAction.hardDrop: _p([PadBtn.dpadUp, PadBtn.rt]),
        GameAction.hold: _p([PadBtn.y, PadBtn.lb, PadBtn.lt]),
        GameAction.pause: _p([PadBtn.start]),
        GameAction.restart: _p([PadBtn.back]),
      };

  static GameAction? keyAction(LogicalKeyboardKey k) {
    for (final e in keys.entries) {
      if (e.value.contains(k)) return e.key;
    }
    return null;
  }

  static GameAction? padAction(PadBtn b) {
    for (final e in pad.entries) {
      if (e.value.contains(b)) return e.key;
    }
    return null;
  }

  /// Liga [k] à ação [a] no espaço [slot]. Se a tecla já era de outra ação,
  /// ela sai de lá (e a ação que perdeu a tecla é devolvida).
  static GameAction? bindKey(GameAction a, int slot, LogicalKeyboardKey k) {
    GameAction? moved;
    for (final e in keys.entries) {
      for (int i = 0; i < e.value.length; i++) {
        if (e.value[i] == k) {
          e.value[i] = null;
          if (e.key != a) moved = e.key;
        }
      }
    }
    keys[a]![slot] = k;
    return moved;
  }

  static GameAction? bindPad(GameAction a, int slot, PadBtn b) {
    GameAction? moved;
    for (final e in pad.entries) {
      for (int i = 0; i < e.value.length; i++) {
        if (e.value[i] == b) {
          e.value[i] = null;
          if (e.key != a) moved = e.key;
        }
      }
    }
    pad[a]![slot] = b;
    return moved;
  }

  static void resetKeys() => keys = defaultKeys();
  static void resetPad() => pad = defaultPad();

  static String keyText(GameAction a, {int max = 2}) => [
        for (final k in keys[a]!)
          if (k != null) keyCapLabel(k)
      ].take(max).join('/');

  static String padText(GameAction a, {int max = 2}) => [
        for (final b in pad[a]!)
          if (b != null) b.glyph
      ].take(max).join('/');

  static const List<GameAction> _hintOrder = [
    GameAction.left,
    GameAction.right,
    GameAction.down,
    GameAction.rotateCw,
    GameAction.rotateCcw,
    GameAction.flip,
    GameAction.hardDrop,
    GameAction.hold,
    GameAction.pause,
  ];

  static String hint() {
    final parts = <String>[];
    for (final a in _hintOrder) {
      final t = keyText(a);
      if (t.isNotEmpty) parts.add('$t ${a.hintName}');
    }
    return parts.join('   ');
  }

  static String padHint() {
    final parts = <String>[];
    for (final a in _hintOrder) {
      final t = padText(a);
      if (t.isNotEmpty) parts.add('$t ${a.hintName}');
    }
    return parts.join('   ');
  }

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    try {
      final ks = p.getString('ctl_keys');
      if (ks != null) {
        final m = jsonDecode(ks) as Map<String, dynamic>;
        final out = defaultKeys();
        for (final a in GameAction.values) {
          final v = m[a.name];
          if (v is List) {
            out[a] = List<LogicalKeyboardKey?>.generate(
                kSlots,
                (i) => (i < v.length && v[i] is int)
                    ? LogicalKeyboardKey(v[i] as int)
                    : null);
          }
        }
        keys = out;
      }
    } catch (_) {}
    try {
      final ps = p.getString('ctl_pad');
      if (ps != null) {
        final m = jsonDecode(ps) as Map<String, dynamic>;
        final out = defaultPad();
        for (final a in GameAction.values) {
          final v = m[a.name];
          if (v is List) {
            out[a] = List<PadBtn?>.generate(kSlots, (i) {
              if (i >= v.length || v[i] is! int) return null;
              final n = v[i] as int;
              return (n >= 0 && n < PadBtn.values.length)
                  ? PadBtn.values[n]
                  : null;
            });
          }
        }
        pad = out;
      }
    } catch (_) {}
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'ctl_keys',
        jsonEncode({
          for (final a in GameAction.values)
            a.name: [for (final k in keys[a]!) k?.keyId]
        }));
    await p.setString(
        'ctl_pad',
        jsonEncode({
          for (final a in GameAction.values)
            a.name: [for (final b in pad[a]!) b?.index]
        }));
  }
}

// ---------------------------------------------------------------------------
// Controle (gamepad)
// ---------------------------------------------------------------------------

typedef PadListener = void Function(PadBtn b, bool down, bool fromKey);

typedef _NativePoll = ffi.Uint32 Function(ffi.Uint32, ffi.Pointer<ffi.Uint8>);
typedef _DartPoll = int Function(int, ffi.Pointer<ffi.Uint8>);

/// Lê o controle.
/// - Windows: XInput (Xbox 360/One/Series e a maioria dos controles em modo
///   XInput) e, se não houver, a API winmm (controles genéricos), via dart:ffi,
///   sem plugin extra.
/// - Android/iOS: os botões chegam como teclas "gameButton*" e são traduzidos.
class Gamepad {
  /// Nome do controle conectado (null = nenhum).
  static final ValueNotifier<String?> name = ValueNotifier<String?>(null);

  static final List<PadListener> _ls = <PadListener>[];
  static Set<PadBtn> _prev = <PadBtn>{};
  static final Set<PadBtn> _keyDown = <PadBtn>{};
  static bool _started = false;
  static Timer? _timer;
  static final Stopwatch _sw = Stopwatch();
  static int _lastScan = -100000;
  static int _kind = -1; // 0 = XInput, 1 = winmm
  static int _idx = 0;
  static int _fails = 0;

  static ffi.Pointer<ffi.Uint8>? _buf;
  static _DartPoll? _xGet;
  static _DartPoll? _jGet;

  // Ordem dos botões nos controles genéricos (winmm), no estilo Xbox.
  static const List<PadBtn> _jMap = [
    PadBtn.a,
    PadBtn.b,
    PadBtn.x,
    PadBtn.y,
    PadBtn.lb,
    PadBtn.rb,
    PadBtn.back,
    PadBtn.start,
    PadBtn.ls,
    PadBtn.rs,
  ];

  static void addListener(PadListener f) {
    if (!_ls.contains(f)) _ls.add(f);
  }

  static void removeListener(PadListener f) => _ls.remove(f);

  static void start() {
    if (_started) return;
    _started = true;
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    if (kWindows && _initFfi()) {
      _sw.start();
      _timer =
          Timer.periodic(const Duration(milliseconds: 8), (_) => _pollTick());
    }
  }

  static bool get _focused {
    final st = WidgetsBinding.instance.lifecycleState;
    return st == null || st == AppLifecycleState.resumed;
  }

  static void _emit(PadBtn b, bool down, bool fromKey) {
    for (final f in List<PadListener>.of(_ls)) {
      try {
        f(b, down, fromKey);
      } catch (_) {}
    }
  }

  // ---- Android / iOS: botões do controle chegam como teclas
  static PadBtn? _fromKey(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.gameButtonA) return PadBtn.a;
    if (k == LogicalKeyboardKey.gameButtonB) return PadBtn.b;
    if (k == LogicalKeyboardKey.gameButtonX) return PadBtn.x;
    if (k == LogicalKeyboardKey.gameButtonY) return PadBtn.y;
    if (k == LogicalKeyboardKey.gameButtonLeft1) return PadBtn.lb;
    if (k == LogicalKeyboardKey.gameButtonRight1) return PadBtn.rb;
    if (k == LogicalKeyboardKey.gameButtonLeft2) return PadBtn.lt;
    if (k == LogicalKeyboardKey.gameButtonRight2) return PadBtn.rt;
    if (k == LogicalKeyboardKey.gameButtonSelect) return PadBtn.back;
    if (k == LogicalKeyboardKey.gameButtonStart) return PadBtn.start;
    if (k == LogicalKeyboardKey.gameButtonThumbLeft) return PadBtn.ls;
    if (k == LogicalKeyboardKey.gameButtonThumbRight) return PadBtn.rs;
    return null;
  }

  static bool _onKeyEvent(KeyEvent e) {
    if (e is KeyRepeatEvent) return false;
    final b = _fromKey(e.logicalKey);
    if (b == null) return false;
    if (e is KeyDownEvent) {
      if (_keyDown.add(b)) {
        if (name.value == null) name.value = 'Controle';
        _emit(b, true, true);
      }
    } else if (e is KeyUpEvent) {
      if (_keyDown.remove(b)) _emit(b, false, true);
    }
    return false; // não consome: o Flutter ainda trata A como "ativar"
  }

  // ---- Windows: XInput e winmm via FFI
  static bool _initFfi() {
    try {
      ffi.DynamicLibrary? lib;
      for (final n in const [
        'xinput1_4.dll',
        'xinput1_3.dll',
        'xinput9_1_0.dll'
      ]) {
        try {
          lib = ffi.DynamicLibrary.open(n);
          break;
        } catch (_) {}
      }
      if (lib != null) {
        _xGet = lib.lookupFunction<_NativePoll, _DartPoll>('XInputGetState');
      }
    } catch (_) {
      _xGet = null;
    }
    try {
      final w = ffi.DynamicLibrary.open('winmm.dll');
      _jGet = w.lookupFunction<_NativePoll, _DartPoll>('joyGetPosEx');
    } catch (_) {
      _jGet = null;
    }
    if (_xGet == null && _jGet == null) return false;
    _buf = pkg.calloc<ffi.Uint8>(64);
    return true;
  }

  static void _pollTick() {
    try {
      if (_kind < 0) {
        final now = _sw.elapsedMilliseconds;
        if (now - _lastScan < 700) return;
        _lastScan = now;
        _scan();
        if (_kind < 0) return;
      }
      final s = _read();
      if (s == null) {
        _kind = -1;
        name.value = null;
        _apply(<PadBtn>{});
        return;
      }
      _apply(s);
      _fails = 0;
    } catch (_) {
      _fails++;
      if (_fails > 50) {
        _timer?.cancel();
        _timer = null;
        _kind = -1;
        name.value = null;
      }
    }
  }

  static void _scan() {
    final buf = _buf!;
    if (_xGet != null) {
      for (int i = 0; i < 4; i++) {
        if (_xGet!(i, buf) == 0) {
          _kind = 0;
          _idx = i;
          name.value = 'Xbox / XInput ${i + 1}';
          return;
        }
      }
    }
    if (_jGet != null) {
      final bd = ByteData.sublistView(buf.asTypedList(64));
      for (int i = 0; i < 4; i++) {
        bd.setUint32(0, 52, Endian.little);
        bd.setUint32(4, 0xFF, Endian.little);
        if (_jGet!(i, buf) == 0) {
          _kind = 1;
          _idx = i;
          name.value = 'Controle genérico ${i + 1}';
          return;
        }
      }
    }
  }

  static bool _stickOn(bool was, int v) => was ? v > 9000 : v > 16000;

  /// Analógico esquerdo vira direcional (só o eixo mais forte vale).
  static void _stick(Set<PadBtn> s, int lx, int dy) {
    if (lx.abs() >= dy.abs()) {
      if (_stickOn(_prev.contains(PadBtn.dpadLeft), -lx)) {
        s.add(PadBtn.dpadLeft);
      }
      if (_stickOn(_prev.contains(PadBtn.dpadRight), lx)) {
        s.add(PadBtn.dpadRight);
      }
    } else {
      if (_stickOn(_prev.contains(PadBtn.dpadUp), -dy)) s.add(PadBtn.dpadUp);
      if (_stickOn(_prev.contains(PadBtn.dpadDown), dy)) {
        s.add(PadBtn.dpadDown);
      }
    }
  }

  static void _trigger(Set<PadBtn> s, PadBtn b, int v) {
    if (_prev.contains(b) ? v > 50 : v > 120) s.add(b);
  }

  static Set<PadBtn>? _read() {
    final buf = _buf!;
    final bd = ByteData.sublistView(buf.asTypedList(64));
    final s = <PadBtn>{};
    if (_kind == 0) {
      if (_xGet!(_idx, buf) != 0) return null;
      final m = bd.getUint16(4, Endian.little);
      void bit(int mask, PadBtn b) {
        if ((m & mask) != 0) s.add(b);
      }

      bit(0x0001, PadBtn.dpadUp);
      bit(0x0002, PadBtn.dpadDown);
      bit(0x0004, PadBtn.dpadLeft);
      bit(0x0008, PadBtn.dpadRight);
      bit(0x0010, PadBtn.start);
      bit(0x0020, PadBtn.back);
      bit(0x0040, PadBtn.ls);
      bit(0x0080, PadBtn.rs);
      bit(0x0100, PadBtn.lb);
      bit(0x0200, PadBtn.rb);
      bit(0x1000, PadBtn.a);
      bit(0x2000, PadBtn.b);
      bit(0x4000, PadBtn.x);
      bit(0x8000, PadBtn.y);
      _trigger(s, PadBtn.lt, bd.getUint8(6));
      _trigger(s, PadBtn.rt, bd.getUint8(7));
      final lx = bd.getInt16(8, Endian.little);
      final ly = bd.getInt16(10, Endian.little); // positivo = para cima
      _stick(s, lx, -ly);
      return s;
    }
    // winmm (controle genérico)
    bd.setUint32(0, 52, Endian.little);
    bd.setUint32(4, 0xFF, Endian.little);
    if (_jGet!(_idx, buf) != 0) return null;
    final btn = bd.getUint32(32, Endian.little);
    for (int i = 0; i < _jMap.length; i++) {
      if (((btn >> i) & 1) == 1) s.add(_jMap[i]);
    }
    final pov = bd.getUint32(40, Endian.little);
    if (pov <= 35999) {
      final ang = pov ~/ 100;
      if (ang >= 315 || ang <= 45) s.add(PadBtn.dpadUp);
      if (ang >= 45 && ang <= 135) s.add(PadBtn.dpadRight);
      if (ang >= 135 && ang <= 225) s.add(PadBtn.dpadDown);
      if (ang >= 225 && ang <= 315) s.add(PadBtn.dpadLeft);
    }
    final x = bd.getUint32(8, Endian.little) - 32768;
    final y = bd.getUint32(12, Endian.little) - 32768; // positivo = para baixo
    _stick(s, x, y);
    return s;
  }

  /// Compara com o estado anterior e avisa só o que mudou. Com a janela sem
  /// foco, novos botões são ignorados (não mexe no jogo em segundo plano).
  static void _apply(Set<PadBtn> now) {
    final focused = _focused;
    final eff = <PadBtn>{};
    for (final b in now) {
      if (_prev.contains(b) || focused) eff.add(b);
    }
    final old = _prev;
    _prev = eff;
    for (final b in old) {
      if (!eff.contains(b)) _emit(b, false, false);
    }
    for (final b in eff) {
      if (!old.contains(b)) _emit(b, true, false);
    }
  }
}

/// Navega pelos menus com o controle: direcional/analógico move o foco,
/// A ativa e B volta. O jogo em andamento cuida do próprio controle.
class PadNav {
  static int suspended = 0; // >0 enquanto se captura um botão
  static final List<bool Function()> owners = <bool Function()>[];
  static Timer? _t;
  static PadBtn? _held;

  static bool get _owned {
    for (final o in owners) {
      if (o()) return true;
    }
    return false;
  }

  static void onPad(PadBtn b, bool down, bool fromKey) {
    if (fromKey) return; // no Android o Flutter já navega com as teclas
    if (suspended > 0) return;
    if (_owned) return;
    handle(b, down);
  }

  static void handle(PadBtn p, bool down) {
    if (!down) {
      if (p == _held) {
        _t?.cancel();
        _t = null;
        _held = null;
      }
      return;
    }
    switch (p) {
      case PadBtn.dpadUp:
        _step(p, TraversalDirection.up);
        break;
      case PadBtn.dpadDown:
        _step(p, TraversalDirection.down);
        break;
      case PadBtn.dpadLeft:
        _step(p, TraversalDirection.left);
        break;
      case PadBtn.dpadRight:
        _step(p, TraversalDirection.right);
        break;
      case PadBtn.a:
        _activate();
        break;
      case PadBtn.b:
        Presence.nav.currentState?.maybePop();
        break;
      default:
        break;
    }
  }

  static void _step(PadBtn p, TraversalDirection d) {
    _t?.cancel();
    _held = p;
    _dir(d);
    _t = Timer(const Duration(milliseconds: 380), () {
      _t = Timer.periodic(const Duration(milliseconds: 110), (_) => _dir(d));
    });
  }

  static BuildContext? get _ctx {
    final c = FocusManager.instance.primaryFocus?.context;
    return (c != null && c.mounted) ? c : null;
  }

  static void _dir(TraversalDirection d) {
    final c = _ctx;
    if (c == null) return;
    Actions.maybeInvoke<DirectionalFocusIntent>(c, DirectionalFocusIntent(d));
  }

  static void _activate() {
    final c = _ctx;
    if (c == null) return;
    Actions.maybeInvoke<ActivateIntent>(c, const ActivateIntent());
  }
}

/// Junta teclado e controle: traduz teclas/botões em ações do jogo, com
/// DAS/ARR para mover e descer. Usado pela partida e pelo tutorial.
class InputRouter {
  final bool Function() isCurrent;
  final bool Function() playing;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onDown;
  final void Function(GameAction a) onPress;
  final VoidCallback? onBack;

  final AutoRepeat _rep = AutoRepeat();
  Object? _src;
  bool _wasPlaying = true;
  int _since = 0;

  InputRouter({
    required this.isCurrent,
    required this.playing,
    required this.onLeft,
    required this.onRight,
    required this.onDown,
    required this.onPress,
    this.onBack,
  });

  int get _now => DateTime.now().millisecondsSinceEpoch;

  void attach() {
    HardwareKeyboard.instance.addHandler(handleKey);
    Gamepad.addListener(handlePad);
    PadNav.owners.add(isCurrent);
  }

  void detach() {
    HardwareKeyboard.instance.removeHandler(handleKey);
    Gamepad.removeListener(handlePad);
    PadNav.owners.remove(isCurrent);
    releaseAll();
  }

  void releaseAll() {
    _rep.stop();
    _src = null;
  }

  /// Chamado a cada quadro para medir há quanto tempo o jogo parou de aceitar
  /// comandos (evita apertar um botão do overlay sem querer ao morrer).
  void poke() => _isPlaying();

  bool _isPlaying() {
    final p = playing();
    if (p != _wasPlaying) {
      _wasPlaying = p;
      _since = _now;
    }
    return p;
  }

  void _hold(Object src, GameAction a) {
    final VoidCallback f;
    final int arr;
    int? das;
    switch (a) {
      case GameAction.left:
        f = onLeft;
        arr = Settings.arr.value.round();
        break;
      case GameAction.right:
        f = onRight;
        arr = Settings.arr.value.round();
        break;
      default:
        f = onDown;
        arr = 40;
        das = 120;
        break;
    }
    _rep.stop();
    _src = src;
    f();
    _rep.start(f, dasMs: das ?? Settings.das.value.round(), arrMs: arr);
  }

  void _release(Object src) {
    if (_src == src) {
      _rep.stop();
      _src = null;
    }
  }

  bool _dispatch(GameAction a, Object src, bool repeat) {
    if (a == GameAction.pause || a == GameAction.restart) {
      if (!repeat) onPress(a);
      return true;
    }
    if (!_isPlaying()) return false; // deixa o Flutter navegar nos menus
    if (a == GameAction.left ||
        a == GameAction.right ||
        a == GameAction.down) {
      if (!repeat) _hold(src, a);
    } else if (!repeat) {
      onPress(a);
    }
    return true;
  }

  bool handleKey(KeyEvent e) {
    final k = e.logicalKey;
    if (e is KeyUpEvent) {
      _release(k);
      return false;
    }
    if (!isCurrent()) return false;
    final a = Controls.keyAction(k);
    if (a == null) return false;
    return _dispatch(a, k, e is KeyRepeatEvent);
  }

  void handlePad(PadBtn b, bool down, bool fromKey) {
    if (!down) {
      _release(b);
      PadNav.handle(b, false);
      return;
    }
    if (!isCurrent()) return;
    final a = Controls.padAction(b);
    if (a == GameAction.pause || a == GameAction.restart) {
      onPress(a!);
      return;
    }
    if (_isPlaying()) {
      if (a != null) _dispatch(a, b, false);
      return;
    }
    if (_now - _since < 600) return;
    if (b == PadBtn.b && onBack != null) {
      onBack!();
      return;
    }
    if (!fromKey) PadNav.handle(b, true);
  }
}

// ---------------------------------------------------------------------------
// Tela "Teclas e controle"
// ---------------------------------------------------------------------------

class _Cap {
  final LogicalKeyboardKey? key;
  final PadBtn? pad;
  final bool clear;
  const _Cap({this.key, this.pad, this.clear = false});
}

class _KeyCaptureDialog extends StatelessWidget {
  final String title;
  const _KeyCaptureDialog({required this.title});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Focus(
        autofocus: true,
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent) {
            Navigator.pop(context, _Cap(key: e.logicalKey));
          }
          return KeyEventResult.handled;
        },
        child: const Text('Aperte a tecla que você quer usar…'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const _Cap(clear: true)),
          child: const Text('Limpar'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

class _PadCaptureDialog extends StatefulWidget {
  final String title;
  const _PadCaptureDialog({required this.title});

  @override
  State<_PadCaptureDialog> createState() => _PadCaptureDialogState();
}

class _PadCaptureDialogState extends State<_PadCaptureDialog> {
  bool _done = false;

  void _on(PadBtn b, bool down, bool fromKey) {
    if (!down || _done || !mounted) return;
    _done = true;
    Navigator.pop(context, _Cap(pad: b));
  }

  @override
  void initState() {
    super.initState();
    PadNav.suspended++;
    Gamepad.addListener(_on);
  }

  @override
  void dispose() {
    Gamepad.removeListener(_on);
    PadNav.suspended--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: ValueListenableBuilder<String?>(
        valueListenable: Gamepad.name,
        builder: (_, n, __) => Text(n == null
            ? 'Aperte um botão do controle…\n(nenhum controle detectado ainda)'
            : 'Aperte o botão do controle que você quer usar…'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const _Cap(clear: true)),
          child: const Text('Limpar'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

class ControlsScreen extends StatefulWidget {
  const ControlsScreen({super.key});

  @override
  State<ControlsScreen> createState() => _ControlsScreenState();
}

class _ControlsScreenState extends State<ControlsScreen> {
  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(t,
            style: const TextStyle(
                color: Colors.white54, fontSize: 12, letterSpacing: 2)),
      );

  Widget _card(Widget child) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black38,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: child,
      );

  void _snack(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(m), duration: const Duration(seconds: 3)));
  }

  Future<void> _editKey(GameAction a, int slot) async {
    final r = await showDialog<_Cap>(
      context: context,
      builder: (_) => _KeyCaptureDialog(title: a.label),
    );
    if (r == null || !mounted) return;
    if (r.clear) {
      Controls.keys[a]![slot] = null;
    } else if (r.key != null) {
      final moved = Controls.bindKey(a, slot, r.key!);
      if (moved != null) {
        _snack('${keyCapLabel(r.key!)} saiu de "${moved.label}".');
      }
    }
    await Controls.save();
    if (mounted) setState(() {});
  }

  Future<void> _editPad(GameAction a, int slot) async {
    final r = await showDialog<_Cap>(
      context: context,
      builder: (_) => _PadCaptureDialog(title: a.label),
    );
    if (r == null || !mounted) return;
    if (r.clear) {
      Controls.pad[a]![slot] = null;
    } else if (r.pad != null) {
      final moved = Controls.bindPad(a, slot, r.pad!);
      if (moved != null) {
        _snack('${r.pad!.glyph} saiu de "${moved.label}".');
      }
    }
    await Controls.save();
    if (mounted) setState(() {});
  }

  Widget _cap(String text, VoidCallback onTap,
      {required bool empty, required Color color}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            height: 38,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: empty ? Colors.white10 : color.withAlpha(35),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: empty ? Colors.white24 : color.withAlpha(160)),
            ),
            child: Text(
              empty ? '—' : text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: empty ? Colors.white38 : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionRow(GameAction a, {required bool pad}) {
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(a.icon, color: a.color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(a.label)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (int i = 0; i < Controls.kSlots; i++)
            if (pad)
              _cap(Controls.pad[a]![i]?.glyph ?? '', () => _editPad(a, i),
                  empty: Controls.pad[a]![i] == null, color: a.color)
            else
              _cap(
                  Controls.keys[a]![i] == null
                      ? ''
                      : keyCapLabel(Controls.keys[a]![i]!),
                  () => _editKey(a, i),
                  empty: Controls.keys[a]![i] == null,
                  color: a.color),
        ]),
      ],
    ));
  }

  // ---- desenho do teclado
  Widget _keyboardDiagram() {
    Widget key(LogicalKeyboardKey k, {String? text, int flex = 2}) {
      final a = Controls.keyAction(k);
      final c = a?.color;
      return Expanded(
        flex: flex,
        child: Container(
          margin: const EdgeInsets.all(1.5),
          height: 40,
          decoration: BoxDecoration(
            color: c == null ? Colors.white10 : c.withAlpha(60),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c ?? Colors.white24),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(text ?? keyCapLabel(k),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: c == null ? Colors.white54 : Colors.white)),
                  if (a != null)
                    Text(a.tag, style: TextStyle(fontSize: 8, color: c)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final r1 = [
      LogicalKeyboardKey.keyQ,
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyR,
      LogicalKeyboardKey.keyT,
      LogicalKeyboardKey.keyY,
      LogicalKeyboardKey.keyU,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.keyO,
      LogicalKeyboardKey.keyP,
    ];
    final r2 = [
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyL,
    ];
    final r3 = [
      LogicalKeyboardKey.keyZ,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyM,
    ];

    return _card(Column(
      children: [
        Row(children: [
          key(LogicalKeyboardKey.escape, text: 'Esc'),
          const Spacer(flex: 18),
        ]),
        Row(children: [for (final k in r1) key(k)]),
        Row(children: [
          const Spacer(flex: 1),
          for (final k in r2) key(k),
          const Spacer(flex: 1),
        ]),
        Row(children: [
          key(LogicalKeyboardKey.shiftLeft, text: 'Shift', flex: 3),
          for (final k in r3) key(k),
          key(LogicalKeyboardKey.shiftRight, text: 'Shift', flex: 3),
        ]),
        Row(children: [
          key(LogicalKeyboardKey.controlLeft, text: 'Ctrl', flex: 3),
          key(LogicalKeyboardKey.altLeft, text: 'Alt', flex: 3),
          key(LogicalKeyboardKey.space, text: 'Espaço', flex: 8),
          key(LogicalKeyboardKey.altRight, text: 'Alt', flex: 3),
          key(LogicalKeyboardKey.controlRight, text: 'Ctrl', flex: 3),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          const Spacer(flex: 14),
          Expanded(
            flex: 6,
            child: Column(children: [
              Row(children: [
                const Spacer(flex: 2),
                key(LogicalKeyboardKey.arrowUp),
                const Spacer(flex: 2),
              ]),
              Row(children: [
                key(LogicalKeyboardKey.arrowLeft),
                key(LogicalKeyboardKey.arrowDown),
                key(LogicalKeyboardKey.arrowRight),
              ]),
            ]),
          ),
        ]),
      ],
    ));
  }

  // ---- desenho do controle
  Widget _padDiagram() {
    final tags = <PadBtn, GameAction>{
      for (final e in Controls.pad.entries)
        for (final b in e.value)
          if (b != null) b: e.key
    };

    Widget spot(PadBtn b, double x, double y, {double r = 13}) {
      final a = tags[b];
      final c = a?.color ?? Colors.white24;
      return Align(
        alignment: Alignment(x, y),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: r * 2,
              height: r * 2,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: a == null ? Colors.white10 : c.withAlpha(70),
                border: Border.all(color: c, width: 1.5),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(b.glyph,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
            ),
            Text(a?.tag ?? ' ', style: TextStyle(fontSize: 9, color: c)),
          ],
        ),
      );
    }

    return _card(Column(
      children: [
        SizedBox(
          height: 250,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(22, 46, 22, 14),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(70),
                    border: Border.all(color: Colors.white24),
                  ),
                ),
              ),
              spot(PadBtn.lt, -0.62, -1.0),
              spot(PadBtn.rt, 0.62, -1.0),
              spot(PadBtn.lb, -0.62, -0.62),
              spot(PadBtn.rb, 0.62, -0.62),
              spot(PadBtn.ls, -0.6, -0.1),
              spot(PadBtn.dpadUp, -0.3, 0.2, r: 11),
              spot(PadBtn.dpadLeft, -0.46, 0.55, r: 11),
              spot(PadBtn.dpadRight, -0.14, 0.55, r: 11),
              spot(PadBtn.dpadDown, -0.3, 0.9, r: 11),
              spot(PadBtn.back, -0.12, -0.25, r: 11),
              spot(PadBtn.start, 0.12, -0.25, r: 11),
              spot(PadBtn.y, 0.58, -0.5, r: 12),
              spot(PadBtn.x, 0.42, -0.1, r: 12),
              spot(PadBtn.b, 0.74, -0.1, r: 12),
              spot(PadBtn.a, 0.58, 0.3, r: 12),
              spot(PadBtn.rs, 0.28, 0.6),
            ],
          ),
        ),
        const Text(
          'O analógico esquerdo também move (como o direcional). '
          'L3 e R3 são os cliques dos analógicos.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    ));
  }

  Widget _presetChip(String text, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ActionChip(label: Text(text), onPressed: onTap),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text('Teclas e controle',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    _card(ValueListenableBuilder<String?>(
                      valueListenable: Gamepad.name,
                      builder: (_, n, __) => Row(children: [
                        Icon(Icons.sports_esports,
                            color: n == null
                                ? Colors.white38
                                : Colors.greenAccent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            n != null
                                ? 'Controle conectado: $n'
                                : (kWindows
                                    ? 'Nenhum controle detectado. Conecte um '
                                        'controle Xbox (ou compatível) por USB '
                                        'ou Bluetooth.'
                                    : 'Nenhum controle detectado. Os botões '
                                        'aparecem aqui quando o aparelho os '
                                        'enviar ao jogo.'),
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      ]),
                    )),
                    _section('TECLADO'),
                    _card(Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Predefinições'),
                        const SizedBox(height: 6),
                        Row(children: [
                          _presetChip('Setas + Z/X/C', () async {
                            setState(Controls.resetKeys);
                            await Controls.save();
                          }),
                          _presetChip('WASD', () async {
                            setState(() => Controls.keys = Controls.wasdKeys());
                            await Controls.save();
                          }),
                        ]),
                      ],
                    )),
                    _keyboardDiagram(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: Text(
                        'Toque numa caixa para trocar a tecla (cada ação '
                        'aceita até 3). Uma tecla só pode ter uma função.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                    for (final a in GameAction.values)
                      _actionRow(a, pad: false),
                    _section('CONTROLE'),
                    _padDiagram(),
                    for (final a in GameAction.values) _actionRow(a, pad: true),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.restore),
                      label: const Text('Restaurar teclas e controle'),
                      onPressed: () async {
                        setState(() {
                          Controls.resetKeys();
                          Controls.resetPad();
                        });
                        await Controls.save();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== main.dart =====

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Settings.load();
  await Controls.load();
  Gamepad.start();
  Gamepad.addListener(PadNav.onPad);
  Presence.start();
  Audio.init();
  AntiCheat.startup(); // temporada + ranqueada abandonada, sem travar a abertura
  runApp(const StackApp());
}

const String kAppName = 'EMPILHA';

class StackApp extends StatefulWidget {
  const StackApp({super.key});

  @override
  State<StackApp> createState() => _StackAppState();
}

class _StackAppState extends State<StackApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Audio.resumeFromBackground();
      Presence.setStatus(Presence.pref);
    } else if (state == AppLifecycleState.paused ||
        (kDesktop && state == AppLifecycleState.hidden)) {
      Audio.pauseForBackground();
      Presence.setStatus(Presence.pref == 'offline' ? 'offline' : 'away');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: Presence.nav,
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      builder: (context, child) => kDesktop
          ? ColoredBox(
              color: Colors.black,
              child: Center(
                // Janela larga/alta do PC: a coluna cresce com a altura, para
                // o tabuleiro aproveitar a tela sem esticar demais.
                child: LayoutBuilder(builder: (context, c) {
                  final w = min(c.maxWidth, max(560.0, c.maxHeight * 0.8));
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: w),
                    child: child,
                  );
                }),
              ),
            )
          : child!,
      home: const _Gate(),
    );
  }
}

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  BlockTheme theme = BlockTheme.neon;
  final Map<GameMode, int?> bests = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await Storage.loadTheme();
    final loaded = <GameMode, int?>{};
    for (final m in GameMode.values) {
      loaded[m] = await Storage.best(m);
    }
    if (!mounted) return;
    setState(() {
      theme = t;
      bests
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _play(GameMode m) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(mode: m, theme: theme)),
    );
    await _load();
  }

  Future<void> _openAccount() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AccountScreen()),
    );
    if (mounted) await _load();
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (mounted) setState(() => theme = Settings.theme.value);
  }

  String _bestText(GameMode m) {
    final b = bests[m];
    if (b == null) return 'Sem recorde';
    return m.timeBased ? 'Melhor: ${fmtTime(b)}' : 'Recorde: $b pts';
  }

  IconData _icon(GameMode m) {
    switch (m) {
      case GameMode.classic:
        return Icons.sports_esports;
      case GameMode.sprint:
        return Icons.flag;
      case GameMode.ultra:
        return Icons.timer;
      case GameMode.zen:
        return Icons.self_improvement;
      case GameMode.marathon:
        return Icons.directions_run;
      case GameMode.survival:
        return Icons.whatshot;
      case GameMode.cheese:
        return Icons.cleaning_services;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: theme.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Configurações',
                      icon: const Icon(Icons.settings, color: Colors.white70),
                      style: IconButton.styleFrom(
                        side: const BorderSide(color: Colors.cyanAccent),
                      ),
                      onPressed: _openSettings,
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.cyanAccent),
                      ),
                      onPressed: _openAccount,
                      icon: const Icon(Icons.account_circle,
                          color: Colors.cyanAccent),
                      label: Text(
                          Settings.loggedIn ? Settings.username : 'Entrar',
                          style: TextStyle(
                              color: Settings.nameColor < 1
                                  ? Colors.white70
                                  : Elo.nameStyleColor(Settings.nameColor))),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  colors: [Color(0xFF26C6DA), Color(0xFFEC407A)],
                ).createShader(r),
                child: const Text(
                  kAppName,
                  style: TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 8,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text('Escolha um modo',
                  style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    for (final m in GameMode.values) _modeCard(m),
                    _onlineCard(),
                    _eloCard(),
                    _boardCard(),
                    _replayCard(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openElo() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const EloScreen()),
    );
    if (mounted) await _load();
  }

  Widget _eloCard() {
    final t = Elo.tiers[Elo.current];
    final next = Elo.nextOf(Settings.rating);
    return Card(
      color: Colors.black38,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: t.color, width: 1.5),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(t.icon, color: t.color, size: 32),
        title: const Text('Elos e recompensas',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        subtitle: Text(
            '${t.name} · ${Settings.rating} pts'
            '${next == null ? '' : ' · faltam ${next.min - Settings.rating} para ${next.name}'}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openElo,
      ),
    );
  }

  Widget _boardCard() {
    return Card(
      color: Colors.black38,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading:
            const Icon(Icons.emoji_events, color: Colors.amber, size: 32),
        title: const Text('Placar mundial',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        subtitle: const Text('Ranking de jogadores do mundo todo'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
        ),
      ),
    );
  }

  Widget _onlineCard() {
    return Card(
      color: Colors.black38,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: const Icon(Icons.public, color: Colors.cyanAccent, size: 32),
        title: const Text('Multiplayer online',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        subtitle: const Text('Até 10 jogadores pela internet'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const OnlineLobbyScreen()),
        ),
      ),
    );
  }

  Widget _replayCard() {
    return Card(
      color: Colors.black38,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: const Icon(Icons.replay, color: Colors.cyanAccent, size: 32),
        title: const Text('Replays',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        subtitle: const Text('Reveja a última partida e os seus recordes'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ReplayListScreen()),
        ),
      ),
    );
  }

  Widget _modeCard(GameMode m) {
    return Card(
      color: Colors.black38,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _play(m),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(_icon(m), size: 36, color: Colors.cyanAccent),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.title,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(m.description,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(_bestText(m),
                        style: const TextStyle(
                            color: Colors.amber, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== replay.dart (gravação e reprodução de partidas offline) =====

class ReplayData {
  final GameMode mode;
  final int seed;
  final int gseed;
  final int startLevel;
  final double speed;
  final int score;
  final int lines;
  final int ms;
  final bool finished;
  final int at;
  final List<int> rec;

  const ReplayData({
    required this.mode,
    required this.seed,
    required this.gseed,
    required this.startLevel,
    required this.speed,
    required this.score,
    required this.lines,
    required this.ms,
    required this.finished,
    required this.at,
    required this.rec,
  });

  Map<String, dynamic> toJson() => {
        'm': mode.name,
        's': seed,
        'g': gseed,
        'l': startLevel,
        'v': speed,
        'sc': score,
        'ln': lines,
        'ms': ms,
        'f': finished,
        'at': at,
        'r': rec.join(','),
      };

  static ReplayData? fromJson(dynamic j) {
    try {
      if (j is! Map) return null;
      final raw = j['r'] as String;
      return ReplayData(
        mode: GameMode.values.firstWhere((m) => m.name == j['m']),
        seed: (j['s'] as num).toInt(),
        gseed: (j['g'] as num).toInt(),
        startLevel: (j['l'] as num).toInt(),
        speed: (j['v'] as num).toDouble(),
        score: (j['sc'] as num).toInt(),
        lines: (j['ln'] as num).toInt(),
        ms: (j['ms'] as num).toInt(),
        finished: j['f'] == true,
        at: (j['at'] as num?)?.toInt() ?? 0,
        rec: raw.isEmpty ? <int>[] : raw.split(',').map(int.parse).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  StackGame build() => StackGame(
        mode,
        seed: seed,
        garbageSeed: gseed,
        startLevel: startLevel,
        speedMul: speed,
      );
}

class ReplayScreen extends StatefulWidget {
  final ReplayData data;
  const ReplayScreen({super.key, required this.data});

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen>
    with SingleTickerProviderStateMixin {
  late StackGame game;
  late final Ticker _ticker;
  late final int _totalMs;
  Duration _last = Duration.zero;
  int _idx = 0;
  int _playedMs = 0;
  double _budget = 0;
  double _speed = 1.0;
  bool _playing = true;
  double? _drag;

  List<int> get _rec => widget.data.rec;
  bool get _ended => _idx >= _rec.length;

  @override
  void initState() {
    super.initState();
    _totalMs = max(1, _rec.where((e) => e > 0).fold<int>(0, (a, b) => a + b));
    game = widget.data.build();
    _ticker = createTicker(_tick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _apply(int e) {
    switch (e) {
      case -1:
        game.move(-1);
        break;
      case -2:
        game.move(1);
        break;
      case -3:
        game.softDrop();
        break;
      case -4:
        game.rotate(true);
        break;
      case -5:
        game.rotate(false);
        break;
      case -6:
        game.rotate180();
        break;
      case -7:
        game.hardDrop();
        break;
      case -8:
        game.hold();
        break;
      default:
        if (e > 0) {
          game.update(e);
          _playedMs += e;
        }
    }
  }

  void _tick(Duration elapsed) {
    var dt = (elapsed - _last).inMilliseconds;
    _last = elapsed;
    if (!_playing || dt <= 0) return;
    if (dt > 100) dt = 100;
    _budget += dt * _speed;
    var lockBefore = game.lockCount;
    while (_idx < _rec.length) {
      final e = _rec[_idx];
      if (e > 0) {
        if (_budget < e) break;
        _budget -= e;
      }
      _apply(e);
      _idx++;
    }
    if (game.lockCount != lockBefore) {
      lockBefore = game.lockCount;
      if (game.lastCleared >= 3 || game.lastChain > 1) {
        Audio.play('quad');
      } else if (game.lastCleared > 0) {
        Audio.play('clear');
      } else {
        Audio.play('drop');
      }
    }
    if (_ended) _playing = false;
    if (mounted) setState(() {});
  }

  void _restart() {
    setState(() {
      game = widget.data.build();
      _idx = 0;
      _playedMs = 0;
      _budget = 0;
      _playing = true;
    });
  }

  void _seek(double f) {
    final target = (_totalMs * f).round();
    game = widget.data.build();
    _idx = 0;
    _playedMs = 0;
    _budget = 0;
    while (_idx < _rec.length) {
      final e = _rec[_idx];
      if (e > 0 && _playedMs + e > target) break;
      _apply(e);
      _idx++;
    }
    setState(() => _drag = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Settings.theme.value;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: theme.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _top(),
              _info(),
              Expanded(child: LayoutBuilder(builder: _field)),
              _bar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _top() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white70),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text('Replay · ${widget.data.mode.title}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ),
            const SoundButtons(),
          ],
        ),
      );

  Widget _info() {
    const st = TextStyle(color: Colors.white70, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Pontos ${fmtScore(game.score)}', style: st),
          Text('Linhas ${game.lines}', style: st),
          Text('Nível ${game.level}', style: st),
          Text(fmtTime(game.elapsedMs), style: st),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t,
            style: const TextStyle(
                color: Colors.white54, fontSize: 10, letterSpacing: 1)),
      );

  Widget _box(int? type, {bool dim = false}) => Container(
        width: 56,
        height: 42,
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: type == null
            ? null
            : CustomPaint(
                painter: PiecePainter(type, Settings.theme.value, dim: dim)),
      );

  Widget _field(BuildContext context, BoxConstraints c) {
    gNesLevel = game.level - 1;
    const sideW = 58.0;
    final cell = max(
        4.0, min((c.maxWidth - sideW * 2 - 24) / kCols, c.maxHeight / kRows));
    final boardW = cell * kCols;
    final boardH = cell * kRows;
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: sideW,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('RESERVA'),
                _box(game.holdType, dim: !game.canHold),
              ],
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: boardW,
            height: boardH,
            child: Stack(
              children: [
                CustomPaint(
                  size: Size(boardW, boardH),
                  painter: BoardPainter(game, Settings.theme.value),
                ),
                if (game.bannerMs > 0 && game.banner != null)
                  Positioned.fill(
                    child: Center(
                      child: Text(
                        game.banner!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: sideW,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('NEXT'),
                for (final t in game.preview) _box(t),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar() {
    final frac = _drag ?? (_playedMs / _totalMs).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_ended)
            const Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Text('Fim do replay',
                  style: TextStyle(color: Colors.amber, fontSize: 13)),
            ),
          Slider(
            value: frac,
            activeColor: Colors.cyanAccent,
            onChanged: (v) => setState(() => _drag = v),
            onChangeEnd: _seek,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 32,
                color: Colors.white,
                icon: Icon(_ended
                    ? Icons.replay
                    : (_playing ? Icons.pause : Icons.play_arrow)),
                onPressed: () {
                  if (_ended) {
                    _restart();
                  } else {
                    setState(() => _playing = !_playing);
                  }
                },
              ),
              const SizedBox(width: 8),
              for (final s in const [0.5, 1.0, 2.0, 4.0])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(
                    label: Text(s == s.roundToDouble() ? '${s.round()}x' : '${s}x'),
                    selected: _speed == s,
                    onSelected: (_) => setState(() => _speed = s),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class ReplayListScreen extends StatefulWidget {
  const ReplayListScreen({super.key});

  @override
  State<ReplayListScreen> createState() => _ReplayListScreenState();
}

class _ReplayListScreenState extends State<ReplayListScreen> {
  bool _loading = true;
  final List<MapEntry<String, ReplayData>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = <MapEntry<String, ReplayData>>[];
    final last = await Storage.loadReplay('replay_last');
    if (last != null) items.add(MapEntry('Última partida', last));
    for (final m in GameMode.values) {
      final r = await Storage.loadReplay('replay_best_${m.name}');
      if (r != null) items.add(MapEntry('Recorde · ${m.title}', r));
    }
    if (!mounted) return;
    setState(() {
      _items
        ..clear()
        ..addAll(items);
      _loading = false;
    });
  }

  String _date(int at) {
    if (at <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(at);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Replays')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'Nenhum replay ainda. Jogue uma partida offline e '
                        'ela fica guardada aqui.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70)),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final e in _items)
                      Card(
                        color: Colors.black38,
                        child: ListTile(
                          leading: const Icon(Icons.play_circle,
                              color: Colors.cyanAccent, size: 34),
                          title: Text(e.key,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                              '${e.value.mode.title} · ${fmtScore(e.value.score)} pts · '
                              '${e.value.lines} linhas · ${fmtTime(e.value.ms)}'
                              '${_date(e.value.at).isEmpty ? '' : '\n${_date(e.value.at)}'}'),
                          isThreeLine: _date(e.value.at).isNotEmpty,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => ReplayScreen(data: e.value)),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

// ===== settings screen =====

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static void _noop() {}

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(t,
            style: const TextStyle(
                color: Colors.white54, fontSize: 12, letterSpacing: 2)),
      );

  Widget _card(Widget child) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black38,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: child,
      );

  Widget _slider({
    required IconData icon,
    required String label,
    required double value,
    required double lo,
    required double hi,
    required String text,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onEnd,
  }) {
    return _card(Row(
      children: [
        Icon(icon, color: Colors.cyanAccent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              Slider(
                value: value.clamp(lo, hi).toDouble(),
                min: lo,
                max: hi,
                activeColor: Colors.cyanAccent,
                onChanged: onChanged,
                onChangeEnd: onEnd,
              ),
            ],
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(text,
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.white70)),
        ),
      ],
    ));
  }

  Widget _switch(String title, String sub, bool value, ValueChanged<bool> on) {
    return _card(SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
      value: value,
      onChanged: on,
    ));
  }

  Widget _trackList() {
    final names = [...kTrackNames, 'Aleatória'];
    return _card(Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Trocar de música sozinha'),
          subtitle: const Text('Toca a próxima quando uma termina',
              style: TextStyle(fontSize: 12)),
          value: Settings.musicAuto.value,
          onChanged: (v) {
            Audio.setAuto(v);
            setState(() {});
          },
        ),
        for (int i = 0; i < names.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.music_note,
                color: Settings.musicTrack.value == i
                    ? Colors.cyanAccent
                    : Colors.white38),
            title: Text(names[i]),
            trailing: Settings.musicTrack.value == i
                ? const Icon(Icons.check_circle, color: Colors.cyanAccent)
                : null,
            onTap: () {
              Audio.changeTrack(i);
              setState(() {});
            },
          ),
      ],
    ));
  }

  Widget _themeItem(BlockTheme t) {
    final selected = t == Settings.theme.value;
    final locked = !Elo.themeUnlocked(t);
    return GestureDetector(
      onTap: () {
        if (locked) {
          Elo.showLocked(context, Elo.needTier(Elo.themeReq(t)));
          return;
        }
        setState(() => Settings.theme.value = t);
        Storage.saveTheme(t);
      },
      child: Container(
        width: 62,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? Colors.cyanAccent : Colors.white12,
                  width: selected ? 2 : 1,
                ),
              ),
              child: SizedBox(
                width: 42,
                height: 42,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: locked ? 0.3 : 1,
                      child: CustomPaint(
                          size: const Size(42, 42),
                          painter: ThemeSamplePainter(t)),
                    ),
                    if (locked)
                      const Icon(Icons.lock, size: 18, color: Colors.white70),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(t.label,
                style: TextStyle(
                    color: selected ? Colors.white : Colors.white54,
                    fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _choice(PadLayout l, String title, String sub, IconData icon) {
    final sel = Settings.layout.value == l;
    return GestureDetector(
      onTap: () {
        setState(() => Settings.layout.value = l);
        Settings.save();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: sel ? Colors.cyanAccent.withAlpha(30) : Colors.black38,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: sel ? Colors.cyanAccent : Colors.white12,
            width: sel ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: sel ? Colors.cyanAccent : Colors.white54),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  Text(sub,
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 12)),
                ],
              ),
            ),
            if (sel) const Icon(Icons.check_circle, color: Colors.cyanAccent),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditor() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const HudEditorScreen()),
    );
    if (mounted) setState(() {});
  }

  Widget _preview() {
    final l = Settings.layout.value;
    Widget body;
    if (l == PadLayout.gestures) {
      body = const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Sem botões, só gestos:\n'
          '• Arraste para os lados: mover\n'
          '• Arraste para baixo: descer\n'
          '• Deslize rápido para baixo: queda\n'
          '• Deslize rápido para cima ou toque em RESERVA: guardar\n'
          '• Toque no tabuleiro: girar\n'
          '• Segure o dedo parado no tabuleiro: girar 180°',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
      );
    } else if (l == PadLayout.custom) {
      body = Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            const Text(
              'Monte o seu HUD: arraste cada botão para onde preferir, '
              'mude o tamanho, esconda os que não quer e até ative um '
              'botão de RESERVA.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.edit),
              label: const Text('Editar meu HUD'),
              onPressed: _openEditor,
            ),
          ],
        ),
      );
    } else {
      body = Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ControlPad(
          layout: l,
          scale: Settings.padScale.value,
          onLeft: _noop,
          onRight: _noop,
          onDown: _noop,
          onRotate: _noop,
          onDrop: _noop,
          onFlip: _noop,
        ),
      );
    }
    return _card(Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Pré-visualização',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ),
        body,
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final layout = Settings.layout.value;
    final gestures = layout == PadLayout.gestures;
    final scalable = layout == PadLayout.standard || layout == PadLayout.mirrored;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text('Configurações',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    _section('TEXTURA DAS PEÇAS'),
                    _card(SizedBox(
                      height: 84,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final t in BlockTheme.values) _themeItem(t),
                        ],
                      ),
                    )),
                    _section('JOGO'),
                    _card(Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text('Velocidade de queda'),
                        ),
                        SpeedChips(value: Settings.speedMul),
                      ],
                    )),
                    _slider(
                      icon: Icons.speed,
                      label: 'Nível inicial',
                      value: Settings.startLevel.value.toDouble(),
                      lo: 1,
                      hi: 15,
                      text: '${Settings.startLevel.value}',
                      onChanged: (v) =>
                          setState(() => Settings.startLevel.value = v.round()),
                      onEnd: (_) => Settings.save(),
                    ),
                    _section('SOM'),
                    _slider(
                      icon: Icons.music_note,
                      label: 'Volume da música',
                      value: Settings.musicVol.value,
                      lo: 0,
                      hi: 1,
                      text: '${(Settings.musicVol.value * 100).round()}%',
                      onChanged: (v) {
                        Audio.setMusicVolume(v);
                        setState(() {});
                      },
                      onEnd: (_) => Settings.save(),
                    ),
                    _slider(
                      icon: Icons.volume_up,
                      label: 'Volume dos efeitos',
                      value: Settings.sfxVol.value,
                      lo: 0,
                      hi: 1,
                      text: '${(Settings.sfxVol.value * 100).round()}%',
                      onChanged: (v) =>
                          setState(() => Settings.sfxVol.value = v),
                      onEnd: (_) {
                        Settings.save();
                        Audio.play('clear');
                      },
                    ),
                    _section('MÚSICA'),
                    _trackList(),
                    _section('CONTROLES'),
                    _card(ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.keyboard_alt_outlined,
                          color: Colors.cyanAccent),
                      title: const Text('Teclas e controle'),
                      subtitle: const Text(
                          'Layout do teclado e do controle, trocar teclas e botões',
                          style: TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ControlsScreen()),
                      ),
                    )),
                    _choice(
                      PadLayout.standard,
                      'Padrão',
                      'Mover à esquerda, girar e queda à direita',
                      Icons.gamepad,
                    ),
                    _choice(
                      PadLayout.mirrored,
                      'Invertido (canhoto)',
                      'Girar e queda à esquerda, mover à direita',
                      Icons.swap_horiz,
                    ),
                    _choice(
                      PadLayout.custom,
                      'Meu HUD',
                      'Você posiciona cada botão onde quiser',
                      Icons.dashboard_customize,
                    ),
                    _choice(
                      PadLayout.gestures,
                      'Só gestos',
                      'Esconde os botões e deixa o tabuleiro maior',
                      Icons.swipe,
                    ),
                    _preview(),
                    if (scalable)
                      _slider(
                        icon: Icons.photo_size_select_small,
                        label: 'Tamanho dos botões',
                        value: Settings.padScale.value,
                        lo: 0.6,
                        hi: 1.0,
                        text: '${(Settings.padScale.value * 100).round()}%',
                        onChanged: (v) =>
                            setState(() => Settings.padScale.value = v),
                        onEnd: (_) => Settings.save(),
                      ),
                    if (!gestures)
                      _slider(
                        icon: Icons.opacity,
                        label: 'Transparência dos botões',
                        value: Settings.padOpacity.value,
                        lo: 0.3,
                        hi: 1.0,
                        text: '${(Settings.padOpacity.value * 100).round()}%',
                        onChanged: (v) =>
                            setState(() => Settings.padOpacity.value = v),
                        onEnd: (_) => Settings.save(),
                      ),
                    _slider(
                      icon: Icons.touch_app,
                      label: 'Sensibilidade do deslize',
                      value: Settings.swipeSens.value,
                      lo: 0.6,
                      hi: 1.6,
                      text: '${Settings.swipeSens.value.toStringAsFixed(1)}x',
                      onChanged: (v) =>
                          setState(() => Settings.swipeSens.value = v),
                      onEnd: (_) => Settings.save(),
                    ),
                    _slider(
                      icon: Icons.timer,
                      label: 'DAS: atraso para repetir ao segurar',
                      value: Settings.das.value,
                      lo: 60,
                      hi: 300,
                      text: '${Settings.das.value.round()}ms',
                      onChanged: (v) => setState(() => Settings.das.value = v),
                      onEnd: (_) => Settings.save(),
                    ),
                    _slider(
                      icon: Icons.speed,
                      label: 'ARR: velocidade da repetição (0 = direto)',
                      value: Settings.arr.value,
                      lo: 0,
                      hi: 100,
                      text: '${Settings.arr.value.round()}ms',
                      onChanged: (v) => setState(() => Settings.arr.value = v),
                      onEnd: (_) => Settings.save(),
                    ),
                    if (!gestures)
                      _switch(
                        'Botão de giro 180°',
                        'Botão rosa ao lado do girar (nos layouts com botões)',
                        Settings.flipBtn.value,
                        (v) {
                          setState(() => Settings.flipBtn.value = v);
                          Settings.save();
                        },
                      ),
                    _switch(
                      'Vibração',
                      'Toque de resposta ao girar e travar',
                      Settings.haptics.value,
                      (v) {
                        setState(() => Settings.haptics.value = v);
                        Settings.save();
                      },
                    ),
                    _switch(
                      'Efeitos visuais',
                      'Brilho ao limpar linhas, tremor e alerta de perigo',
                      Settings.fx.value,
                      (v) {
                        setState(() => Settings.fx.value = v);
                        Settings.save();
                      },
                    ),
                    _section('O QUE APARECE NA TELA'),
                    _switch(
                      'Placar grande',
                      'Pontos e recorde no topo',
                      Settings.showScore.value,
                      (v) {
                        setState(() => Settings.showScore.value = v);
                        Settings.save();
                      },
                    ),
                    _switch(
                      'Próximas peças',
                      'Coluna NEXT à direita do tabuleiro',
                      Settings.showNext.value,
                      (v) {
                        setState(() => Settings.showNext.value = v);
                        Settings.save();
                      },
                    ),
                    _switch(
                      'Painel lateral esquerdo',
                      'RESERVA, linhas e nível/tempo',
                      Settings.showSide.value,
                      (v) {
                        setState(() => Settings.showSide.value = v);
                        Settings.save();
                      },
                    ),
                    _section('AJUDA'),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.school),
                      label: const Text('Rever tutorial'),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const TutorialScreen()),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.restore),
                      label: const Text('Restaurar padrão'),
                      onPressed: () {
                        Settings.resetDefaults();
                        Controls.resetKeys();
                        Controls.resetPad();
                        Controls.save();
                        Audio.setMusicVolume(Settings.musicVol.value);
                        Audio.changeTrack(Settings.musicTrack.value);
                        Audio.setAuto(Settings.musicAuto.value);
                        Settings.save();
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== hud editor =====

/// Editor do HUD: arraste os botões, ajuste tamanho e visibilidade.
class HudEditorScreen extends StatefulWidget {
  const HudEditorScreen({super.key});

  @override
  State<HudEditorScreen> createState() => _HudEditorScreenState();
}

class _HudEditorScreenState extends State<HudEditorScreen> {
  static const Map<String, String> _names = {
    'left': 'Mover à esquerda',
    'down': 'Descer',
    'right': 'Mover à direita',
    'rotate': 'Girar',
    'flip': 'Girar 180°',
    'drop': 'Queda rápida',
    'hold': 'Guardar peça (RESERVA)',
  };

  String? _sel;
  bool _panelOpen = true;

  @override
  void initState() {
    super.initState();
    // Ao entrar no editor, o HUD próprio passa a ser o layout ativo.
    Settings.layout.value = PadLayout.custom;
    Settings.save();
  }

  Widget _editable(String key, PadItem it, double w, double h) {
    final sz = it.size;
    final selected = _sel == key;
    return Positioned(
      left: (it.x * w - sz / 2).clamp(0.0, max(0.0, w - sz)).toDouble(),
      top: (it.y * h - sz / 2).clamp(0.0, max(0.0, h - sz)).toDouble(),
      child: GestureDetector(
        onTap: () => setState(() => _sel = key),
        onPanStart: (_) => setState(() => _sel = key),
        onPanUpdate: (d) {
          setState(() {
            it.x = (it.x + d.delta.dx / w).clamp(0.0, 1.0).toDouble();
            it.y = (it.y + d.delta.dy / h).clamp(0.0, 1.0).toDouble();
          });
        },
        onPanEnd: (_) => Settings.save(),
        child: Container(
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(sz * 0.3 + 3),
            border: Border.all(
              color: selected ? Colors.cyanAccent : Colors.transparent,
              width: 2,
            ),
          ),
          child: Opacity(
            opacity: it.on ? Settings.padOpacity.value : 0.3,
            child: AbsorbPointer(child: _padFor(key, sz, () {})),
          ),
        ),
      ),
    );
  }

  Widget _panel() {
    final key = _sel;
    final it = key == null ? null : Settings.custom[key];
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 8),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(225),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white70),
                onPressed: () => Navigator.pop(context),
              ),
              const Expanded(
                child: Text('Editar meu HUD',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                tooltip: 'Restaurar posições',
                icon: const Icon(Icons.restore, color: Colors.white70),
                onPressed: () {
                  setState(() => Settings.custom = Settings.defaultCustom());
                  Settings.save();
                },
              ),
              IconButton(
                tooltip: _panelOpen ? 'Recolher' : 'Abrir',
                icon: Icon(_panelOpen ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white70),
                onPressed: () => setState(() => _panelOpen = !_panelOpen),
              ),
            ],
          ),
          if (_panelOpen) ...[
            if (it == null)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  'Arraste os botões para onde ficar mais confortável. '
                  'Toque em um botão para mudar o tamanho ou escondê-lo.',
                  style: TextStyle(color: Colors.white70, height: 1.4),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_names[key] ?? '',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                    ),
                    const Text('Mostrar',
                        style: TextStyle(color: Colors.white60, fontSize: 12)),
                    Switch(
                      value: it.on,
                      onChanged: (v) {
                        setState(() => it.on = v);
                        Settings.save();
                      },
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  const SizedBox(width: 8),
                  const Icon(Icons.photo_size_select_small,
                      color: Colors.cyanAccent, size: 20),
                  Expanded(
                    child: Slider(
                      value: it.size.clamp(36.0, 120.0).toDouble(),
                      min: 36,
                      max: 120,
                      activeColor: Colors.cyanAccent,
                      onChanged: (v) => setState(() => it.size = v),
                      onChangeEnd: (_) => Settings.save(),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text('${it.size.round()}',
                        textAlign: TextAlign.end,
                        style: const TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ],
            Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.opacity, color: Colors.cyanAccent, size: 20),
                Expanded(
                  child: Slider(
                    value: Settings.padOpacity.value,
                    min: 0.3,
                    max: 1.0,
                    activeColor: Colors.cyanAccent,
                    onChanged: (v) =>
                        setState(() => Settings.padOpacity.value = v),
                    onChangeEnd: (_) => Settings.save(),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text('${(Settings.padOpacity.value * 100).round()}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            final h = c.maxHeight;
            final reserve = Settings.bottomReserve(w, h);
            return Stack(
              children: [
                // Simulação da tela de jogo (mesma estrutura do jogo real).
                Column(
                  children: [
                    const SizedBox(height: 56),
                    if (Settings.showScore.value)
                      Container(
                        margin: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                        height: 64,
                        decoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white12),
                        ),
                        alignment: Alignment.center,
                        child: const Text('PLACAR',
                            style: TextStyle(
                                color: Colors.white24, letterSpacing: 3)),
                      )
                    else
                      const SizedBox(height: 4),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: kCols / kRows,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black26,
                                border: Border.all(color: Colors.white12),
                              ),
                              alignment: Alignment.center,
                              child: const Text('ÁREA DE JOGO',
                                  style: TextStyle(
                                      color: Colors.white24, letterSpacing: 2)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: reserve),
                  ],
                ),
                for (final e in Settings.custom.entries)
                  _editable(e.key, e.value, w, h),
                Positioned(top: 0, left: 0, right: 0, child: _panel()),
              ],
            );
          }),
        ),
      ),
    );
  }
}

// ===== online =====

final ButtonStyle kBlueOutline = FilledButton.styleFrom(
  side: const BorderSide(color: Colors.cyanAccent, width: 2),
);

const String kServer = 'https://tetris-online-4dc62-default-rtdb.firebaseio.com';
const int kMaxPlayers = 10;

class OnlineSession {
  final String base;
  final String code;
  final bool host;
  final int seed;
  final String myKey;
  final String myName;
  final List<String> roster;
  final Map<String, String> names;
  final int round;
  final double speed;
  final String kind;
  final String roomName;
  final bool priv;
  final int maxP;
  final Map<String, int> ratings;

  const OnlineSession({
    required this.base,
    required this.code,
    required this.host,
    required this.seed,
    required this.myKey,
    required this.myName,
    this.roster = const [],
    this.names = const {},
    this.round = 0,
    this.speed = 1.0,
    this.kind = 'battle',
    this.roomName = '',
    this.priv = false,
    this.maxP = kMaxPlayers,
    this.ratings = const {},
  });
}

/// Estado de um rival, como visto por este jogador.
class _Opp {
  final String name;
  String board = '';
  int score = 0;
  bool over = false;
  int n = -2;
  int stale = 0;
  int seenAtk = 0;
  bool fin = false;
  int lines = 0;
  int suspect = 0;

  _Opp(this.name);

  bool get alive => !over && stale < 24;
}

/// Acesso ao Firebase Realtime Database via REST (sem SDK).
class Net {
  static const Duration _timeout = Duration(seconds: 6);

  static Uri _u(String base, String path) => Uri.parse('$base/$path.json');

  static Future<dynamic> get(String base, String path) async {
    final r = await http.get(_u(base, path)).timeout(_timeout);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return jsonDecode(r.body);
  }

  static Future<void> put(
      String base, String path, Map<String, dynamic> body) async {
    final r =
        await http.put(_u(base, path), body: jsonEncode(body)).timeout(_timeout);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  }

  static Future<void> patch(
      String base, String path, Map<String, dynamic> body) async {
    final r = await http
        .patch(_u(base, path), body: jsonEncode(body))
        .timeout(_timeout);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  }

  static Future<void> delete(String base, String path) async {
    await http.delete(_u(base, path)).timeout(_timeout);
  }

  static Future<bool> putIfAbsent(
      String base, String path, Map<String, dynamic> body) async {
    final r = await http
        .put(
          _u(base, path),
          headers: {'if-match': 'null_etag'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    if (r.statusCode == 412) return false;
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return true;
  }

  /// Só as chaves de um nó (para listar sem baixar tudo).
  static Future<Map<String, dynamic>> getShallow(
      String base, String path) async {
    final r = await http
        .get(Uri.parse('$base/$path.json?shallow=true'))
        .timeout(_timeout);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final d = jsonDecode(r.body);
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  /// Hora do servidor (ms), para comparar com os batimentos das salas.
  static Future<int> serverNow(String base) async {
    final key = Settings.username.isEmpty
        ? 'anon'
        : Settings.username.toLowerCase();
    await put(base, 'rooms/_ping/$key', {
      't': {'.sv': 'timestamp'},
    });
    final r = await get(base, 'rooms/_ping/$key/t');
    return (r as num).toInt();
  }

  /// Reserva um nome de usuário único. Retorna false se já for de outra pessoa.
  static Future<bool> claimName(String base, String key, String name) async {
    final path = 'rooms/_users/$key';
    final cur = await get(base, path);
    if (cur is Map) return cur['id'] == Settings.deviceId;
    final r = await http
        .put(
          _u(base, path),
          headers: {'if-match': 'null_etag'},
          body: jsonEncode({'id': Settings.deviceId, 'name': name}),
        )
        .timeout(_timeout);
    if (r.statusCode == 412) return false;
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final back = await get(base, path);
    return back is Map && back['id'] == Settings.deviceId;
  }

  static Future<void> releaseName(String base, String key) async {
    final path = 'rooms/_users/$key';
    final cur = await get(base, path);
    if (cur is Map && cur['id'] == Settings.deviceId) {
      await delete(base, path);
    }
  }
}

/// Tabuleiro de um rival em miniatura.
class MiniBoardPainter extends CustomPainter {
  final String cells;
  final bool dim;

  MiniBoardPainter(this.cells, {this.dim = false});

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / kCols;
    final ch = size.height / kRows;
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0x33000000));
    if (cells.length >= kCols * kRows) {
      final paint = Paint();
      for (int i = 0; i < kCols * kRows; i++) {
        final v = cells.codeUnitAt(i) - 48;
        if (v <= 0 || v >= kPieceColors.length) continue;
        paint.color = kPieceColors[v].withAlpha(dim ? 70 : 255);
        canvas.drawRect(
          Rect.fromLTWH((i % kCols) * cw, (i ~/ kCols) * ch, cw, ch),
          paint,
        );
      }
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x55FFFFFF),
    );
  }

  @override
  bool shouldRepaint(covariant MiniBoardPainter old) =>
      old.cells != cells || old.dim != dim;
}

const List<String> kSpeedNames = ['Lenta', 'Normal', 'Rápida', 'Insana'];
const List<double> kSpeedVals = [0.6, 1.0, 1.5, 2.2];

String speedName(double v) {
  var best = 0;
  for (int i = 1; i < kSpeedVals.length; i++) {
    if ((kSpeedVals[i] - v).abs() < (kSpeedVals[best] - v).abs()) best = i;
  }
  return kSpeedNames[best];
}

/// Escolha rápida de velocidade de queda.
class SpeedChips extends StatefulWidget {
  final ValueNotifier<double> value;

  const SpeedChips({super.key, required this.value});

  @override
  State<SpeedChips> createState() => _SpeedChipsState();
}

class _SpeedChipsState extends State<SpeedChips> {
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      alignment: WrapAlignment.center,
      children: [
        for (int i = 0; i < kSpeedNames.length; i++)
          ChoiceChip(
            label: Text(kSpeedNames[i]),
            selected: (widget.value.value - kSpeedVals[i]).abs() < 0.01,
            selectedColor: Colors.cyanAccent.withAlpha(90),
            side: const BorderSide(color: Colors.cyanAccent),
            onSelected: (_) {
              setState(() => widget.value.value = kSpeedVals[i]);
              Settings.save();
            },
          ),
      ],
    );
  }
}

const int kRankedMax = 4;

String statusLabel(String s) =>
    s == 'online' ? 'Online' : (s == 'away' ? 'Ausente' : 'Offline');

Color statusColor(String s) => s == 'online'
    ? Colors.greenAccent
    : (s == 'away' ? Colors.amber : Colors.grey);

Widget statusDot(String s, {double size = 10}) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: statusColor(s), shape: BoxShape.circle),
    );

String kindLabel(String k) {
  switch (k) {
    case 'ranked':
      return 'Ranqueada';
    case 'race':
      return 'Corrida 40';
    case 'ultra':
      return 'Relâmpago 2:00';
    case 'cheese':
      return 'Desafio do lixo';
    default:
      return 'Batalha';
  }
}

/// Modos que podem ser criados em salas online (a ranqueada tem botão próprio).
const List<(String, String, String)> kOnlineKinds = [
  ('battle', 'Batalha',
      'Linhas limpas viram lixo nos rivais. O último vivo vence.'),
  ('race', 'Corrida 40',
      'Quem limpar 40 linhas primeiro vence. Ainda dá para atacar.'),
  ('ultra', 'Ultra 2:00',
      'Maior pontuação em 2 minutos vence. Quem cair fica para trás.'),
  ('cheese', 'Desafio do lixo',
      'Todos começam com lixo no tabuleiro. Quem limpar tudo primeiro vence.'),
];

/// Modo de jogo local usado por cada tipo de sala online.
GameMode kindMode(String k) {
  switch (k) {
    case 'race':
      return GameMode.sprint;
    case 'ultra':
      return GameMode.ultra;
    case 'cheese':
      return GameMode.cheese;
    default:
      return GameMode.classic;
  }
}

Map<String, String> pickNames(dynamic m) {
  final out = <String, String>{};
  if (m is Map) {
    m.forEach((k, v) {
      out['$k'] = (v is Map && v['name'] is String) ? v['name'] as String : '$k';
    });
  }
  return out;
}

/// Presença: online, ausente ou offline, mais convites de amigos.
class Presence {
  static final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
  static Timer? _timer;
  static String status = 'online';
  /// Status escolhido pela pessoa (online, away ou offline = invisível).
  static String pref = 'online';
  static String? room;
  static String? roomName;
  static bool roomWaiting = false;
  static final Set<String> _seen = <String>{};

  static void start() {
    _timer?.cancel();
    _timer = null;
    if (!Settings.loggedIn) return;
    _beat();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _beat());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> setStatus(String s) async {
    status = s;
    await _beat();
  }

  static Future<void> _beat() async {
    if (!Settings.loggedIn) return;
    try {
      final me = Account.key(Settings.username);
      await Net.put(kServer, 'rooms/_presence/$me', {
        's': status,
        'r': room,
        'rn': roomName,
        't': {'.sv': 'timestamp'},
      });
      if (status == 'online' && room == null) await _checkInvites(me);
    } catch (_) {}
  }

  /// online (batimento recente), ausente (app em segundo plano) ou offline.
  static String compute(Map? e, int now) {
    if (e == null) return 'offline';
    if (e['s'] == 'offline') return 'offline';
    final age = now - ((e['t'] as num?)?.toInt() ?? 0);
    if (e['s'] == 'away') return age < 600000 ? 'away' : 'offline';
    if (age < 45000) return 'online';
    return age < 600000 ? 'away' : 'offline';
  }

  static Future<Map<String, String>> all() async {
    final now = await Net.serverNow(kServer);
    final m = await Net.get(kServer, 'rooms/_presence');
    final out = <String, String>{};
    if (m is Map) {
      m.forEach((k, v) {
        out['$k'] = compute(v is Map ? v : null, now);
      });
    }
    return out;
  }

  /// Status, sala atual e nome da sala de todos (só quem não está offline).
  static Future<Map<String, Map>> info() async {
    final now = await Net.serverNow(kServer);
    final m = await Net.get(kServer, 'rooms/_presence');
    final out = <String, Map>{};
    if (m is Map) {
      m.forEach((k, v) {
        final e = v is Map ? v : null;
        final st = compute(e, now);
        out['$k'] = {
          's': st,
          'r': st == 'offline' ? null : e?['r'],
          'rn': st == 'offline' ? null : e?['rn'],
        };
      });
    }
    return out;
  }

  static Future<Map> infoOf(String key) async {
    final now = await Net.serverNow(kServer);
    final v = await Net.get(kServer, 'rooms/_presence/$key');
    final e = v is Map ? v : null;
    final st = compute(e, now);
    return {
      's': st,
      'r': st == 'offline' ? null : e?['r'],
      'rn': st == 'offline' ? null : e?['rn'],
    };
  }

  static Future<void> _checkInvites(String me) async {
    final inv = await Net.get(kServer, 'rooms/_accounts/$me/invites');
    if (inv is! Map) return;
    for (final e in inv.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final sig = '${e.key}:${v['code']}';
      if (_seen.contains(sig)) continue;
      _seen.add(sig);
      await _showInvite('${e.key}', v, me);
      break;
    }
  }

  static Future<void> _showInvite(String from, Map v, String me) async {
    final ctx = nav.currentState?.overlay?.context;
    if (ctx == null) return;
    final code = '${v['code']}';
    final r = await Net.get(kServer, 'rooms/$code');
    if (r is! Map || r['state'] != 'waiting') {
      await Net.delete(kServer, 'rooms/_accounts/$me/invites/$from');
      return;
    }
    if (!ctx.mounted) return;
    final duel = v['duel'] == true;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: Text(duel ? 'Desafio de ${v['name']}' : 'Convite de ${v['name']}'),
        content: Text(duel
            ? 'Duelo 1x1: ${v['room']}'
            : 'Sala: ${v['room']}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Recusar'),
          ),
          FilledButton(
            style: kBlueOutline,
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Entrar'),
          ),
        ],
      ),
    );
    await Net.delete(kServer, 'rooms/_accounts/$me/invites/$from');
    if (ok != true) return;
    final err = await Rooms.join(code);
    if (err == null) {
      nav.currentState?.push(MaterialPageRoute(
          builder: (_) => OnlineWaitScreen(code: code, host: false)));
    }
  }
}

/// Criar, entrar, convidar e achar partida ranqueada.
class Rooms {
  static Future<String> create({
    required String name,
    required bool priv,
    String pw = '',
    double speed = 1.0,
    String kind = 'battle',
    int max = kMaxPlayers,
    String? inviteKey,
    bool duel = false,
  }) async {
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    final rnd = Random();
    var code = '';
    for (int i = 0; i < 5; i++) {
      code = List.generate(4, (_) => letters[rnd.nextInt(letters.length)]).join();
      if (await Net.get(kServer, 'rooms/$code') == null) break;
    }
    final key = Account.key(Settings.username);
    final ms = DateTime.now().millisecondsSinceEpoch;
    await Net.put(kServer, 'rooms/$code', {
      'seed': rnd.nextInt(1 << 30),
      'state': 'waiting',
      'host': key,
      'round': 0,
      'created': ms,
      'name': name,
      'public': !priv,
      'speed': speed,
      'kind': kind,
      'max': max,
      if (duel) 'duel': true,
      if (priv) 'pass': Account.roomHash(code, pw),
      'players': {
        key: {'name': Settings.username, 'dev': Account.devTag},
      },
    });
    if (inviteKey != null) await invite(code, name, duel, inviteKey);
    return code;
  }

  static Future<void> invite(
      String code, String roomName, bool duel, String toKey) async {
    final me = Account.key(Settings.username);
    await Net.put(kServer, 'rooms/$code/invited/$toKey',
        {'t': DateTime.now().millisecondsSinceEpoch});
    await Net.put(kServer, 'rooms/_accounts/$toKey/invites/$me', {
      'name': Settings.username,
      'code': code,
      'room': roomName,
      'duel': duel,
      't': {'.sv': 'timestamp'},
    });
  }

  /// Retorna null se entrou, ou a mensagem de erro.
  static Future<String?> join(String code,
      {String pw = '', bool spectate = false}) async {
    final r = await Net.get(kServer, 'rooms/$code');
    if (r is! Map || r['host'] == null) return 'Essa sala não existe mais.';
    final key = Account.key(Settings.username);
    final invited =
        r['invited'] is Map && (r['invited'] as Map).containsKey(key);
    final pass = r['pass'];
    if (pass is String && pass.isNotEmpty && !invited) {
      var ok = pw.isNotEmpty && Account.roomHash(code, pw) == pass;
      if (!ok) {
        // Amigos do anfitrião entram sem senha.
        try {
          ok = (await Account.friendKeys()).contains('${r['host']}');
        } catch (_) {}
      }
      if (!ok) {
        return pw.isEmpty ? 'Sala privada: digite a senha.' : 'Senha incorreta.';
      }
    }
    if (spectate) {
      await Net.put(
          kServer, 'rooms/$code/spectators/$key', {'name': Settings.username});
      return null;
    }
    if (r['state'] != 'waiting') return 'Essa partida já começou.';
    final players = r['players'];
    final maxP = (r['max'] as num?)?.toInt() ?? kMaxPlayers;
    final count = players is Map ? players.length : 0;
    final already = players is Map && players.containsKey(key);
    if (count >= maxP && !already) return 'Sala cheia ($maxP/$maxP).';
    if (r['kind'] == 'ranked' && players is Map) {
      final mine = Account.devTag;
      final dup = players.entries.any((e) =>
          e.key != key && e.value is Map && (e.value as Map)['dev'] == mine);
      if (dup) {
        return 'Outra conta deste aparelho já está nesta sala ranqueada.';
      }
    }
    await Net.put(kServer, 'rooms/$code/players/$key',
        {'name': Settings.username, 'dev': Account.devTag});
    return null;
  }

  /// Partida ranqueada: entra numa sala ranqueada aberta ou cria uma nova.
  static Future<(String, bool)> quickMatch() async {
    await AntiCheat.settlePending();
    await Season.refresh();
    final block = AntiCheat.blockedMessage();
    if (block != null) throw RankedBlocked(block);
    final now = await Net.serverNow(kServer);
    final all = await Net.get(kServer, 'rooms/_public');
    String? best;
    var bestCount = -1;
    if (all is Map) {
      all.forEach((k, v) {
        if (v is! Map || v['kind'] != 'ranked' || v['state'] != 'waiting') {
          return;
        }
        final t = (v['t'] as num?)?.toInt() ?? 0;
        final count = (v['count'] as num?)?.toInt() ?? 0;
        final mx = (v['max'] as num?)?.toInt() ?? kRankedMax;
        if (now - t > 40000 || count >= mx) return;
        if (count > bestCount) {
          bestCount = count;
          best = '$k';
        }
      });
    }
    final found = best;
    if (found != null) {
      final err = await join(found);
      if (err == null) return (found, false);
    }
    final code = await create(
      name: 'Ranqueada de ${Settings.username}',
      priv: false,
      kind: 'ranked',
      max: kRankedMax,
    );
    return (code, true);
  }
}

/// Contas: nome único + senha (guardada só como hash) e progresso na nuvem.
class Account {
  static String key(String name) => name.toLowerCase();

  /// Identificador (hash) do aparelho: impede 2 contas do mesmo aparelho
  /// na mesma sala ranqueada.
  static String get devTag => sha256
      .convert(utf8.encode('dev:${Settings.deviceId}'))
      .toString()
      .substring(0, 16);

  static String hash(String salt, String pw) =>
      sha256.convert(utf8.encode('$salt:$pw')).toString();

  static String roomHash(String code, String pw) =>
      sha256.convert(utf8.encode('room:$code:$pw')).toString();

  static Future<String?> register(String name, String pw) async {
    if (!RegExp(r'^[A-Za-z0-9_]{3,12}$').hasMatch(name)) {
      return 'Nome: 3 a 12 caracteres (letras, números ou _).';
    }
    if (pw.length < 4) return 'A senha precisa ter pelo menos 4 caracteres.';
    final path = 'rooms/_accounts/${key(name)}';
    final cur = await Net.get(kServer, path);
    if (cur != null) return 'Esse nome já está em uso.';
    final rnd = Random.secure();
    final salt =
        List.generate(12, (_) => rnd.nextInt(36).toRadixString(36)).join();
    final h = hash(salt, pw);
    final ok = await Net.putIfAbsent(kServer, path, {
      'name': name,
      'salt': salt,
      'hash': h,
      'created': DateTime.now().millisecondsSinceEpoch,
    });
    if (!ok) return 'Esse nome já está em uso.';
    await Settings.saveLogin(name, h);
    await sync();
    return null;
  }

  static Future<String?> login(String name, String pw) async {
    final cur = await Net.get(kServer, 'rooms/_accounts/${key(name)}');
    if (cur is! Map) return 'Conta não encontrada.';
    final h = hash('${cur['salt']}', pw);
    if (h != cur['hash']) return 'Senha incorreta.';
    await Settings.saveLogin((cur['name'] as String?) ?? name, h);
    final prof = cur['profile'];
    if (prof is Map) {
      Settings.avatar = (prof['avatar'] as num?)?.toInt() ?? 0;
      Settings.bio = (prof['bio'] as String?) ?? '';
      Settings.frame = (prof['frame'] as num?)?.toInt() ?? -1;
      Settings.nameColor = (prof['nameColor'] as num?)?.toInt() ?? -1;
      await Settings.saveProfileLocal();
      await Settings.saveCosmetics();
    }
    await sync();
    return null;
  }

  static const List<String> avatars = [
    '🙂', '😎', '🤖', '👾', '🐱', '🦊', '🐼', '🐸', '🦄', '🔥', '⚡', '👑',
    // recompensas (tutorial e elos) — mesma ordem de Elo.avatarReq
    '🎓',
    '🎯', '🛡️', '🌙', '🦅', '🦁', '🏆', '🐉', '💎', '🧊', '🌌', '🧙', '🌋', '🐲', '☄️',
  ];

  static String av(int i) => avatars[(i % avatars.length + avatars.length) % avatars.length];

  static Future<void> saveProfile() async {
    if (!Settings.loggedIn) return;
    await Net.patch(
        kServer, 'rooms/_accounts/${key(Settings.username)}/profile', {
      'avatar': Settings.avatar,
      'bio': Settings.bio,
      'frame': Settings.frame,
      'nameColor': Settings.nameColor,
    });
  }

  static Future<Map?> fetch(String k) async {
    final r = await Net.get(kServer, 'rooms/_accounts/$k');
    return r is Map ? r : null;
  }

  static Future<Set<String>> friendKeys() async {
    if (!Settings.loggedIn) return <String>{};
    final acc = await fetch(key(Settings.username));
    final fr = acc?['friends'];
    return fr is Map ? fr.keys.map((e) => '$e').toSet() : <String>{};
  }

  static Future<void> sendRequest(String target) async {
    final me = key(Settings.username);
    await Net.put(kServer, 'rooms/_accounts/$target/requests/$me', {
      'name': Settings.username,
      't': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> accept(String from, String fromName) async {
    final me = key(Settings.username);
    await Net.put(kServer, 'rooms/_accounts/$me/friends/$from', {'name': fromName});
    await Net.put(
        kServer, 'rooms/_accounts/$from/friends/$me', {'name': Settings.username});
    await Net.delete(kServer, 'rooms/_accounts/$me/requests/$from');
  }

  static Future<void> decline(String from) async {
    await Net.delete(
        kServer, 'rooms/_accounts/${key(Settings.username)}/requests/$from');
  }

  static Future<void> removeFriend(String other) async {
    final me = key(Settings.username);
    await Net.delete(kServer, 'rooms/_accounts/$me/friends/$other');
    await Net.delete(kServer, 'rooms/_accounts/$other/friends/$me');
  }

  static Future<List<String>> searchKeys(String q) async {
    final all = await Net.getShallow(kServer, 'rooms/_accounts');
    final low = q.trim().toLowerCase();
    final me = Settings.loggedIn ? key(Settings.username) : '';
    final out = all.keys
        .where((k) => k != me && (low.isEmpty || k.contains(low)))
        .toList()
      ..sort();
    return out.take(30).toList();
  }

  static Future<Map<String, int>> ratings(List<String> keys) async {
    final out = <String, int>{};
    try {
      await Season.refresh();
      final all = await Net.get(kServer, 'rooms/_rank');
      for (final k in keys) {
        final e = all is Map ? all[k] : null;
        out[k] = AntiCheat.entryRating(k, e);
      }
    } catch (_) {}
    return out;
  }

  /// Atualiza o rating depois de uma partida ranqueada (estilo Elo).
  /// [suspicious]: o resultado deste aparelho falhou nas checagens do anti-cheat.
  static Future<int> applyRanked(OnlineSession s, int place,
      {int elapsedMs = 1 << 30, bool suspicious = false}) async {
    final others = <int>[
      for (final k in s.roster)
        if (k != s.myKey) s.ratings[k] ?? kStartRating,
    ];
    // A partida deixa de estar "pendente" assim que o resultado é tratado.
    await AntiCheat.clearPending();
    return applyRankedRaw(others, place,
        elapsedMs: elapsedMs, suspicious: suspicious);
  }

  /// Núcleo do cálculo (também usado para punir partida abandonada).
  static Future<int> applyRankedRaw(List<int> others, int place,
      {int elapsedMs = 1 << 30, bool suspicious = false}) async {
    final n = others.length + 1;
    if (n < 2) return 0;
    await Season.refresh();
    await Settings.ensureSeason();
    final me = Settings.rating;
    var exp = 0.0;
    for (final ro in others) {
      final r = ro.clamp(0, kMaxRating).toInt();
      exp += 1 / (1 + pow(10, (r - me) / 400).toDouble());
    }
    exp /= others.length;
    final score = (n - place) / (n - 1);
    // As 10 primeiras partidas da temporada valem mais (calibragem).
    final k = Settings.rg < 10 ? 48 : 32;
    var delta = (k * (score - exp)).round().clamp(-k, k).toInt();
    if (suspicious) {
      await AntiCheat.strike('ranqueada com resultado impossível');
      if (delta > 0) delta = 0;
    } else if (delta > 0 && elapsedMs < 25000) {
      delta = 0; // vitória relâmpago não vale (combinada ou rival ausente)
    }
    Settings.rating = (me + delta).clamp(0, kMaxRating).toInt();
    delta = Settings.rating - me;
    Settings.rg++;
    if (place == 1) Settings.rw++;
    await Settings.saveRank();
    try {
      final ownKey = key(Settings.username);
      await Net.patch(
          kServer, 'rooms/_accounts/$ownKey/progress', _rankFields(ownKey));
      await sync();
    } catch (_) {}
    return delta;
  }

  /// Campos do ranked que vão para a nuvem, com a assinatura de integridade.
  static Map<String, dynamic> _rankFields(String owner) => {
        'season': Settings.season,
        'rating': Settings.rating,
        'rw': Settings.rw,
        'rg': Settings.rg,
        'pt': Settings.peakTier,
        'rsig': AntiCheat.rankSig(owner, Settings.season, Settings.rating,
            Settings.rw, Settings.rg, Settings.peakTier),
      };

  static Future<void> publishRank(Map<String, dynamic> best) async {
    if (!Settings.loggedIn) return;
    await Net.put(kServer, 'rooms/_rank/${key(Settings.username)}', {
      'name': Settings.username,
      'av': Settings.avatar,
      'fr': Settings.frame,
      'nc': Settings.nameColor,
      ..._rankFields(key(Settings.username)),
      'points': Settings.points,
      'owins': Settings.owins,
      'games': Settings.games,
      'best': best,
    });
  }

  /// Junta o progresso do aparelho com o da nuvem (maior vale / menor tempo).
  static Future<void> sync() async {
    if (!Settings.loggedIn) return;
    try {
      final base = 'rooms/_accounts/${key(Settings.username)}';
      final acc = await Net.get(kServer, base);
      if (acc is! Map || acc['hash'] != Settings.passHash) return;
      final Map cloud = acc['progress'] is Map ? acc['progress'] as Map : {};
      final Map cloudBest = cloud['best'] is Map ? cloud['best'] as Map : {};
      final games = max(Settings.games, (cloud['games'] as num?)?.toInt() ?? 0);
      final owins = max(Settings.owins, (cloud['owins'] as num?)?.toInt() ?? 0);
      final ogames =
          max(Settings.ogames, (cloud['ogames'] as num?)?.toInt() ?? 0);
      final points =
          max(Settings.points, (cloud['points'] as num?)?.toInt() ?? 0);
      // Temporada (hora do servidor) e ranked (assinatura de integridade).
      await Season.refresh();
      final ownKey = key(Settings.username);
      final cloudOk = AntiCheat.cloudRankValid(ownKey, cloud);
      final cloudSeason = (cloud['season'] as num?)?.toInt() ?? -1;
      if (Season.synced) {
        final cur = Season.current;
        if (cloudOk && cloudSeason == cur) {
          final cg = (cloud['rg'] as num?)?.toInt() ?? 0;
          // Partidas feitas offline neste aparelho não se perdem.
          if (Settings.season != cur || cg >= Settings.rg) {
            Settings.rating = ((cloud['rating'] as num?)?.toInt() ?? 0)
                .clamp(0, kMaxRating)
                .toInt();
            Settings.rw = (cloud['rw'] as num?)?.toInt() ?? 0;
            Settings.rg = cg;
          }
        } else if (Settings.season != cur) {
          Settings.rating = kStartRating;
          Settings.rw = 0;
          Settings.rg = 0;
        }
        Settings.season = cur;
      }
      if (cloudOk) {
        Settings.peakTier =
            max(Settings.peakTier, (cloud['pt'] as num?)?.toInt() ?? 0);
      } else if (cloud['pt'] == null && cloud['peak'] is num) {
        // Progresso antigo (antes das temporadas): converte o melhor elo.
        Settings.peakTier = max(Settings.peakTier,
            Elo.legacyIndexFor((cloud['peak'] as num).toInt()));
      }
      final cloudBan = ((cloud['ban'] as num?)?.toInt() ?? 0)
          .clamp(0, Season.nowMs + 7 * 24 * 3600 * 1000)
          .toInt();
      Settings.acBanUntil = max(Settings.acBanUntil, cloudBan);
      if (cloud['tut'] == true && !Settings.tutorialDone) {
        await Settings.setTutorialDone(push: false);
      }
      await Settings.saveRank();
      Elo.sanitize();
      final bestOut = <String, dynamic>{};
      for (final m in GameMode.values) {
        final local = await Storage.best(m);
        final c = (cloudBest[m.name] as num?)?.toInt();
        int? merged;
        if (local == null) {
          merged = c;
        } else if (c == null) {
          merged = local;
        } else {
          merged = m.timeBased ? min(local, c) : max(local, c);
        }
        if (merged != null) {
          bestOut[m.name] = merged;
          if (merged != local) await Storage.mergeBest(m, merged);
        }
      }
      await Settings.setStats(games, owins, ogames, points);
      await Net.patch(kServer, '$base/progress', {
        'games': games,
        'owins': owins,
        'ogames': ogames,
        'points': points,
        'best': bestOut,
        if (Season.synced) ..._rankFields(ownKey),
        'ban': Settings.acBanUntil,
        'tut': Settings.tutorialDone,
        'updated': DateTime.now().millisecondsSinceEpoch,
      });
      await publishRank(bestOut);
    } catch (_) {}
  }
}

Widget _glassCard(Widget child) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: child,
    );

Widget _statRow(String a, String b) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
              child: Text(a, style: const TextStyle(color: Colors.white70))),
          Text(b, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );

Widget _avatarCircle(int index, {double size = 44, int frame = -1}) =>
    Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white10,
        border: (frame >= 0 && frame < Elo.tiers.length)
            ? Border.all(color: Elo.tiers[frame].color, width: 2.5)
            : null,
        boxShadow: (frame >= 0 && frame < Elo.tiers.length)
            ? [
                BoxShadow(
                    color: Elo.tiers[frame].color.withAlpha(110),
                    blurRadius: 8)
              ]
            : null,
      ),
      child: Text(Account.av(index), style: TextStyle(fontSize: size * 0.55)),
    );

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _pass2 = TextEditingController();
  final TextEditingController _bio = TextEditingController(text: Settings.bio);
  final TextEditingController _find = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String _msg = '';
  Map<GameMode, int?> _bests = {};
  Map<String, String> _friends = {};
  Map<String, String> _reqs = {};
  List<String> _found = [];
  Map<String, Map> _pres = {};
  Timer? _presTimer;

  @override
  void initState() {
    super.initState();
    _loadBests();
    _loadSocial();
    _presTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _loadPresence());
  }

  Future<void> _loadPresence() async {
    if (!Settings.loggedIn || !mounted) return;
    try {
      final p = await Presence.info();
      if (mounted) setState(() => _pres = p);
    } catch (_) {}
  }

  String _st(String k) => '${_pres[k]?['s'] ?? 'offline'}';

  String _stText(String k) {
    final s = _st(k);
    final r = _pres[k]?['r'];
    return statusLabel(s) + (r != null ? ' · numa sala' : '');
  }

  @override
  void dispose() {
    _presTimer?.cancel();
    _user.dispose();
    _pass.dispose();
    _pass2.dispose();
    _bio.dispose();
    _find.dispose();
    super.dispose();
  }

  Future<void> _loadBests() async {
    final out = <GameMode, int?>{};
    for (final m in GameMode.values) {
      out[m] = await Storage.best(m);
    }
    if (mounted) setState(() => _bests = out);
  }

  Map<String, String> _pick(dynamic m) {
    final out = <String, String>{};
    if (m is Map) {
      m.forEach((k, v) {
        out['$k'] = (v is Map && v['name'] is String) ? v['name'] as String : '$k';
      });
    }
    return out;
  }

  Future<void> _loadSocial() async {
    if (!Settings.loggedIn) return;
    try {
      final acc = await Account.fetch(Account.key(Settings.username));
      if (acc == null || !mounted) return;
      setState(() {
        _friends = _pick(acc['friends']);
        _reqs = _pick(acc['requests']);
      });
      _loadPresence();
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (_busy) return;
    final name = _user.text.trim();
    final pw = _pass.text;
    if (_register && pw != _pass2.text) {
      setState(() => _msg = 'As senhas não são iguais.');
      return;
    }
    setState(() {
      _busy = true;
      _msg = _register ? 'Criando conta...' : 'Entrando...';
    });
    String? err;
    try {
      err = _register
          ? await Account.register(name, pw)
          : await Account.login(name, pw);
    } catch (_) {
      err = 'Não consegui conectar ao servidor.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = err ?? '';
      _bio.text = Settings.bio;
    });
    if (err == null) {
      _loadBests();
      _loadSocial();
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _msg = 'Sincronizando...';
    });
    await Account.sync();
    await _loadBests();
    await _loadSocial();
    if (mounted) {
      setState(() {
        _busy = false;
        _msg = 'Progresso sincronizado.';
      });
    }
  }

  Future<void> _saveBio() async {
    Settings.bio = _bio.text.trim();
    await Settings.saveProfileLocal();
    try {
      await Account.saveProfile();
      if (mounted) setState(() => _msg = 'Perfil salvo.');
    } catch (_) {
      if (mounted) setState(() => _msg = 'Não consegui salvar o perfil.');
    }
  }

  Future<void> _search() async {
    try {
      final r = await Account.searchKeys(_find.text);
      if (mounted) setState(() => _found = r);
    } catch (_) {
      if (mounted) setState(() => _msg = 'Não consegui buscar jogadores.');
    }
  }

  Future<void> _openProfile(String k) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(userKey: k)),
    );
    _loadSocial();
  }

  Widget _loginForm() {
    return _glassCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_register ? 'Criar conta' : 'Entrar na conta',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _user,
          autocorrect: false,
          maxLength: 12,
          decoration: const InputDecoration(labelText: 'Nome de usuário'),
        ),
        TextField(
          controller: _pass,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Senha'),
        ),
        if (_register)
          TextField(
            controller: _pass2,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Repita a senha'),
          ),
        const SizedBox(height: 14),
        FilledButton(
          style: kBlueOutline,
          onPressed: _busy ? null : _submit,
          child: Text(_register ? 'Criar conta' : 'Entrar'),
        ),
        TextButton(
          onPressed: () => setState(() {
            _register = !_register;
            _msg = '';
          }),
          child: Text(_register
              ? 'Já tenho conta: entrar'
              : 'Não tenho conta: criar uma'),
        ),
      ],
    ));
  }

  Widget _editProfile() {
    return _glassCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _avatarCircle(Settings.avatar, size: 56, frame: Settings.frame),
            const SizedBox(width: 12),
            Expanded(
              child: Text(Settings.username,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Escolha seu avatar',
            style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (int i = 0; i < Account.avatars.length; i++)
              GestureDetector(
                onTap: () {
                  if (!Elo.avatarUnlocked(i)) {
                    Elo.showLocked(context, Elo.needAvatar(i));
                    return;
                  }
                  setState(() => Settings.avatar = i);
                  Settings.saveProfileLocal();
                  Account.saveProfile().catchError((_) {});
                },
                child: Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white10,
                    border: Border.all(
                      color: Settings.avatar == i
                          ? Colors.cyanAccent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Elo.avatarUnlocked(i)
                      ? Text(Account.avatars[i],
                          style: const TextStyle(fontSize: 22))
                      : Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: 0.3,
                              child: Text(Account.avatars[i],
                                  style: const TextStyle(fontSize: 22)),
                            ),
                            const Icon(Icons.lock,
                                size: 16, color: Colors.white70),
                          ],
                        ),
                ),
              ),
          ],
        ),
        TextField(
          controller: _bio,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Sobre mim'),
        ),
        FilledButton(
          style: kBlueOutline,
          onPressed: _saveBio,
          child: const Text('Salvar perfil'),
        ),
      ],
    ));
  }

  Widget _friendsCard() {
    final keys = _friends.keys.toList()..sort();
    return _glassCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Amigos (${keys.length})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        if (keys.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Você ainda não tem amigos. Busque jogadores abaixo.',
                style: TextStyle(color: Colors.white54)),
          ),
        for (final k in keys)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: statusDot(_st(k), size: 12),
            title: Text(_friends[k] ?? k),
            subtitle: Text(_stText(k),
                style: TextStyle(color: statusColor(_st(k)), fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openProfile(k),
          ),
      ],
    ));
  }

  Widget _requestsCard() {
    final keys = _reqs.keys.toList()..sort();
    if (keys.isEmpty) return const SizedBox.shrink();
    return _glassCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Pedidos de amizade (${keys.length})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        for (final k in keys)
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => _openProfile(k),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                  child: Text(_reqs[k] ?? k),
                ),
              ),
              IconButton(
                tooltip: 'Aceitar',
                icon: const Icon(Icons.check_circle, color: Colors.greenAccent),
                onPressed: () async {
                  try {
                    await Account.accept(k, _reqs[k] ?? k);
                  } catch (_) {}
                  _loadSocial();
                },
              ),
              IconButton(
                tooltip: 'Recusar',
                icon: const Icon(Icons.cancel, color: Colors.redAccent),
                onPressed: () async {
                  try {
                    await Account.decline(k);
                  } catch (_) {}
                  _loadSocial();
                },
              ),
            ],
          ),
      ],
    ));
  }

  Widget _searchCard() {
    return _glassCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Buscar jogadores',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _find,
                autocorrect: false,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Nome do jogador',
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward, color: Colors.cyanAccent),
              onPressed: _search,
            ),
          ],
        ),
        for (final k in _found)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text(k),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openProfile(k),
          ),
      ],
    ));
  }

  Widget _profile() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _editProfile(),
        _glassCard(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Meu progresso',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            _statRow('Pontos totais', fmtScore(Settings.points)),
            _statRow('Partidas jogadas', '${Settings.games}'),
            _statRow('Partidas online', '${Settings.ogames}'),
            _statRow('Vitórias online', '${Settings.owins}'),
            const Divider(),
            for (final m in GameMode.values)
              _statRow(
                m.title,
                _bests[m] == null
                    ? '—'
                    : (m.timeBased
                        ? fmtTime(_bests[m]!)
                        : '${fmtScore(_bests[m]!)} pts'),
              ),
          ],
        )),
        _requestsCard(),
        _friendsCard(),
        _searchCard(),
        FilledButton.icon(
          style: kBlueOutline,
          icon: const Icon(Icons.sync),
          label: const Text('Sincronizar progresso'),
          onPressed: _busy ? null : _syncNow,
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          style: kBlueOutline,
          icon: const Icon(Icons.logout),
          label: const Text('Sair da conta'),
          onPressed: () async {
            await Settings.logout();
            if (mounted) {
              setState(() {
                _msg = '';
                _friends = {};
                _reqs = {};
              });
            }
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text('Minha conta',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    if (Settings.loggedIn) _profile() else _loginForm(),
                    if (_msg.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(_msg,
                            textAlign: TextAlign.center,
                            style:
                                const TextStyle(color: Colors.orangeAccent)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Perfil de qualquer jogador (inclusive você), com pontos e botão de amizade.
class ProfileScreen extends StatefulWidget {
  final String userKey;

  const ProfileScreen({super.key, required this.userKey});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map? _acc;
  bool _loading = true;
  bool _busy = false;
  String _rel = 'none'; // me, friend, sent, received, none
  String _msg = '';
  Map _pres = const {};
  String _roomState = '';

  String get _pStatus => '${_pres['s'] ?? 'offline'}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final acc = await Account.fetch(widget.userKey);
      final me = Settings.loggedIn ? Account.key(Settings.username) : '';
      var rel = 'none';
      if (acc != null && me.isNotEmpty) {
        if (widget.userKey == me) {
          rel = 'me';
        } else {
          final myAcc = await Account.fetch(me);
          final fr = myAcc?['friends'];
          final rq = myAcc?['requests'];
          final theirs = acc['requests'];
          if (fr is Map && fr.containsKey(widget.userKey)) {
            rel = 'friend';
          } else if (rq is Map && rq.containsKey(widget.userKey)) {
            rel = 'received';
          } else if (theirs is Map && theirs.containsKey(me)) {
            rel = 'sent';
          }
        }
      }
      var pres = <dynamic, dynamic>{};
      var roomState = '';
      try {
        if (acc != null && rel != 'me') {
          pres = await Presence.infoOf(widget.userKey);
          if (pres['r'] != null) {
            final rr = await Net.get(kServer, 'rooms/${pres['r']}/state');
            roomState = '${rr ?? ''}';
          }
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _acc = acc;
        _rel = rel;
        _pres = pres;
        _roomState = roomState;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _msg = 'Não consegui carregar o perfil.';
        });
      }
    }
  }

  Future<void> _duel() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final code = await Rooms.create(
        name: 'Duelo de ${Settings.username}',
        priv: true,
        max: 2,
        duel: true,
        inviteKey: widget.userKey,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _msg = 'Desafio enviado! Aguarde na sala.';
      });
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => OnlineWaitScreen(code: code, host: true)),
      );
      if (mounted) setState(() => _msg = '');
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _msg = 'Não consegui enviar o desafio.';
        });
      }
    }
  }

  Future<void> _inviteMine() async {
    final code = Presence.room;
    if (code == null || _busy) return;
    setState(() => _busy = true);
    try {
      await Rooms.invite(
          code, Presence.roomName ?? code, false, widget.userKey);
      if (mounted) setState(() => _msg = 'Convite enviado!');
    } catch (_) {
      if (mounted) setState(() => _msg = 'Não consegui enviar o convite.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _goRoom() async {
    final code = '${_pres['r']}';
    if (_busy) return;
    if (_roomState == 'waiting') {
      setState(() => _busy = true);
      String? err;
      try {
        err = await Rooms.join(code);
      } catch (_) {
        err = 'Não consegui entrar na sala.';
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _msg = err ?? '';
      });
      if (err == null) {
        await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => OnlineWaitScreen(code: code, host: false)),
        );
        _load();
      }
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SpectatorScreen(code: code)),
      );
    }
  }

  Future<void> _do(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (_) {
      _msg = 'Não consegui concluir. Tente de novo.';
    }
    _busy = false;
    await _load();
  }

  Widget _actions() {
    final name = (_acc?['name'] as String?) ?? widget.userKey;
    if (!Settings.loggedIn) {
      return const Text('Entre na sua conta para adicionar amigos.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54));
    }
    switch (_rel) {
      case 'none':
        return FilledButton.icon(
          style: kBlueOutline,
          icon: const Icon(Icons.person_add),
          label: const Text('Adicionar amigo'),
          onPressed: _busy
              ? null
              : () => _do(() => Account.sendRequest(widget.userKey)),
        );
      case 'sent':
        return const FilledButton(
          onPressed: null,
          child: Text('Pedido enviado'),
        );
      case 'received':
        return Row(
          children: [
            Expanded(
              child: FilledButton(
                style: kBlueOutline,
                onPressed:
                    _busy ? null : () => _do(() => Account.accept(widget.userKey, name)),
                child: const Text('Aceitar pedido'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonal(
                style: kBlueOutline,
                onPressed:
                    _busy ? null : () => _do(() => Account.decline(widget.userKey)),
                child: const Text('Recusar'),
              ),
            ),
          ],
        );
      case 'friend':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Vocês são amigos ✓',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.greenAccent)),
            const SizedBox(height: 8),
            if (_pres['r'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  style: kBlueOutline,
                  icon: Icon(_roomState == 'waiting'
                      ? Icons.login
                      : Icons.visibility),
                  label: Text(_roomState == 'waiting'
                      ? 'Entrar na sala do amigo'
                      : 'Assistir partida'),
                  onPressed: _busy ? null : _goRoom,
                ),
              ),
            if (_pStatus != 'offline')
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  style: kBlueOutline,
                  icon: const Icon(Icons.sports_mma),
                  label: const Text('Desafiar para duelo 1x1'),
                  onPressed: _busy ? null : _duel,
                ),
              ),
            if (Presence.room != null && Presence.roomWaiting)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  style: kBlueOutline,
                  icon: const Icon(Icons.person_add),
                  label: const Text('Convidar para minha sala'),
                  onPressed: _busy ? null : _inviteMine,
                ),
              ),
            FilledButton.tonal(
              style: kBlueOutline,
              onPressed: _busy
                  ? null
                  : () => _do(() => Account.removeFriend(widget.userKey)),
              child: const Text('Remover amigo'),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _content() {
    final acc = _acc;
    if (acc == null) {
      return const Center(child: Text('Jogador não encontrado.'));
    }
    final prof = acc['profile'] is Map ? acc['profile'] as Map : const {};
    final prog = acc['progress'] is Map ? acc['progress'] as Map : const {};
    final best = prog['best'] is Map ? prog['best'] as Map : const {};
    final created = (acc['created'] as num?)?.toInt();
    String since = '';
    if (created != null) {
      final d = DateTime.fromMillisecondsSinceEpoch(created);
      since =
          '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    }
    final bio = (prof['bio'] as String?) ?? '';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _glassCard(Column(
          children: [
            _avatarCircle((prof['avatar'] as num?)?.toInt() ?? 0,
                size: 84, frame: (prof['frame'] as num?)?.toInt() ?? -1),
            const SizedBox(height: 8),
            Text((acc['name'] as String?) ?? widget.userKey,
                style: const TextStyle(
                    fontSize: 24, fontWeight: FontWeight.bold)),
            if (_rel != 'me')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    statusDot(_pStatus, size: 12),
                    const SizedBox(width: 6),
                    Text(
                      statusLabel(_pStatus) +
                          (_pres['r'] != null
                              ? (_roomState == 'waiting'
                                  ? ' · numa sala'
                                  : ' · em partida')
                              : ''),
                      style: TextStyle(
                          color: statusColor(_pStatus), fontSize: 14),
                    ),
                  ],
                ),
              ),
            if (bio.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(bio,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              ),
            if (since.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Membro desde $since',
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ),
          ],
        )),
        _glassCard(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _statRow('Pontos totais',
                fmtScore((prog['points'] as num?)?.toInt() ?? 0)),
            _statRow('Partidas jogadas',
                '${(prog['games'] as num?)?.toInt() ?? 0}'),
            _statRow('Partidas online',
                '${(prog['ogames'] as num?)?.toInt() ?? 0}'),
            _statRow('Vitórias online',
                '${(prog['owins'] as num?)?.toInt() ?? 0}'),
            const Divider(),
            for (final m in GameMode.values)
              if (best[m.name] is num)
                _statRow(
                  m.title,
                  m.timeBased
                      ? fmtTime((best[m.name] as num).toInt())
                      : '${fmtScore((best[m.name] as num).toInt())} pts',
                ),
          ],
        )),
        if (_rel != 'me') _actions(),
        if (_msg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_msg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.orangeAccent)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text('Perfil',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _content(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PubRoom {
  final String code;
  final String name;
  final String host;
  final int count;
  final int max;
  final double speed;
  final bool priv;
  final int av;
  final bool friend;
  final String kind;
  final String state;

  const _PubRoom({
    required this.code,
    required this.name,
    required this.host,
    required this.count,
    required this.max,
    required this.speed,
    required this.priv,
    required this.av,
    required this.friend,
    required this.kind,
    required this.state,
  });

  bool get playing => state == 'playing';
}

class OnlineLobbyScreen extends StatefulWidget {
  const OnlineLobbyScreen({super.key});

  @override
  State<OnlineLobbyScreen> createState() => _OnlineLobbyScreenState();
}

class _OnlineLobbyScreenState extends State<OnlineLobbyScreen> {
  final TextEditingController _roomName = TextEditingController();
  final TextEditingController _roomPass = TextEditingController();
  final TextEditingController _search = TextEditingController();
  final ValueNotifier<double> _speed = ValueNotifier<double>(1.0);
  bool _private = false;
  bool _busy = false;
  bool _loadingList = false;
  String _kind = 'battle';
  String _msg = '';
  List<_PubRoom> _rooms = [];
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _refreshList();
    _refresh = Timer.periodic(const Duration(seconds: 6), (_) => _refreshList());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _roomName.dispose();
    _roomPass.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _refreshList() async {
    if (_loadingList || !mounted) return;
    _loadingList = true;
    try {
      final now = await Net.serverNow(kServer);
      final all = await Net.get(kServer, 'rooms/_public');
      Set<String> friends = <String>{};
      try {
        friends = await Account.friendKeys();
      } catch (_) {}
      final out = <_PubRoom>[];
      if (all is Map) {
        all.forEach((k, v) {
          if (v is! Map) return;
          final t = (v['t'] as num?)?.toInt() ?? 0;
          final count = (v['count'] as num?)?.toInt() ?? 0;
          final mx = (v['max'] as num?)?.toInt() ?? kMaxPlayers;
          final state = '${v['state'] ?? 'waiting'}';
          final kind = '${v['kind'] ?? 'battle'}';
          if (now - t > 40000) return;
          if (v['duel'] == true) return;
          if (state == 'waiting' && (count >= mx || kind == 'ranked')) return;
          final host = '${v['host'] ?? '?'}';
          out.add(_PubRoom(
            code: '$k',
            name: '${v['name'] ?? k}',
            host: host,
            count: count,
            max: mx,
            speed: (v['speed'] as num?)?.toDouble() ?? 1.0,
            priv: v['private'] == true,
            av: (v['av'] as num?)?.toInt() ?? 0,
            friend: friends.contains(Account.key(host)),
            kind: kind,
            state: state,
          ));
        });
      }
      out.sort((a, b) {
        if (a.friend != b.friend) return a.friend ? -1 : 1;
        if (a.playing != b.playing) return a.playing ? 1 : -1;
        return b.count.compareTo(a.count);
      });
      if (mounted) setState(() => _rooms = out);
    } catch (_) {}
    _loadingList = false;
  }

  Future<void> _create() async {
    if (_busy) return;
    if (!Settings.loggedIn) {
      setState(() => _msg = 'Entre na sua conta para criar uma sala.');
      return;
    }
    final pw = _roomPass.text;
    if (_private && pw.length < 4) {
      setState(() =>
          _msg = 'A senha da sala precisa ter pelo menos 4 caracteres.');
      return;
    }
    setState(() {
      _busy = true;
      _msg = 'Criando sala...';
    });
    try {
      final typed = _roomName.text.trim();
      final name = typed.isEmpty ? 'Sala de ${Settings.username}' : typed;
      final code = await Rooms.create(
        name: name,
        priv: _private,
        pw: pw,
        speed: _speed.value,
        kind: _kind,
      );
      if (!mounted) return;
      setState(() => _msg = '');
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OnlineWaitScreen(code: code, host: true),
        ),
      );
      _refreshList();
    } catch (_) {
      if (mounted) setState(() => _msg = 'Não consegui conectar ao servidor.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _ranked() async {
    if (_busy) return;
    if (!Settings.loggedIn) {
      setState(() => _msg = 'Entre na sua conta para jogar ranqueada.');
      return;
    }
    setState(() {
      _busy = true;
      _msg = 'Procurando partida ranqueada...';
    });
    try {
      final (code, host) = await Rooms.quickMatch();
      if (!mounted) return;
      setState(() => _msg = '');
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OnlineWaitScreen(code: code, host: host),
        ),
      );
      _refreshList();
    } on RankedBlocked catch (e) {
      if (mounted) setState(() => _msg = e.message);
    } catch (_) {
      if (mounted) setState(() => _msg = 'Não consegui conectar ao servidor.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _tapRoom(_PubRoom r) async {
    if (!r.priv || r.friend) {
      _enter(r.code, watch: r.playing);
      return;
    }
    final ctl = TextEditingController();
    final pw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Sala "${r.name}"'),
        content: TextField(
          controller: ctl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Senha da sala'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: kBlueOutline,
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: Text(r.playing ? 'Assistir' : 'Entrar'),
          ),
        ],
      ),
    );
    if (pw != null && pw.isNotEmpty && mounted) {
      _enter(r.code, pw: pw, watch: r.playing);
    }
  }

  Future<void> _enter(String code,
      {String pw = '', bool watch = false}) async {
    if (_busy) return;
    if (!Settings.loggedIn) {
      setState(() => _msg = 'Entre na sua conta para jogar online.');
      return;
    }
    if (watch) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SpectatorScreen(code: code, pw: pw)),
      );
      _refreshList();
      return;
    }
    setState(() {
      _busy = true;
      _msg = 'Entrando na sala...';
    });
    try {
      final err = await Rooms.join(code, pw: pw);
      if (err != null) {
        if (mounted) setState(() => _msg = err);
      } else {
        if (!mounted) return;
        setState(() => _msg = '');
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OnlineWaitScreen(code: code, host: false),
          ),
        );
        _refreshList();
      }
    } catch (_) {
      if (mounted) setState(() => _msg = 'Não consegui conectar ao servidor.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _statusMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Meu status',
      onSelected: (s) {
        Presence.pref = s;
        Presence.setStatus(s);
        setState(() {});
      },
      itemBuilder: (_) => [
        for (final s in const ['online', 'away', 'offline'])
          PopupMenuItem<String>(
            value: s,
            child: Row(
              children: [
                statusDot(s),
                const SizedBox(width: 8),
                Text(s == 'offline' ? 'Invisível' : statusLabel(s)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            statusDot(Presence.status),
            const SizedBox(width: 5),
            Text(statusLabel(Presence.status),
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const Icon(Icons.arrow_drop_down, color: Colors.white54, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _accountCard() {
    if (!Settings.loggedIn) {
      return _glassCard(Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Entre na sua conta para jogar online.',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 10),
          FilledButton.icon(
            style: kBlueOutline,
            icon: const Icon(Icons.account_circle),
            label: const Text('Entrar / Criar conta'),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AccountScreen()),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ));
    }
    return _glassCard(Row(
      children: [
        _avatarCircle(Settings.avatar, frame: Settings.frame),
        const SizedBox(width: 10),
        Expanded(
          child: Text(Settings.username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        _statusMenu(),
        FilledButton.tonal(
          style: kBlueOutline,
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AccountScreen()),
            );
            if (mounted) setState(() {});
          },
          child: const Text('Perfil'),
        ),
      ],
    ));
  }

  Widget _rankedCard() {
    return _glassCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.military_tech, color: Colors.amber),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Partida ranqueada',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            Text('${Elo.tierFor(Settings.rating).name} · Rating ${Settings.rating}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.amber)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 10),
          child: Text(
              'Até $kRankedMax jogadores, começa sozinha. ${Settings.rw} vitórias em ${Settings.rg} partidas. '
              'A temporada reinicia em ${Season.daysLeft} dia${Season.daysLeft == 1 ? '' : 's'}.',
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ),
        FilledButton.icon(
          style: kBlueOutline,
          icon: const Icon(Icons.bolt),
          label: const Text('Procurar partida'),
          onPressed: _busy ? null : _ranked,
        ),
        TextButton.icon(
          icon: const Icon(Icons.emoji_events, color: Colors.amber),
          label: const Text('Placar mundial'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
          ),
        ),
      ],
    ));
  }

  Widget _searchCard() {
    final q = _search.text.trim().toLowerCase();
    final list = _rooms
        .where((r) =>
            q.isEmpty ||
            r.name.toLowerCase().contains(q) ||
            r.host.toLowerCase().contains(q))
        .toList();
    return _glassCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Salas abertas e em jogo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            IconButton(
              tooltip: 'Atualizar',
              icon: const Icon(Icons.refresh, color: Colors.cyanAccent),
              onPressed: _refreshList,
            ),
          ],
        ),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Buscar por nome da sala ou do anfitrião',
          ),
        ),
        const SizedBox(height: 8),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nenhuma sala agora. Crie a sua!',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54)),
          ),
        for (final r in list)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _avatarCircle(r.av, size: 38),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (r.priv)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(Icons.lock,
                                  size: 14, color: Colors.amber),
                            ),
                          Expanded(
                            child: Text(r.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                      Text(
                          '${kindLabel(r.kind)} · ${r.friend ? '★ ' : ''}${r.host} · ${speedName(r.speed)} · ${r.count}/${r.max}${r.playing ? ' · em jogo' : ''}',
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 12)),
                    ],
                  ),
                ),
                FilledButton.tonal(
                  style: kBlueOutline,
                  onPressed: _busy ? null : () => _tapRoom(r),
                  child: r.playing
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.visibility, size: 16),
                            SizedBox(width: 4),
                            Text('Assistir'),
                          ],
                        )
                      : const Text('Entrar'),
                ),
              ],
            ),
          ),
      ],
    ));
  }

  Widget _createCard() {
    var desc = '';
    for (final k in kOnlineKinds) {
      if (k.$1 == _kind) desc = k.$3;
    }
    return _glassCard(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Criar sala',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        TextField(
          controller: _roomName,
          maxLength: 20,
          decoration: const InputDecoration(labelText: 'Nome da sala'),
        ),
        const SizedBox(height: 4),
        const Text('Modo de jogo',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            for (final k in kOnlineKinds)
              ChoiceChip(
                label: Text(k.$2),
                selected: _kind == k.$1,
                onSelected: (_) => setState(() => _kind = k.$1),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 8),
          child: Text(desc,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            ChoiceChip(
              avatar: const Icon(Icons.public, size: 18),
              label: const Text('Aberta'),
              selected: !_private,
              onSelected: (_) => setState(() => _private = false),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.lock, size: 18),
              label: const Text('Com senha'),
              selected: _private,
              onSelected: (_) => setState(() => _private = true),
            ),
          ],
        ),
        if (_private)
          TextField(
            controller: _roomPass,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Senha da sala'),
          ),
        const SizedBox(height: 10),
        const Text('Velocidade da partida',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12)),
        SpeedChips(value: _speed),
        const SizedBox(height: 10),
        FilledButton.icon(
          style: kBlueOutline,
          icon: const Icon(Icons.add),
          label: Text('Criar sala (até $kMaxPlayers jogadores)'),
          onPressed: _busy ? null : _create,
        ),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text('Multiplayer online',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _accountCard(),
                    if (_msg.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(_msg,
                            textAlign: TextAlign.center,
                            style:
                                const TextStyle(color: Colors.orangeAccent)),
                      ),
                    _rankedCard(),
                    _searchCard(),
                    _createCard(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Map<String, String> _parsePlayers(dynamic players) {
  final names = <String, String>{};
  if (players is Map) {
    players.forEach((k, v) {
      final nm = v is Map ? v['name'] : null;
      names['$k'] = nm is String ? nm : '$k';
    });
  }
  return names;
}

/// Lista de amigos com status para convidar para uma sala.
class _InviteSheet extends StatefulWidget {
  final String code;
  final String roomName;

  const _InviteSheet({required this.code, required this.roomName});

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  Map<String, String> _friends = {};
  Map<String, Map> _info = {};
  final Set<String> _sent = {};
  bool _loading = true;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final acc = await Account.fetch(Account.key(Settings.username));
      final fr = pickNames(acc?['friends']);
      Map<String, Map> info = {};
      try {
        info = await Presence.info();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _friends = fr;
        _info = info;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = 'Não consegui carregar seus amigos.';
        });
      }
    }
  }

  String _st(String k) => '${_info[k]?['s'] ?? 'offline'}';

  int _rank(String s) => s == 'online' ? 0 : (s == 'away' ? 1 : 2);

  Future<void> _invite(String k) async {
    try {
      await Rooms.invite(widget.code, widget.roomName, false, k);
      if (mounted) setState(() => _sent.add(k));
    } catch (_) {
      if (mounted) setState(() => _err = 'Não consegui enviar o convite.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = _friends.keys.toList()
      ..sort((a, b) {
        final c = _rank(_st(a)).compareTo(_rank(_st(b)));
        return c != 0 ? c : a.compareTo(b);
      });
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Convidar amigos',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (keys.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Você ainda não tem amigos para convidar.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54)),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final k in keys)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: statusDot(_st(k), size: 12),
                        title: Text(_friends[k] ?? k),
                        subtitle: Text(statusLabel(_st(k)),
                            style: TextStyle(
                                color: statusColor(_st(k)), fontSize: 12)),
                        trailing: _sent.contains(k)
                            ? const Text('Enviado ✓',
                                style: TextStyle(color: Colors.greenAccent))
                            : FilledButton.tonal(
                                style: kBlueOutline,
                                onPressed: () => _invite(k),
                                child: const Text('Convidar'),
                              ),
                      ),
                  ],
                ),
              ),
            if (_err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_err,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.orangeAccent)),
              ),
          ],
        ),
      ),
    );
  }
}

class OnlineWaitScreen extends StatefulWidget {
  final String code;
  final bool host;
  final int afterRound;

  const OnlineWaitScreen({
    super.key,
    required this.code,
    required this.host,
    this.afterRound = -1,
  });

  @override
  State<OnlineWaitScreen> createState() => _OnlineWaitScreenState();
}

class _OnlineWaitScreenState extends State<OnlineWaitScreen> {
  Timer? _poll;
  Timer? _count;
  bool _busy = false;
  bool _started = false;
  bool _marked = false;
  bool _missed = false;
  int _n = 0;
  String _msg = '';
  Map<String, String> _names = {};
  Set<String> _ready = {};
  List<String> _roster = [];
  Map<String, int> _ratings = {};
  int _seed = 0;
  int _round = 0;
  double _speed = 1.0;
  String _roomName = '';
  String _kind = 'battle';
  int _maxP = kMaxPlayers;
  bool _isPrivate = false;
  bool _duel = false;
  int _lastCount = -1;
  int _beat = 0;
  DateTime _since = DateTime.now();

  String get _myKey => Settings.username.toLowerCase();

  bool get _ranked => _kind == 'ranked';

  @override
  void initState() {
    super.initState();
    Presence.room = widget.code;
    Presence.roomWaiting = true;
    if (widget.host && widget.afterRound >= 0) {
      _resetRoom();
    } else {
      _check();
    }
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _count?.cancel();
    if (!_started) {
      if (Presence.room == widget.code) {
        Presence.room = null;
        Presence.roomName = null;
        Presence.roomWaiting = false;
      }
      if (widget.host) {
        Net.delete(kServer, 'rooms/${widget.code}').catchError((_) {});
        Net.delete(kServer, 'rooms/_public/${widget.code}')
            .catchError((_) {});
      } else {
        Net.delete(kServer, 'rooms/${widget.code}/players/$_myKey')
            .catchError((_) {});
      }
    }
    super.dispose();
  }

  /// Revanche: o anfitrião zera a sala com uma nova semente.
  Future<void> _resetRoom() async {
    _busy = true;
    try {
      await Net.delete(kServer, 'rooms/${widget.code}/s');
      await Net.patch(kServer, 'rooms/${widget.code}', {
        'state': 'waiting',
        'round': widget.afterRound + 1,
        'seed': Random().nextInt(1 << 30),
        'roster': null,
      });
    } catch (_) {
      if (mounted) setState(() => _msg = 'Não consegui reiniciar a sala.');
    }
    _busy = false;
  }

  /// Avisa a sala que este jogador está de volta e pronto para a próxima.
  void _markReady(int round) {
    if (_marked) return;
    _marked = true;
    final rd = widget.afterRound >= 0 ? widget.afterRound + 1 : round;
    Net.patch(kServer, 'rooms/${widget.code}/players/$_myKey', {'rd': rd})
        .catchError((_) {});
  }

  Set<String> _readyOf(dynamic players, int round) {
    final out = <String>{};
    if (players is Map) {
      players.forEach((k, v) {
        final rd = v is Map ? (v['rd'] as num?)?.toInt() : null;
        if (round == 0 || (rd != null && rd >= round)) out.add('$k');
      });
    }
    return out;
  }

  Future<void> _loadRatings(List<String> roster) async {
    if (!_ranked) return;
    try {
      _ratings = await Account.ratings(roster);
    } catch (_) {}
  }

  void _publish(Map r, int count) {
    if (!widget.host || _duel) return;
    Net.put(kServer, 'rooms/_public/${widget.code}', {
      'name': _roomName.isEmpty ? widget.code : _roomName,
      'host': Settings.username,
      'private': r['public'] == false,
      'av': Settings.avatar,
      'count': count,
      'max': _maxP,
      'kind': _kind,
      'speed': (r['speed'] as num?)?.toDouble() ?? 1.0,
      'state': 'waiting',
      't': {'.sv': 'timestamp'},
    }).catchError((_) {});
  }

  Future<void> _check() async {
    if (_busy || _started || !mounted) return;
    _busy = true;
    var wantStart = false;
    try {
      final r = await Net.get(kServer, 'rooms/${widget.code}');
      if (r is Map) {
        final names = _parsePlayers(r['players']);
        final round = (r['round'] as num?)?.toInt() ?? 0;
        _roomName = (r['name'] as String?) ?? '';
        _kind = (r['kind'] as String?) ?? 'battle';
        _maxP = (r['max'] as num?)?.toInt() ?? kMaxPlayers;
        _isPrivate = r['public'] == false;
        _duel = r['duel'] == true;
        Presence.roomName = _roomName;
        _markReady(round);
        final ready = _readyOf(r['players'], round);
        if (r['state'] == 'waiting') {
          final changed = names.length != _lastCount;
          if (changed) {
            _lastCount = names.length;
            _since = DateTime.now();
          }
          if (widget.host) {
            _beat++;
            if (changed || _beat % 8 == 1) {
              _publish(r, names.length);
            }
            if (_ranked && ready.length >= 2) {
              final secs = DateTime.now().difference(_since).inSeconds;
              if (ready.length >= _maxP || secs >= 12) {
                wantStart = true;
              } else {
                _msg = 'Começando em ${12 - secs}s…';
              }
            }
          }
        }
        if (r['state'] == 'playing' && round > widget.afterRound) {
          final roster = ((r['roster'] as String?) ?? '')
              .split(',')
              .where((e) => e.isNotEmpty)
              .toList();
          if (roster.contains(_myKey)) {
            _names = names;
            _roster = roster;
            _seed = (r['seed'] as num?)?.toInt() ?? 0;
            _round = round;
            _speed = (r['speed'] as num?)?.toDouble() ?? 1.0;
            await _loadRatings(roster);
            _startCountdown();
          } else if (mounted) {
            setState(() {
              _names = names;
              _missed = true;
              _msg = 'A partida começou sem você.';
            });
          }
        } else if (mounted) {
          setState(() {
            _names = names;
            _ready = ready;
            if (r['state'] == 'playing') {
              _msg = 'Aguardando nova partida…';
            } else if (!wantStart && !(_ranked && ready.length >= 2)) {
              _msg = '';
            }
          });
        }
      } else if (mounted) {
        setState(() => _msg = 'A sala foi encerrada.');
      }
    } catch (_) {
      if (mounted) setState(() => _msg = 'Sem conexão…');
    }
    _busy = false;
    if (wantStart) _hostStart();
  }

  Future<void> _hostStart() async {
    if (_busy) return;
    _busy = true;
    try {
      final r = await Net.get(kServer, 'rooms/${widget.code}');
      if (r is! Map) {
        if (mounted) setState(() => _msg = 'A sala foi encerrada.');
        return;
      }
      final round = (r['round'] as num?)?.toInt() ?? 0;
      final names = _parsePlayers(r['players']);
      final keys = _readyOf(r['players'], round).toList()..sort();
      if (!keys.contains(_myKey)) keys.add(_myKey);
      if (keys.length < 2) {
        if (mounted) setState(() => _msg = 'Precisa de pelo menos 2 jogadores na sala.');
        return;
      }
      keys.remove(_myKey);
      keys.insert(0, _myKey);
      await Net.patch(kServer, 'rooms/${widget.code}', {
        'state': 'playing',
        'roster': keys.join(','),
      });
      _names = names;
      _roster = keys;
      _seed = (r['seed'] as num?)?.toInt() ?? 0;
      _round = round;
      _speed = (r['speed'] as num?)?.toDouble() ?? 1.0;
      await _loadRatings(keys);
      Net.delete(kServer, 'rooms/_public/${widget.code}').catchError((_) {});
      _startCountdown();
    } catch (_) {
      if (mounted) setState(() => _msg = 'Não consegui iniciar. Tente de novo.');
    } finally {
      _busy = false;
    }
  }

  void _startCountdown() {
    if (_started || !mounted) return;
    _started = true;
    _poll?.cancel();
    setState(() => _n = 3);
    _count = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_n > 1) {
        setState(() => _n--);
      } else {
        t.cancel();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => GameScreen(
              mode: kindMode(_kind),
              theme: Settings.theme.value,
              session: OnlineSession(
                base: kServer,
                code: widget.code,
                host: widget.host,
                seed: _seed,
                myKey: _myKey,
                myName: Settings.username,
                roster: _roster,
                names: _names,
                round: _round,
                speed: _speed,
                kind: _kind,
                roomName: _roomName,
                priv: _isPrivate,
                maxP: _maxP,
                ratings: _ratings,
              ),
            ),
          ),
        );
      }
    });
  }

  void _invite() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF15152B),
      isScrollControlled: true,
      builder: (_) => _InviteSheet(
          code: widget.code,
          roomName: _roomName.isEmpty ? widget.code : _roomName),
    );
  }

  Widget _playerTile(String k) {
    final back = widget.afterRound >= 0;
    final ok = _ready.contains(k) || !back;
    return ListTile(
      dense: true,
      leading: Icon(
        k == _myKey ? Icons.person : Icons.person_outline,
        color: Colors.cyanAccent,
      ),
      title: Text(_names[k] ?? k),
      subtitle: back
          ? Text(ok ? 'Na sala' : 'Voltando para a sala…',
              style: TextStyle(
                  fontSize: 12,
                  color: ok ? Colors.greenAccent : Colors.white54))
          : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ProfileScreen(userKey: k)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keys = _names.keys.toList()..sort();
    final readyCount =
        widget.afterRound >= 0 ? _ready.length : keys.length;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Expanded(
                child: _n > 0
                    ? Center(
                        child: Text('$_n',
                            style: const TextStyle(
                                fontSize: 120, fontWeight: FontWeight.w900)),
                      )
                    : Column(
                        children: [
                          if (_ranked) ...[
                            const Icon(Icons.military_tech,
                                color: Colors.amber, size: 48),
                            const Text('Partida ranqueada',
                                style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold)),
                            Text('Rating ${Settings.rating}',
                                style: const TextStyle(color: Colors.amber)),
                          ] else ...[
                            const Text('Código da sala',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 16)),
                            Text(widget.code,
                                style: const TextStyle(
                                    fontSize: 64,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 10)),
                            if (_roomName.isNotEmpty)
                              Text(_roomName + (_isPrivate ? ' 🔒' : ''),
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 18)),
                            Text(_duel ? 'Duelo 1x1' : kindLabel(_kind),
                                style: const TextStyle(
                                    color: Colors.cyanAccent, fontSize: 14)),
                          ],
                          Text('Jogadores ${keys.length}/$_maxP',
                              style: const TextStyle(color: Colors.white70)),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ListView(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              children: [
                                for (final k in keys) _playerTile(k),
                              ],
                            ),
                          ),
                          if (_msg.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(_msg,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Colors.orangeAccent)),
                            ),
                          if (_missed)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: FilledButton.icon(
                                style: kBlueOutline,
                                icon: const Icon(Icons.visibility),
                                label: const Text('Assistir a partida'),
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          SpectatorScreen(code: widget.code)),
                                ),
                              ),
                            ),
                          if (!_ranked && Settings.loggedIn)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.person_add),
                                label: const Text('Convidar amigo'),
                                onPressed: _invite,
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: _ranked
                                ? const Text(
                                    'Procurando adversários… a partida começa sozinha.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.white70))
                                : (widget.host
                                    ? FilledButton.icon(
                                        style: kBlueOutline,
                                        icon: const Icon(Icons.play_arrow),
                                        label: Text(readyCount < 2
                                            ? 'Aguardando jogadores…'
                                            : 'Iniciar partida ($readyCount)'),
                                        onPressed:
                                            readyCount < 2 ? null : _hostStart,
                                      )
                                    : const Text(
                                        'Aguardando o anfitrião iniciar…',
                                        style:
                                            TextStyle(color: Colors.white70))),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Assistir a uma partida online em andamento (somente leitura).
class SpectatorScreen extends StatefulWidget {
  final String code;
  final bool register;
  final String pw;

  const SpectatorScreen(
      {super.key, required this.code, this.register = true, this.pw = ''});

  @override
  State<SpectatorScreen> createState() => _SpectatorScreenState();
}

class _SpectatorScreenState extends State<SpectatorScreen> {
  Timer? _timer;
  bool _busy = false;
  bool _loading = true;
  String _error = '';
  String _state = '';
  final Map<String, String> _names = {};
  final Map<String, Map> _states = {};

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (widget.register) {
      try {
        final err =
            await Rooms.join(widget.code, pw: widget.pw, spectate: true);
        if (err != null) {
          if (mounted) setState(() { _error = err; _loading = false; });
          return;
        }
      } catch (_) {
        if (mounted) {
          setState(() { _error = 'Sem conexão com o servidor.'; _loading = false; });
        }
        return;
      }
    }
    await _poll();
    _timer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      final r = await Net.get(kServer, 'rooms/${widget.code}');
      if (!mounted) return;
      if (r is! Map) {
        setState(() { _error = 'A sala foi encerrada.'; _loading = false; });
        _timer?.cancel();
        return;
      }
      final players = r['players'];
      final s = r['s'];
      setState(() {
        _state = '${r['state'] ?? ''}';
        _names.clear();
        if (players is Map) {
          players.forEach((k, v) {
            _names['$k'] = (v is Map ? v['name'] as String? : null) ?? '$k';
          });
        }
        _states.clear();
        if (s is Map) {
          s.forEach((k, v) {
            if (v is Map) _states['$k'] = v;
          });
        }
        _loading = false;
        _error = '';
      });
    } catch (_) {
      // tenta de novo no próximo ciclo
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.register && Settings.loggedIn) {
      Net.delete(kServer,
              'rooms/${widget.code}/spectators/${Account.key(Settings.username)}')
          .catchError((_) {});
    }
    super.dispose();
  }

  Widget _tile(String key) {
    final st = _states[key];
    final name = _names[key] ?? key;
    final over = st?['over'] == true;
    final fin = st?['fin'] == true;
    final score = (st?['score'] as num?)?.toInt() ?? 0;
    final lines = (st?['lines'] as num?)?.toInt() ?? 0;
    final board = (st?['b'] as String?) ?? '';
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: over ? Colors.redAccent : Colors.white12),
      ),
      child: Column(
        children: [
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Expanded(
            child: AspectRatio(
              aspectRatio: kCols / kRows,
              child: CustomPaint(painter: MiniBoardPainter(board, dim: over)),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            over ? 'Eliminado' : (fin ? 'Terminou' : '${fmtScore(score)} pts · $lines linhas'),
            style: TextStyle(
                fontSize: 12,
                color: over ? Colors.redAccent : Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.orangeAccent)),
        ),
      );
    }
    final keys = <String>{..._names.keys, ..._states.keys}.toList()..sort();
    if (keys.isEmpty || _state == 'waiting') {
      return const Center(
        child: Text('Aguardando a partida começar…',
            style: TextStyle(color: Colors.white70)),
      );
    }
    return GridView.count(
      padding: const EdgeInsets.all(12),
      crossAxisCount: keys.length <= 2 ? 2 : 3,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: keys.length <= 2 ? 0.62 : 0.5,
      children: [for (final k in keys) _tile(k)],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Text('Assistindo · ${widget.code}',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Placar mundial: ranking de jogadores (rating, pontos, vitórias e recordes).
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  bool _loading = true;
  String _error = '';
  final List<MapEntry<String, Map>> _all = [];
  // 'rating', 'points', 'owins' ou o nome de um GameMode
  String _sort = 'rating';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = ''; });
    try {
      await Season.refresh();
      final r = await Net.get(kServer, 'rooms/_rank');
      _all.clear();
      if (r is Map) {
        r.forEach((k, v) {
          if (v is Map) _all.add(MapEntry('$k', AntiCheat.cleanEntry('$k', v)));
        });
      }
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Não foi possível carregar o placar.';
        });
      }
    }
  }

  GameMode? get _mode {
    for (final m in GameMode.values) {
      if (m.name == _sort) return m;
    }
    return null;
  }

  int? _value(Map e) {
    final m = _mode;
    if (m != null) {
      final b = e['best'];
      final v = b is Map ? b[m.name] : null;
      return v is num ? v.toInt() : null;
    }
    final v = e[_sort];
    return v is num ? v.toInt() : 0;
  }

  String _fmt(int v) {
    final m = _mode;
    if (m != null) return m.timeBased ? fmtTime(v) : '${fmtScore(v)} pts';
    if (_sort == 'rating') return '$v';
    if (_sort == 'owins') return '$v vit.';
    return '${fmtScore(v)} pts';
  }

  List<MapEntry<String, Map>> _sorted() {
    final m = _mode;
    final list = _all.where((e) => _value(e.value) != null).toList();
    list.sort((a, b) {
      final x = _value(a.value)!;
      final y = _value(b.value)!;
      return (m != null && m.timeBased) ? x.compareTo(y) : y.compareTo(x);
    });
    return list.take(100).toList();
  }

  Widget _chips() {
    final items = <MapEntry<String, String>>[
      const MapEntry('rating', 'Rating'),
      const MapEntry('points', 'Pontos'),
      const MapEntry('owins', 'Vitórias'),
      for (final m in GameMode.values) MapEntry(m.name, m.title),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(it.value),
                selected: _sort == it.key,
                onSelected: (_) => setState(() => _sort = it.key),
              ),
            ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error,
                style: const TextStyle(color: Colors.orangeAccent)),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('Tentar de novo')),
          ],
        ),
      );
    }
    final list = _sorted();
    if (list.isEmpty) {
      return const Center(
        child: Text('Ninguém no ranking ainda.',
            style: TextStyle(color: Colors.white70)),
      );
    }
    final me = Settings.loggedIn ? Account.key(Settings.username) : '';
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: list.length,
        itemBuilder: (_, i) {
          final e = list[i];
          final mine = e.key == me;
          final medal = i == 0 ? '🥇' : (i == 1 ? '🥈' : (i == 2 ? '🥉' : '${i + 1}'));
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: mine ? Colors.blueAccent.withAlpha(50) : Colors.black38,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: mine ? Colors.blueAccent : Colors.white12),
            ),
            child: ListTile(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ProfileScreen(userKey: e.key)),
              ),
              leading: SizedBox(
                width: 84,
                child: Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: Text(medal,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 6),
                    _avatarCircle((e.value['av'] as num?)?.toInt() ?? 0,
                        size: 40,
                        frame: (e.value['fr'] as num?)?.toInt() ?? -1),
                  ],
                ),
              ),
              title: Text((e.value['name'] as String?) ?? e.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Elo.nameStyleColor(
                          (e.value['nc'] as num?)?.toInt() ?? -1))),
              subtitle: Text(Elo.tierOfEntry(e.value).name,
                  style: TextStyle(
                      color: Elo.tierOfEntry(e.value).color, fontSize: 12)),
              trailing: Text(_fmt(_value(e.value)!),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Settings.theme.value.bg,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text('Placar mundial',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
              _chips(),
              const SizedBox(height: 6),
              Expanded(child: _list()),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== anticheat.dart (temporadas do ranked e anti-cheat) =====

/// Rating de quem acabou de entrar (e de todos no início de cada temporada).
const int kStartRating = 0;
const int kMaxRating = 5000;

/// Lançada quando o ranqueado está bloqueado para este jogador.
class RankedBlocked implements Exception {
  final String message;
  const RankedBlocked(this.message);

  @override
  String toString() => message;
}

/// Temporadas do ranked: todo mundo zera junto a cada 30 dias.
/// A conta usa a hora do SERVIDOR, então mexer no relógio do aparelho não adianta.
class Season {
  static const int days = 30;
  static const int _len = days * 24 * 60 * 60 * 1000;

  /// Início da 1ª temporada (UTC). Não mude depois de publicar o app.
  static final int epochMs = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;

  static int _offset = 0;
  static int _lastSync = 0;
  static bool synced = false;

  static int get nowMs => DateTime.now().millisecondsSinceEpoch + _offset;
  static int get current => nowMs < epochMs ? 0 : (nowMs - epochMs) ~/ _len;
  static int get endMs => epochMs + (current + 1) * _len;
  static int get daysLeft => max(1, ((endMs - nowMs) / 86400000).ceil());

  /// Sincroniza com o relógio do servidor (no máximo a cada 5 minutos).
  static Future<void> refresh({bool force = false}) async {
    final local = DateTime.now().millisecondsSinceEpoch;
    final age = local - _lastSync;
    if (!force && synced && age >= 0 && age < 300000) return;
    try {
      final srv = await Net.serverNow(kServer);
      _offset = srv - local;
      _lastSync = local;
      synced = true;
    } catch (_) {}
  }
}

/// Anti-cheat do lado do aparelho:
///  - assinatura (HMAC) dos dados do ranked, no aparelho e na nuvem;
///  - hora do servidor para temporadas e bloqueios;
///  - checagem de resultados impossíveis (peças/s, linhas, pontuação);
///  - limite de lixo aceito de cada rival;
///  - sair/cair/fechar uma ranqueada conta como derrota;
///  - infrações acumuladas bloqueiam o ranqueado por 7 dias.
/// Sem servidor próprio isso dificulta, mas não impede, quem desmonta o app.
class AntiCheat {
  /// Chave da assinatura. Para trocar sem mexer no código:
  /// flutter build apk --dart-define=AC_KEY=sua-chave-secreta
  static const String _secret = String.fromEnvironment('AC_KEY',
      defaultValue: 'empilha-anticheat-v1-troque-esta-chave');

  static String _mac(String payload) => Hmac(sha256, utf8.encode(_secret))
      .convert(utf8.encode(payload))
      .toString()
      .substring(0, 32);

  static String rankSig(
          String owner, int season, int rating, int rw, int rg, int pt) =>
      _mac('rank|$owner|$season|$rating|$rw|$rg|$pt');

  static String localRankSig() => rankSig('local', Settings.season,
      Settings.rating, Settings.rw, Settings.rg, Settings.peakTier);

  /// A entrada da nuvem (conta ou placar) tem assinatura válida para [owner]?
  static bool cloudRankValid(String owner, dynamic e) {
    if (e is! Map) return false;
    final Map m = e;
    final sig = m['rsig'];
    if (sig is! String) return false;
    int n(String k, int d) => (m[k] as num?)?.toInt() ?? d;
    return sig ==
        rankSig(owner, n('season', -1), n('rating', 0), n('rw', 0), n('rg', 0),
            n('pt', 0));
  }

  /// Entrada do placar com o ranked já validado: de temporada antiga ou sem
  /// assinatura válida vira rating 0.
  static Map<String, dynamic> cleanEntry(String key, Map e) {
    final m = Map<String, dynamic>.from(e);
    final valid = ((e['season'] as num?)?.toInt() ?? -1) == Season.current &&
        cloudRankValid(key, e);
    if (valid) {
      m['rating'] =
          ((e['rating'] as num?)?.toInt() ?? 0).clamp(0, kMaxRating).toInt();
    } else {
      m['rating'] = kStartRating;
      m['rw'] = 0;
      m['rg'] = 0;
    }
    return m;
  }

  static int entryRating(String key, dynamic e) =>
      e is Map ? (cleanEntry(key, e)['rating'] as int) : kStartRating;

  /// Confere se o resultado deste aparelho é humanamente possível.
  /// Retorna o motivo, ou null se está tudo certo.
  static String? checkGame(StackGame g, {bool versus = false}) {
    final secs = max(2.0, g.elapsedMs / 1000.0);
    final pieces = g.lockCount;
    if (pieces / secs > 12) return 'peças por segundo impossível';
    // Com lixo (survival, cheese, versus) uma peça pode limpar mais linhas.
    if (!versus &&
        g.mode != GameMode.cheese &&
        g.mode != GameMode.survival &&
        g.lines * kCols > pieces * 4) {
      return 'mais linhas do que as peças permitem';
    }
    if (g.score > (pieces + 1) * (60 + g.level * 3800)) {
      return 'pontuação acima do possível';
    }
    return null;
  }

  /// Maior ataque acumulado que um rival pode ter mandado: nunca passa das
  /// linhas que ele mesmo informa, nem de ~4 linhas por segundo de partida.
  static int maxAttack(int oppLines, int myElapsedMs) {
    final byTime = (myElapsedMs / 1000 * 4).ceil() + 10;
    return min(oppLines, byTime);
  }

  /// Registra (só para consulta) um rival suspeito. Não pune ninguém sozinho.
  static void report(OnlineSession s, String oppKey, String why) {
    Net.put(s.base, 'rooms/_flags/$oppKey/${s.code}_${s.round}_${s.myKey}', {
      'by': s.myKey,
      'why': why,
      'room': s.code,
      't': {'.sv': 'timestamp'},
    }).catchError((_) {});
  }

  // ---- bloqueio temporário do ranqueado

  static String? blockedMessage() {
    final left = Settings.acBanUntil - Season.nowMs;
    if (left <= 0) return null;
    final h = (left / 3600000).ceil();
    final when = h > 48 ? '${(h / 24).ceil()} dias' : '$h h';
    return 'Ranqueado bloqueado por atividade suspeita. Volte em $when.';
  }

  static Future<void> strike(String why) async {
    Settings.acStrikes++;
    if (Settings.acStrikes >= 3) {
      Settings.acStrikes = 0;
      Settings.acBanUntil = Season.nowMs + 7 * 24 * 3600 * 1000;
    }
    await Settings.saveRank();
    Account.sync();
  }

  // ---- anti-dodge: partida ranqueada abandonada conta como último lugar

  static Future<void> markRankedStart(OnlineSession s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'ac_pend',
        jsonEncode({
          'u': Settings.username,
          'o': [
            for (final k in s.roster)
              if (k != s.myKey) s.ratings[k] ?? kStartRating,
          ],
        }));
  }

  static Future<void> clearPending() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('ac_pend');
  }

  /// Se o app foi fechado no meio de uma ranqueada, aplica a derrota agora.
  static Future<void> settlePending() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('ac_pend');
    if (raw == null) return;
    await p.remove('ac_pend');
    try {
      final m = jsonDecode(raw);
      if (m is! Map || !Settings.loggedIn || m['u'] != Settings.username) {
        return;
      }
      final others = [for (final v in (m['o'] as List)) (v as num).toInt()];
      if (others.isEmpty) return;
      await Account.applyRankedRaw(others, others.length + 1);
    } catch (_) {}
  }

  /// Ao abrir o app: confere a temporada e pune partida ranqueada abandonada.
  static Future<void> startup() async {
    try {
      await Season.refresh(force: true);
      await Settings.ensureSeason();
      await settlePending();
      if (Settings.loggedIn) await Account.sync();
    } catch (_) {}
  }
}

// ===== elo.dart (elos, recompensas e personalização) =====

class EloTier {
  final String name;
  final int min;
  final Color color;
  final IconData icon;
  const EloTier(this.name, this.min, this.color, this.icon);
}

/// Elos baseados no rating das partidas ranqueadas. As recompensas ficam
/// liberadas pelo MELHOR elo já alcançado (cair de elo não tira nada).
class Elo {
  static const List<EloTier> tiers = [
    EloTier('Ferro', 0, Color(0xFF9E9E9E), Icons.shield_outlined),
    EloTier('Bronze', 60, Color(0xFFCD7F32), Icons.shield),
    EloTier('Prata', 150, Color(0xFFCFD8DC), Icons.workspace_premium),
    EloTier('Ouro', 280, Color(0xFFFFD54F), Icons.emoji_events),
    EloTier('Platina', 450, Color(0xFF4DD0E1), Icons.stars),
    EloTier('Diamante', 650, Color(0xFF64B5F6), Icons.diamond),
    EloTier('Mestre', 900, Color(0xFFBA68C8), Icons.local_fire_department),
    EloTier('Lenda', 1200, Color(0xFFFF5252), Icons.auto_awesome),
  ];

  /// Requisito de cada avatar (mesma ordem de Account.avatars):
  /// -1 = livre, -2 = recompensa do tutorial, 1..7 = índice do elo.
  static const List<int> avatarReq = [
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, //
    -2,
    1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
  ];

  static int indexFor(int rating) {
    var idx = 0;
    for (int i = 0; i < tiers.length; i++) {
      if (rating >= tiers[i].min) idx = i;
    }
    return idx;
  }

  static EloTier tierFor(int rating) => tiers[indexFor(rating)];

  /// Faixas da escala antiga (antes das temporadas): só para converter o
  /// melhor elo que o jogador já tinha salvo.
  static const List<int> _legacyMins = [0, 900, 1100, 1300, 1500, 1700, 1900, 2100];

  static int legacyIndexFor(int rating) {
    var idx = 0;
    for (int i = 0; i < _legacyMins.length; i++) {
      if (rating >= _legacyMins[i]) idx = i;
    }
    return idx;
  }

  static EloTier tierOfEntry(dynamic v) {
    final r = (v is Map ? (v['rating'] as num?)?.toInt() : null) ?? kStartRating;
    return tierFor(r);
  }

  static int get current => indexFor(Settings.rating);

  static int get peakIndex => max(Settings.peakTier, indexFor(Settings.rating));

  static EloTier? nextOf(int rating) {
    final i = indexFor(rating);
    return i + 1 < tiers.length ? tiers[i + 1] : null;
  }

  static int themeReq(BlockTheme t) {
    switch (t) {
      case BlockTheme.ouro:
        return 3;
      case BlockTheme.cristal:
        return 5;
      case BlockTheme.holo:
        return 7;
      default:
        return 0;
    }
  }

  static bool themeUnlocked(BlockTheme t) => peakIndex >= themeReq(t);

  static bool avatarUnlocked(int i) {
    if (i < 0 || i >= avatarReq.length) return true;
    final r = avatarReq[i];
    if (r == -1) return true;
    if (r == -2) return Settings.tutorialDone;
    return peakIndex >= r;
  }

  static bool frameUnlocked(int i) => peakIndex >= i;

  static bool nameUnlocked(int i) => i >= 1 && peakIndex >= i;

  static Color nameStyleColor(int nc) =>
      (nc >= 1 && nc < tiers.length) ? tiers[nc].color : Colors.white;

  static String needTier(int i) =>
      'Bloqueado: alcance o elo ${tiers[i].name} (${tiers[i].min} pts) nas partidas ranqueadas.';

  static String needAvatar(int i) {
    final r = (i >= 0 && i < avatarReq.length) ? avatarReq[i] : -1;
    if (r == -2) return 'Bloqueado: conclua o tutorial para liberar este avatar.';
    return needTier(r.clamp(0, tiers.length - 1).toInt());
  }

  static void showLocked(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Lista das recompensas liberadas ao chegar em cada elo.
  static List<String> perks(int i) {
    final out = <String>['Moldura ${tiers[i].name}'];
    if (i >= 1) out.add('Cor de nome ${tiers[i].name}');
    final av = <String>[];
    for (int a = 0; a < avatarReq.length && a < Account.avatars.length; a++) {
      if (avatarReq[a] == i) av.add(Account.avatars[a]);
    }
    if (av.isNotEmpty) out.add('Avatares ${av.join(' ')}');
    if (i > 0) {
      for (final t in BlockTheme.values) {
        if (themeReq(t) == i) out.add('Textura ${t.label}');
      }
    }
    return out;
  }

  /// Volta para o padrão qualquer item equipado que esteja bloqueado.
  static void sanitize() {
    if (!themeUnlocked(Settings.theme.value)) {
      Settings.theme.value = BlockTheme.neon;
      Storage.saveTheme(BlockTheme.neon);
    }
    if (!avatarUnlocked(Settings.avatar)) Settings.avatar = 0;
    if (Settings.frame >= 0 && !frameUnlocked(Settings.frame)) {
      Settings.frame = -1;
    }
    if (Settings.nameColor >= 0 && !nameUnlocked(Settings.nameColor)) {
      Settings.nameColor = -1;
    }
  }
}

class EloBadge extends StatelessWidget {
  final EloTier tier;
  final bool big;
  const EloBadge({super.key, required this.tier, this.big = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: big ? 12 : 8, vertical: big ? 6 : 3),
      decoration: BoxDecoration(
        color: tier.color.withAlpha(40),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tier.color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(tier.icon, size: big ? 20 : 14, color: tier.color),
          const SizedBox(width: 4),
          Text(tier.name,
              style: TextStyle(
                  color: tier.color,
                  fontWeight: FontWeight.bold,
                  fontSize: big ? 16 : 12)),
        ],
      ),
    );
  }
}

class EloScreen extends StatefulWidget {
  const EloScreen({super.key});

  @override
  State<EloScreen> createState() => _EloScreenState();
}

class _EloScreenState extends State<EloScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: Settings.theme.value.bg,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Text('Elos e recompensas',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
                const TabBar(
                  indicatorColor: Colors.cyanAccent,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white54,
                  tabs: [Tab(text: 'Elos'), Tab(text: 'Personalizar')],
                ),
                Expanded(
                  child: TabBarView(children: [_tiersTab(), _customTab()]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(Widget child) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.black38,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: child,
      );

  Widget _sec(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6),
        child: Text(t,
            style: const TextStyle(
                color: Colors.white54, fontSize: 12, letterSpacing: 1)),
      );

  // ---------------------------------------------------------------- Elos

  Widget _tiersTab() {
    final rating = Settings.rating;
    final cur = Elo.current;
    final peak = Elo.peakIndex;
    final tier = Elo.tiers[cur];
    final next = Elo.nextOf(rating);
    final double prog = next == null
        ? 1.0
        : ((rating - tier.min) / (next.min - tier.min))
            .clamp(0.0, 1.0)
            .toDouble();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _panel(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(tier.icon, color: tier.color, size: 46),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Seu elo',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 12)),
                      Text(tier.name,
                          style: TextStyle(
                              color: tier.color,
                              fontSize: 26,
                              fontWeight: FontWeight.w900)),
                      Text('Rating $rating',
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: prog,
                minHeight: 10,
                backgroundColor: Colors.white12,
                color: tier.color,
              ),
            ),
            const SizedBox(height: 6),
            Text(
                next == null
                    ? 'Você está no elo máximo!'
                    : 'Faltam ${next.min - rating} pts para ${next.name}',
                style: const TextStyle(color: Colors.white70)),
            if (!Settings.loggedIn)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                    'Entre na sua conta e jogue "Ranqueada" no Multiplayer online para subir de elo.',
                    style: TextStyle(color: Colors.amber, fontSize: 12)),
              ),
            if (peak > cur)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    'Melhor elo alcançado: ${Elo.tiers[peak].name}. Suas recompensas continuam liberadas.',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
          ],
        )),
        _panel(Text(
          'Como subir: vença partidas ranqueadas (Multiplayer online). '
          'Você começa com $kStartRating pts e ganha ou perde pontos conforme sua '
          'colocação e o rating dos adversários. Cada elo libera texturas, '
          'avatares, molduras e cores de nome na aba Personalizar.\n\n'
          'Temporada ${Season.current + 1}: os pontos voltam a $kStartRating a cada '
          '${Season.days} dias (faltam ${Season.daysLeft} '
          'dia${Season.daysLeft == 1 ? '' : 's'}). O melhor elo que você já '
          'alcançou, e tudo que ele liberou (inclusive as texturas), fica '
          'com você para sempre.',
          style: const TextStyle(color: Colors.white70, height: 1.4),
        )),
        for (int i = 0; i < Elo.tiers.length; i++) _tierCard(i),
      ],
    );
  }

  Widget _tierCard(int i) {
    final t = Elo.tiers[i];
    final unlocked = Elo.peakIndex >= i;
    final isCur = Elo.current == i;
    final range = i + 1 < Elo.tiers.length
        ? '${t.min} – ${Elo.tiers[i + 1].min - 1}'
        : '${t.min}+';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isCur ? t.color.withAlpha(30) : Colors.black38,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: isCur ? t.color : Colors.white12, width: isCur ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(t.icon, color: unlocked ? t.color : Colors.white24, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name,
                        style: TextStyle(
                            color: unlocked ? t.color : Colors.white54,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    Text('$range pts',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              if (isCur)
                Text('ATUAL',
                    style: TextStyle(
                        color: t.color,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1))
              else if (unlocked)
                const Icon(Icons.check_circle, color: Colors.greenAccent)
              else
                const Icon(Icons.lock, color: Colors.white38),
            ],
          ),
          const SizedBox(height: 8),
          const Text('RECOMPENSAS',
              style: TextStyle(
                  color: Colors.white54, fontSize: 11, letterSpacing: 1)),
          const SizedBox(height: 4),
          for (final p in Elo.perks(i))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Icon(unlocked ? Icons.check : Icons.lock_outline,
                      size: 14,
                      color: unlocked ? Colors.greenAccent : Colors.white38),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(p,
                        style: TextStyle(
                            color: unlocked ? Colors.white : Colors.white54)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------- Personalizar

  Widget _customTab() {
    final name = Settings.loggedIn ? Settings.username : 'Jogador';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _panel(Row(
          children: [
            _avatarCircle(Settings.avatar, size: 64, frame: Settings.frame),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Elo.nameStyleColor(Settings.nameColor))),
                  const SizedBox(height: 4),
                  EloBadge(tier: Elo.tiers[Elo.current]),
                ],
              ),
            ),
          ],
        )),
        _sec('TEXTURA DAS PEÇAS'),
        _panel(SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [for (final t in BlockTheme.values) _textureItem(t)],
          ),
        )),
        _sec('AVATAR'),
        _panel(Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (int i = 0; i < Account.avatars.length; i++) _avatarItem(i),
          ],
        )),
        _sec('MOLDURA DO AVATAR'),
        _panel(Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _frameItem(-1),
            for (int i = 0; i < Elo.tiers.length; i++) _frameItem(i),
          ],
        )),
        _sec('COR DO NOME'),
        _panel(Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _nameItem(-1),
            for (int i = 1; i < Elo.tiers.length; i++) _nameItem(i),
          ],
        )),
      ],
    );
  }

  void _saveProfileCloud() {
    Settings.saveProfileLocal();
    Settings.saveCosmetics();
    Account.saveProfile().catchError((_) {});
  }

  Widget _textureItem(BlockTheme t) {
    final selected = t == Settings.theme.value;
    final locked = !Elo.themeUnlocked(t);
    return GestureDetector(
      onTap: () {
        if (locked) {
          Elo.showLocked(context, Elo.needTier(Elo.themeReq(t)));
          return;
        }
        setState(() => Settings.theme.value = t);
        Storage.saveTheme(t);
      },
      child: Container(
        width: 62,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? Colors.cyanAccent : Colors.white12,
                  width: selected ? 2 : 1,
                ),
              ),
              child: SizedBox(
                width: 42,
                height: 42,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: locked ? 0.3 : 1,
                      child: CustomPaint(
                          size: const Size(42, 42),
                          painter: ThemeSamplePainter(t)),
                    ),
                    if (locked)
                      const Icon(Icons.lock, size: 18, color: Colors.white70),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(t.label,
                style: TextStyle(
                    color: selected ? Colors.white : Colors.white54,
                    fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _avatarItem(int i) {
    final selected = Settings.avatar == i;
    final unlocked = Elo.avatarUnlocked(i);
    return GestureDetector(
      onTap: () {
        if (!unlocked) {
          Elo.showLocked(context, Elo.needAvatar(i));
          return;
        }
        setState(() => Settings.avatar = i);
        _saveProfileCloud();
      },
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white10,
          border: Border.all(
            color: selected ? Colors.cyanAccent : Colors.transparent,
            width: 2,
          ),
        ),
        child: unlocked
            ? Text(Account.avatars[i], style: const TextStyle(fontSize: 22))
            : Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: 0.3,
                    child: Text(Account.avatars[i],
                        style: const TextStyle(fontSize: 22)),
                  ),
                  const Icon(Icons.lock, size: 16, color: Colors.white70),
                ],
              ),
      ),
    );
  }

  Widget _frameItem(int i) {
    final selected = Settings.frame == i;
    final unlocked = i < 0 || Elo.frameUnlocked(i);
    return GestureDetector(
      onTap: () {
        if (!unlocked) {
          Elo.showLocked(context, Elo.needTier(i));
          return;
        }
        setState(() => Settings.frame = i);
        _saveProfileCloud();
      },
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? Colors.cyanAccent : Colors.transparent,
              width: 2),
        ),
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: unlocked ? 1 : 0.35,
                  child: _avatarCircle(Settings.avatar, size: 46, frame: i),
                ),
                if (!unlocked)
                  const Icon(Icons.lock, size: 16, color: Colors.white70),
              ],
            ),
            const SizedBox(height: 2),
            Text(i < 0 ? 'Nenhuma' : Elo.tiers[i].name,
                style: const TextStyle(color: Colors.white60, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _nameItem(int i) {
    final selected = Settings.nameColor == i;
    final unlocked = i < 0 || Elo.nameUnlocked(i);
    final color = i < 0 ? Colors.white : Elo.tiers[i].color;
    return GestureDetector(
      onTap: () {
        if (!unlocked) {
          Elo.showLocked(context, Elo.needTier(i));
          return;
        }
        setState(() => Settings.nameColor = i);
        _saveProfileCloud();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? Colors.cyanAccent : Colors.white12,
              width: selected ? 2 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!unlocked) ...[
              const Icon(Icons.lock, size: 14, color: Colors.white54),
              const SizedBox(width: 4),
            ],
            Text(i < 0 ? 'Padrão' : Elo.tiers[i].name,
                style: TextStyle(
                    color: unlocked ? color : color.withAlpha(110),
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

// ===== tutorial =====

/// Porta de entrada: novos jogadores precisam concluir o tutorial uma vez.
class _Gate extends StatefulWidget {
  const _Gate({super.key});

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  @override
  Widget build(BuildContext context) {
    if (Settings.tutorialDone) return const MenuScreen();
    return TutorialScreen(mandatory: true, onDone: () => setState(() {}));
  }
}

class _TutCount {
  int moves = 0;
  int rot = 0;
  int flips = 0;
  int soft = 0;
  int holds = 0;
}

class _TutGoal {
  final String Function(StackGame g, _TutCount c) hint;
  final bool Function(StackGame g, _TutCount c) done;
  _TutGoal(this.hint, this.done);
}

class _TutStep {
  final String title;
  final String text;
  final StackGame Function() build;
  final List<_TutGoal> goals;
  final bool gravity;
  final bool resetOnLock;
  final bool hlHold;
  final List<List<int>> targets;
  _TutStep({
    required this.title,
    required this.text,
    required this.build,
    this.goals = const [],
    this.gravity = false,
    this.resetOnLock = false,
    this.hlHold = false,
    this.targets = const [],
  });
}

StackGame _tutGame(int type, {Map<int, List<int>> gaps = const {}}) {
  final g = StackGame(GameMode.zen, seed: 11 + type);
  g.current = Piece.spawn(type);
  gaps.forEach((row, gap) {
    g.board[row] = List<int>.generate(kCols, (c) => gap.contains(c) ? 0 : 8);
  });
  return g;
}

int _tutMinCol(StackGame g) {
  var m = kCols;
  final s = g.current.shape;
  for (int r = 0; r < s.length; r++) {
    for (int c = 0; c < s.length; c++) {
      if (s[r][c] != 0) m = min(m, g.current.x + c);
    }
  }
  return m;
}

int _tutMaxCol(StackGame g) {
  var m = -1;
  final s = g.current.shape;
  for (int r = 0; r < s.length; r++) {
    for (int c = 0; c < s.length; c++) {
      if (s[r][c] != 0) m = max(m, g.current.x + c);
    }
  }
  return m;
}

List<_TutStep> _tutSteps() => [
      _TutStep(
        title: 'Bem-vindo ao Empilha!',
        text: 'Encaixe as peças que caem para completar linhas horizontais. '
            'Cada linha completa some e dá pontos. Depois de limpar linhas, '
            'os blocos soltos CAEM sozinhos: se isso fechar outra linha, é '
            'uma CASCATA com pontos em dobro, triplo... Este tutorial rápido '
            'ensina o essencial e só é obrigatório na primeira vez.',
        build: () => _tutGame(3),
      ),
      _TutStep(
        title: '1. Mover',
        text: 'Use as setas de esquerda e direita, ou arraste o dedo para os '
            'lados sobre o tabuleiro. Segurando o botão a peça desliza '
            'rápido (ajuste DAS e ARR em Configurações). Neste treino a '
            'peça fica parada.',
        build: () => _tutGame(2),
        goals: [
          _TutGoal((g, c) => 'Leve a peça até a parede esquerda',
              (g, c) => _tutMinCol(g) == 0),
          _TutGoal((g, c) => 'Agora leve até a parede direita',
              (g, c) => _tutMaxCol(g) == kCols - 1),
        ],
      ),
      _TutStep(
        title: '2. Girar',
        text: 'Toque no botão azul de girar (ou toque no tabuleiro) para '
            'rodar a peça.',
        build: () => _tutGame(3),
        goals: [
          _TutGoal((g, c) => 'Gire a peça 4 vezes (${min(c.rot, 4)}/4)',
              (g, c) => c.rot >= 4),
        ],
      ),
      _TutStep(
        title: '3. Girar 180°',
        text: 'Às vezes a peça precisa ficar de cabeça para baixo. Em vez de '
            'girar duas vezes, use o botão rosa de 180° (no teclado, a tecla '
            'Q; no modo só gestos, segure o dedo parado no tabuleiro). '
            'É um movimento só.',
        build: () => _tutGame(7),
        goals: [
          _TutGoal((g, c) => 'Gire 180° com o botão rosa (${min(c.flips, 2)}/2)',
              (g, c) => c.flips >= 2),
        ],
      ),
      _TutStep(
        title: '4. Descer',
        text: 'A seta para baixo desce a peça devagar. O botão amarelo de '
            'queda (ou deslizar rápido para baixo) joga a peça de uma vez e '
            'a trava no lugar.',
        build: () => _tutGame(6),
        goals: [
          _TutGoal((g, c) => 'Segure a seta para baixo até o fundo',
              (g, c) => g.current.y >= g.ghostY),
          _TutGoal((g, c) => 'Agora toque no botão amarelo de queda',
              (g, c) => g.lockCount >= 1),
        ],
      ),
      _TutStep(
        title: '5. Completar uma linha',
        text: 'Leve a peça até o espaço brilhante e solte com a queda. '
            'Linha completa desaparece!',
        build: () => _tutGame(1, gaps: {
          kRows - 1: [0, 1, 2, 3]
        }),
        resetOnLock: true,
        targets: [
          [kRows - 1, 0],
          [kRows - 1, 1],
          [kRows - 1, 2],
          [kRows - 1, 3],
        ],
        goals: [
          _TutGoal((g, c) => 'Encaixe a peça no espaço marcado e solte',
              (g, c) => g.lines >= 1),
        ],
      ),
      _TutStep(
        title: '6. Várias linhas',
        text: 'Quanto mais linhas de uma vez, mais pontos você ganha. '
            'Encaixe o quadrado para limpar duas linhas juntas.',
        build: () => _tutGame(2, gaps: {
          kRows - 2: [kCols - 2, kCols - 1],
          kRows - 1: [kCols - 2, kCols - 1],
        }),
        resetOnLock: true,
        targets: [
          [kRows - 2, kCols - 2],
          [kRows - 2, kCols - 1],
          [kRows - 1, kCols - 2],
          [kRows - 1, kCols - 1],
        ],
        goals: [
          _TutGoal((g, c) => 'Limpe 2 linhas de uma vez',
              (g, c) => g.lines >= 2),
        ],
      ),
      _TutStep(
        title: '7. QUADRA!',
        text: 'Limpar 4 linhas de uma vez é a QUADRA, a jogada que mais '
            'pontua. Gire a peça comprida para ficar em pé e leve até o '
            'poço da direita.',
        build: () => _tutGame(1, gaps: {
          kRows - 4: [kCols - 1],
          kRows - 3: [kCols - 1],
          kRows - 2: [kCols - 1],
          kRows - 1: [kCols - 1],
        }),
        resetOnLock: true,
        targets: [
          [kRows - 4, kCols - 1],
          [kRows - 3, kCols - 1],
          [kRows - 2, kCols - 1],
          [kRows - 1, kCols - 1],
        ],
        goals: [
          _TutGoal((g, c) => 'Faça uma QUADRA: 4 linhas de uma vez',
              (g, c) => g.lines >= 4),
        ],
      ),
      _TutStep(
        title: '8. Reserva',
        text: 'A RESERVA guarda a peça atual para usar depois, ótimo para '
            'esperar a peça certa. Toque na caixa RESERVA (à esquerda do '
            'tabuleiro) ou deslize rápido para cima.',
        build: () => _tutGame(5),
        hlHold: true,
        goals: [
          _TutGoal((g, c) => 'Guarde a peça na RESERVA', (g, c) => c.holds >= 1),
          _TutGoal((g, c) => 'Use a nova peça e solte com a queda',
              (g, c) => g.lockCount >= 1),
          _TutGoal((g, c) => 'Guarde de novo para trocar com a peça guardada',
              (g, c) => c.holds >= 2),
        ],
      ),
      _TutStep(
        title: '9. Prática final',
        text: 'Agora a peça cai sozinha! Use tudo o que aprendeu. O contorno '
            'claro (fantasma) mostra onde a peça vai cair.',
        build: () {
          final g = _tutGame(1, gaps: {
            kRows - 2: [3, 4, 5, 6],
            kRows - 1: [3, 4, 5, 6],
          });
          g.forceQueue([1]);
          return g;
        },
        gravity: true,
        goals: [
          _TutGoal((g, c) => 'Limpe 2 linhas (${min(g.lines, 2)}/2)',
              (g, c) => g.lines >= 2),
        ],
      ),
    ];

class TutorialScreen extends StatefulWidget {
  /// true na primeira abertura do app: não dá para sair nem pular.
  final bool mandatory;
  final VoidCallback? onDone;

  const TutorialScreen({super.key, this.mandatory = false, this.onDone});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen>
    with SingleTickerProviderStateMixin {
  late final List<_TutStep> _steps;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  int _t = 0;
  int _si = 0;
  int _goal = 0;
  int _lastLocks = 0;
  late StackGame game;
  _TutCount cnt = _TutCount();
  String _note = '';
  bool _finished = false;
  double _dragX = 0;
  double _dragY = 0;
  late final InputRouter _router;

  _TutStep get step => _steps[_si];
  bool get stepDone => _goal >= step.goals.length;

  @override
  void initState() {
    super.initState();
    _steps = _tutSteps();
    _loadStep(0);
    _ticker = createTicker(_tick)..start();
    _router = InputRouter(
      isCurrent: () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
      playing: () => !stepDone && !_finished,
      onLeft: () => _move(-1),
      onRight: () => _move(1),
      onDown: _soft,
      onPress: _onAction,
    )..attach();
  }

  @override
  void dispose() {
    _router.detach();
    _ticker.dispose();
    super.dispose();
  }

  void _loadStep(int i) {
    _si = i;
    _goal = 0;
    cnt = _TutCount();
    _note = '';
    _lastLocks = 0;
    game = step.build();
  }

  void _sounds() {
    if (game.lockCount != _lastLocks) {
      _lastLocks = game.lockCount;
      if (game.lastCleared >= 3 || game.lastChain > 1) {
        Audio.play('quad');
      } else if (game.lastCleared > 0) {
        Audio.play('clear');
      } else {
        Audio.play('drop');
      }
    }
  }

  void _evaluate() {
    final wasDone = stepDone;
    final goals = step.goals;
    while (_goal < goals.length && goals[_goal].done(game, cnt)) {
      _goal++;
    }
    if (!wasDone && stepDone) Settings.medium();
    if (step.resetOnLock && !stepDone && game.lockCount > 0) {
      _loadStep(_si);
      _note = 'Quase! A peça travou fora do lugar. Vamos tentar de novo.';
    }
  }

  void _tick(Duration elapsed) {
    var dt = (elapsed - _last).inMilliseconds;
    _last = elapsed;
    if (dt <= 0 || _finished) return;
    if (dt > 100) dt = 100;
    _t += dt;
    if (game.bannerMs > 0) game.bannerMs -= dt;
    if (game.flashMs > 0) game.flashMs -= dt;
    if (game.shakeMs > 0) game.shakeMs -= dt;
    if (step.gravity && !stepDone) {
      game.update(dt);
      _sounds();
      _evaluate();
    }
    final animating = step.gravity ||
        step.targets.isNotEmpty ||
        step.hlHold ||
        game.flashMs > 0 ||
        game.shakeMs > 0 ||
        game.bannerMs > 0;
    if (animating && mounted) setState(() {});
  }

  void _act(VoidCallback f) {
    if (stepDone || _finished) return;
    setState(() {
      f();
      _sounds();
      _evaluate();
    });
  }

  void _move(int dx) => _act(() {
        if (game.move(dx)) cnt.moves++;
      });

  void _soft() => _act(() {
        if (game.softDrop()) cnt.soft++;
      });

  void _rotate() {
    _act(() {
      if (game.rotate(true)) {
        cnt.rot++;
        Audio.play('rotate');
      }
    });
    Settings.selection();
  }

  void _flip() {
    _act(() {
      if (game.rotate180()) {
        cnt.flips++;
        Audio.play('rotate');
      }
    });
    Settings.selection();
  }

  void _hard() {
    _act(() => game.hardDrop());
    Settings.light();
  }

  void _hold() {
    _act(() {
      final before = game.canHold;
      game.hold();
      if (before && !game.canHold) cnt.holds++;
    });
    Settings.selection();
  }

  void _next() {
    if (_si >= _steps.length - 1) {
      _finish();
    } else {
      setState(() => _loadStep(_si + 1));
    }
  }

  void _restart() => setState(() => _loadStep(_si));

  /// Teclado e controle no tutorial.
  void _onAction(GameAction a) {
    switch (a) {
      case GameAction.rotateCw:
        _rotate();
        break;
      case GameAction.rotateCcw:
        _act(() {
          if (game.rotate(false)) Audio.play('rotate');
        });
        break;
      case GameAction.flip:
        _flip();
        break;
      case GameAction.hardDrop:
        _hard();
        break;
      case GameAction.hold:
        _hold();
        break;
      case GameAction.restart:
        if (!_finished) _restart();
        break;
      case GameAction.pause:
        if (stepDone && !_finished) _next();
        break;
      case GameAction.left:
      case GameAction.right:
      case GameAction.down:
        break;
    }
  }

  Future<void> _finish() async {
    setState(() => _finished = true);
    await Settings.setTutorialDone();
  }

  void _leave() {
    if (widget.mandatory) {
      widget.onDone?.call();
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.mandatory,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: Settings.theme.value.bg,
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: [
                Column(
                  children: [
                    _topBar(),
                    _card(),
                    Expanded(child: LayoutBuilder(builder: _playfield)),
                    _controls(),
                  ],
                ),
                if (_finished) _finishOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final total = _steps.length;
    final done = _si + (stepDone ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Column(
        children: [
          Row(
            children: [
              if (!widget.mandatory)
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                )
              else
                const SizedBox(width: 12, height: 48),
              Text('Tutorial · ${_si + 1}/$total',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              const SoundButtons(),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: done / total,
                minHeight: 5,
                backgroundColor: Colors.white12,
                color: Colors.cyanAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card() {
    final s = step;
    final last = _si >= _steps.length - 1;
    final shown = s.goals.isEmpty ? 0 : min(_goal, s.goals.length - 1);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: stepDone
                ? Colors.greenAccent
                : Colors.cyanAccent.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(s.title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(s.text,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.3)),
          if (s.goals.isNotEmpty) const SizedBox(height: 8),
          if (s.goals.isNotEmpty)
            for (int i = 0; i <= shown; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Icon(
                        i < _goal
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: i < _goal ? Colors.greenAccent : Colors.amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(s.goals[i].hint(game, cnt),
                          style: TextStyle(
                              color: i < _goal ? Colors.white54 : Colors.amber,
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ),
                  ],
                ),
              ),
          if (_note.isNotEmpty && !stepDone)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_note,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 12)),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (stepDone)
                Expanded(
                  child: FilledButton(
                    autofocus: true,
                    onPressed: _next,
                    child: Text(last
                        ? 'Concluir tutorial'
                        : (s.goals.isEmpty ? 'Começar' : 'Continuar')),
                  ),
                )
              else
                TextButton(
                    onPressed: _restart, child: const Text('Reiniciar passo')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _playfield(BuildContext context, BoxConstraints c) {
    gNesLevel = 0;
    const sideW = 58.0;
    final cell = max(
        4.0,
        min((c.maxWidth - sideW * 2 - 24) / kCols, c.maxHeight / kRows));
    final boardW = cell * kCols;
    final boardH = cell * kRows;
    final g = game;
    final pulse = 0.5 + 0.5 * sin(_t / 250);

    final left = SizedBox(
      width: sideW,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('RESERVA'),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _hold,
            child: _pieceBox(g.holdType,
                dim: !g.canHold,
                hint: true,
                glow: step.hlHold && !stepDone ? pulse : null),
          ),
        ],
      ),
    );

    final right = SizedBox(
      width: sideW,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('NEXT'),
          for (final t in g.preview) _pieceBox(t),
        ],
      ),
    );

    final board = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _rotate,
      onLongPress: Settings.layout.value == PadLayout.gestures ? _flip : null,
      onPanStart: (_) {
        _dragX = 0;
        _dragY = 0;
      },
      onPanUpdate: (d) {
        final stepPx = cell * 0.9 / Settings.swipeSens.value;
        _dragX += d.delta.dx;
        _dragY += d.delta.dy;
        if (_dragY < 0) _dragY = 0;
        while (_dragX > stepPx) {
          _move(1);
          _dragX -= stepPx;
        }
        while (_dragX < -stepPx) {
          _move(-1);
          _dragX += stepPx;
        }
        while (_dragY > stepPx) {
          _soft();
          _dragY -= stepPx;
        }
      },
      onPanEnd: (d) {
        final v = d.velocity.pixelsPerSecond;
        if (v.dy > 1400 && v.dy.abs() > v.dx.abs() * 2) {
          _hard();
        } else if (v.dy < -1000 && v.dy.abs() > v.dx.abs() * 2) {
          _hold();
        }
      },
      child: SizedBox(
        width: boardW,
        height: boardH,
        child: Stack(
          children: [
            CustomPaint(
              size: Size(boardW, boardH),
              painter: BoardPainter(game, Settings.theme.value),
            ),
            if (!stepDone)
              for (final t in step.targets)
                Positioned(
                  left: t[1] * cell,
                  top: t[0] * cell,
                  width: cell,
                  height: cell,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.amber.withAlpha((40 + 90 * pulse).round()),
                        border: Border.all(color: Colors.amber, width: 1.5),
                      ),
                    ),
                  ),
                ),
            if (game.bannerMs > 0 && game.banner != null)
              Positioned.fill(
                child: Center(
                  child: Text(
                    game.banner!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          left,
          const SizedBox(width: 6),
          board,
          const SizedBox(width: 6),
          right,
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t,
            style: const TextStyle(
                color: Colors.white54, fontSize: 10, letterSpacing: 1)),
      );

  Widget _pieceBox(int? type,
      {bool dim = false, bool hint = false, double? glow}) {
    return Container(
      width: 56,
      height: 42,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: glow == null
              ? Colors.white12
              : Colors.amber.withAlpha((120 + 135 * glow).round()),
          width: glow == null ? 1 : 2,
        ),
      ),
      child: (type == null && hint)
          ? const Center(
              child: Icon(Icons.swap_vert, color: Colors.white24, size: 22))
          : CustomPaint(
              painter: PiecePainter(type, Settings.theme.value, dim: dim)),
    );
  }

  Widget _controls() {
    final l = Settings.layout.value == PadLayout.mirrored
        ? PadLayout.mirrored
        : PadLayout.standard;
    return ControlPad(
      layout: l,
      scale: Settings.padScale.value,
      onLeft: () => _move(-1),
      onRight: () => _move(1),
      onDown: _soft,
      onRotate: _rotate,
      onDrop: _hard,
      onFlip: _flip,
      forceFlip: true,
    );
  }

  Widget _finishOverlay() {
    final bronze = Elo.tiers[0];
    return Positioned.fill(
      child: Container(
        color: Colors.black.withAlpha(225),
        padding: const EdgeInsets.all(24),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle,
                    color: Colors.greenAccent, size: 64),
                const SizedBox(height: 8),
                const Text('Tutorial concluído!',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                const Text('Agora você está pronto para jogar.',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.amber),
                  ),
                  child: Row(
                    children: [
                      _avatarCircle(12, size: 52),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                            'Recompensa: avatar 🎓 liberado! Escolha-o em '
                            'Elos e recompensas > Personalizar.',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: bronze.color),
                  ),
                  child: Column(
                    children: [
                      EloBadge(tier: bronze, big: true),
                      const SizedBox(height: 8),
                      const Text(
                          'Você começa no elo Ferro (0 pts). Vença partidas '
                          'ranqueadas no Multiplayer online para subir de elo e '
                          'liberar texturas, avatares, molduras e cores de nome.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, height: 1.4)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: 240,
                  child: FilledButton(
                    autofocus: true,
                    onPressed: _leave,
                    child: Text(widget.mandatory ? 'Ir para o menu' : 'Voltar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
