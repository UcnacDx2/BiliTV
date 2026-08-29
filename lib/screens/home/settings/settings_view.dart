import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../services/auth_service.dart';
import 'tabs/playback_settings.dart';
import 'tabs/interface_settings.dart';
import 'tabs/plugins_settings.dart';
import 'tabs/storage_settings.dart';
import 'tabs/about_settings.dart';
import '../../../widgets/time_display.dart';
import '../../../widgets/vip_avatar_badge.dart';
import '../../../services/account_store.dart';
import '../login/login_view.dart';

/// 设置分类枚举
enum SettingsCategory {
  playback('播放设置'),
  interface_('界面设置'),
  plugins('插件中心'),
  storage('其他设置'),
  about('关于软件');

  const SettingsCategory(this.label);
  final String label;
}

class SettingsView extends StatefulWidget {
  final FocusNode? sidebarFocusNode;
  final VoidCallback onLogout;

  const SettingsView({
    super.key,
    this.sidebarFocusNode,
    required this.onLogout,
  });

  @override
  State<SettingsView> createState() => SettingsViewState();
}

class SettingsViewState extends State<SettingsView> {
  int _selectedCategoryIndex = 0;
  late List<FocusNode> _categoryFocusNodes;
  late FocusNode _logoutFocusNode;

  @override
  void initState() {
    super.initState();
    _logoutFocusNode = FocusNode();
    _categoryFocusNodes = List.generate(
      SettingsCategory.values.length,
      (_) => FocusNode(),
    );
  }

  @override
  void dispose() {
    _logoutFocusNode.dispose();
    for (var node in _categoryFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// 请求第一个分类标签的焦点（用于从侧边栏导航）
  void focusFirstCategory() {
    if (_categoryFocusNodes.isNotEmpty) {
      _categoryFocusNodes[0].requestFocus();
    }
  }

  Future<bool> _showConfirmDialog(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认', style: TextStyle(color: Color(0xFFfb7299))),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _handleLogout() async {
    final confirmed = await _showConfirmDialog('确认退出', '确定要退出登录吗？');
    if (confirmed) {
      widget.onLogout();
    }
  }

  Future<void> _addAccount() async {
    final added = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF181818),
        child: SizedBox(
          width: 520,
          height: 560,
          child: LoginView(
            onLoginSuccess: () => Navigator.of(context).pop(true),
          ),
        ),
      ),
    );
    if (added == true && mounted) setState(() {});
  }

  Future<void> _showAccountRoles() async {
    final accounts = AccountStore.accounts.toList();
    if (accounts.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('账号分工', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '可让视频解析和历史续播使用不同账号，解决账号权限或大会员状态不同的问题。',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 18),
                for (final role in const [
                  AccountRole.main,
                  AccountRole.video,
                  AccountRole.history,
                  AccountRole.heartbeat,
                ])
                  _buildRoleSelector(role, accounts, setDialogState),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                '完成',
                style: TextStyle(color: Color(0xFFfb7299)),
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _buildRoleSelector(
    AccountRole role,
    List<BiliAccount> accounts,
    StateSetter setDialogState,
  ) {
    final selected = AccountStore.accountFor(role)?.mid;
    final labels = {
      AccountRole.main: '当前账号',
      AccountRole.video: '视频解析账号',
      AccountRole.history: '历史/续播账号',
      AccountRole.heartbeat: '进度上报账号',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              labels[role]!,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          Expanded(
            child: DropdownButton<int>(
              isExpanded: true,
              value: accounts.any((account) => account.mid == selected)
                  ? selected
                  : null,
              dropdownColor: const Color(0xFF3A3A3A),
              style: const TextStyle(color: Colors.white),
              items: accounts
                  .map(
                    (account) => DropdownMenuItem<int>(
                      value: account.mid,
                      child: Text(
                        '${account.uname?.isNotEmpty == true ? account.uname : '账号'} (${account.mid})',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (mid) async {
                await AccountStore.setRole(role, mid);
                setDialogState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Container(
      width: 50,
      height: 50,
      color: Colors.grey[700],
      child: const Icon(Icons.person, size: 30, color: Colors.white54),
    );
  }

  Widget _buildActionButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
    FocusNode? focusNode,
  }) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.select) {
          onTap();
          return KeyEventResult.handled;
        }
        // 阻止向上导航超出设置页面 (如跳到搜索框)
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final isFocused = Focus.of(context).hasFocus;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: isFocused ? color : color.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(6),
              border: isFocused
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
            ),
            child: Text(
              label,
              style: TextStyle(
                color: isFocused ? Colors.white : color,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 构建分类标签
  Widget _buildCategoryTab({
    required String label,
    required bool isSelected,
    required FocusNode focusNode,
    required VoidCallback onTap,
    VoidCallback? onMoveLeft,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Focus(
        focusNode: focusNode,
        onFocusChange: (f) => f ? onTap() : null,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;

          if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
              onMoveLeft != null) {
            onMoveLeft();
            return KeyEventResult.handled;
          }
          // 向上导航跳转到退出按钮
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            _logoutFocusNode.requestFocus();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (ctx) {
            final isFocused = Focus.of(ctx).hasFocus;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isFocused ? const Color(0xFFfb7299) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isFocused ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isFocused
                          ? Colors.white
                          : (isSelected
                                ? const Color(0xFFfb7299)
                                : Colors.grey),
                      fontSize: 15,
                      fontWeight: isFocused || isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    height: 3,
                    width: 24,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFFfb7299)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    void moveToCurrentTab() {
      if (_categoryFocusNodes.isNotEmpty) {
        _categoryFocusNodes[_selectedCategoryIndex].requestFocus();
      }
    }

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部用户信息栏
            Container(
              padding: const EdgeInsets.fromLTRB(40, 30, 40, 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 头像
                  if (AuthService.face != null && AuthService.face!.isNotEmpty)
                    VipAvatarBadge(
                      size: 45,
                      child: ClipOval(
                        child: Image.network(
                          AuthService.face!,
                          width: 45,
                          height: 45,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _buildDefaultAvatar(),
                        ),
                      ),
                    )
                  else
                    _buildDefaultAvatar(),
                  const SizedBox(width: 15),
                  // 用户名和 UID
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AuthService.uname ?? '已登录',
                        style: TextStyle(
                          color: AuthService.isVip
                              ? const Color(0xFFfb7299) // VIP 粉色
                              : Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'UID: ${AuthService.mid ?? ""}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 30),
                  _buildActionButton(
                    label: '添加账号',
                    color: const Color(0xFFfb7299),
                    onTap: _addAccount,
                  ),
                  const SizedBox(width: 12),
                  _buildActionButton(
                    label: '账号分工',
                    color: Colors.blue,
                    onTap: _showAccountRoles,
                  ),
                  const SizedBox(width: 12),
                  // 退出登录按钮
                  _buildActionButton(
                    label: '退出登录',
                    color: Colors.red,
                    onTap: _handleLogout,
                    focusNode: _logoutFocusNode,
                  ),
                ],
              ),
            ),

            // 设置分类标签栏
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Row(
                children: List.generate(SettingsCategory.values.length, (
                  index,
                ) {
                  final category = SettingsCategory.values[index];
                  final isSelected = _selectedCategoryIndex == index;
                  return _buildCategoryTab(
                    label: category.label,
                    isSelected: isSelected,
                    focusNode: _categoryFocusNodes[index],
                    onTap: () => setState(() => _selectedCategoryIndex = index),
                    onMoveLeft: index == 0
                        ? () => widget.sidebarFocusNode?.requestFocus()
                        : null,
                  );
                }),
              ),
            ),

            const SizedBox(height: 20),

            // 设置内容区域
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: _buildContent(moveToCurrentTab),
              ),
            ),
          ],
        ),

        // 常驻时间显示 (与主界面位置保持一致)
        const Positioned(top: 20, right: 30, child: TimeDisplay()),
      ],
    );
  }

  Widget _buildContent(VoidCallback moveToCurrentTab) {
    switch (SettingsCategory.values[_selectedCategoryIndex]) {
      case SettingsCategory.playback:
        return PlaybackSettings(
          onMoveUp: moveToCurrentTab,
          sidebarFocusNode: widget.sidebarFocusNode,
        );
      case SettingsCategory.interface_:
        return InterfaceSettings(
          onMoveUp: moveToCurrentTab,
          sidebarFocusNode: widget.sidebarFocusNode,
        );
      case SettingsCategory.plugins:
        return PluginsSettingsTab(
          onMoveUp: moveToCurrentTab,
          sidebarFocusNode: widget.sidebarFocusNode,
        );
      case SettingsCategory.storage:
        return StorageSettings(
          onMoveUp: moveToCurrentTab,
          sidebarFocusNode: widget.sidebarFocusNode,
        );
      case SettingsCategory.about:
        return AboutSettings(
          onMoveUp: moveToCurrentTab,
          sidebarFocusNode: widget.sidebarFocusNode,
        );
    }
  }
}
