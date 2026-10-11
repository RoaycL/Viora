import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/ui/widgets/art.dart';
import 'package:viora/ui/widgets/backdrop.dart';
import 'package:viora/ui/widgets/image_sizing.dart';

void main() {
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  testWidgets('电视上全屏背景解码到 1280 宽，其他图片不变；电脑不受影响', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox();
        },
      ),
    );
    final desktopPoster = ImageSizing.physicalWidth(ctx, 220);
    PlatformProfile.debugOverride = PlatformProfile.tv;
    expect(ImageSizing.physicalWidth(ctx, 1920), ImageSizing.tvBackdropWidth);
    expect(ImageSizing.physicalWidth(ctx, 220), desktopPoster);
    PlatformProfile.debugOverride = PlatformProfile.desktop;
    expect(ImageSizing.physicalWidth(ctx, 1920), greaterThanOrEqualTo(1920));
  });

  testWidgets('电视上背景快速切换时最多同时留两层（新图 + 上一张）', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    const art = ArtSpec(Color(0xFF111111), Color(0xFF000000), Color(0xFF222222));
    Widget page(int i) => Directionality(
      textDirection: TextDirection.ltr,
      child: PageBackdrop(
        art: art,
        image: SizedBox.expand(key: ValueKey('img$i')),
        imageKey: i,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(page(i));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final layers = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('img'),
    );
    expect(layers, findsNWidgets(2));
    await tester.pumpAndSettle();
    expect(layers, findsOneWidget);
  });
}
