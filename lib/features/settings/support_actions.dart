import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../core/log/app_log.dart';
import '../../data/config/config_store.dart';
import '../../data/media/server_registry.dart';
import '../../data/sync/config_payload.dart';
import '../../data/sync/config_receiver.dart';
import '../../domain/models/segment_settings.dart';
import '../../ui/glass/glass.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/toast.dart';
import '../segments/segment_service.dart';
import '../sync/sync_settings_section.dart';

String _stamp() {
  final t = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
}

// ───────────────────────── 日志 ─────────────────────────

/// 导出日志：Windows 保存成文件；电视显示二维码，手机扫码在浏览器里打开
Future<void> exportLogs(BuildContext context, WidgetRef ref) async {
  final servers = ref.read(configProvider).servers;
  final text = AppLog.dump(
    appVersion: appVersion,
    extra: '服务器：${servers.map((s) => '${s.type.label}（${s.lines.length} 条线路）').join('、')}',
  );
  if (PlatformProfile.isDesktop) {
    final loc = await getSaveLocation(
      suggestedName: 'viora-log-${_stamp()}.txt',
      acceptedTypeGroups: const [
        XTypeGroup(label: '文本', extensions: ['txt']),
      ],
    );
    if (loc == null) return;
    await XFile.fromData(utf8.encode(text), mimeType: 'text/plain', name: 'viora-log.txt').saveTo(loc.path);
    showToast('日志已保存：${loc.path}');
    return;
  }
  if (!context.mounted) return;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: const Color(0xB307080B),
    pageBuilder: (context, _, _) => _LogShareDialog(text: text),
  );
}

class _LogShareDialog extends StatefulWidget {
  const _LogShareDialog({required this.text});

  final String text;

  @override
  State<_LogShareDialog> createState() => _LogShareDialogState();
}

class _LogShareDialogState extends State<_LogShareDialog> {
  late final _server = LogShareServer(widget.text);
  String? _url;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final ips = await localAddresses();
      if (ips.isEmpty) throw Exception('没有找到局域网地址');
      await _server.start();
      if (mounted) setState(() => _url = 'http://${ips.first}:${_server.port}${_server.path}');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _server.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Glass(
          width: 1000,
          radius: VRadius.panel,
          fill: const Color(0xE614161E),
          padding: const EdgeInsets.all(44),
          child: Row(
            children: [
              Container(
                width: 320,
                height: 320,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(VRadius.md)),
                child: _url == null
                    ? Center(
                        child: Text(_error ?? '正在准备…', style: const TextStyle(color: Color(0xFF0B0C10), fontSize: 20)),
                      )
                    : QrImageView(data: _url!, padding: EdgeInsets.zero),
              ),
              const SizedBox(width: 40),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('导出日志', style: VText.h2.copyWith(fontSize: 34)),
                    const SizedBox(height: 16),
                    Text(
                      '手机连同一个 Wi-Fi 扫码，会在浏览器里打开日志，可以保存或复制后发给开发者。5 分钟后自动关闭。',
                      style: VText.label.copyWith(color: VColors.textSecondary),
                    ),
                    if (_url != null) ...[
                      const SizedBox(height: 16),
                      Text(_url!, style: VText.small.copyWith(color: VColors.textTertiary)),
                    ],
                    const SizedBox(height: 28),
                    PillButton(autofocus: true, label: '完成', onPressed: () => Navigator.of(context).pop()),
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

// ───────────────────────── 配置备份 ─────────────────────────

/// 导出全部配置（与局域网同步同一格式，含密码和 Key，请妥善保存）
Future<void> exportBackup(WidgetRef ref) async {
  SegmentSettings? segments;
  try {
    segments = await ref.read(segmentSettingsProvider.future);
  } catch (_) {}
  final payload = buildSyncPayload(
    ref.read(configProvider),
    sections: {...SyncSection.values},
    segments: segments,
    from: '备份文件',
  );
  final loc = await getSaveLocation(
    suggestedName: 'viora-backup-${_stamp()}.json',
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Viora 备份', extensions: ['json']),
    ],
  );
  if (loc == null) return;
  final json = const JsonEncoder.withIndent('  ').convert(payload);
  await XFile.fromData(utf8.encode(json), mimeType: 'application/json', name: 'viora-backup.json').saveTo(loc.path);
  showToast('配置已导出：${loc.path}');
}

/// 从备份导入：和同步一样合并（同一台服务器更新，其他新增），不会清掉现有设置
Future<void> importBackup(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Viora 备份', extensions: ['json']),
    ],
  );
  if (file == null) return;
  try {
    final payload = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final message = await applySyncPayload(container, payload, (line) => debugPrint('import backup: $line'));
    showToast(message);
  } on FormatException {
    showToast('不是 Viora 的备份文件');
  } catch (e) {
    showToast('导入失败：$e');
  }
}
