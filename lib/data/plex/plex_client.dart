part of '../emby/emby_client.dart';

/// 按服务器类型创建客户端：Plex 用 [PlexClient]，Emby / Jellyfin 用 [EmbyClient]
EmbyClient mediaServerClient({
  required AppConfig config,
  required ServerConfig server,
  required String appVersion,
  void Function(ServerConfig server)? onServerChanged,
  void Function(bool reachable)? onProbed,
}) => server.type == ServerType.plex
    ? PlexClient(
        config: config,
        server: server,
        appVersion: appVersion,
        onServerChanged: onServerChanged,
        onProbed: onProbed,
      )
    : EmbyClient(
        config: config,
        server: server,
        appVersion: appVersion,
        onServerChanged: onServerChanged,
        onProbed: onProbed,
      );

/// plex.tv/link 授权码
typedef PlexPin = ({int id, String code});

/// Plex 媒体服务器（docs/03-media-servers.md §3）。
///
/// 继承 [EmbyClient]：线路选择、测速、反向代理、401 重新登录、播放上报队列、最近条目缓存都沿用，
/// 接口与解析按 Plex 覆盖，界面和其他模块不用区分服务器类型。
///
/// 登录两种方式：
/// - 用户名 + 密码：plex.tv 账号（开了两步验证时在密码后面接上 6 位验证码）
/// - 用户名留空、密码填账号令牌：plex.tv/link 授权（[createPin] / [checkPin]）或手动粘贴的 X-Plex-Token
///
/// 拿到账号令牌后到 plex.tv 查这台服务器的访问令牌（别人共享的服务器要用它），查不到就直接用账号令牌。
class PlexClient extends EmbyClient {
  PlexClient({
    required super.config,
    required super.server,
    required super.appVersion,
    super.onServerChanged,
    super.onProbed,
  });

  static final _plexTv = Uri.parse('https://plex.tv');

  // ───────────────────────── plex.tv ─────────────────────────

  static Future<Response<dynamic>> _plexTvRequest(
    AppConfig config,
    String appVersion,
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? form,
    String? token,
  }) => EmbyClient._once(
    (dio) => dio.requestUri<dynamic>(
      _plexTv.replace(path: path, queryParameters: query),
      data: form,
      options: Options(
        method: method,
        headers: {...plexIdentityHeaders(config, appVersion), 'Accept': 'application/json', 'X-Plex-Token': ?token},
        contentType: form == null ? null : Headers.formUrlEncodedContentType,
      ),
    ),
  );

  /// 申请 plex.tv/link 授权码（4 位，电视上用遥控器不用输入账号密码）
  static Future<PlexPin> createPin(AppConfig config, String appVersion) async {
    final r = await _plexTvRequest(config, appVersion, 'POST', '/api/v2/pins', query: {'strong': 'false'});
    final data = r.data;
    if ((r.statusCode ?? 500) >= 400 || data is! Map || data['id'] == null || data['code'] == null) {
      throw MediaServerException('无法连接 plex.tv（HTTP ${r.statusCode}）', statusCode: r.statusCode);
    }
    return (id: (data['id'] as num).toInt(), code: '${data['code']}');
  }

  /// 授权码对应的账号令牌；用户还没在 plex.tv/link 输入时返回 null
  static Future<String?> checkPin(AppConfig config, String appVersion, int id) async {
    final r = await _plexTvRequest(config, appVersion, 'GET', '/api/v2/pins/$id');
    if (r.statusCode == 404) throw const MediaServerException('授权码已过期，请重新获取');
    final token = r.data is Map ? (r.data as Map)['authToken'] as String? : null;
    return token == null || token.isEmpty ? null : token;
  }

  // ───────────────────────── 测速 / 登录 ─────────────────────────

  @override
  String get _probePath => '/identity';

  @override
  Future<Map<String, dynamic>> publicInfo() async {
    final ident = _container(await _request('GET', '/identity', auth: false));
    final info = <String, dynamic>{'Id': ident['machineIdentifier'], 'Version': ident['version']};
    try {
      // 服务器名要登录后才能读
      final root = _container(await _request('GET', '/'));
      info['ServerName'] = root['friendlyName'];
      info['Version'] = root['version'] ?? info['Version'];
    } catch (_) {}
    return info;
  }

  @override
  Future<ServerConfig> login() async {
    final String accountToken;
    final String userId;
    final username = _server.username.trim();
    if (username.isEmpty) {
      accountToken = _server.password.trim();
      if (accountToken.isEmpty) {
        throw const MediaServerException('请填写 Plex 账号和密码，或用 plex.tv/link 授权登录', statusCode: 401);
      }
      // 令牌就是"密码"：用它的摘要区分账号，换令牌才算换账号
      userId = 'token-${sha1Hex(accountToken).substring(0, 12)}';
    } else {
      final r = await _plexTvRequest(
        config,
        appVersion,
        'POST',
        '/users/sign_in.json',
        form: {'user[login]': username, 'user[password]': _server.password},
      );
      final code = r.statusCode ?? 500;
      if (code == 401 || code == 403 || code == 422) {
        throw MediaServerException(
          '${loginRejectedMessage(code, r.data is Map ? (r.data as Map)['error'] : r.data, 'plex.tv 返回 HTTP $code')}。'
          '开了两步验证的账号，在密码后面直接接上 6 位验证码；也可以用 plex.tv/link 授权登录',
          statusCode: 401,
        );
      }
      final user = r.data is Map ? (r.data as Map)['user'] : null;
      if (code >= 400 || user is! Map || user['authToken'] == null) {
        throw MediaServerException('plex.tv 登录失败（HTTP $code）', statusCode: code);
      }
      accountToken = user['authToken'] as String;
      userId = '${user['id'] ?? user['uuid'] ?? username.toLowerCase()}';
    }
    final serverToken = await _serverAccessToken(accountToken) ?? accountToken;
    _server = _server.copyWith(token: serverToken, userId: userId);
    // 验证令牌能访问这台服务器
    try {
      await _request('GET', '/library/sections', retried: true);
    } on MediaServerException catch (e) {
      if (e.statusCode == 401) {
        _server = _server.copyWith(clearSession: true);
        throw const MediaServerException('这个 Plex 账号没有访问这台服务器的权限（HTTP 401）', statusCode: 401);
      }
      rethrow;
    }
    onServerChanged?.call(_server);
    return _server;
  }

  /// 在 plex.tv 的设备列表里找这台服务器的访问令牌（共享来的服务器必须用它）；找不到返回 null
  Future<String?> _serverAccessToken(String accountToken) async {
    try {
      final machineId = _container(await _request('GET', '/identity', auth: false))['machineIdentifier'];
      if (machineId == null) return null;
      final r = await _plexTvRequest(
        config,
        appVersion,
        'GET',
        '/api/v2/resources',
        query: {'includeHttps': '1', 'includeRelay': '1'},
        token: accountToken,
      );
      if (r.data is! List) return null;
      for (final res in (r.data as List).whereType<Map<dynamic, dynamic>>()) {
        if (res['clientIdentifier'] == machineId) return res['accessToken'] as String?;
      }
    } catch (e) {
      debugPrint('plex resources failed: $e');
    }
    return null;
  }

  // ───────────────────────── 通用 ─────────────────────────

  static Map<String, dynamic> _container(Object? data) {
    final c = data is Map ? data['MediaContainer'] : null;
    if (c is! Map) throw const MediaServerException('Plex 服务器响应不完整');
    return c.cast<String, dynamic>();
  }

  static List<Map<String, dynamic>> _metadata(Map<String, dynamic> container) => [
    for (final m in (container['Metadata'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
      m.cast<String, dynamic>(),
  ];

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async =>
      _container(await _request('GET', path, query: query));

  static Map<String, String> _page(int start, int size) => {
    'X-Plex-Container-Start': '$start',
    'X-Plex-Container-Size': '$size',
  };

  List<_PlexSection>? _sectionCache;
  DateTime? _sectionAt;

  Future<List<_PlexSection>> _sections() async {
    final at = _sectionAt;
    if (_sectionCache != null && at != null && DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _sectionCache!;
    }
    final c = await _get('/library/sections');
    final list = [
      for (final d in (c['Directory'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
        if (d['type'] == 'movie' || d['type'] == 'show')
          _PlexSection('${d['key']}', d['title'] as String? ?? '', d['type'] as String, d['composite'] as String?),
    ];
    _sectionCache = list;
    _sectionAt = DateTime.now();
    return list;
  }

  // ───────────────────────── 浏览 ─────────────────────────

  @override
  Future<List<Library>> libraries() async => [
    for (final s in await _sections())
      Library(
        id: s.key,
        name: s.title,
        collectionType: s.type == 'movie' ? 'movies' : 'tvshows',
        image: s.composite == null ? null : ImageRef(s.key, ImageKind.primary, tag: s.composite),
      ),
  ];

  /// Emby 排序字段 → Plex 排序字段
  static String _sortKey(String emby) => switch (emby.trim()) {
    'SortName' => 'titleSort',
    'PremiereDate' => 'originallyAvailableAt',
    'CommunityRating' => 'audienceRating',
    'DatePlayed' => 'lastViewedAt',
    _ => 'addedAt',
  };

  static int _compare(MediaItem a, MediaItem b, String key) {
    int cmp<T extends Comparable<Object>>(T? x, T? y) => x == null
        ? (y == null ? 0 : -1)
        : y == null
        ? 1
        : x.compareTo(y);
    return switch (key) {
      'titleSort' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      'originallyAvailableAt' => cmp(a.premiereDate, b.premiereDate),
      'audienceRating' => cmp(a.rating, b.rating),
      'lastViewedAt' => cmp(a.lastPlayed, b.lastPlayed),
      _ => cmp(a.dateCreated, b.dateCreated),
    };
  }

  @override
  Future<PagedItems> items({
    String? parentId,
    String types = 'Movie,Series',
    int start = 0,
    int limit = 60,
    String sortBy = 'DateCreated,SortName',
    String sortOrder = 'Descending',
    String? searchTerm,
    DateTime? minDateLastSaved,
    String? filters,
    String? fields,
    bool userData = true,
  }) async {
    // Plex 服务器上没有收藏（plex.tv 的「稍后观看」是账号级的，不在服务器上）
    if (filters?.contains('IsFavorite') ?? false) return const PagedItems([], 0);
    final want = types.split(',').map((t) => t.trim()).toSet();
    final targets = <(String, int)>[
      for (final s in await _sections())
        if (parentId == null || s.key == parentId) ...[
          if (s.type == 'movie' && want.contains('Movie')) (s.key, 1),
          if (s.type == 'show' && want.contains('Series')) (s.key, 2),
          if (s.type == 'show' && want.contains('Episode')) (s.key, 4),
        ],
    ];
    if (targets.isEmpty) return const PagedItems([], 0);
    final dir = sortOrder == 'Ascending' ? '' : ':desc';
    final sortKeys = sortBy.split(',').map(_sortKey).toList();
    final query = {
      'sort': sortKeys.map((k) => '$k$dir').join(','),
      'includeGuids': '1',
      if (searchTerm != null && searchTerm.trim().isNotEmpty) 'title': searchTerm.trim(),
      if (minDateLastSaved != null) 'updatedAt>>': '${minDateLastSaved.millisecondsSinceEpoch ~/ 1000}',
      if (filters?.contains('IsPlayed') ?? false) 'viewCount>>': '0',
      if (filters?.contains('IsUnplayed') ?? false) 'unwatched': '1',
    };
    Future<Map<String, dynamic>> fetch((String, int) t, int from, int size) =>
        _get('/library/sections/${t.$1}/all', {...query, 'type': '${t.$2}', ..._page(from, size)});

    if (targets.length == 1) {
      final c = await fetch(targets.single, start, limit);
      final list = _metadata(c);
      return PagedItems(
        _allowed(list.map(parseItem)).toList(),
        (c['totalSize'] as num?)?.toInt() ?? start + list.length,
        rawCount: list.length,
        totalKnown: c['totalSize'] != null,
      );
    }

    if (fields == null) {
      // 跨库查询（搜索、最近看过）：每个库取前 start + limit 条合并排序，结果和 Emby 的全局排序一致
      final pages = await Future.wait(targets.map((t) => fetch(t, 0, start + limit)));
      final all = [for (final c in pages) ..._metadata(c).map(parseItem)];
      all.sort((a, b) {
        final r = _compare(a, b, sortKeys.first);
        return dir.isEmpty ? r : -r;
      });
      final total = pages.fold<int>(0, (n, c) => n + ((c['totalSize'] as num?)?.toInt() ?? _metadata(c).length));
      final slice = all.skip(start).take(limit).toList();
      return PagedItems(_allowed(slice).toList(), total, rawCount: slice.length);
    }

    // 建索引（全量分页）：各库首尾相接，每个库内按要求排序，分页位置稳定
    final sizes = await Future.wait(
      targets.map((t) async => ((await fetch(t, 0, 0))['totalSize'] as num?)?.toInt() ?? 0),
    );
    final total = sizes.fold<int>(0, (a, b) => a + b);
    final out = <Map<String, dynamic>>[];
    var offset = 0;
    for (var i = 0; i < targets.length && out.length < limit; i++) {
      final from = start + out.length - offset;
      if (from < sizes[i]) {
        out.addAll(_metadata(await fetch(targets[i], from, min(limit - out.length, sizes[i] - from))));
      }
      offset += sizes[i];
    }
    return PagedItems(_allowed(out.map(parseItem)).toList(), total, rawCount: out.length);
  }

  /// 剧集的季 / 集换成所属剧集（最近添加按剧显示，和 Emby 一样）
  MediaItem _asSeries(Map<String, dynamic> j) => switch (j['type']) {
    'episode' when j['grandparentRatingKey'] != null => parseItem({
      'ratingKey': j['grandparentRatingKey'],
      'type': 'show',
      'title': j['grandparentTitle'],
      'thumb': j['grandparentThumb'],
      'art': j['grandparentArt'],
      // 集的分级一般跟着剧集走：家长控制要用它过滤
      'contentRating': j['contentRating'],
      'addedAt': j['addedAt'],
    }),
    'season' when j['parentRatingKey'] != null => parseItem({
      'ratingKey': j['parentRatingKey'],
      'type': 'show',
      'title': j['parentTitle'],
      'thumb': j['parentThumb'],
      'art': j['art'],
      'year': j['parentYear'],
      'contentRating': j['contentRating'] ?? j['parentContentRating'],
      'addedAt': j['addedAt'],
    }),
    _ => parseItem(j),
  };

  @override
  Future<List<MediaItem>> latest({String? parentId, int limit = 20}) async {
    final c = await _get(parentId == null ? '/library/recentlyAdded' : '/library/sections/$parentId/recentlyAdded', {
      'includeGuids': '1',
      ..._page(0, limit * 3),
    });
    final seen = <String>{};
    final list = _allowed([
      for (final j in _metadata(c))
        if (const {'movie', 'show', 'season', 'episode'}.contains(j['type'])) _asSeries(j),
    ]).where((it) => seen.add(it.id)).take(limit).toList();
    _remember(list);
    return list;
  }

  @override
  Future<List<MediaItem>> resume({int limit = 20}) async {
    Map<String, dynamic> c;
    try {
      c = await _get('/hubs/continueWatching/items', _page(0, limit * 2));
    } on MediaServerException catch (e) {
      // 旧版服务器没有 continueWatching
      if (e.statusCode != 404 && e.statusCode != 400) rethrow;
      c = await _get('/library/onDeck', _page(0, limit * 2));
    }
    // 只要看了一半的（Plex 还会放没开始的"下一集"，和 Emby 的继续观看不同）。
    // 不看 played：它来自 viewCount（以前看完过），重看到一半的也要留着
    final items = _allowed(_metadata(c).map(parseItem).where((it) => it.position > Duration.zero)).take(limit).toList();
    _remember(items);
    return items;
  }

  Future<Map<String, dynamic>> _metadataOf(String id, [Map<String, String> extra = const {}]) async {
    final list = _metadata(await _get('/library/metadata/$id', {'includeGuids': '1', ...extra}));
    if (list.isEmpty) throw const MediaServerException('条目不存在', statusCode: 404);
    return list.first;
  }

  @override
  Future<MediaItem> _item(String id) async => parseItem(await _metadataOf(id));

  @override
  ({Uri url, Map<String, String> headers})? userImage({int maxWidth = 160}) => null;

  @override
  Future<List<ServerChapter>> chapters(String itemId) async {
    final j = await _metadataOf(itemId, {'includeChapters': '1'});
    return [
      for (final c in (j['Chapter'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
        ServerChapter(
          name: c['tag'] as String? ?? '',
          start: Duration(milliseconds: (c['startTimeOffset'] as num?)?.toInt() ?? 0),
        ),
    ];
  }

  /// Plex 的片头 / 片尾标记（intro / credits）
  @override
  Future<List<ServerMediaSegment>> mediaSegments(String itemId) async {
    final j = await _metadataOf(itemId, {'includeMarkers': '1'});
    return [
      for (final m in (j['Marker'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
        if (m['type'] == 'intro' || m['type'] == 'credits')
          ServerMediaSegment(
            type: m['type'] == 'intro' ? 'Intro' : 'Outro',
            start: Duration(milliseconds: (m['startTimeOffset'] as num?)?.toInt() ?? 0),
            end: Duration(milliseconds: (m['endTimeOffset'] as num?)?.toInt() ?? 0),
          ),
    ];
  }

  /// 进度条缩略图：Plex 生成的「视频预览缩略图」就是 BIF 格式
  @override
  Future<Trickplay?> trickplay(String itemId, String mediaSourceId) async {
    try {
      final data = await _request('GET', '/library/parts/$mediaSourceId/indexes/sd', bytes: true);
      if (data is! List<int> || data.isEmpty) return null;
      return await BifTrickplay.load(data is Uint8List ? data : Uint8List.fromList(data));
    } on MediaServerException catch (e) {
      if (e.statusCode != null && e.statusCode! < 500) return null; // 没生成缩略图
      rethrow;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<List<MediaItem>> seasons(String seriesId) async {
    final c = await _get('/library/metadata/$seriesId/children', {'includeGuids': '1'});
    return [
      for (final j in _metadata(c))
        if (j['type'] == 'season') parseItem(j),
    ];
  }

  @override
  Future<List<MediaItem>> episodes(String seriesId, {String? seasonId}) async {
    final c = await _get(
      seasonId == null ? '/library/metadata/$seriesId/allLeaves' : '/library/metadata/$seasonId/children',
      {'includeGuids': '1'},
    );
    final list = [
      for (final j in _metadata(c))
        if (j['type'] == 'episode') parseItem(j),
    ];
    _remember(list);
    return list;
  }

  /// 下一集：看了一半的那集；否则最后看过的那集之后的第一集；都没看过从第一集（不含特别篇）开始
  @override
  Future<MediaItem?> nextUp(String seriesId) async {
    final eps = await episodes(seriesId);
    final regular = eps.where((e) => (e.seasonNumber ?? 1) > 0).toList();
    final partial = regular.where((e) => e.position > Duration.zero && !e.played).firstOrNull;
    if (partial != null) return partial;
    final last = regular.lastIndexWhere((e) => e.played);
    if (last < 0) return regular.firstOrNull;
    return regular.skip(last + 1).where((e) => !e.played).firstOrNull;
  }

  @override
  Future<({int movies, int series})> counts() async {
    var movies = 0, series = 0;
    for (final s in await _sections()) {
      final c = await _get('/library/sections/${s.key}/all', {'type': s.type == 'movie' ? '1' : '2', ..._page(0, 0)});
      final n = (c['totalSize'] as num?)?.toInt() ?? 0;
      if (s.type == 'movie') {
        movies += n;
      } else {
        series += n;
      }
    }
    return (movies: movies, series: series);
  }

  // ───────────────────────── 播放 ─────────────────────────

  /// Part ID → 文件地址（/library/parts/{id}/{时间戳}/file.mkv）
  static final _partKeys = <String, String>{};

  @override
  Future<({List<MediaSourceInfo> sources, String? playSessionId})> playbackInfo(
    String itemId, {
    bool isPlayback = true,
  }) async {
    final j = await _metadataOf(itemId);
    final sources = [
      for (final m in (j['Media'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
        if ((m['Part'] as List?)?.isNotEmpty ?? false) parseSource(itemId, m.cast<String, dynamic>()),
    ];
    return (sources: sources, playSessionId: newPlaySessionId());
  }

  @override
  PlaybackRequest stream(MediaSourceInfo source, {String? playSessionId}) {
    final c = composer;
    final container = source.container.split(',').first.trim();
    final key =
        _partKeys['${_server.id}/${source.id}'] ??
        '/library/parts/${source.id}/0/file${container.isEmpty ? '' : '.$container'}';
    final original = c.resolve(key, {'X-Plex-Token': ?_server.token});
    final headers = c.headers(RequestKind.stream);
    return PlaybackRequest(
      url: c.finalUrl(original, RequestKind.stream),
      headers: headers,
      userAgent: headers['User-Agent']!,
    );
  }

  @override
  PlaybackRequest? subtitle(MediaSourceInfo source, MediaStreamInfo stream) {
    final key = stream.deliveryUrl;
    if (key == null || key.isEmpty) return null;
    final c = composer;
    final original = c.resolve(key, {'X-Plex-Token': ?_server.token});
    final headers = c.headers(RequestKind.stream);
    return PlaybackRequest(
      url: c.finalUrl(original, RequestKind.stream),
      headers: headers,
      userAgent: headers['User-Agent']!,
    );
  }

  /// Plex 服务器在线字幕接口没有公开文档：只用内置的在线字幕来源
  @override
  Future<List<RemoteSubtitle>> searchSubtitles(String itemId, String language) async => const [];

  @override
  Future<void> downloadSubtitle(String itemId, String subtitleId) async =>
      throw const MediaServerException('Plex 服务器不支持在线下载字幕');

  /// 播放上报：Plex 用 /:/timeline（看过 90% 服务器自动标记已看）
  @override
  Future<bool> _sendReport(
    String path,
    MediaSourceInfo s,
    Duration position,
    String? playSessionId, {
    bool paused = false,
    String? event,
  }) async {
    final state = path.endsWith('/Stopped')
        ? 'stopped'
        : paused
        ? 'paused'
        : 'playing';
    try {
      await _request(
        'GET',
        '/:/timeline',
        idempotent: true,
        query: {
          'ratingKey': s.itemId,
          'key': '/library/metadata/${s.itemId}',
          'state': state,
          'time': '${position.inMilliseconds}',
          'duration': '${s.duration?.inMilliseconds ?? 0}',
          'X-Plex-Session-Identifier': ?playSessionId,
        },
      );
      if (state != 'playing' || event != 'TimeUpdate') {
        debugPrint('plex timeline $state ok ${s.itemId} @${position.inSeconds}s');
      }
      return true;
    } catch (e) {
      debugPrint('plex timeline $state failed: $e');
      return false;
    }
  }

  @override
  Future<void> setPlayed(String itemId, bool played) async {
    forgetItem(itemId);
    await _request(
      'GET',
      played ? '/:/scrobble' : '/:/unscrobble',
      query: {'identifier': 'com.plexapp.plugins.library', 'key': itemId},
    );
    forgetItem(itemId);
  }

  @override
  Future<void> setFavorite(String itemId, bool favorite) async => throw const MediaServerException('Plex 服务器没有收藏功能');

  // ───────────────────────── 图片 ─────────────────────────

  /// [ImageRef.tag] 里存的是 Plex 的图片路径（如 /library/metadata/1/thumb/1700000000），经服务器缩放后返回
  @override
  ({Uri url, Map<String, String> headers}) image(ImageRef ref, {int maxWidth = 440}) {
    final c = composer;
    final path =
        ref.tag ??
        '/library/metadata/${ref.itemId}/${switch (ref.kind) {
          ImageKind.backdrop => 'art',
          ImageKind.logo => 'clearLogo',
          _ => 'thumb',
        }}';
    final original = c.resolve('/photo/:/transcode', {
      'width': '$maxWidth',
      'height': '${maxWidth * 2}',
      'upscale': '0',
      'url': path,
      'X-Plex-Token': ?_server.token,
    });
    return (url: c.finalUrl(original, RequestKind.image), headers: {'User-Agent': c.userAgentFor(RequestKind.image)});
  }

  // ───────────────────────── 解析 ─────────────────────────

  static DateTime? _epoch(Object? s) => s is num ? DateTime.fromMillisecondsSinceEpoch(s.toInt() * 1000) : null;

  static Duration? _ms(Object? v) => v is num ? Duration(milliseconds: v.toInt()) : null;

  static String? _str(Object? v) => v == null || '$v'.isEmpty ? null : '$v';

  @override
  MediaItem parseItem(Map<String, dynamic> j) {
    final id = '${j['ratingKey']}';
    final type = j['type'] as String?;
    final kind = switch (type) {
      'movie' => MediaKind.movie,
      'show' => MediaKind.series,
      'season' => MediaKind.season,
      'episode' => MediaKind.episode,
      _ => MediaKind.other,
    };
    final guids = <String, String>{};
    for (final g in (j['Guid'] as List? ?? const []).whereType<Map<dynamic, dynamic>>()) {
      final m = RegExp(r'^(\w+)://(.+)$').firstMatch('${g['id']}');
      if (m != null) guids[m[1]!] = m[2]!;
    }
    final premiere = DateTime.tryParse(j['originallyAvailableAt'] as String? ?? '');
    final duration = _ms(j['duration']);
    final offset = _ms(j['viewOffset']) ?? Duration.zero;
    final leafCount = (j['leafCount'] as num?)?.toInt();
    final viewedLeaves = (j['viewedLeafCount'] as num?)?.toInt() ?? 0;
    final played = kind == MediaKind.series || kind == MediaKind.season
        ? leafCount != null && leafCount > 0 && viewedLeaves >= leafCount
        : ((j['viewCount'] as num?) ?? 0) > 0;

    final seriesId = _str(kind == MediaKind.season ? j['parentRatingKey'] : j['grandparentRatingKey']);
    ImageRef? ref(String owner, ImageKind k, Object? path) =>
        path is String && path.isNotEmpty ? ImageRef(owner, k, tag: path) : null;
    final primary =
        ref(id, ImageKind.primary, j['thumb']) ??
        ref(seriesId ?? id, ImageKind.primary, j['parentThumb'] ?? j['grandparentThumb']);
    final backdrop =
        ref(id, ImageKind.backdrop, j['art']) ??
        ref(seriesId ?? id, ImageKind.backdrop, j['grandparentArt'] ?? j['parentArt']);
    final logoPath = [
      for (final i in (j['Image'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
        if (i['type'] == 'clearLogo') i['url'],
    ].firstOrNull;

    return MediaItem(
      serverId: _server.id,
      id: id,
      kind: kind,
      name: kind == MediaKind.season
          ? localizeSeasonName(j['title'] as String? ?? '', (j['index'] as num?)?.toInt())
          : j['title'] as String? ?? '',
      originalTitle: j['originalTitle'] as String?,
      overview: j['summary'] as String?,
      year: (j['year'] as num?)?.toInt() ?? premiere?.year,
      premiereDate: premiere,
      rating: ((j['audienceRating'] ?? j['rating']) as num?)?.toDouble(),
      officialRating: j['contentRating'] as String?,
      genres: [
        for (final g in (j['Genre'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
          if (g['tag'] is String) translateGenre(g['tag'] as String),
      ],
      runtime: duration,
      tmdbId: guids['tmdb'],
      imdbId: guids['imdb'],
      tvdbId: guids['tvdb'],
      primary: primary,
      backdrop: backdrop,
      thumb: kind == MediaKind.episode ? ref(id, ImageKind.thumb, j['thumb']) : null,
      logo: ref(id, ImageKind.logo, logoPath),
      seriesId: seriesId,
      seriesName: (kind == MediaKind.season ? j['parentTitle'] : j['grandparentTitle']) as String?,
      seasonId: kind == MediaKind.episode ? _str(j['parentRatingKey']) : null,
      seasonNumber: kind == MediaKind.episode
          ? (j['parentIndex'] as num?)?.toInt()
          : kind == MediaKind.season
          ? (j['index'] as num?)?.toInt()
          : null,
      episodeNumber: kind == MediaKind.episode ? (j['index'] as num?)?.toInt() : null,
      childCount: ((kind == MediaKind.season ? j['leafCount'] : j['childCount']) as num?)?.toInt(),
      played: played,
      position: offset,
      playedPercentage: duration == null || duration == Duration.zero || offset == Duration.zero
          ? null
          : offset.inMilliseconds * 100 / duration.inMilliseconds,
      dateCreated: _epoch(j['addedAt']),
      lastPlayed: _epoch(j['lastViewedAt']),
    );
  }

  /// [s] 是 Plex 的一个 `Media`（一个版本）；MediaSourceInfo.id 用它第一个 Part 的 ID
  @override
  MediaSourceInfo parseSource(String itemId, Map<String, dynamic> s) {
    final parts = s['Part'] as List;
    final part = parts.first as Map<dynamic, dynamic>;
    final partId = '${part['id']}';
    if (part['key'] is String) _partKeys['${_server.id}/$partId'] = part['key'] as String;
    final streams = <MediaStreamInfo>[];
    for (final m in (part['Stream'] as List? ?? const []).whereType<Map<dynamic, dynamic>>()) {
      final type = switch (m['streamType']) {
        1 => 'Video',
        2 => 'Audio',
        3 => 'Subtitle',
        _ => null,
      };
      if (type == null) continue;
      final trc = '${m['colorTrc'] ?? ''}'.toLowerCase();
      final range = m['DOVIPresent'] == true
          ? VideoRange.dolbyVision
          : trc == 'smpte2084'
          ? VideoRange.hdr10
          : trc == 'arib-std-b67'
          ? VideoRange.hlg
          : VideoRange.sdr;
      final key = m['key'] as String?;
      final codec = (m['codec'] as String?)?.toLowerCase();
      streams.add(
        MediaStreamInfo(
          index: (m['index'] as num?)?.toInt() ?? (m['id'] as num?)?.toInt() ?? streams.length,
          type: type,
          codec: codec == 'dca' ? 'dts' : codec,
          language: (m['languageCode'] ?? m['language']) as String?,
          title: (m['displayTitle'] ?? m['title']) as String?,
          isDefault: m['default'] == true || m['selected'] == true,
          isExternal: type == 'Subtitle' && key != null,
          channels: (m['channels'] as num?)?.toInt(),
          width: (m['width'] as num?)?.toInt(),
          height: (m['height'] as num?)?.toInt(),
          bitDepth: (m['bitDepth'] as num?)?.toInt(),
          frameRate: (m['frameRate'] as num?)?.toDouble(),
          range: range,
          deliveryUrl: type == 'Subtitle' ? key : null,
          streamTitle: m['title'] as String?,
          profile: m['profile'] as String?,
          level: (m['level'] as num?)?.toDouble(),
          colorPrimaries: m['colorPrimaries'] as String?,
          colorSpace: m['colorSpace'] as String?,
          colorTransfer: m['colorTrc'] as String?,
          channelLayout: m['audioChannelLayout'] as String?,
          sampleRate: (m['samplingRate'] as num?)?.toInt(),
          bitrate: m['bitrate'] is num ? (m['bitrate'] as num).toInt() * 1000 : null,
        ),
      );
    }
    final file = part['file'] as String?;
    final container = (part['container'] ?? s['container']) as String? ?? '';
    return MediaSourceInfo(
      serverId: _server.id,
      itemId: itemId,
      id: partId,
      container: container,
      // 分成多个文件的版本只能播放第一个文件：名称里写明，时长用这个文件的，进度和文件对得上
      name: [
        ?(s['title'] as String? ?? file?.split(RegExp(r'[/\\]')).last),
        if (parts.length > 1) '共 ${parts.length} 段，只能播放第 1 段',
      ].join(' · '),
      size: (part['size'] as num?)?.toInt(),
      bitrate: s['bitrate'] is num ? (s['bitrate'] as num).toInt() * 1000 : null,
      duration: _ms(parts.length > 1 ? part['duration'] : s['duration'] ?? part['duration']),
      streams: streams,
    );
  }
}

class _PlexSection {
  const _PlexSection(this.key, this.title, this.type, this.composite);

  final String key;
  final String title;

  /// movie / show
  final String type;
  final String? composite;
}

/// 十六进制 SHA-1
String sha1Hex(String s) => sha1.convert(utf8.encode(s)).toString();
