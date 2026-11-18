import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/ui/rows/cards.dart';
import 'package:viora/ui/widgets/server_image.dart';

void main() {
  for (final profile in PlatformProfile.values) {
    testWidgets('${profile.name}：卡片上直接播放（电视播放键 / Windows 悬停 ▶），不影响打开详情', (tester) async {
      PlatformProfile.debugOverride = profile;
      addTearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);
      var opened = 0, played = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Center(
              child: PosterCard(
                node: node,
                art: placeholderArt('x'),
                title: '电影',
                onActivate: () => opened++,
                onPlay: () => played++,
              ),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      expect(played, 1);
      expect(opened, 0);
      final button = find.byType(HoverPlayButton);
      if (profile == PlatformProfile.desktop) {
        await tester.tap(find.byIcon(Icons.play_arrow_rounded));
        await tester.pump();
        expect(played, 2);
        expect(opened, 0, reason: '点 ▶ 不打开详情');
      } else {
        expect(find.byIcon(Icons.play_arrow_rounded), findsNothing, reason: '电视不显示 ▶');
        expect(button, findsOneWidget);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 600));
      expect(opened, 1);
    });
  }
}
