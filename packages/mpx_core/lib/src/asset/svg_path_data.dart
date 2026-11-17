import 'dart:ui';

/// Reads SVG path data (the `d` attribute) into a [Path]: the outline of a
/// piece of media a host hands over as a preview (`MediaPreview.outline`).
///
/// It reads the commands outlines use: `M` `L` `H` `V` `C` `S` `Q` `T` `Z`,
/// absolute and relative, with implicit repeats (a move followed by more
/// pairs draws lines through them). An arc (`A`) or anything else it cannot
/// read yields null rather than a partial shape: a wrong outline is worse
/// than none, and the media stays at the stage it had.
abstract final class SvgPathData {
  /// The path [data] describes, or null when it is empty, starts with
  /// anything but a move, holds an arc or does not parse.
  static Path? parse(String data) => _Reader(data).read();
}

final class _Reader {
  _Reader(this._data);

  final String _data;
  int _at = 0;
  final Path _path = Path();
  double _x = 0, _y = 0;
  // Where the current subpath started, for a close.
  double _startX = 0, _startY = 0;
  // The last control point of a curve, for the smooth forms; null after any
  // other command.
  Offset? _cubicControl, _quadControl;

  Path? read() {
    var command = '';
    var any = false;
    while (true) {
      _skipSeparators();
      if (_at >= _data.length) break;
      final char = _data[_at];
      if (_isCommand(char)) {
        command = char;
        _at++;
      } else if (command.isEmpty || command == 'Z' || command == 'z') {
        // Numbers with no command, or after a close.
        return null;
      } else if (command == 'M') {
        command = 'L';
      } else if (command == 'm') {
        command = 'l';
      }
      if (!any && command != 'M' && command != 'm') return null;
      if (!_apply(command)) return null;
      any = true;
    }
    return any ? _path : null;
  }

  static bool _isCommand(String char) => 'MmLlHhVvCcSsQqTtZzAa'.contains(char);

  bool _apply(String command) {
    final relative = command.toLowerCase() == command;
    final dx = relative ? _x : 0.0;
    final dy = relative ? _y : 0.0;
    switch (command.toUpperCase()) {
      case 'M':
        final p = _pair(dx, dy);
        if (p == null) return false;
        _path.moveTo(p.dx, p.dy);
        _startX = p.dx;
        _startY = p.dy;
        _to(p);
      case 'L':
        final p = _pair(dx, dy);
        if (p == null) return false;
        _path.lineTo(p.dx, p.dy);
        _to(p);
      case 'H':
        final x = _number();
        if (x == null) return false;
        final p = Offset(x + dx, _y);
        _path.lineTo(p.dx, p.dy);
        _to(p);
      case 'V':
        final y = _number();
        if (y == null) return false;
        final p = Offset(_x, y + dy);
        _path.lineTo(p.dx, p.dy);
        _to(p);
      case 'C':
        final c1 = _pair(dx, dy);
        final c2 = _pair(dx, dy);
        final p = _pair(dx, dy);
        if (c1 == null || c2 == null || p == null) return false;
        _path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy);
        _to(p, cubic: c2);
      case 'S':
        final c1 = _reflect(_cubicControl);
        final c2 = _pair(dx, dy);
        final p = _pair(dx, dy);
        if (c2 == null || p == null) return false;
        _path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy);
        _to(p, cubic: c2);
      case 'Q':
        final c = _pair(dx, dy);
        final p = _pair(dx, dy);
        if (c == null || p == null) return false;
        _path.quadraticBezierTo(c.dx, c.dy, p.dx, p.dy);
        _to(p, quad: c);
      case 'T':
        final c = _reflect(_quadControl);
        final p = _pair(dx, dy);
        if (p == null) return false;
        _path.quadraticBezierTo(c.dx, c.dy, p.dx, p.dy);
        _to(p, quad: c);
      case 'Z':
        _path.close();
        _to(Offset(_startX, _startY));
      default:
        // An arc, which outlines do not need.
        return false;
    }
    return true;
  }

  void _to(Offset point, {Offset? cubic, Offset? quad}) {
    _x = point.dx;
    _y = point.dy;
    _cubicControl = cubic;
    _quadControl = quad;
  }

  // The control point a smooth curve starts with: the last one mirrored in
  // the current point, or the current point when the last command was not
  // a curve of that kind.
  Offset _reflect(Offset? control) => control == null
      ? Offset(_x, _y)
      : Offset(2 * _x - control.dx, 2 * _y - control.dy);

  Offset? _pair(double dx, double dy) {
    final x = _number();
    if (x == null) return null;
    final y = _number();
    if (y == null) return null;
    return Offset(x + dx, y + dy);
  }

  void _skipSeparators() {
    while (_at < _data.length && ' ,\t\n\r'.contains(_data[_at])) {
      _at++;
    }
  }

  static final RegExp _numberPattern = RegExp(
    r'[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?',
  );

  double? _number() {
    _skipSeparators();
    final match = _numberPattern.matchAsPrefix(_data, _at);
    if (match == null) return null;
    _at = match.end;
    return double.tryParse(match[0]!);
  }
}
