import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../ui/glass/glass.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/toast.dart';

/// 打开网页：Windows 用系统默认浏览器；电视大多没有浏览器，显示二维码让手机扫码打开
Future<void> openExternalUrl(BuildContext context, Uri url, {String title = '打开网页'}) async {
  if (PlatformProfile.isDesktop && Platform.isWindows) {
    try {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url.toString()]);
    } catch (e) {
      showToast('无法打开浏览器：$e');
    }
    return;
  }
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: const Color(0xB307080B),
    transitionDuration: VMotion.focus,
    pageBuilder: (context, _, _) => Center(
      child: Material(
        type: MaterialType.transparency,
        child: Glass(
          width: 860,
          radius: VRadius.panel,
          blur: 40,
          fill: const Color(0xE614161E),
          padding: const EdgeInsets.all(48),
          child: Row(
            children: [
              Container(
                width: 280,
                height: 280,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(VRadius.md)),
                child: QrImageView(data: url.toString(), padding: EdgeInsets.zero, backgroundColor: Colors.white),
              ),
              const SizedBox(width: 40),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: VText.h2.copyWith(fontSize: 34)),
                    const SizedBox(height: 16),
                    Text('用手机扫码打开', style: VText.label.copyWith(color: VColors.textSecondary)),
                    const SizedBox(height: 8),
                    Text(url.toString(), style: VText.caption.copyWith(color: VColors.textTertiary)),
                    const SizedBox(height: 32),
                    PillButton(
                      autofocus: true,
                      icon: Icons.check_rounded,
                      label: '完成',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
}
