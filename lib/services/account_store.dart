import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum AccountRole { main, video, history, heartbeat }

/// A persisted Bilibili login. Roles deliberately point at the same account
/// records so video parsing and history/heartbeat can use different cookies.
class BiliAccount {
  const BiliAccount({
    required this.mid,
    required this.accessToken,
    required this.refreshToken,
    required this.sessdata,
    required this.biliJct,
    this.face,
    this.uname,
    this.isVip = false,
  });

  final int mid;
  final String accessToken;
  final String refreshToken;
  final String sessdata;
  final String biliJct;
  final String? face;
  final String? uname;
  final bool isVip;

  BiliAccount copyWith({String? face, String? uname, bool? isVip}) =>
      BiliAccount(
        mid: mid,
        accessToken: accessToken,
        refreshToken: refreshToken,
        sessdata: sessdata,
        biliJct: biliJct,
        face: face ?? this.face,
        uname: uname ?? this.uname,
        isVip: isVip ?? this.isVip,
      );

  Map<String, dynamic> toJson() => {
    'mid': mid,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'sessdata': sessdata,
    'biliJct': biliJct,
    'face': face,
    'uname': uname,
    'isVip': isVip,
  };

  factory BiliAccount.fromJson(Map<String, dynamic> json) => BiliAccount(
    mid: (json['mid'] as num?)?.toInt() ?? 0,
    accessToken: json['accessToken'] as String? ?? '',
    refreshToken: json['refreshToken'] as String? ?? '',
    sessdata: json['sessdata'] as String? ?? '',
    biliJct: json['biliJct'] as String? ?? '',
    face: json['face'] as String?,
    uname: json['uname'] as String?,
    isVip: json['isVip'] as bool? ?? false,
  );
}

/// Multi-account storage and role routing adapted from PiliPlus' account
/// separation. Existing single-account keys are migrated on first launch.
abstract final class AccountStore {
  static const _accountsKey = 'bili_accounts_v1';
  static const _rolePrefix = 'bili_account_role_';
  static SharedPreferences? _prefs;
  static final Map<int, BiliAccount> _accounts = {};
  static final Map<AccountRole, int> _roles = {};

  static Future<void> init() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    final encoded = _prefs!.getString(_accountsKey);
    if (encoded != null && encoded.isNotEmpty) {
      try {
        final list = jsonDecode(encoded) as List;
        for (final item in list) {
          final account = BiliAccount.fromJson(
            Map<String, dynamic>.from(item as Map),
          );
          if (account.mid > 0 && account.sessdata.isNotEmpty) {
            _accounts[account.mid] = account;
          }
        }
      } catch (_) {
        // A corrupt account list must not prevent the TV app from starting.
      }
    }
    for (final role in AccountRole.values) {
      final mid = _prefs!.getInt('$_rolePrefix${role.name}');
      if (mid != null && _accounts.containsKey(mid)) _roles[role] = mid;
    }
  }

  static BiliAccount? accountFor(AccountRole role) {
    final mid = _roles[role];
    return mid == null ? null : _accounts[mid];
  }

  static Iterable<BiliAccount> get accounts => _accounts.values;

  static Map<String, int> get roleAssignments => {
    for (final entry in _roles.entries) entry.key.name: entry.value,
  };

  /// Export the complete account/role state for the local management page.
  /// The caller is responsible for treating the returned data as sensitive.
  static Future<Map<String, dynamic>> exportData() async {
    await init();
    return {
      'version': 1,
      'accounts': _accounts.values.map((account) => account.toJson()).toList(),
      'roles': roleAssignments,
    };
  }

  /// Replace account/role state from an exported JSON object.
  static Future<int> importData(Map<String, dynamic> data) async {
    await init();
    final rawAccounts = data['accounts'];
    if (rawAccounts is! List) {
      throw const FormatException('accounts must be a list');
    }

    final imported = <int, BiliAccount>{};
    for (final raw in rawAccounts) {
      if (raw is! Map) continue;
      final account = BiliAccount.fromJson(Map<String, dynamic>.from(raw));
      if (account.mid > 0 && account.sessdata.isNotEmpty) {
        imported[account.mid] = account;
      }
    }

    final rawRoles = data['roles'];
    final importedRoles = <AccountRole, int>{};
    if (rawRoles is Map) {
      for (final role in AccountRole.values) {
        final rawMid = rawRoles[role.name];
        final mid = rawMid is num ? rawMid.toInt() : int.tryParse('$rawMid');
        if (mid != null && imported.containsKey(mid)) {
          importedRoles[role] = mid;
        }
      }
    }

    _accounts
      ..clear()
      ..addAll(imported);
    _roles
      ..clear()
      ..addAll(importedRoles);
    await _prefs!.setString(
      _accountsKey,
      jsonEncode(_accounts.values.map((account) => account.toJson()).toList()),
    );
    for (final role in AccountRole.values) {
      final key = '$_rolePrefix${role.name}';
      final mid = _roles[role];
      if (mid == null) {
        await _prefs!.remove(key);
      } else {
        await _prefs!.setInt(key, mid);
      }
    }
    return _accounts.length;
  }

  static bool get isLoggedIn => accountFor(AccountRole.main) != null;

  static Future<void> addOrUpdate(
    BiliAccount account, {
    bool activate = true,
  }) async {
    await init();
    _accounts[account.mid] = account;
    if (activate) {
      for (final role in AccountRole.values) {
        _roles[role] = account.mid;
      }
    }
    await _persist();
  }

  static Future<void> updateUserInfo({
    required int mid,
    required String face,
    required String uname,
    required bool isVip,
  }) async {
    await init();
    final account = _accounts[mid];
    if (account == null) return;
    _accounts[mid] = account.copyWith(face: face, uname: uname, isVip: isVip);
    await _persist();
  }

  static Future<void> setRole(AccountRole role, int? mid) async {
    await init();
    if (mid == null || !_accounts.containsKey(mid)) {
      _roles.remove(role);
      await _prefs!.remove('$_rolePrefix${role.name}');
      return;
    }
    _roles[role] = mid;
    await _prefs!.setInt('$_rolePrefix${role.name}', mid);
  }

  static Map<String, String> headers(AccountRole role) {
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/143.0.0.0 Safari/537.36',
      'Referer': 'https://www.bilibili.com',
    };
    final account = accountFor(role);
    if (account != null) {
      headers['Cookie'] =
          'SESSDATA=${account.sessdata}; bili_jct=${account.biliJct}';
      if (account.mid > 0) headers['x-bili-mid'] = '${account.mid}';
    }
    return headers;
  }

  static Future<void> logout({int? mid}) async {
    await init();
    final target = mid ?? accountFor(AccountRole.main)?.mid;
    if (target == null) return;
    _accounts.remove(target);
    _roles.removeWhere((_, value) => value == target);
    await _persist();
  }

  static Future<void> _persist() async {
    await _prefs!.setString(
      _accountsKey,
      jsonEncode(_accounts.values.map((account) => account.toJson()).toList()),
    );
    for (final role in AccountRole.values) {
      final mid = _roles[role];
      if (mid != null) {
        await _prefs!.setInt('$_rolePrefix${role.name}', mid);
      }
    }
  }
}
