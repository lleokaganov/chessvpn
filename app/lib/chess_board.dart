import 'dart:math';
import 'package:flutter/material.dart';

// Faithful Dart port of the idiotychess engine (was chess.js). Standard start
// position so it looks like ordinary chess; white = the brave human, black = the
// coward "idiot" who makes two random moves per turn. Plus a covert toggle: the
// white knight g1<->a3 fires onArm/onDisarm — an illegal move, so it never happens
// in real play and reads as ordinary fiddling to a bystander.

const _start = [
  'rnbqkbnr',
  'pppppppp',
  '........',
  '........',
  '........',
  '........',
  'PPPPPPPP',
  'RNBQKBNR',
];
const _glyph = {'p': '♟', 'n': '♞', 'b': '♝', 'r': '♜', 'q': '♛', 'k': '♚'};
const _idiotMoves = 2;

bool _isWhite(String p) => p.isNotEmpty && p == p.toUpperCase();
bool _isBlack(String p) => p.isNotEmpty && p == p.toLowerCase();
bool _sameSide(String a, String b) =>
    a.isNotEmpty && b.isNotEmpty && (_isWhite(a) == _isWhite(b));
bool _inside(int r, int c) => r >= 0 && r < 8 && c >= 0 && c < 8;
bool _isKing(String p) => p.isNotEmpty && p.toLowerCase() == 'k';

List<List<String>> _freshBoard() => _start
    .map((row) => row.split('').map((ch) => ch == '.' ? '' : ch).toList())
    .toList();

List<List<int>> _movesFor(List<List<String>> bd, int r, int c) {
  final p = bd[r][c];
  if (p.isEmpty) return [];
  final out = <List<int>>[];
  final me = p.toLowerCase();
  bool add(int tr, int tc) {
    if (!_inside(tr, tc)) return false;
    final t = bd[tr][tc];
    if (t.isEmpty) {
      out.add([tr, tc]);
      return true;
    }
    if (!_sameSide(p, t)) out.add([tr, tc]);
    return false;
  }

  void slide(List<List<int>> dirs) {
    for (final d in dirs) {
      var tr = r + d[0], tc = c + d[1];
      while (add(tr, tc)) {
        tr += d[0];
        tc += d[1];
      }
    }
  }

  const diag = [[-1, -1], [-1, 1], [1, -1], [1, 1]];
  const orth = [[-1, 0], [1, 0], [0, -1], [0, 1]];
  if (me == 'p') {
    final dir = _isWhite(p) ? -1 : 1;
    final startRow = _isWhite(p) ? 6 : 1;
    if (_inside(r + dir, c) && bd[r + dir][c].isEmpty) {
      out.add([r + dir, c]);
      if (r == startRow && bd[r + 2 * dir][c].isEmpty) out.add([r + 2 * dir, c]);
    }
    for (final dc in [-1, 1]) {
      final tr = r + dir, tc = c + dc;
      if (_inside(tr, tc) && bd[tr][tc].isNotEmpty && !_sameSide(p, bd[tr][tc])) {
        out.add([tr, tc]);
      }
    }
  } else if (me == 'n') {
    for (final d in [[-2, -1], [-2, 1], [-1, -2], [-1, 2], [1, -2], [1, 2], [2, -1], [2, 1]]) {
      add(r + d[0], c + d[1]);
    }
  } else if (me == 'b') {
    slide(diag);
  } else if (me == 'r') {
    slide(orth);
  } else if (me == 'q') {
    slide([...diag, ...orth]);
  } else if (me == 'k') {
    for (final d in [...diag, ...orth]) {
      add(r + d[0], c + d[1]);
    }
  }
  return out;
}

bool _attacked(List<List<String>> bd, int r, int c, bool byWhite) {
  final pr = r + (byWhite ? 1 : -1);
  for (final dc in [-1, 1]) {
    final t = _inside(pr, c + dc) ? bd[pr][c + dc] : '';
    if (t.isNotEmpty && t.toLowerCase() == 'p' && _isWhite(t) == byWhite) return true;
  }
  for (final d in [[-2, -1], [-2, 1], [-1, -2], [-1, 2], [1, -2], [1, 2], [2, -1], [2, 1]]) {
    final t = _inside(r + d[0], c + d[1]) ? bd[r + d[0]][c + d[1]] : '';
    if (t.isNotEmpty && t.toLowerCase() == 'n' && _isWhite(t) == byWhite) return true;
  }
  for (final d in [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 1], [1, -1], [1, 0], [1, 1]]) {
    final t = _inside(r + d[0], c + d[1]) ? bd[r + d[0]][c + d[1]] : '';
    if (t.isNotEmpty && t.toLowerCase() == 'k' && _isWhite(t) == byWhite) return true;
  }
  bool ray(List<List<int>> dirs, List<String> types) {
    for (final d in dirs) {
      var tr = r + d[0], tc = c + d[1];
      while (_inside(tr, tc)) {
        final t = bd[tr][tc];
        if (t.isNotEmpty) {
          if (_isWhite(t) == byWhite && types.contains(t.toLowerCase())) return true;
          break;
        }
        tr += d[0];
        tc += d[1];
      }
    }
    return false;
  }

  if (ray([[-1, -1], [-1, 1], [1, -1], [1, 1]], ['b', 'q'])) return true;
  if (ray([[-1, 0], [1, 0], [0, -1], [0, 1]], ['r', 'q'])) return true;
  return false;
}

List<int>? _findKing(List<List<String>> bd, bool white) {
  final k = white ? 'K' : 'k';
  for (var r = 0; r < 8; r++) {
    for (var c = 0; c < 8; c++) {
      if (bd[r][c] == k) return [r, c];
    }
  }
  return null;
}

bool _inCheck(List<List<String>> bd, bool white) {
  final k = _findKing(bd, white);
  return k != null && _attacked(bd, k[0], k[1], !white);
}

List<List<String>> _tryMove(List<List<String>> bd, int fr, int fc, int tr, int tc) {
  final nb = bd.map((row) => [...row]).toList();
  final p = nb[fr][fc];
  nb[tr][tc] = p;
  nb[fr][fc] = '';
  if (p == 'P' && tr == 0) nb[tr][tc] = 'Q';
  if (p == 'p' && tr == 7) nb[tr][tc] = 'q';
  return nb;
}

List<List<int>> _legalMoves(List<List<String>> bd, int r, int c) {
  final p = bd[r][c];
  if (p.isEmpty) return [];
  final white = _isWhite(p);
  return _movesFor(bd, r, c)
      .where((m) => !_inCheck(_tryMove(bd, r, c, m[0], m[1]), white))
      .toList();
}

class ChessBoard extends StatefulWidget {
  final VoidCallback? onArm;
  final VoidCallback? onDisarm;
  final VoidCallback? onMenu; // covert: fired by the illegal rook move a1->c3
  final String vpnStatus; // 'disconnected' | 'connecting' | 'connected' | 'error...'
  const ChessBoard(
      {super.key,
      this.onArm,
      this.onDisarm,
      this.onMenu,
      this.vpnStatus = 'disconnected'});
  @override
  State<ChessBoard> createState() => _ChessBoardState();
}

class _ChessBoardState extends State<ChessBoard> {
  late List<List<String>> board;
  List<int>? selected;
  List<List<int>> legal = [];
  bool busy = false, over = false;
  List<int>? last;
  String status = 'Ваш ход.';
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    board = _freshBoard();
  }

  void _reset() {
    setState(() {
      board = _freshBoard();
      selected = null;
      legal = [];
      busy = false;
      over = false;
      last = null;
      status = 'Ваш ход.';
    });
  }

  String _apply(int fr, int fc, int tr, int tc) {
    final p = board[fr][fc];
    final captured = board[tr][tc];
    board[tr][tc] = p;
    board[fr][fc] = '';
    if (p == 'P' && tr == 0) board[tr][tc] = 'Q';
    if (p == 'p' && tr == 7) board[tr][tc] = 'q';
    last = [fr, fc, tr, tc];
    return captured;
  }

  void _secretKnight(int fr, int fc, int tr, int tc, bool arm) {
    setState(() {
      board[tr][tc] = board[fr][fc];
      board[fr][fc] = '';
      last = [fr, fc, tr, tc];
      selected = null;
      legal = [];
    });
    if (arm) {
      widget.onArm?.call();
    } else {
      widget.onDisarm?.call();
    }
  }

  void _tap(int r, int c) {
    if (busy || over) return;
    final p = board[r][c];
    if (selected != null) {
      final sp = board[selected![0]][selected![1]];
      if (sp == 'N') {
        if (selected![0] == 7 && selected![1] == 6 && r == 5 && c == 0) {
          return _secretKnight(7, 6, 5, 0, true);
        }
        if (selected![0] == 5 && selected![1] == 0 && r == 7 && c == 6) {
          return _secretKnight(5, 0, 7, 6, false);
        }
      }
      // covert: illegal rook move a1 -> c3 opens the hidden settings menu
      if (sp == 'R' && selected![0] == 7 && selected![1] == 0 && r == 5 && c == 2) {
        setState(() {
          selected = null;
          legal = [];
        });
        widget.onMenu?.call();
        return;
      }
      if (legal.any((m) => m[0] == r && m[1] == c)) {
        _humanMove(selected![0], selected![1], r, c);
        return;
      }
      if (_isWhite(p)) {
        setState(() {
          selected = [r, c];
          legal = _movesFor(board, r, c);
        });
        return;
      }
      setState(() {
        selected = null;
        legal = [];
      });
      return;
    }
    if (_isWhite(p)) {
      setState(() {
        selected = [r, c];
        legal = _movesFor(board, r, c);
      });
    }
  }

  void _humanMove(int fr, int fc, int tr, int tc) {
    final cap = _apply(fr, fc, tr, tc);
    setState(() {
      selected = null;
      legal = [];
    });
    if (_isKing(cap)) return _end(true);
    setState(() {
      busy = true;
      status = 'Идиот думает…';
    });
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted) _idiotMove(1);
    });
  }

  void _idiotMove(int step) {
    final pieces = <List<dynamic>>[];
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        if (_isBlack(board[r][c])) {
          final m = _legalMoves(board, r, c);
          if (m.isNotEmpty) pieces.add([r, c, m]);
        }
      }
    }
    if (pieces.isEmpty) return _end(true); // coward mated/stalemated -> you win
    final pick = pieces[_rng.nextInt(pieces.length)];
    final fr = pick[0] as int, fc = pick[1] as int;
    final m = pick[2] as List<List<int>>;
    final dest = m[_rng.nextInt(m.length)];
    final cap = _apply(fr, fc, dest[0], dest[1]);
    setState(() {});
    if (_isKing(cap)) return _end(false);
    if (step < _idiotMoves) {
      setState(() => status = '…и ещё раз!');
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) _idiotMove(step + 1);
      });
    } else {
      setState(() {
        status = 'Ваш ход.';
        busy = false;
      });
    }
  }

  void _end(bool win) {
    setState(() {
      over = true;
      busy = false;
      selected = null;
      legal = [];
      status = win ? 'Вы победили!' : 'Вы проиграли!';
    });
  }

  Color _vpnColor() {
    final s = widget.vpnStatus;
    if (s == 'connected') return const Color(0xFF4CAF50); // green
    if (s == 'connecting') return const Color(0xFFFFB300); // amber
    if (s.startsWith('error')) return const Color(0xFFE53935); // red
    return const Color(0xFF555B62); // disconnected / off
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(right: 9),
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, color: _vpnColor()),
                  ),
                  Text(status,
                      style: const TextStyle(
                          color: Color(0xFFF2EFE6),
                          fontSize: 18,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            // board scales to fit whatever room the window leaves (resizable)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          border:
                              Border.all(color: const Color(0xFF11120F), width: 3),
                          borderRadius: BorderRadius.circular(6)),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: GridView.builder(
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 8),
                          itemCount: 64,
                          itemBuilder: (ctx, i) => _square(i ~/ 8, i % 8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: FilledButton(
                onPressed: _reset,
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF7EC46B),
                    foregroundColor: const Color(0xFF10210C)),
                child: const Text('Новая игра'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _square(int r, int c) {
    final dark = (r + c) % 2 == 1;
    final isSel = selected != null && selected![0] == r && selected![1] == c;
    final isLast = last != null &&
        ((r == last![0] && c == last![1]) || (r == last![2] && c == last![3]));
    final isMove = legal.any((m) => m[0] == r && m[1] == c);
    final p = board[r][c];
    Color bg = dark ? const Color(0xFF9A7B56) : const Color(0xFFE9E2CF);
    if (isSel) bg = const Color(0xFFF6E96B);
    return GestureDetector(
      onTap: () => _tap(r, c),
      child: Container(
        color: bg,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (isLast) Container(color: const Color(0x66CDE89A)),
            if (isMove && p.isEmpty)
              FractionallySizedBox(
                widthFactor: 0.3,
                heightFactor: 0.3,
                child: Container(
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Color(0x59282828))),
              ),
            if (isMove && p.isNotEmpty)
              FractionallySizedBox(
                widthFactor: 0.84,
                heightFactor: 0.84,
                child: Container(
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0x59282828), width: 4))),
              ),
            if (p.isNotEmpty)
              FractionallySizedBox(
                widthFactor: 0.82,
                heightFactor: 0.82,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Text(
                    _glyph[p.toLowerCase()]!,
                    style: TextStyle(
                      // bundled text font with all 12 chess glyphs — without it
                      // Android draws the pawn from the colour-emoji font (ignoring
                      // our colour) so both sides' pawns looked grey.
                      fontFamily: 'ChessFont',
                      fontSize: 100,
                      height: 1,
                      color: _isWhite(p) ? Colors.white : const Color(0xFF15130F),
                      shadows: _isWhite(p)
                          ? const [
                              Shadow(color: Colors.black, blurRadius: 1),
                              Shadow(color: Colors.black, offset: Offset(0, 1)),
                              Shadow(color: Colors.black, offset: Offset(1, 0)),
                            ]
                          : const [Shadow(color: Color(0xFF777777), blurRadius: 1)],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
