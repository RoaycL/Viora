/// 睡眠定时（播放页「播放设置 → 睡眠定时」）。
///
/// 放在播放页外面：连播下一集时播放页会重建，按分钟的定时要接着算；「本集播完」只管当前这一集。
/// 只在内存里，退出播放（不是连播 / 换版本）就取消。
abstract final class SleepTimer {
  /// 到点暂停的时间；null = 没有按分钟的定时
  static DateTime? deadline;

  /// 本集播完后停下（不自动播下一集）
  static bool endOfItem = false;

  /// 菜单里的选项（分钟）
  static const presets = [15, 30, 45, 60, 90, 120];

  static bool get active => deadline != null || endOfItem;

  static void setMinutes(int minutes, {DateTime? now}) {
    deadline = (now ?? DateTime.now()).add(Duration(minutes: minutes));
    endOfItem = false;
  }

  static void setEndOfItem() {
    deadline = null;
    endOfItem = true;
  }

  static void clear() {
    deadline = null;
    endOfItem = false;
  }

  /// 离到点还有多久（已经到点时为 0）；没有按分钟的定时为 null
  static Duration? remaining({DateTime? now}) {
    final d = deadline;
    if (d == null) return null;
    final left = d.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 菜单上显示的状态
  static String label({DateTime? now}) {
    if (endOfItem) return '本集播完';
    final left = remaining(now: now);
    if (left == null) return '关';
    return '剩 ${(left.inSeconds / 60).ceil()} 分钟';
  }
}
