import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/external_rating.dart';
import '../../domain/models/ratings_settings.dart';
import '../../ui/panels/form_dialog.dart';
import 'ratings_service.dart';

/// Shared by both detail pages. Provider requests have independent states.
class ExternalRatings extends ConsumerWidget {
  const ExternalRatings({
    super.key,
    this.query,
    this.serverRating,
    this.criticRating,
    this.tmdbRating,
    this.serverCertification,
  });
  final RatingQuery? query;
  final double? serverRating;
  final double? criticRating;
  final double? tmdbRating;
  final String? serverCertification;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(ratingsSettingsProvider);
    final badges = <Widget>[];
    final status = <String>[];
    final retry = <ProviderRatingQuery>[];
    final kind = query?.kind;
    final scope = kind == RatingMediaKind.series
        ? '整剧'
        : kind == RatingMediaKind.episode
        ? '单集'
        : null;
    void badge(String label, String value, {bool stale = false, int? votes}) {
      badges.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(8)),
          child: Text(
            '$label $value${votes == null ? '' : ' · $votes 票'}${stale ? ' · 旧缓存' : ''}',
            style: VText.small.copyWith(color: VColors.rating),
          ),
        ),
      );
    }

    if (serverRating != null && serverRating!.isFinite && serverRating! > 0) {
      badge('媒体库', '${serverRating!.toStringAsFixed(1)}/10');
    }
    if (criticRating != null && criticRating!.isFinite && criticRating! > 0) {
      badge('媒体库影评人', '${criticRating!.round()}%');
    }
    if (tmdbRating != null && tmdbRating!.isFinite && tmdbRating! > 0) {
      badge('TMDB', '${tmdbRating!.toStringAsFixed(1)}/10');
    }
    var loading = false;
    String? certification;
    if (query != null) {
      for (final p in settings.value?.providers ?? const <RatingProviderSettings>[]) {
        if (!p.enabled || !p.configured) continue;
        final key = (provider: p.id, query: query!);
        final async = ref.watch(externalRatingsProvider(key));
        if (async.isLoading) {
          loading = true;
          continue;
        }
        final result = async.value;
        if (async.hasError) {
          status.add('${p.id.label}：评分暂不可用');
          retry.add(key);
          continue;
        }
        if (result == null) continue;
        for (final r in result.data.ratings) {
          badge(r.source.label, r.formatted, stale: result.stale, votes: r.votes);
        }
        if (serverCertification == null && result.data.certification != null) {
          certification = 'OMDb 年龄分级：${result.data.certification}${result.stale ? '（旧缓存）' : ''}';
        }
        // 缺少 ID、没有评分都不是故障：详情页首屏不显示这类提示，只在真正失败时提示并可重试
        if (result.error != null && !result.unsupported) {
          status.add('${p.id.label}：${result.error}');
          retry.add(key);
        }
      }
    }
    // 评分设置读不出来（系统安全存储不可用）只在设置页提示，详情页不显示
    if (badges.isEmpty && status.isEmpty && !loading && certification == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (scope != null && badges.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('$scope评分', style: VText.small.copyWith(color: VColors.textTertiary)),
            ),
          if (badges.isNotEmpty) Wrap(spacing: 10, runSpacing: 8, children: badges),
          if (certification != null) Text(certification, style: VText.small.copyWith(color: VColors.textSecondary)),
          if (loading) Text('外部评分加载中…', style: VText.small.copyWith(color: VColors.textTertiary)),
          for (final message in status) Text(message, style: VText.small.copyWith(color: VColors.textTertiary)),
          if (retry.isNotEmpty)
            SmallIconButton(
              icon: Icons.refresh_rounded,
              label: '重试评分',
              onPressed: () {
                for (final key in retry) {
                  ref.invalidate(externalRatingsProvider(key));
                }
              },
            ),
        ],
      ),
    );
  }
}
