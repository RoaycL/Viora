import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/cache/account_scope.dart';
import '../../data/config/config_store.dart';
import '../../data/download/downloads.dart';
import '../../data/media/server_registry.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/toast.dart';

/// 下载页（导航栏「下载」）：下载中的进度、暂停 / 继续，下载完的直接播放（没有网络也能看）
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  @override
  void initState() {
    super.initState();
    Downloads.instance.load();
  }

  void _resume(DownloadEntry e) {
    final client = ref.read(serverClientProvider(e.serverId));
    if (client == null) {
      showToast('服务器已删除，无法继续下载');
      return;
    }
    Downloads.instance.resume(e, client);
  }

  void _play(DownloadEntry e) {
    final pos = e.played ? 0 : e.position.inMilliseconds;
    context.push('/play/${e.serverId}/${e.itemId}?source=${e.source.id}&pos=$pos');
  }

  @override
  Widget build(BuildContext context) {
    // 儿童模式等设置变了要重新筛选
    final config = ref.watch(configProvider);
    return ListenableBuilder(
      listenable: Downloads.instance,
      builder: (context, _) {
        // 只列当前登录账号的下载（同一服务器换了账号，不显示上一个账号的），并按儿童模式过滤（和别处一样）；
        // 服务器删掉了的在儿童模式关闭时照常列出，可以删除文件
        final list = Downloads.instance.entries.reversed.where((e) {
          final client = ref.read(serverClientProvider(e.serverId));
          if (client == null) return !config.parental.enabled;
          return accountScope(client.server) == e.account && itemVisible(config, e.item);
        }).toList();
        final done = list.where((e) => e.state == DownloadState.done).length;
        return FocusAutoScroll(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.pageTop, VSpace.contentLeft, 64),
            child: RowFocusScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('下载', style: VText.h1),
                  const SizedBox(height: 12),
                  Text(
                    list.isEmpty ? '在详情页按「下载」，没有网络时也能在这里看' : '已下载 $done 个 · 共 ${list.length} 个',
                    style: VText.small.copyWith(color: VColors.textTertiary),
                  ),
                  const SizedBox(height: 32),
                  for (var i = 0; i < list.length; i++) ...[
                    _Row(
                      key: ValueKey(list[i].id),
                      entry: list[i],
                      rowIndex: i,
                      onPlay: () => _play(list[i]),
                      onPause: () => Downloads.instance.pause(list[i]),
                      onResume: () => _resume(list[i]),
                      onDelete: () => Downloads.instance.remove(list[i]),
                    ),
                    const SizedBox(height: 28),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.entry,
    required this.rowIndex,
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
  });

  final DownloadEntry entry;
  final int rowIndex;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final it = e.item;
    final title = [
      if (it.seriesName != null) it.seriesName!,
      if (it.episodeLabel != null) it.episodeLabel!,
      it.name,
    ].join('  ');
    final size = formatBytes(e.total ?? e.received);
    final status = switch (e.state) {
      DownloadState.done =>
        e.played
            ? '$size · 已看完'
            : e.position > Duration.zero
            ? '$size · 看到 ${_clock(e.position)}'
            : size,
      DownloadState.downloading =>
        '下载中 ${e.fraction == null ? formatBytes(e.received) : '${(e.fraction! * 100).toStringAsFixed(1)}%'} · ${formatBytes(e.received)} / $size',
      DownloadState.queued => '等待下载',
      DownloadState.paused => '已暂停 · ${formatBytes(e.received)} / $size',
      DownloadState.failed => '下载失败：${e.error ?? '未知错误'}',
    };
    final (String label, IconData icon, VoidCallback action) = switch (e.state) {
      DownloadState.done => (e.position > Duration.zero && !e.played ? '继续播放' : '播放', Icons.play_arrow_rounded, onPlay),
      DownloadState.downloading || DownloadState.queued => ('暂停', Icons.pause_rounded, onPause),
      DownloadState.paused => ('继续下载', Icons.download_rounded, onResume),
      DownloadState.failed => ('重试', Icons.refresh_rounded, onResume),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: VText.label),
        const SizedBox(height: 6),
        Text(
          '${e.source.resolutionLabel} · $status',
          style: VText.small.copyWith(color: e.state == DownloadState.failed ? VColors.bad : VColors.textTertiary),
        ),
        if (e.state != DownloadState.done && e.fraction != null) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: 640,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: e.fraction,
                minHeight: 6,
                backgroundColor: const Color(0x22FFFFFF),
                color: VColors.accent,
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        FocusButtonRow(
          rowIndex: rowIndex,
          itemKeys: const ['main', 'delete'],
          children: [
            (node) => PillButton(focusNode: node, icon: icon, label: label, onPressed: action),
            (node) => CircleIconButton(
              focusNode: node,
              icon: Icons.delete_outline_rounded,
              tooltip: e.state == DownloadState.done ? '删除下载的文件' : '取消下载',
              onPressed: onDelete,
            ),
          ],
        ),
      ],
    );
  }
}

String _clock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
