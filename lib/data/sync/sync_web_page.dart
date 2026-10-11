import 'dart:convert';

/// 手机扫码后打开的配置网页（电视在局域网里提供，不依赖任何外部资源）。
/// 填写的内容打包成和 Windows「发送到电视」相同的格式（见 config_payload.dart）。
String syncWebPage({required String deviceName}) {
  final name = const HtmlEscape().convert(deviceName);
  return '''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Viora · 导入配置</title>
<style>
  :root { color-scheme: dark; --bg:#0b0c10; --card:#16181f; --line:#262a33; --text:#f2f3f5; --sub:#9aa0aa; --accent:#5b8cff; --ok:#7be07b; --bad:#ff7b7b; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:16px/1.5 -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", sans-serif; }
  main { max-width:560px; margin:0 auto; padding:20px 16px 120px; }
  h1 { font-size:24px; margin:8px 0 4px; }
  .sub { color:var(--sub); font-size:14px; margin:0 0 20px; }
  section { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:16px; margin:0 0 16px; }
  h2 { font-size:17px; margin:0 0 12px; display:flex; justify-content:space-between; align-items:center; }
  label { display:block; font-size:13px; color:var(--sub); margin:10px 0 4px; }
  input, select, textarea { width:100%; padding:11px 12px; border-radius:10px; border:1px solid var(--line); background:#0f1116; color:var(--text); font-size:16px; }
  textarea { min-height:70px; resize:vertical; }
  .row { display:flex; gap:10px; } .row > * { flex:1; }
  .check { display:flex; align-items:center; gap:8px; margin-top:10px; font-size:14px; color:var(--text); }
  .check input { width:auto; }
  .server { border-top:1px dashed var(--line); padding-top:12px; margin-top:12px; }
  .server:first-of-type { border-top:none; padding-top:0; margin-top:0; }
  button { border:0; border-radius:12px; padding:12px 16px; font-size:16px; font-weight:600; color:#fff; background:#2a2e38; }
  button.primary { background:var(--accent); width:100%; padding:15px; font-size:17px; }
  button.link { background:none; color:var(--accent); padding:4px 0; font-weight:500; font-size:14px; }
  .hint { color:var(--sub); font-size:13px; margin:6px 0 0; }
  #code { font-size:24px; letter-spacing:8px; text-align:center; }
  .bar { position:fixed; left:0; right:0; bottom:0; padding:12px 16px calc(12px + env(safe-area-inset-bottom)); background:rgba(11,12,16,.92); backdrop-filter:blur(12px); border-top:1px solid var(--line); }
  .bar > div { max-width:560px; margin:0 auto; }
  #msg { font-size:14px; margin:0 0 8px; min-height:1em; }
  .ok { color:var(--ok); } .bad { color:var(--bad); }
</style>
</head>
<body>
<main>
  <h1>导入配置到 $name</h1>
  <p class="sub">填写的内容会直接发送到电视（只在局域网内传输）。没用到的项目留空即可，可以多次提交。</p>

  <section>
    <h2>配对码</h2>
    <input id="code" inputmode="numeric" maxlength="4" placeholder="电视上的 4 位数字">
  </section>

  <section>
    <h2>媒体服务器 <button class="link" type="button" onclick="addServer()">＋ 再加一台</button></h2>
    <div id="servers"></div>
  </section>

  <section>
    <h2>反向代理与播放 UA</h2>
    <label>反向代理地址（emby-reverse-proxy-go）</label>
    <input id="proxy" type="url" placeholder="https://embyproxy.example.com/proxy/">
    <label>播放 UA</label>
    <input id="ua" placeholder="留空使用默认">
  </section>

  <section>
    <h2>TMDB</h2>
    <label>API Key 或读取令牌</label>
    <input id="tmdb" autocomplete="off">
  </section>

  <section>
    <h2>外部评分</h2>
    <label>OMDb API Key（也可粘贴示例链接）</label>
    <input id="omdb" type="password" autocapitalize="off" autocomplete="off">
    <label>Trakt Client ID</label>
    <input id="trakt" autocapitalize="off" autocomplete="off">
  </section>

  <section>
    <h2>弹幕服务器</h2>
    <label>danmu_api 地址，一行一个（最多 3 个）</label>
    <textarea id="danmu" placeholder="https://danmu.example.com/87654321"></textarea>
  </section>

  <section>
    <h2>WebDAV 同步（可选）</h2>
    <label>填好后电视会从 WebDAV 下载其他设备上传的全部配置，之后自动保持同步</label>
    <input id="davurl" type="url" placeholder="https://dav.jianguoyun.com/dav/">
    <div class="row">
      <div><label>用户名</label><input id="davuser" autocapitalize="off" autocomplete="off"></div>
      <div><label>密码</label><input id="davpass" type="password" autocomplete="off"></div>
    </div>
    <label>加密口令（其他设备设置了才填）</label>
    <input id="davphrase" type="password" autocomplete="off">
  </section>

  <section>
    <h2>片头片尾</h2>
    <label>TheIntroDB API Key</label>
    <input id="theintrodb" autocomplete="off">
    <label>IntroDB API Key</label>
    <input id="introdb" autocomplete="off">
  </section>
</main>

<div class="bar"><div>
  <p id="msg"></p>
  <button class="primary" id="send" type="button" onclick="send()">发送到电视</button>
</div></div>

<template id="tpl">
  <div class="server">
    <div class="row">
      <div><label>类型</label><select data-k="type"><option value="emby">Emby</option><option value="jellyfin">Jellyfin</option></select></div>
      <div><label>名称（可留空）</label><input data-k="name"></div>
    </div>
    <label>地址（多条线路一行一个，第一条为主线路）</label>
    <textarea data-k="urls" placeholder="https://emby.example.com:8920"></textarea>
    <div class="row">
      <div><label>用户名</label><input data-k="username" autocapitalize="off" autocomplete="off"></div>
      <div><label>密码</label><input data-k="password" type="password" autocomplete="off"></div>
    </div>
    <label class="check"><input type="checkbox" data-k="proxied"> 走反向代理</label>
    <button class="link" type="button" onclick="this.parentElement.remove()">删除这台</button>
  </div>
</template>

<script>
  const q = new URLSearchParams(location.search);
  document.getElementById('code').value = q.get('code') || '';
  function addServer() {
    document.getElementById('servers').appendChild(document.getElementById('tpl').content.cloneNode(true));
  }
  addServer();
  const val = (id) => document.getElementById(id).value.trim();
  function payload() {
    const p = { viora: 1, from: '手机网页' };
    const servers = [];
    document.querySelectorAll('.server').forEach((el) => {
      const f = (k) => el.querySelector('[data-k="' + k + '"]');
      const urls = f('urls').value.split(/\\n+/).map((s) => s.trim()).filter(Boolean);
      if (!urls.length) return;
      servers.push({
        type: f('type').value, name: f('name').value.trim(),
        lines: urls.map((u, i) => ({ name: i === 0 ? '主线路' : '线路 ' + (i + 1), url: u, proxied: f('proxied').checked })),
        username: f('username').value.trim(), password: f('password').value,
      });
    });
    if (servers.length) p.servers = servers;
    if (val('proxy')) p.proxy = { baseUrl: val('proxy') };
    if (val('ua')) p.playback = { userAgent: val('ua') };
    if (val('tmdb')) p.tmdb = { apiKey: val('tmdb') };
    const ratingKeys = {};
    if (val('omdb')) ratingKeys.omdb = val('omdb');
    if (val('trakt')) ratingKeys.trakt = val('trakt');
    if (Object.keys(ratingKeys).length) p.ratings = { keys: ratingKeys };
    const danmu = val('danmu').split(/\\n+/).map((s) => s.trim()).filter(Boolean).slice(0, 3);
    if (danmu.length) p.danmaku = { servers: danmu };
    const keys = {};
    if (val('theintrodb')) keys.theintrodb = val('theintrodb');
    if (val('introdb')) keys.introdb = val('introdb');
    if (Object.keys(keys).length) p.segments = { keys };
    if (val('davurl')) {
      p.webdav = { url: val('davurl'), username: val('davuser'), password: document.getElementById('davpass').value,
        passphrase: document.getElementById('davphrase').value, autoSync: true };
    }
    return p;
  }
  async function send() {
    const msg = document.getElementById('msg'), btn = document.getElementById('send');
    const p = payload();
    if (Object.keys(p).length <= 2) { msg.className = 'bad'; msg.textContent = '还没有填写任何内容'; return; }
    btn.disabled = true; msg.className = ''; msg.textContent = '正在发送…';
    try {
      const r = await fetch('/viora/import', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: val('code'), payload: p }) });
      const j = await r.json();
      msg.className = r.ok ? 'ok' : 'bad';
      msg.textContent = r.ok ? '已发送：' + j.message : j.error;
    } catch (e) {
      msg.className = 'bad'; msg.textContent = '发送失败：电视上的导入页面可能已经关闭';
    } finally { btn.disabled = false; }
  }
</script>
</body>
</html>''';
}
