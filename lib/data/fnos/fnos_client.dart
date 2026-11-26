part of '../emby/emby_client.dart';

/// 飞牛影视的接口签名常量。不是 Viora 自己的密钥：每台 fnOS 的影视网页端（trimemedia-web）都用这一对，
/// 写在它的前端代码里，社区客户端（FlyNarwhal、Kodi 插件 fnmedia 等）也都用它。飞牛升级换了常量时这里跟着改
const _fnosApiKey = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';
const _fnosApiSecret = '16CCEB3D-AB42-077D-36A1-F355324E4237';

String _md5Hex(String s) => md5.convert(utf8.encode(s)).toString();

/// 签名用的请求内容摘要：有请求体时是请求体（原样发出去的 JSON 字符串），
/// GET 带查询参数时是按参数名排序后的 `k=v&k=v`（不做 URL 编码），都没有时是空串
@visibleForTesting
String fnosPayloadDigest({String? body, Map<String, String>? query}) {
  if (body != null) return _md5Hex(body);
  if (query != null && query.isNotEmpty) {
    final keys = query.keys.toList()..sort();
    return _md5Hex(keys.map((k) => '$k=${query[k]}').join('&'));
  }
  return _md5Hex('');
}

/// 飞牛影视每个接口都要带的 `Authx` 请求头：
/// `nonce=<6 位数字>&timestamp=<毫秒>&sign=md5(key_路径_nonce_时间戳_内容摘要_secret)`。
/// [path] 是 `/v/api/v1/...`，不含查询参数
@visibleForTesting
String fnosAuthx(String path, {String? body, Map<String, String>? query, int? nonce, int? timestamp}) {
  final n = nonce ?? 100000 + Random.secure().nextInt(900000);
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch;
  final digest = fnosPayloadDigest(body: body, query: query);
  final sign = _md5Hex([_fnosApiKey, path, n, ts, digest, _fnosApiSecret].join('_'));
  return 'nonce=$n&timestamp=$ts&sign=$sign';
}

/// 飞牛影视（fnOS 的影视应用，docs/03-media-servers.md §4）。
///
/// 飞牛没有公开的第三方接口，这里按它网页端用的 `/v/api/v1` 接口实现：每个请求带 `Authorization: <token>`
/// 和 `Authx` 签名头，响应统一是 `{code, msg, data}`，code 为 0 才算成功。
///
/// 继承 [EmbyClient]：线路选择、测速、反向代理、播放上报队列、最近条目缓存都沿用，接口与解析按飞牛覆盖。
/// 第一版支持：账号密码登录、媒体库、浏览、详情、季 / 集、继续观看、收藏、搜索，
/// 播放 NAS 上的文件（`/media/range`）、上报进度、标记已看。网盘直链、服务端转码、FN Connect 中继还没做。
class FnosClient extends EmbyClient {
  FnosClient({
    required super.config,
    required super.server,
    required super.appVersion,
    super.onServerChanged,
    super.onProbed,
  }) : _accountId = server.userId;

  /// 已确认的飞牛用户 guid：重新登录时 /user/info 暂时取不到，也不能换成别的用户 ID
  /// （用户 ID 变了会被当成换了账号：清掉索引、历史换命名空间、丢掉待补发的上报）
  String? _accountId;

  static const _api = '/v/api/v1';

  /// 登录态失效（token 过期 / 被踢）
  static const _codeAuthFailed = -2;

  /// 签名不对：一般是 nonce 撞了，换一个重试
  static const _codeInvalidSign = 5000;

  /// 密码错误
  static const _codePasswordIncorrect = -15;

  // ───────────────────────── 请求 ─────────────────────────

  @override
  Map<String, String> _signedHeaders(String method, String path, Map<String, String>? query, Object? body) =>
      path.startsWith(_api) ? {'Authx': fnosAuthx(path, body: body is String ? body : null, query: query)} : const {};

  static String _nonce() => '${100000 + Random.secure().nextInt(900000)}';

  /// 调一个 `/v/api/v1` 接口，返回 `data`。POST / PUT / DELETE 的请求体末尾加随机 nonce（和网页端一样），签名按发出去的 JSON 算
  Future<Object?> _fn(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? data,
    bool auth = true,
    bool retried = false,
    int signRetries = 2,
  }) async {
    final body = method == 'GET' ? null : jsonEncode({...?data, 'nonce': _nonce()});
    final r = await _request(method, '$_api$path', query: query, body: body, auth: auth, idempotent: method != 'POST');
    if (r is! Map) throw const MediaServerException('飞牛影视响应不完整');
    final code = (r['code'] as num?)?.toInt();
    if (code == 0) return r['data'];
    if (code == _codeInvalidSign && signRetries > 0) {
      return _fn(method, path, query: query, data: data, auth: auth, retried: retried, signRetries: signRetries - 1);
    }
    if (code == _codeAuthFailed && auth && !retried && _server.password.isNotEmpty) {
      _server = _server.copyWith(clearSession: true);
      await login();
      return _fn(method, path, query: query, data: data, auth: auth, retried: true, signRetries: signRetries);
    }
    final msg = '${r['msg'] ?? ''}'.trim();
    throw _FnosException(
      code == _codeAuthFailed ? '登录已失效，请重新登录' : '飞牛影视返回错误${msg.isEmpty ? '' : '：$msg'}（$code）',
      code,
      statusCode: code == _codeAuthFailed ? 401 : null,
    );
  }

  static Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

  static List<Map<String, dynamic>> _maps(Object? v) => [
    for (final m in (v is List ? v : const []).whereType<Map<dynamic, dynamic>>()) m.cast<String, dynamic>(),
  ];

  // ───────────────────────── 测速 / 登录 ─────────────────────────

  /// 影视网页端首页，免登录
  @override
  String get _probePath => '/v';

  /// 飞牛没有免登录的服务器信息接口：名称用地址
  @override
  Future<Map<String, dynamic>> publicInfo() async => const {};

  @override
  Future<ServerConfig> login() async {
    try {
      return await _fnLogin(_server.password);
    } on MediaServerException catch (e) {
      // 电视屏幕键盘有时会在密码前后带上空格：去掉空格再试一次
      final trimmed = _server.password.trim();
      if (e.statusCode == 401 && trimmed != _server.password) {
        await _fnLogin(trimmed);
        _server = _server.copyWith(password: trimmed);
        onServerChanged?.call(_server);
        return _server;
      }
      rethrow;
    }
  }

  Future<ServerConfig> _fnLogin(String password) async {
    final Object? data;
    try {
      data = await _fn(
        'POST',
        '/login',
        data: {'app_name': 'trimemedia-web', 'username': _server.username.trim(), 'password': password},
        auth: false,
      );
    } on _FnosException catch (e) {
      if (e.code == _codePasswordIncorrect) throw const MediaServerException('用户名或密码错误', statusCode: 401);
      rethrow;
    }
    final token = _map(data)['token'];
    if (token is! String || token.isEmpty) throw const MediaServerException('飞牛影视登录成功但没有返回令牌');
    // 用户 ID 用飞牛的用户 guid（换账号才算换账号）。先放一个占位，让 /user/info 能带上令牌
    _server = _server.copyWith(token: token, userId: _accountId ?? 'pending');
    try {
      final guid = _map(await _fn('GET', '/user/info', retried: true))['guid'];
      if (guid is! String || guid.isEmpty) throw const MediaServerException('飞牛影视没有返回用户信息');
      _accountId = guid;
      _server = _server.copyWith(userId: guid);
    } on MediaServerException catch (e) {
      // 以前确认过 guid（令牌过期重新登录）：沿用它；第一次登录取不到就算登录失败，不能先用一个别的 ID 存下来
      if (e.statusCode == 401 || _accountId == null) {
        _server = _server.copyWith(clearSession: true);
        rethrow;
      }
    }
    onServerChanged?.call(_server);
    return _server;
  }

  // ───────────────────────── 缓存 ─────────────────────────

  /// 类型 ID → 名称（条目里的 genres 是 ID），按服务器缓存
  static final _genreNames = <String, Map<int, String>>{};

  /// 季 guid → 剧集 guid（集的详情里只有所属季），按服务器缓存
  static final _seasonSeries = <String, String>{};

  String _key(String id) => '${_server.id}/$id';

  Future<void> _ensureGenres() async {
    if (_genreNames.containsKey(_server.id)) return;
    try {
      _genreNames[_server.id] = {
        for (final g in _maps(await _fn('GET', '/tag/genres')))
          if (g['id'] is num && g['value'] is String) (g['id'] as num).toInt(): translateGenre(g['value'] as String),
      };
    } catch (e) {
      debugPrint('fnos genres failed: $e');
    }
  }

  /// 查出这些季所属的剧集，[parseItem] 才能给集填上 seriesId
  Future<void> _learnSeasons(Iterable<String> seasonIds) async {
    final unknown = {
      for (final id in seasonIds)
        if (id.isNotEmpty && !_seasonSeries.containsKey(_key(id))) id,
    };
    await Future.wait(
      unknown.map((id) async {
        try {
          final parent = _map(await _fn('GET', '/item/$id'))['parent_guid'];
          if (parent is String && parent.isNotEmpty) _seasonSeries[_key(id)] = parent;
        } catch (e) {
          debugPrint('fnos season $id failed: $e');
        }
      }),
    );
  }

  Future<void> _learnEpisodes(Iterable<Map<String, dynamic>> list) => _learnSeasons([
    for (final j in list)
      if (j['type'] == 'Episode' && j['parent_guid'] is String) j['parent_guid'] as String,
  ]);

  // ───────────────────────── 浏览 ─────────────────────────

  @override
  Future<List<Library>> libraries() async => [
    for (final d in _maps(await _fn('GET', '/mediadb/list')))
      if (d['category'] == 'Movie' || d['category'] == 'TV')
        Library(
          id: '${d['guid']}',
          name: d['title'] as String? ?? '',
          collectionType: d['category'] == 'Movie' ? 'movies' : 'tvshows',
          image: _img(
            '${d['guid']}',
            ImageKind.primary,
            d['poster'] ?? (d['posters'] is List ? (d['posters'] as List).firstOrNull : null),
          ),
        ),
  ];

  /// Emby 排序字段 → 飞牛排序字段
  static String _sortColumn(String emby) => switch (emby.split(',').first.trim()) {
    'SortName' => 'sort_title',
    'PremiereDate' || 'ProductionYear' => 'release_date',
    'CommunityRating' => 'vote_average',
    _ => 'create_time',
  };

  /// 飞牛按页码分页：[start] 不是 [limit] 的整数倍时取两页拼起来
  Future<({List<Map<String, dynamic>> list, int total})> _paged(
    String path,
    Map<String, Object?> query,
    int start,
    int limit,
  ) async {
    Future<Map<String, dynamic>> page(int p, int size) async =>
        _map(await _fn('POST', path, data: {...query, 'page': p, 'page_size': size}));
    int total(Map<String, dynamic> d, int fallback) => (d['total'] as num?)?.toInt() ?? fallback;

    if (limit <= 0) {
      final d = await page(1, 1);
      return (list: const <Map<String, dynamic>>[], total: total(d, 0));
    }
    final skip = start % limit;
    final first = await page(start ~/ limit + 1, limit);
    final n = total(first, start + _maps(first['list']).length);
    final list = _maps(first['list']).skip(skip).toList();
    if (skip > 0 && start + list.length < n) {
      list.addAll(_maps((await page(start ~/ limit + 2, limit))['list']).take(limit - list.length));
    }
    return (list: list, total: n);
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
    await _ensureGenres();
    final want = types.split(',').map((t) => t.trim()).toSet();
    final fnTypes = [if (want.contains('Movie')) 'Movie', if (want.contains('Series')) 'TV'];

    // 最近看过：飞牛的播放记录（按最近播放排序）
    if ((filters?.contains('IsPlayed') ?? false) && sortBy.startsWith('DatePlayed')) {
      final list = [
        for (final j in _maps(await _fn('GET', '/play/list')))
          if ((j['type'] == 'Movie' && want.contains('Movie')) || (j['type'] == 'Episode' && want.contains('Episode')))
            j,
      ];
      await _learnEpisodes(list);
      final slice = list.skip(start).take(limit).map(parseItem).toList();
      return PagedItems(_allowed(slice).toList(), list.length, rawCount: slice.length);
    }
    if (fnTypes.isEmpty) return const PagedItems([], 0);

    if (searchTerm != null && searchTerm.trim().isNotEmpty) {
      final list = [
        for (final j in _maps(await _fn('GET', '/search/list', query: {'q': searchTerm.trim()})))
          if (fnTypes.contains(j['type']) && (parentId == null || j['ancestor_guid'] == parentId)) j,
      ];
      final slice = list.skip(start).take(limit).map(parseItem).toList();
      return PagedItems(_allowed(slice).toList(), list.length, rawCount: slice.length);
    }

    final favorites = filters?.contains('IsFavorite') ?? false;
    final page = await _paged(
      favorites ? '/favorite/list' : '/item/list',
      {
        'ancestor_guid': parentId ?? '',
        'parent_guid': '',
        'exclude_grouped_video': 1,
        'sort_type': sortOrder == 'Ascending' ? 'ASC' : 'DESC',
        'sort_column': _sortColumn(sortBy),
        'tags': {'type': fnTypes},
      },
      start,
      limit,
    );
    return PagedItems(_allowed(page.list.map(parseItem)).toList(), page.total, rawCount: page.list.length);
  }

  @override
  Future<List<MediaItem>> latest({String? parentId, int limit = 20}) async {
    final page = await items(parentId: parentId, limit: limit);
    _remember(page.items);
    return page.items;
  }

  @override
  Future<List<MediaItem>> resume({int limit = 20}) async {
    await _ensureGenres();
    final list = _maps(await _fn('GET', '/play/list'));
    await _learnEpisodes(list);
    final items = _allowed(list.map(parseItem).where((it) => it.position > Duration.zero)).take(limit).toList();
    _remember(items);
    return items;
  }

  @override
  Future<MediaItem> _item(String id) async {
    await _ensureGenres();
    final j = _map(await _fn('GET', '/item/$id'));
    if (j.isEmpty) throw const MediaServerException('条目不存在', statusCode: 404);
    if (j['type'] == 'Season' && j['parent_guid'] is String) _seasonSeries[_key(id)] = j['parent_guid'] as String;
    await _learnEpisodes([j]);
    return parseItem(j);
  }

  @override
  ({Uri url, Map<String, String> headers})? userImage({int maxWidth = 160}) => null;

  @override
  Future<List<ServerChapter>> chapters(String itemId) async => const [];

  @override
  Future<List<ServerMediaSegment>> mediaSegments(String itemId) async => const [];

  @override
  Future<Trickplay?> trickplay(String itemId, String mediaSourceId) async => null;

  @override
  Future<List<MediaItem>> seasons(String seriesId) async {
    final list = _maps(await _fn('GET', '/season/list/$seriesId'));
    for (final j in list) {
      _seasonSeries[_key('${j['guid']}')] = seriesId;
    }
    return [for (final j in list) parseItem(j)];
  }

  @override
  Future<List<MediaItem>> episodes(String seriesId, {String? seasonId}) async {
    final seasonIds = seasonId != null
        ? [seasonId]
        : [for (final j in _maps(await _fn('GET', '/season/list/$seriesId'))) '${j['guid']}'];
    for (final s in seasonIds) {
      _seasonSeries[_key(s)] = seriesId;
    }
    final pages = await Future.wait(seasonIds.map((s) async => _maps(await _fn('GET', '/episode/list/$s'))));
    final list = [
      for (final p in pages)
        for (final j in p)
          if (j['type'] == 'Episode') parseItem(j),
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
    final d = _map(await _fn('GET', '/mediadb/sum'));
    return (movies: (d['movie'] as num?)?.toInt() ?? 0, series: (d['tv'] as num?)?.toInt() ?? 0);
  }

  // ───────────────────────── 播放 ─────────────────────────

  /// 文件（media_guid）→ 进度上报要带的视频 / 音频流 guid
  static final _streamGuids = <String, ({String video, String audio})>{};

  @override
  Future<({List<MediaSourceInfo> sources, String? playSessionId})> playbackInfo(
    String itemId, {
    bool isPlayback = true,
  }) async {
    final results = await Future.wait([
      _fn('GET', '/stream/list/$itemId'),
      // 上次播放的是哪个版本：排在第一个
      _fn('POST', '/play/info', data: {'item_guid': itemId}).then<Object?>((v) => v, onError: (_) => null),
    ]);
    final d = _map(results[0]);
    final lastMedia = _map(results[1])['media_guid'];
    final video = _maps(d['video_streams']);
    final audio = _maps(d['audio_streams']);
    final subs = _maps(d['subtitle_streams']);
    final sources = [
      for (final f in _maps(d['files']))
        if (f['guid'] is String && f['can_play'] != 0)
          _source(
            itemId,
            f,
            [
              for (final s in video)
                if (s['media_guid'] == f['guid']) s,
            ],
            [
              for (final s in audio)
                if (s['media_guid'] == f['guid']) s,
            ],
            [
              for (final s in subs)
                if (s['media_guid'] == f['guid']) s,
            ],
          ),
    ];
    if (lastMedia is String) {
      final i = sources.indexWhere((s) => s.id == lastMedia);
      if (i > 0) sources.insert(0, sources.removeAt(i));
    }
    return (sources: sources, playSessionId: newPlaySessionId());
  }

  MediaSourceInfo _source(
    String itemId,
    Map<String, dynamic> f,
    List<Map<String, dynamic>> video,
    List<Map<String, dynamic>> audio,
    List<Map<String, dynamic>> subs,
  ) {
    final mediaGuid = f['guid'] as String;
    final defaultAudio = audio.where((a) => a['is_default'] == 1).firstOrNull ?? audio.firstOrNull;
    _streamGuids[_key(mediaGuid)] = (
      video: '${video.firstOrNull?['guid'] ?? ''}',
      audio: '${defaultAudio?['guid'] ?? ''}',
    );
    final fileName = f['file_name'] as String? ?? '';
    final dot = fileName.lastIndexOf('.');
    final duration = (video.firstOrNull?['duration'] ?? audio.firstOrNull?['duration']) as num?;
    String? lang(Object? l) => l is String && l.isNotEmpty && l != 'und' ? l : null;
    int? toInt(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    return MediaSourceInfo(
      serverId: _server.id,
      itemId: itemId,
      id: mediaGuid,
      container: dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase(),
      name: fileName.isEmpty ? null : fileName,
      size: (f['size'] as num?)?.toInt(),
      bitrate: [...video, ...audio].fold<int>(0, (n, s) => n + ((s['bps'] as num?)?.toInt() ?? 0)).nonZero,
      duration: duration == null || duration <= 0 ? null : Duration(seconds: duration.toInt()),
      streams: [
        for (final v in video)
          MediaStreamInfo(
            index: toInt(v['index']) ?? 0,
            type: 'Video',
            codec: (v['codec_name'] as String?)?.toLowerCase(),
            title: _nonEmpty(v['title']),
            width: toInt(v['width']),
            height: toInt(v['height']),
            bitDepth: toInt(v['bit_depth']),
            frameRate: double.tryParse('${v['avg_frame_rate'] ?? v['r_frame_rate'] ?? ''}'.split(' ').first),
            range: _range(v),
            profile: _nonEmpty(v['profile']),
            level: double.tryParse('${v['level'] ?? ''}'),
            colorPrimaries: _nonEmpty(v['color_primaries']),
            colorSpace: _nonEmpty(v['color_space']),
            colorTransfer: _nonEmpty(v['color_transfer']),
            bitrate: toInt(v['bps']),
            aspectRatio: _nonEmpty(v['display_aspect_ratio']),
          ),
        for (final a in audio)
          MediaStreamInfo(
            index: toInt(a['index']) ?? 0,
            type: 'Audio',
            codec: (a['codec_name'] as String?)?.toLowerCase(),
            language: lang(a['language']),
            title: _nonEmpty(a['title']),
            streamTitle: _nonEmpty(a['title']),
            isDefault: identical(a, defaultAudio),
            channels: toInt(a['channels']),
            channelLayout: _nonEmpty(a['channel_layout']),
            sampleRate: toInt(a['sample_rate']),
            profile: _nonEmpty(a['profile']),
            bitrate: toInt(a['bps']),
          ),
        for (final s in subs)
          MediaStreamInfo(
            index: toInt(s['index']) ?? 0,
            type: 'Subtitle',
            codec: (_nonEmpty(s['codec_name']) ?? _nonEmpty(s['format']))?.toLowerCase(),
            language: lang(s['language']),
            title: _nonEmpty(s['title']),
            streamTitle: _nonEmpty(s['title']),
            isDefault: s['is_default'] == 1,
            isExternal: s['is_external'] == 1,
            deliveryUrl: s['is_external'] == 1 && s['guid'] is String ? '$_api/subtitle/dl/${s['guid']}' : null,
          ),
      ],
    );
  }

  static String? _nonEmpty(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

  static VideoRange _range(Map<String, dynamic> v) {
    final t = '${v['color_range_type'] ?? ''}'.toLowerCase();
    final dv = ((v['dv_profile'] as num?) ?? 0) > 0;
    if (dv || t.contains('dolby') || t.contains('dovi')) return VideoRange.dolbyVision;
    if (t.contains('hdr10+') || t.contains('hdr10plus')) return VideoRange.hdr10Plus;
    if (t.contains('hlg')) return VideoRange.hlg;
    if (t.contains('hdr')) return VideoRange.hdr10;
    return VideoRange.sdr;
  }

  /// NAS 上的文件：`/media/range/{media_guid}`，带 Authorization 头（播放器的请求头里已有）
  @override
  PlaybackRequest stream(MediaSourceInfo source, {String? playSessionId}) {
    final c = composer;
    final original = c.resolve('$_api/media/range/${source.id}');
    final headers = c.headers(RequestKind.stream);
    return PlaybackRequest(
      url: c.finalUrl(original, RequestKind.stream),
      headers: headers,
      userAgent: headers['User-Agent']!,
    );
  }

  /// 外挂字幕：`/subtitle/dl/{guid}`，要签名
  @override
  PlaybackRequest? subtitle(MediaSourceInfo source, MediaStreamInfo stream) {
    final path = stream.deliveryUrl;
    if (path == null || path.isEmpty) return null;
    final c = composer;
    final headers = {...c.headers(RequestKind.stream), 'Authx': fnosAuthx(path)};
    return PlaybackRequest(
      url: c.finalUrl(c.resolve(path), RequestKind.stream),
      headers: headers,
      userAgent: headers['User-Agent']!,
    );
  }

  /// 播放器加载外挂字幕时只能给地址、带不上签名头：先下载到本机临时文件
  @override
  Future<Uri?> subtitleUri(MediaSourceInfo source, MediaStreamInfo stream) async {
    final path = stream.deliveryUrl;
    if (path == null || path.isEmpty) return null;
    final data = await _request('GET', path, bytes: true);
    if (data is! List<int> || data.isEmpty) throw const MediaServerException('字幕下载失败');
    final ext = stream.codec == null || stream.codec!.isEmpty ? 'srt' : stream.codec!;
    return Uri.file(await saveSubtitleFile(SubtitleFile('${path.split('/').last}.$ext', data)));
  }

  @override
  Future<List<RemoteSubtitle>> searchSubtitles(String itemId, String language) async => const [];

  @override
  Future<void> downloadSubtitle(String itemId, String subtitleId) async =>
      throw const MediaServerException('飞牛影视暂不支持在线下载字幕');

  /// 播放上报：飞牛只有一个 `/play/record`（位置和时长都是秒），开始、进度、停止都发它
  @override
  Future<bool> _sendReport(
    String path,
    MediaSourceInfo s,
    Duration position,
    String? playSessionId, {
    bool paused = false,
    String? event,
  }) async {
    try {
      var guids = _streamGuids[_key(s.id)];
      var duration = s.duration;
      // 重启后补发的停止上报只有条目和文件 ID：重新取一次播放信息，补上流 guid 和时长
      if (guids == null || duration == null) {
        final source = (await playbackInfo(s.itemId, isPlayback: false)).sources.where((x) => x.id == s.id).firstOrNull;
        guids = _streamGuids[_key(s.id)];
        duration ??= source?.duration;
      }
      await _fn(
        'POST',
        '/play/record',
        data: {
          'item_guid': s.itemId,
          'media_guid': s.id,
          'video_guid': guids?.video ?? '',
          'audio_guid': guids?.audio ?? '',
          'subtitle_guid': '',
          'play_link': '',
          'ts': position.inSeconds,
          'duration': duration?.inSeconds ?? 0,
        },
      );
      if (!path.endsWith('/Progress')) debugPrint('fnos record ok ${s.itemId} @${position.inSeconds}s');
      return true;
    } catch (e) {
      debugPrint('fnos record failed: $e');
      return false;
    }
  }

  @override
  Future<void> setPlayed(String itemId, bool played) async {
    forgetItem(itemId);
    await _fn(played ? 'POST' : 'DELETE', '/item/watched', data: {'item_guid': itemId});
    forgetItem(itemId);
  }

  @override
  Future<void> setFavorite(String itemId, bool favorite) async =>
      _fn(favorite ? 'PUT' : 'DELETE', '/item/favorite', data: {'item_guid': itemId});

  // ───────────────────────── 图片 ─────────────────────────

  static ImageRef? _img(String owner, ImageKind kind, Object? path) =>
      path is String && path.isNotEmpty ? ImageRef(owner, kind, tag: path) : null;

  /// [ImageRef.tag] 里存的是飞牛的图片路径（如 /39/09/xxx.webp），`/sys/img` 按宽度缩放，不用登录
  @override
  ({Uri url, Map<String, String> headers}) image(ImageRef ref, {int maxWidth = 440}) {
    final c = composer;
    final path = ref.tag ?? '';
    final original = c.resolve('$_api/sys/img${path.startsWith('/') ? path : '/$path'}', {'w': '$maxWidth'});
    return (url: c.finalUrl(original, RequestKind.image), headers: {'User-Agent': c.userAgentFor(RequestKind.image)});
  }

  // ───────────────────────── 解析 ─────────────────────────

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

  @override
  MediaItem parseItem(Map<String, dynamic> j) {
    final id = '${j['guid']}';
    final type = j['type'] as String?;
    final kind = switch (type) {
      'Movie' => MediaKind.movie,
      'TV' => MediaKind.series,
      'Season' => MediaKind.season,
      'Episode' => MediaKind.episode,
      'Directory' => MediaKind.folder,
      _ => MediaKind.other,
    };
    final premiere = DateTime.tryParse('${j['release_date'] ?? j['air_date'] ?? ''}');
    // duration 是文件时长（秒），runtime 是资料里的片长（分钟）
    final seconds = (j['duration'] as num?)?.toInt() ?? 0;
    final minutes = (j['runtime'] as num?)?.toInt() ?? 0;
    final runtime = seconds > 0
        ? Duration(seconds: seconds)
        : minutes > 0
        ? Duration(minutes: minutes)
        : null;
    final played = (j['watched'] ?? j['is_watched']) == 1;
    final position = Duration(seconds: ((j['ts'] ?? j['watched_ts']) as num?)?.toInt() ?? 0);
    final parent = _str(j['parent_guid']);
    final seriesId = switch (kind) {
      MediaKind.season => parent,
      MediaKind.episode => parent == null ? null : _seasonSeries[_key(parent)],
      _ => null,
    };
    final poster = j['poster'] ?? j['posters'];
    final genreNames = _genreNames[_server.id] ?? const {};
    final rating = double.tryParse('${j['vote_average'] ?? ''}');
    final number = (j['season_number'] as num?)?.toInt();

    return MediaItem(
      serverId: _server.id,
      id: id,
      kind: kind,
      name: kind == MediaKind.season
          ? localizeSeasonName(j['title'] as String? ?? '', number)
          : j['title'] as String? ?? '',
      originalTitle: _str(j['original_title']),
      overview: _str(j['overview']),
      year: premiere?.year,
      premiereDate: premiere,
      rating: rating == null || rating <= 0 ? null : rating,
      genres: [
        for (final g in (j['genres'] as List? ?? const []))
          if (g is num && genreNames[g.toInt()] != null) genreNames[g.toInt()]!,
      ],
      runtime: runtime,
      imdbId: _str(j['imdb_id']),
      primary: _img(id, ImageKind.primary, poster),
      backdrop: _img(id, ImageKind.backdrop, j['backdrops']),
      thumb: kind == MediaKind.episode ? _img(id, ImageKind.thumb, j['still_path'] ?? poster) : null,
      logo: _img(id, ImageKind.logo, j['logos']),
      seriesId: seriesId,
      seriesName: kind == MediaKind.episode ? _str(j['tv_title']) : null,
      seasonId: kind == MediaKind.episode ? parent : null,
      seasonNumber: kind == MediaKind.episode || kind == MediaKind.season ? number : null,
      episodeNumber: kind == MediaKind.episode ? (j['episode_number'] as num?)?.toInt() : null,
      childCount: ((kind == MediaKind.season ? j['local_number_of_episodes'] : j['local_number_of_seasons']) as num?)
          ?.toInt(),
      played: played,
      favorite: j['is_favorite'] == 1,
      position: played ? Duration.zero : position,
      playedPercentage: played || runtime == null || position == Duration.zero
          ? null
          : position.inMilliseconds * 100 / runtime.inMilliseconds,
    );
  }
}

/// 飞牛接口返回的错误（code 不为 0）
class _FnosException extends MediaServerException {
  const _FnosException(super.message, this.code, {super.statusCode});

  final int? code;
}

extension on int {
  int? get nonZero => this == 0 ? null : this;
}
