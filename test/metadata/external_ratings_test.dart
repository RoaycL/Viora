import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/core/storage/ratings_settings_store.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/domain/models/external_rating.dart';
import 'package:viora/domain/models/ratings_settings.dart';
import 'package:viora/features/metadata/external_ratings.dart';
import 'package:viora/features/metadata/ratings_service.dart';

void main() {
  testWidgets('shows early provider results, preserves source labels (tooltips) and wraps at narrow widths', (
    tester,
  ) async {
    final vault = MemoryVault();
    final store = RatingsSettingsStore(vault: vault);
    await store.save(
      const RatingsSettings(
        providers: [
          RatingProviderSettings(id: RatingProviderId.omdb, apiKey: 'test', enabled: true),
          RatingProviderSettings(id: RatingProviderId.trakt, apiKey: 'test', enabled: true),
        ],
      ),
    );
    const query = RatingQuery(kind: RatingMediaKind.series, imdbId: 'tt0903747');
    final trakt = Completer<RatingsResult>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ratingsSettingsStoreProvider.overrideWithValue(store),
          externalRatingsProvider.overrideWith(
            (ref, key) async => key.provider == RatingProviderId.trakt
                ? trakt.future
                : const RatingsResult(
                    RatingsData(
                      ratings: [
                        ExternalRating(
                          source: RatingSource.imdb,
                          value: 9.5,
                          scale: 10,
                          kind: RatingMediaKind.series,
                          entityId: 'tt0903747',
                        ),
                      ],
                    ),
                  ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 360, child: ExternalRatings(query: query, serverRating: 8.3)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('媒体库 · 8.3'), findsOneWidget);
    expect(find.byTooltip('IMDb · 9.5'), findsOneWidget);
    expect(find.text('9.5'), findsOneWidget);
    expect(find.text('整剧评分'), findsOneWidget);
    expect(find.text('外部评分加载中…'), findsOneWidget);
    trakt.complete(const RatingsResult(RatingsData(), error: '访问被拒绝'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('IMDb · 9.5'), findsOneWidget);
    expect(find.text('Trakt：访问被拒绝'), findsOneWidget);
    expect(find.text('重试评分'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OMDb 和 MDBList 都给出 IMDb 时只显示排在前面的；剧集的烂番茄来自 MDBList', (tester) async {
    final store = RatingsSettingsStore(vault: MemoryVault());
    await store.save(
      const RatingsSettings(
        providers: [
          RatingProviderSettings(id: RatingProviderId.omdb, apiKey: 'test', enabled: true),
          RatingProviderSettings(id: RatingProviderId.mdblist, apiKey: 'test', enabled: true),
        ],
      ),
    );
    ExternalRating rating(RatingSource source, double value, double scale) =>
        ExternalRating(source: source, value: value, scale: scale, kind: RatingMediaKind.series, entityId: 'tt0903747');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ratingsSettingsStoreProvider.overrideWithValue(store),
          externalRatingsProvider.overrideWith(
            (ref, key) async => key.provider == RatingProviderId.omdb
                ? RatingsResult(RatingsData(ratings: [rating(RatingSource.imdb, 9.5, 10)]))
                : RatingsResult(
                    RatingsData(
                      ratings: [rating(RatingSource.imdb, 9.4, 10), rating(RatingSource.rottenTomatoes, 96, 100)],
                    ),
                  ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ExternalRatings(
              query: RatingQuery(kind: RatingMediaKind.series, imdbId: 'tt0903747'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('9.5'), findsOneWidget);
    expect(find.text('9.4'), findsNothing);
    expect(find.text('96%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
