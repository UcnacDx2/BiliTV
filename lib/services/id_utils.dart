/// Bilibili BV/AV conversion used by mobile app endpoints.
abstract final class BilibiliIdUtils {
  static const _xorCode = 23442827791579;
  static const _maskCode = 2251799813685247;
  static const _base = 58;
  static const _data =
      'FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf';
  static final _inverse = <int, int>{
    for (var i = 0; i < _data.length; i++) _data.codeUnitAt(i): i,
  };

  static int bv2av(String bvid) {
    if (!RegExp(r'^BV1[0-9A-Za-z]{9}$').hasMatch(bvid)) return 0;
    final chars = bvid.codeUnits.sublist(3);
    final first = chars[0];
    chars[0] = chars[6];
    chars[6] = first;
    final second = chars[1];
    chars[1] = chars[4];
    chars[4] = second;
    var value = 0;
    for (final char in chars) {
      final digit = _inverse[char];
      if (digit == null) return 0;
      value = value * _base + digit;
    }
    return (value & _maskCode) ^ _xorCode;
  }
}
