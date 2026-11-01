/// 折叠后缀剥离（U14）：QQ/微信把汇总通知的标题写成「群名(2条新消息)」，
/// 同一群名因此带着不同数字反复出现，列表很乱。
///
/// 设计：**只改展示，不改数据**——数据库里的标题保持原样（合作者要求原始消息
/// 可作为「参考和查证」），所有 UI 展示处调用本函数。
/// 只剥离**结尾**的「(N条新消息)」或「（N条新消息）」；正文里的「[N条]」前缀
/// 不动（那个更可能是真实内容）。
///
/// 2026-10-20 性能：正则提成顶层常量。原实现每次调用都现编译，
/// 消息列表滚动时每行标题 + 来源行各编译一次。
final RegExp _foldMarkerRe = RegExp(
  r'[（(]\s*\d{1,4}\s*\+?\s*条(?:以上)?\s*(?:新消息|未读消息|未读)\s*[）)]\s*$',
);

String stripFoldMarkers(String title) {
  var v = title.trim();
  if (v.isEmpty) return v;
  // 2026-10-21 D02：QQ 常见「(100条以上新消息)」「(99+条新消息)」，旧正则只认「N条新消息」，
  // 导致群名一直带着计数；这里放宽写法并连续剥离（最多 3 层）。
  for (var i = 0; i < 3; i++) {
    if (!_foldMarkerRe.hasMatch(v)) break;
    final out = v.replaceFirst(_foldMarkerRe, '').trim();
    // 整条标题就只有这个标记时保留原文，避免展示成空
    if (out.isEmpty) return title.trim();
    v = out;
  }
  return v;
}

/// 是否「聊天类」来源：只有聊天类才按会话（群名/联系人）做二级分组，
/// 音乐/天气/电商这类来源的 title 是内容标题（歌名、商品名），拿来当会话名只会制造噪音。
bool isChatSource(String? packageName, String? appName) {
  const chatPackages = {
    'com.tencent.mm', // 微信
    'com.tencent.mobileqq', // QQ
    'com.tencent.tim', // TIM
    'com.tencent.wework', // 企业微信
    'com.alibaba.android.rimet', // 钉钉
    'com.ss.android.lark', // 飞书
    'cn.wps.moffice_eng.xiaomi.lite', // 小米文档（含聊天）
  };
  if (packageName != null && chatPackages.contains(packageName)) return true;
  final n = (appName ?? '').toLowerCase();
  const chatNames = ['微信', 'qq', 'tim', '短信', '信息', '钉钉', '飞书', '企业微信', 'wechat'];
  return chatNames.any((k) => n.contains(k));
}

/// 推导「会话名」（二级分组用）。
///
/// 采集端目前**基本没写 conversation_title**（6848 条里 94.8% 为空），
/// 群名/联系名实际落在 title 里（如「爱灯天文部(5条新消息)」「南邮 梧桐 59 506」），
/// 所以按 conversationTitle → title 的优先级回退，并统一剥掉折叠后缀与「群名: 内容」前缀。
String guessConversationName({
  String? conversationTitle,
  required String title,
  String? sender,
}) {
  String clean(String s) {
    var v = stripFoldMarkers(s).trim();
    // 「某某群: 内容」「某某: 内容」→ 取冒号前（仅当前缀不太长，避免把正文切开）
    final m = RegExp(r'^(.{1,30}?)[:：]\s').firstMatch(v);
    if (m != null) v = m.group(1)!.trim();
    return v;
  }

  final ct = conversationTitle?.trim();
  if (ct != null && ct.isNotEmpty) {
    final v = clean(ct);
    if (v.isNotEmpty) return v;
  }
  final tv = clean(title);
  if (tv.isNotEmpty) return tv;
  final sv = sender?.trim();
  if (sv != null && sv.isNotEmpty) return sv;
  return '其它';
}
