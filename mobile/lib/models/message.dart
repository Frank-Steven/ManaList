import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../services/assistant/models.dart';

/// SHA-256(packageName|title|body|postedAt)，消息入库去重的统一算法。
///
/// v3（design-v3-details §1.4）：参与哈希的正文必须先剥离锚点 marker。
/// strip 内建在本函数里，所有调用点（通知采集入库、导入、手动添加、
/// 编辑保存/锚点插入移除时的重算）天然统一，逐个调用点 strip 反而可能漏。
/// strip 不做空白折叠：追加式 marker 留下的空格差异同样参与哈希。
String computeContentHash(
    String packageName, String title, String body, int postedAt) {
  return sha256
      .convert(
          utf8.encode('$packageName|$title|${stripAnchorMarkers(body)}|$postedAt'))
      .toString();
}

/// 附件访问方式：本地路径 / content URI / 链接 / 小程序路径等，不复制文件内容。
class AttachmentAccess {
  static const typeLocalPath = 'local_path';
  static const typeContentUri = 'content_uri';
  static const typeUrl = 'url';
  static const typeAppDeeplink = 'app_deeplink';
  static const typeMiniprogramPath = 'miniprogram_path';

  final String type;
  final String value;
  final String? mimeType;

  const AttachmentAccess(
      {required this.type, required this.value, this.mimeType});

  factory AttachmentAccess.fromJson(Map<String, dynamic> json) =>
      AttachmentAccess(
        type: json['type'] as String,
        value: json['value'] as String,
        mimeType: json['mimeType'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'value': value,
        if (mimeType != null) 'mimeType': mimeType,
      };
}

class Attachment {
  static const kindImage = 'image';
  static const kindFile = 'file';
  static const kindMiniprogram = 'miniprogram';
  static const kindLink = 'link';
  static const kindOther = 'other';

  final String id;
  final String kind;
  final String? label;
  final AttachmentAccess access;

  /// 文件大小（字节）；旧数据可能为 null。
  final int? bytes;

  const Attachment({
    required this.id,
    required this.kind,
    this.label,
    required this.access,
    this.bytes,
  });

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id'] as String,
        kind: json['kind'] as String,
        label: json['label'] as String?,
        bytes: (json['bytes'] as num?)?.toInt(),
        access:
            AttachmentAccess.fromJson(json['access'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        if (label != null) 'label': label,
        if (bytes != null) 'bytes': bytes,
        'access': access.toJson(),
      };
}

/// v2 消息状态：pending（未处理）→ processed（已评估）→ archived（归档）。
class MessageStatus {
  static const pending = 'pending';
  static const processed = 'processed';
  static const archived = 'archived';
}

/// v2 消息优先级：红=重要、黄=值得关注、绿=一般、junk=垃圾、none=未评估。
class MessagePriority {
  static const none = 'none';
  static const red = 'red';
  static const yellow = 'yellow';
  static const green = 'green';
  static const junk = 'junk';
}

/// v2 消息模型，对应设计文档 §1.1 的 messages 表。
class Message {
  final String id;
  final String packageName;
  final String? appName;
  final String? channelId;
  final String? conversationTitle;
  final String? sender;
  final String title;
  final String body;
  final int postedAt;
  final String captureType;
  final String? importSource;
  final List<Attachment> attachments;
  final String contentHash;
  final String status;
  final String priority;

  /// v2 遗留的 1:1 关联列。v8 起关联落 task_anchors，本列只读保留
  /// （历史数据展示），不再写入新值。
  final String? linkedTaskId;
  final int createdAt;

  const Message({
    required this.id,
    required this.packageName,
    this.appName,
    this.channelId,
    this.conversationTitle,
    this.sender,
    required this.title,
    required this.body,
    required this.postedAt,
    required this.captureType,
    this.importSource,
    this.attachments = const [],
    required this.contentHash,
    this.status = MessageStatus.pending,
    this.priority = MessagePriority.none,
    this.linkedTaskId,
    required this.createdAt,
  });

  factory Message.fromRow(Map<String, Object?> row) => Message(
        id: row['id'] as String,
        packageName: row['package_name'] as String,
        appName: row['app_name'] as String?,
        channelId: row['channel_id'] as String?,
        conversationTitle: row['conversation_title'] as String?,
        sender: row['sender'] as String?,
        title: row['title'] as String,
        body: row['body'] as String,
        postedAt: (row['posted_at'] as num).toInt(),
        captureType: row['capture_type'] as String,
        importSource: row['import_source'] as String?,
        attachments: (jsonDecode(row['attachments'] as String) as List)
            .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
            .toList(),
        contentHash: row['content_hash'] as String,
        status: row['status'] as String,
        priority: row['priority'] as String,
        linkedTaskId: row['linked_task_id'] as String?,
        createdAt: (row['created_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'package_name': packageName,
        'app_name': appName,
        'channel_id': channelId,
        'conversation_title': conversationTitle,
        'sender': sender,
        'title': title,
        'body': body,
        'posted_at': postedAt,
        'capture_type': captureType,
        'import_source': importSource,
        'attachments': jsonEncode(attachments.map((e) => e.toJson()).toList()),
        'content_hash': contentHash,
        'status': status,
        'priority': priority,
        'linked_task_id': linkedTaskId,
        'created_at': createdAt,
      };

  Message copyWith({
    String? id,
    String? packageName,
    String? Function()? appName,
    String? Function()? channelId,
    String? Function()? conversationTitle,
    String? Function()? sender,
    String? title,
    String? body,
    int? postedAt,
    String? captureType,
    String? Function()? importSource,
    List<Attachment>? attachments,
    String? contentHash,
    String? status,
    String? priority,
    String? Function()? linkedTaskId,
    int? createdAt,
  }) =>
      Message(
        id: id ?? this.id,
        packageName: packageName ?? this.packageName,
        appName: appName != null ? appName() : this.appName,
        channelId: channelId != null ? channelId() : this.channelId,
        conversationTitle: conversationTitle != null
            ? conversationTitle()
            : this.conversationTitle,
        sender: sender != null ? sender() : this.sender,
        title: title ?? this.title,
        body: body ?? this.body,
        postedAt: postedAt ?? this.postedAt,
        captureType: captureType ?? this.captureType,
        importSource: importSource != null ? importSource() : this.importSource,
        attachments: attachments ?? this.attachments,
        contentHash: contentHash ?? this.contentHash,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        linkedTaskId: linkedTaskId != null ? linkedTaskId() : this.linkedTaskId,
        createdAt: createdAt ?? this.createdAt,
      );
}
