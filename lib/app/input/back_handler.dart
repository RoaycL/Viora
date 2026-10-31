import 'dart:async';

import 'package:flutter/widgets.dart';

/// 返回键处理链。
///
/// 页面通过 [BackHandler] 注册回调；按下返回时从最后注册（最内层）的开始调用，
/// 返回 true 表示已处理（例如"先回到行首"、"先关闭面板"），否则交给外层，
/// 最终由应用壳做路由级处理（出栈 / 回首页）。
class BackDispatcher {
  final List<bool Function()> _handlers = <bool Function()>[];

  void register(bool Function() handler) => _handlers.add(handler);

  void unregister(bool Function() handler) => _handlers.remove(handler);

  /// 返回 true 表示某个页面已处理。
  bool dispatch() {
    for (final handler in _handlers.reversed.toList()) {
      if (handler()) return true;
    }
    return false;
  }
}

final backDispatcher = BackDispatcher();

/// 遥控器按一次返回可能走两条路到达：按键事件（按下时页面自己处理）和安卓系统返回（松开时没被消费的
/// 返回键会被系统转成一次返回）。按键路径处理过返回后短时间内到的系统返回当作同一次，丢掉，
/// 否则一次按键会连退两步（如关掉面板后紧接着退出播放）。
abstract final class BackDedup {
  static Timer? _window;
  static const window = Duration(milliseconds: 350);

  /// 按键路径处理了一次返回：之后 [window] 内到达的系统返回当作它的重复
  static void markKey() {
    _window?.cancel();
    _window = Timer(window, () => _window = null);
  }

  /// 系统返回到达：是不是刚才那次按键的重复
  static bool isEchoOfKey() => _window?.isActive ?? false;
}

class BackHandler extends StatefulWidget {
  const BackHandler({super.key, required this.onBack, required this.child});

  final bool Function() onBack;
  final Widget child;

  @override
  State<BackHandler> createState() => _BackHandlerState();
}

class _BackHandlerState extends State<BackHandler> {
  bool _handler() => mounted && _isOnTop(context) && widget.onBack();

  /// 只有所在路由在每一层 Navigator 中都位于顶部时才处理，
  /// 避免被详情页盖住的首页抢走返回键。
  static bool _isOnTop(BuildContext context) {
    BuildContext? ctx = context;
    while (ctx != null) {
      final route = ModalRoute.of(ctx);
      if (route == null) return true;
      if (!route.isCurrent) return false;
      ctx = route.navigator?.context;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    backDispatcher.register(_handler);
  }

  @override
  void dispose() {
    backDispatcher.unregister(_handler);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
