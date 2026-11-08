import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../models/library_file.dart';
import '../models/message.dart';
import '../models/note.dart';
import '../models/task.dart';
import 'anchor_service.dart';
import 'app_log.dart';
import 'assistant/models.dart';
import 'reminder_service.dart';

/// 收件箱按应用筛选用的来源应用项。
class SourceApp {
  final String packageName;
  final String? appName;

  const SourceApp(this.packageName, this.appName);

  String get displayName =>
      (appName != null && appName!.isNotEmpty) ? appName! : packageName;
}

List<String> _stringList(dynamic v) =>
    v == null ? const [] : (v as List).map((e) => e.toString()).toList();

int? _intOrNull(dynamic v) => v == null ? null : (v as num).toInt();

/// 本地 SQLite 存储（设计 §1，DB v5）：messages / tasks / 笔记三级为主表；
/// v1 的 raw_messages / structured_items 旧表保留不删（只删了读写代码）。
///
/// v6 的 message_task_links 表在 v8 被 task_anchors 取代并 DROP；
/// 以下两个函数仅保留给 v5→v6 升级链使用（全新安装不再建 links 表）。
Future<void> createMessageTaskLinksTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS message_task_links(
      message_id TEXT NOT NULL,
      task_id TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY(message_id, task_id)
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_links_task ON message_task_links(task_id)');
}

/// v5 → v6 数据迁移：把旧的 1:1 绑定（messages.linked_task_id 与
/// tasks.source_message_id 两个方向）灌进关联表。旧的列保留不删（兼容只读回放）。
Future<void> migrateLinksToV6(DatabaseExecutor db) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.rawInsert('''
    INSERT OR IGNORE INTO message_task_links(message_id, task_id, created_at)
    SELECT id, linked_task_id, ? FROM messages WHERE linked_task_id IS NOT NULL
  ''', [now]);
  await db.rawInsert('''
    INSERT OR IGNORE INTO message_task_links(message_id, task_id, created_at)
    SELECT source_message_id, id, ? FROM tasks WHERE source_message_id IS NOT NULL
  ''', [now]);
}

/// DB v8 建表（design-v3 §1.1/§1.3/§1.4）：task_anchors / files /
/// conversations / chat_messages / change_proposals。onCreate 与 v8 迁移共用。
///
/// v9 起初始建表直接带上新列（files.folder、conversations.draft_attachments）；
/// 老库升级链走 [migrateToV9] 的幂等 ALTER（先查 PRAGMA 再加列），两条路径收敛。
Future<void> createV8Tables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS task_anchors(
      id TEXT PRIMARY KEY,
      task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      label TEXT,
      created_by TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_anchors_task ON task_anchors(task_id)');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_anchors_target ON task_anchors(target_type, target_id)');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS files(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      mime_type TEXT,
      size INTEGER,
      local_path TEXT NOT NULL,
      source TEXT NOT NULL,
      folder TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS conversations(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      model_config_id TEXT,
      draft_attachments TEXT NOT NULL DEFAULT '[]',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS chat_messages(
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      attachments TEXT,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS change_proposals(
      id TEXT PRIMARY KEY,
      conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
      batch_id TEXT,
      tool TEXT NOT NULL,
      summary TEXT NOT NULL,
      payload TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      resolved_at INTEGER
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_proposals_status ON change_proposals(status)');
}

/// v7 → v8 迁移（design-v3 §1.5）：message_task_links 全量行 +
/// messages.linked_task_id 非空行 → task_anchors（按 (message_id, task_id)
/// 去重，悬挂引用跳过），marker 以空格分隔追加到对应消息正文末尾；
/// 完成后 DROP message_task_links；notes 加 attachments 列。
///
/// 锚点 id 为新的小写 uuid，created_by='user'，label 取任务标题快照。
/// content_hash 不在此重算：迁移产生的尾部空格差异不应改变既有去重语义
/// （details §1.4 的重算只约束编辑与锚点插入/移除路径）。
Future<void> migrateToV8(DatabaseExecutor db) async {
  await createV8Tables(db);

  final taskTitles = {
    for (final r in await db.query('tasks', columns: ['id', 'title']))
      r['id'] as String: r['title'] as String,
  };
  final messageRows =
      await db.query('messages', columns: ['id', 'body', 'created_at', 'linked_task_id']);
  final bodies = {for (final r in messageRows) r['id'] as String: r['body'] as String};

  // (messageId, taskId, createdAt)，按关联创建时间升序收集、去重、悬挂跳过
  final pairs = <(String, String, int)>[];
  final seen = <String>{};
  void add(String messageId, String taskId, int createdAt) {
    if (!seen.add('$messageId|$taskId')) return;
    if (!taskTitles.containsKey(taskId)) return; // 任务已删：悬挂引用
    if (!bodies.containsKey(messageId)) return; // 消息已删：悬挂引用
    pairs.add((messageId, taskId, createdAt));
  }

  final linkRows =
      await db.query('message_task_links', orderBy: 'created_at ASC');
  for (final r in linkRows) {
    add(r['message_id'] as String, r['task_id'] as String,
        (r['created_at'] as num).toInt());
  }
  for (final r in messageRows) {
    final linked = r['linked_task_id'] as String?;
    if (linked != null) {
      add(r['id'] as String, linked, (r['created_at'] as num).toInt());
    }
  }

  const uuid = Uuid();
  final markersByMessage = <String, List<String>>{};
  for (final (messageId, taskId, createdAt) in pairs) {
    final anchorId = uuid.v4();
    await db.insert('task_anchors', {
      'id': anchorId,
      'task_id': taskId,
      'target_type': AnchorTargetType.message,
      'target_id': messageId,
      'label': taskTitles[taskId],
      'created_by': AnchorCreatedBy.user,
      'created_at': createdAt,
    });
    markersByMessage
        .putIfAbsent(messageId, () => [])
        .add(anchorMarker(anchorId));
  }
  for (final entry in markersByMessage.entries) {
    final body = bodies[entry.key]!;
    final markers = entry.value.join(' ');
    await db.update(
      'messages',
      {'body': body.isEmpty ? markers : '$body $markers'},
      where: 'id = ?',
      whereArgs: [entry.key],
    );
  }

  await db.execute('DROP TABLE message_task_links');
  // 升级链上 notes 可能是新建的（已带 attachments 列），先查再加。
  final noteCols = await db.rawQuery('PRAGMA table_info(notes)');
  if (!noteCols.any((c) => c['name'] == 'attachments')) {
    await db.execute(
        "ALTER TABLE notes ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'");
  }
}

/// v8 → v9 迁移：files 加 folder 列（路径式虚拟文件夹，'' = 根目录）；
/// conversations 加 draft_attachments 列（草稿附件 JSON 数组 [{type,id}]，
/// 库页「发送给助理」与对话页附件选择器的落点，发送后清空）。
/// 幂等：先查 PRAGMA 再 ALTER，初始建表（createV8Tables）已带新列时不重复加。
Future<void> migrateToV9(DatabaseExecutor db) async {
  final fileCols = await db.rawQuery('PRAGMA table_info(files)');
  if (!fileCols.any((c) => c['name'] == 'folder')) {
    await db.execute(
        "ALTER TABLE files ADD COLUMN folder TEXT NOT NULL DEFAULT ''");
  }
  final convCols = await db.rawQuery('PRAGMA table_info(conversations)');
  if (!convCols.any((c) => c['name'] == 'draft_attachments')) {
    await db.execute(
        "ALTER TABLE conversations ADD COLUMN draft_attachments TEXT NOT NULL DEFAULT '[]'");
  }
}

/// v9 → v10 迁移：library_folders 表（空文件夹持久化，2026-11-01）。
/// v9 的文件夹只由文件 folder 字段派生（虚拟），会话内新建的空文件夹
/// 重启即丢；v10 起新建文件夹落表，列表/移动选择器派生时与文件
/// folder 字段取并集（空文件夹删除 = 删表内行）。
Future<void> migrateToV10(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS library_folders(
      path TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL
    )
  ''');
}

/// 批量入库的分块大小：SQLite 的绑定变量上限（老版本 999），留足余量。
const int kMessageHashLookupChunk = 400;

/// 「按 contentHash 去重后批量插入」的事务内实现（O03，2026-10-21）。
///
/// 语义与**逐条**调用 [AppDatabase.insertMessageIfNew] 等价：
/// - 批内同一个 contentHash 只留**第一条**（先到先得，与逐条 check-then-insert 一致）；
/// - 库里已存在的 hash 跳过（不覆盖、不更新）；
/// - 插入顺序 = 入参顺序（rowid 递增，保证与队列文件读取顺序一致）。
///
/// 拆成顶层函数（而不是直接写在 AppDatabase 里）是为了能用 sqflite_common_ffi
/// 直接单测，不依赖 AppDatabase 单例与迁移链。调用方负责提供事务——
/// [AppDatabase.insertMessagesIfNew] 就是 `db.transaction(...)` 包一层。
///
/// 返回实际新增条数（被跳过的不计）。
Future<int> insertMessagesIfNewInto(
    DatabaseExecutor txn, List<Message> messages) async {
  if (messages.isEmpty) return 0;

  // 1) 批内去重：同 hash 只留第一条，避免同一批里的重复通知被插两次
  final seenHashes = <String>{};
  final candidates = <Message>[];
  for (final m in messages) {
    if (seenHashes.add(m.contentHash)) candidates.add(m);
  }

  // 2) 一次查出库中已存在的 hash（分块，避免超出 SQLite 绑定变量上限）
  final existing = <String>{};
  for (var i = 0; i < candidates.length; i += kMessageHashLookupChunk) {
    final end = i + kMessageHashLookupChunk <= candidates.length
        ? i + kMessageHashLookupChunk
        : candidates.length;
    final part = <String>[
      for (var j = i; j < end; j++) candidates[j].contentHash,
    ];
    final rows = await txn.query('messages',
        columns: ['content_hash'],
        where: 'content_hash IN (${List.filled(part.length, '?').join(',')})',
        whereArgs: part);
    for (final r in rows) {
      existing.add(r['content_hash'] as String);
    }
  }

  // 3) 只插新的（batch = 事务内的多条 insert，一次性提交）
  final batch = txn.batch();
  var inserted = 0;
  for (final m in candidates) {
    if (existing.contains(m.contentHash)) continue;
    batch.insert('messages', m.toRow());
    inserted++;
  }
  if (inserted > 0) await batch.commit(noResult: true);
  return inserted;
}

/// 删除任务撤销快照中的一条受影响正文（[AppDatabase.snapshotTaskDeletion]）。
///
/// message → body 原文 + edited_at 原值；note → content 原文 + updated_at 原值
///（统一放在 [editedAt] 字段）。撤销时整段原文回写，marker 精确复原，
/// 消息的 content_hash 由原文重算（同一输入天然复原），留痕字段写回原值。
class TaskDeletionBodySnapshot {
  final String targetType; // AnchorTargetType.message | note
  final String targetId;

  /// 删除前的正文原文（含 ⟦task:id⟧ marker，未残迹化）。
  final String content;

  /// 删除前的留痕字段原值：message.edited_at / note.updated_at。
  final int? editedAt;

  const TaskDeletionBodySnapshot({
    required this.targetType,
    required this.targetId,
    required this.content,
    required this.editedAt,
  });

  factory TaskDeletionBodySnapshot.fromJson(Map<String, dynamic> json) =>
      TaskDeletionBodySnapshot(
        targetType: json['targetType'] as String,
        targetId: json['targetId'] as String,
        content: json['content'] as String,
        editedAt: (json['editedAt'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'targetType': targetType,
        'targetId': targetId,
        'content': content,
        'editedAt': editedAt,
      };
}

/// 删除任务的撤销快照（details §1.5 撤销补全）：任务行由调用方持有，
/// 本快照覆盖 [AppDatabase.deleteTasks] 事务内被改写的其余状态 ——
/// 该任务的全部 task_anchors 行 + 所有受影响正文（notes.content /
/// messages.body）的原文与留痕原值。file 锚点不入正文，只记行。
class TaskDeletionSnapshot {
  final List<TaskAnchor> anchors;
  final List<TaskDeletionBodySnapshot> bodies;

  const TaskDeletionSnapshot({required this.anchors, required this.bodies});

  factory TaskDeletionSnapshot.fromJson(Map<String, dynamic> json) =>
      TaskDeletionSnapshot(
        anchors: [
          for (final a in (json['anchors'] as List?) ?? const [])
            TaskAnchor.fromJson((a as Map).cast<String, dynamic>()),
        ],
        bodies: [
          for (final b in (json['bodies'] as List?) ?? const [])
            TaskDeletionBodySnapshot.fromJson(
                (b as Map).cast<String, dynamic>()),
        ],
      );

  Map<String, dynamic> toJson() => {
        'anchors': [for (final a in anchors) a.toJson()],
        'bodies': [for (final b in bodies) b.toJson()],
      };
}

class AppDatabase {
  AppDatabase._();

  /// 列表默认上限（P3-8）：超出时调用方应提示「仅显示前 N 条」而不是静默截断。
  static const defaultMessageLimit = 500;
  static const defaultTaskLimit = 1000;

  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  /// 测试注入：让 confirm 等写库路径跑内存 SQLite，而不是真机库。
  @visibleForTesting
  void debugAttachDatabase(Database db) => _db = db;

  @visibleForTesting
  void debugDetachDatabase() => _db = null;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'msgrepo.db'),
      version: 10,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE raw_messages ADD COLUMN needs_reprocess INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 3) {
      await _splitFoldedMessages(db);
    }
    if (oldVersion < 4) {
      await _createV4Tables(db);
      await _migrateV3ToV4(db);
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE tasks ADD COLUMN parent_id TEXT');
    }
    if (oldVersion < 6) {
      // N1：消息 ↔ 任务从 1:1 升级为多对多（一条消息可产多个任务，多条消息可指向同一任务）
      await createMessageTaskLinksTable(db);
      await migrateLinksToV6(db);
    }
    if (oldVersion < 7) {
      // v7（2026-10-21，F07）：记录用户手动编辑正文/附件的时间，NULL = 采集原文。
      await db.execute('ALTER TABLE messages ADD COLUMN edited_at INTEGER');
    }
    if (oldVersion < 8) {
      // v8（design-v3 §1.5）：任务锚点/文件/对话/提案；links → 锚点迁移。
      await migrateToV8(db);
    }
    if (oldVersion < 9) {
      // v9：files.folder（虚拟文件夹）+ conversations.draft_attachments（草稿附件）。
      await migrateToV9(db);
    }
    if (oldVersion < 10) {
      // v10：library_folders（空文件夹持久化）。
      await migrateToV10(db);
    }
  }

  /// 拆分系统折叠通知留下的存量消息：body 形如 "[5条]周辰羽: 。"、
  /// 标题形如 "26软工班长们的窝(3条新消息)"。折叠层里被盖住的历史消息无法找回，
  /// 这里把每条快照还原成它携带的最新一条（去前缀、解析 sender、重算 content_hash）。
  Future<void> _splitFoldedMessages(Database db) async {
    final foldBody = RegExp(r'^\[(\d+)条\]');
    final foldTitle = RegExp(r'\(\d+条新消息\)$');
    final senderPrefix = RegExp(r'^([^:：\n]{1,30})[:：]\s*');
    final rows = await db.query('raw_messages',
        columns: ['id', 'package_name', 'title', 'body', 'posted_at', 'sender'],
        where: "body LIKE '[%条]%' OR title LIKE '%(%条新消息)'");
    for (final row in rows) {
      var title = row['title'] as String;
      var body = row['body'] as String;
      String? sender = row['sender'] as String?;
      final newTitle = title.replaceFirst(foldTitle, '');
      var newBody = body.replaceFirst(foldBody, '');
      if (sender == null) {
        final m = senderPrefix.firstMatch(newBody);
        if (m != null) sender = m.group(1);
      }
      if (newTitle == title && newBody == body) continue;
      await db.update(
        'raw_messages',
        {
          'title': newTitle,
          'body': newBody,
          'sender': sender,
          'content_hash': computeContentHash(row['package_name'] as String,
              newTitle, newBody, row['posted_at'] as int),
        },
        where: 'id = ?',
        whereArgs: [row['id']],
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE raw_messages(
        id TEXT PRIMARY KEY,
        package_name TEXT NOT NULL,
        app_name TEXT,
        channel_id TEXT,
        conversation_title TEXT,
        sender TEXT,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        posted_at INTEGER NOT NULL,
        capture_type TEXT NOT NULL,
        attachments TEXT NOT NULL DEFAULT '[]',
        content_hash TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL DEFAULT 'pending',
        needs_reprocess INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_raw_messages_status ON raw_messages(status)');
    await db.execute(
        'CREATE INDEX idx_raw_messages_posted_at ON raw_messages(posted_at)');
    await db.execute('''
      CREATE TABLE structured_items(
        id TEXT PRIMARY KEY,
        raw_message_ids TEXT NOT NULL,
        category TEXT NOT NULL,
        schema_version TEXT NOT NULL,
        title TEXT NOT NULL,
        summary TEXT NOT NULL,
        priority TEXT NOT NULL,
        confidence REAL NOT NULL,
        time TEXT NOT NULL,
        payload TEXT NOT NULL,
        tags TEXT NOT NULL DEFAULT '[]',
        processed_by TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await _createV4Tables(db);
    await createV8Tables(db);
    // v10 起初始建库直接带上 library_folders（与老库升级链收敛）
    await migrateToV10(db);
  }

  /// v2 数据层建表（设计 §1.1 messages、§1.2 tasks、§1.3 笔记三级）。
  Future<void> _createV4Tables(Database db) async {
    await db.execute('''
      CREATE TABLE messages(
        id TEXT PRIMARY KEY,
        package_name TEXT NOT NULL,
        app_name TEXT,
        channel_id TEXT,
        conversation_title TEXT,
        sender TEXT,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        posted_at INTEGER NOT NULL,
        capture_type TEXT NOT NULL,
        import_source TEXT,
        attachments TEXT NOT NULL DEFAULT '[]',
        content_hash TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL DEFAULT 'pending',
        priority TEXT NOT NULL DEFAULT 'none',
        linked_task_id TEXT,
        edited_at INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_messages_status ON messages(status)');
    await db
        .execute('CREATE INDEX idx_messages_posted_at ON messages(posted_at)');
    await db.execute('''
      CREATE TABLE tasks(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        kind TEXT NOT NULL,
        start_at INTEGER,
        end_at INTEGER,
        priority TEXT NOT NULL DEFAULT 'normal',
        is_annual INTEGER NOT NULL DEFAULT 0,
        source_message_id TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        parent_id TEXT
      )
    ''');
    await db.execute('CREATE INDEX idx_tasks_start ON tasks(start_at)');
    await db.execute('CREATE INDEX idx_tasks_status ON tasks(status)');
    await db.execute('''
      CREATE TABLE notebooks(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sort INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE chapters(
        id TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL REFERENCES notebooks(id),
        name TEXT NOT NULL,
        sort INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE notes(
        id TEXT PRIMARY KEY,
        chapter_id TEXT NOT NULL REFERENCES chapters(id),
        title TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        content_format TEXT NOT NULL DEFAULT 'plain',
        attachments TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// v3 → v4 迁移：只增不删，旧表（raw_messages / structured_items）原样保留。
  Future<void> _migrateV3ToV4(Database db) async {
    // 1. messageId → priority 映射：P0/P1→red、P2→yellow、P3→green；
    //    一条消息被多条条目引用时取更高优先级（red > yellow > green）。
    const rank = {'red': 3, 'yellow': 2, 'green': 1};
    String? itemPriorityToMessage(String p) => switch (p) {
          'P0' || 'P1' => 'red',
          'P2' => 'yellow',
          'P3' => 'green',
          _ => null,
        };
    String itemPriorityToTask(String p) => switch (p) {
          'P0' => 'important',
          'P1' || 'P2' => 'normal',
          _ => 'minor',
        };
    final items = await db.query('structured_items');
    final messagePriorities = <String, String>{};
    for (final row in items) {
      final mapped = itemPriorityToMessage(row['priority'] as String);
      if (mapped == null) continue;
      final ids = _stringList(jsonDecode(row['raw_message_ids'] as String));
      for (final id in ids) {
        final existing = messagePriorities[id];
        if (existing == null || rank[mapped]! > rank[existing]!) {
          messagePriorities[id] = mapped;
        }
      }
    }

    // 2. raw_messages 全量复制进 messages（status 原样、priority 用映射）。
    final rawMessages = await db.query('raw_messages');
    for (final row in rawMessages) {
      await db.insert(
        'messages',
        {
          'id': row['id'],
          'package_name': row['package_name'],
          'app_name': row['app_name'],
          'channel_id': row['channel_id'],
          'conversation_title': row['conversation_title'],
          'sender': row['sender'],
          'title': row['title'],
          'body': row['body'],
          'posted_at': row['posted_at'],
          'capture_type': row['capture_type'],
          'import_source': null,
          'attachments': row['attachments'],
          'content_hash': row['content_hash'],
          'status': row['status'],
          'priority':
              messagePriorities[row['id'] as String] ?? MessagePriority.none,
          'linked_task_id': null,
          'created_at': row['created_at'],
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    // 3/4. structured_items 按 category 分流：todo/schedule → tasks，
    //      note → 默认笔记本「导入」章节「AI 笔记」下的 notes，其他不动。
    const importNotebookId = 'nb-import';
    const aiNotesChapterId = 'ch-ai-notes';
    for (final row in items) {
      final category = row['category'] as String;
      if (category == 'todo' || category == 'schedule') {
        // v1 time 对象（structured-item.schema.json）→ v2 kind/startAt/endAt
        final time =
            (jsonDecode(row['time'] as String) as Map).cast<String, dynamic>();
        String kind;
        int? startAt;
        int? endAt;
        switch (time['kind']) {
          case 'point':
            kind = TaskKind.point;
            startAt = _intOrNull(time['startAt']);
          case 'deadline':
            kind = TaskKind.point;
            startAt = _intOrNull(time['deadline']);
          case 'range':
            kind = TaskKind.range;
            startAt = _intOrNull(time['startAt']);
            endAt = _intOrNull(time['endAt']);
          default:
            kind = TaskKind.point;
        }
        final rawIds =
            _stringList(jsonDecode(row['raw_message_ids'] as String));
        final createdAt = (row['created_at'] as num).toInt();
        await db.insert(
          'tasks',
          {
            'id': row['id'],
            'title': row['title'],
            'description': row['summary'],
            'kind': kind,
            'start_at': startAt,
            'end_at': endAt,
            'priority': itemPriorityToTask(row['priority'] as String),
            'is_annual': 0,
            'source_message_id': rawIds.isEmpty ? null : rawIds.first,
            'status': TaskStatus.active,
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      } else if (category == 'note') {
        final now = DateTime.now().millisecondsSinceEpoch;
        await db.insert(
          'notebooks',
          {'id': importNotebookId, 'name': '导入', 'sort': 0, 'created_at': now},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await db.insert(
          'chapters',
          {
            'id': aiNotesChapterId,
            'notebook_id': importNotebookId,
            'name': 'AI 笔记',
            'sort': 0,
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final createdAt = (row['created_at'] as num).toInt();
        await db.insert(
          'notes',
          {
            'id': row['id'],
            'chapter_id': aiNotesChapterId,
            'title': row['title'],
            'content': row['summary'],
            'content_format': 'plain',
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }

  // ---- v2: messages ----

  /// 入库前按 contentHash 查重；返回是否为新插入。
  Future<bool> insertMessageIfNew(Message message) async {
    final db = await database;
    final rows = await db.query('messages',
        columns: ['id'],
        where: 'content_hash = ?',
        whereArgs: [message.contentHash],
        limit: 1);
    if (rows.isNotEmpty) return false;
    await db.insert('messages', message.toRow());
    return true;
  }

  /// 批量「去重后插入」，**整批一个事务**（O03，2026-10-21）：通知队列一次拉取
  /// 往往有几十上百个文件，原来每个文件一次 `insertMessageIfNew`（一次查重 +
  /// 一次插入，各自隐式事务）= N 次 SQL 往返；现在变成 1 次事务（内含分块的
  /// IN 查重 + 一次 batch insert）。返回实际新增条数。
  ///
  /// 去重/顺序语义见 [insertMessagesIfNewInto]。
  Future<int> insertMessagesIfNew(List<Message> messages) async {
    if (messages.isEmpty) return 0;
    final db = await database;
    return db.transaction((txn) => insertMessagesIfNewInto(txn, messages));
  }

  /// 全部消息的 content_hash 集（批量导入一次性查重用，v2.6）。
  Future<Set<String>> getAllMessageContentHashes() async {
    final db = await database;
    final rows = await db.query('messages', columns: ['content_hash']);
    return {for (final r in rows) r['content_hash'] as String};
  }

  /// 批量插入消息（单事务；调用方负责 content_hash 预去重，v2.6 导入用）。
  Future<void> insertMessagesBatch(List<Message> messages) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final m in messages) {
        batch.insert('messages', m.toRow());
      }
      await batch.commit(noResult: true);
    });
  }

  /// [oldestFirst] = true 时按 posted_at 升序（自动处理用：先清最早的积压）。
  Future<List<Message>> getMessages(
      {String? status,
      String? packageName,
      List<String>? priorities,
      int limit = defaultMessageLimit,
      int offset = 0,
      bool oldestFirst = false}) async {
    final db = await database;
    final wheres = <String>[];
    final args = <Object?>[];
    if (status != null) {
      wheres.add('status = ?');
      args.add(status);
    }
    if (packageName != null) {
      wheres.add('package_name = ?');
      args.add(packageName);
    }
    if (priorities != null && priorities.isNotEmpty) {
      wheres.add(
          'priority IN (${List.filled(priorities.length, '?').join(',')})');
      args.addAll(priorities);
    }
    final rows = await db.query(
      'messages',
      where: wheres.isEmpty ? null : wheres.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'posted_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Message.fromRow).toList();
  }

  Future<Message?> getMessageById(String id) async {
    final db = await database;
    final rows =
        await db.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Message.fromRow(rows.first);
  }

  Future<List<Message>> getMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows =
        await db.query('messages', where: 'id IN ($placeholders)', whereArgs: ids);
    return rows.map(Message.fromRow).toList();
  }

  /// 消息列表按应用筛选：distinct 来源应用，按最近消息时间降序。
  Future<List<SourceApp>> getDistinctMessageSources() async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT package_name, app_name FROM messages '
        'GROUP BY package_name ORDER BY MAX(posted_at) DESC');
    return rows
        .map((r) =>
            SourceApp(r['package_name'] as String, r['app_name'] as String?))
        .toList();
  }

  /// F2（ux-fixes-2026-11 §2.1）：应用名懒解析成功后回填消息行——
  /// 只覆盖「未解析」的行（null / 空串 / 采集期被固化成的包名），
  /// 不动已有正常名称。返回更新行数。
  Future<int> backfillMessageAppName(
      String packageName, String appName) async {
    final db = await database;
    var total = 0;
    for (final table in ['messages', 'raw_messages']) {
      total += await db.update(
        table,
        {'app_name': appName},
        where: "package_name = ? "
            "AND (app_name IS NULL OR app_name = '' OR app_name = ?)",
        whereArgs: [packageName, packageName],
      );
    }
    return total;
  }

  Future<void> updateMessageStatus(List<String> ids, String status) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('messages', {'status': status},
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<void> updateMessagePriority(List<String> ids, String priority) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('messages', {'priority': priority},
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  /// 用户手动编辑消息正文（F07）：同时打上 edited_at，便于区分采集原文。
  /// v8（details §1.4）：保存时重算并更新 content_hash（对剥离 marker 后的
  /// 文本，strip 内建于 computeContentHash），保证与「同一通知再次送达」的
  /// 判重语义一致。锚点插入/移除路径也走这里。
  Future<void> updateMessageBody(String id, String body) async {
    final db = await database;
    final values = <String, Object?>{
      'body': body,
      'edited_at': DateTime.now().millisecondsSinceEpoch,
    };
    final rows = await db.query('messages',
        columns: ['package_name', 'title', 'posted_at'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1);
    if (rows.isNotEmpty) {
      final r = rows.first;
      values['content_hash'] = computeContentHash(r['package_name'] as String,
          r['title'] as String, body, (r['posted_at'] as num).toInt());
    }
    await db.update('messages', values, where: 'id = ?', whereArgs: [id]);
  }

  /// 用户增删消息附件（F07）：整份 attachments JSON 覆盖写，同样打 edited_at。
  Future<void> updateMessageAttachments(
      String id, List<Map<String, dynamic>> attachments) async {
    final db = await database;
    await db.update(
      'messages',
      {
        'attachments': jsonEncode(attachments),
        'edited_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 某条消息关联的任务（F08）：走 task_anchors（v8 起），未定时的排在后面。
  Future<List<Task>> tasksForMessage(String messageId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT t.* FROM tasks t '
      'INNER JOIN task_anchors a ON a.task_id = t.id '
      "WHERE a.target_type = 'message' AND a.target_id = ? "
      'ORDER BY t.start_at IS NULL, t.start_at ASC',
      [messageId],
    );
    return rows.map(Task.fromRow).toList();
  }

  // ---- v8：任务锚点（task_anchors，design-v3 §1.1） ----
  // 锚点 marker 的正文写入统一走 AnchorService；这里只做表行 CRUD 与查询。

  static TaskAnchor _anchorFromRow(Map<String, Object?> r) => TaskAnchor(
        id: r['id'] as String,
        taskId: r['task_id'] as String,
        targetType: r['target_type'] as String,
        targetId: r['target_id'] as String,
        label: r['label'] as String?,
        createdBy: r['created_by'] as String,
        createdAt: (r['created_at'] as num).toInt(),
      );

  static Map<String, Object?> _anchorToRow(TaskAnchor a) => {
        'id': a.id,
        'task_id': a.taskId,
        'target_type': a.targetType,
        'target_id': a.targetId,
        'label': a.label,
        'created_by': a.createdBy,
        'created_at': a.createdAt,
      };

  Future<void> insertAnchor(TaskAnchor anchor) async {
    final db = await database;
    await db.insert('task_anchors', _anchorToRow(anchor),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<TaskAnchor?> getAnchorById(String id) async {
    final db = await database;
    final rows = await db.query('task_anchors',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _anchorFromRow(rows.first);
  }

  /// 某任务的全部锚点（任务详情「来源」列表用）。
  Future<List<TaskAnchor>> anchorsForTask(String taskId) async {
    final db = await database;
    final rows = await db.query('task_anchors',
        where: 'task_id = ?', whereArgs: [taskId], orderBy: 'created_at ASC');
    return rows.map(_anchorFromRow).toList();
  }

  /// 某目标（消息/笔记/文件）的全部锚点（目标详情展示用）。
  Future<List<TaskAnchor>> anchorsForTarget(
      String targetType, String targetId) async {
    final db = await database;
    final rows = await db.query('task_anchors',
        where: 'target_type = ? AND target_id = ?',
        whereArgs: [targetType, targetId],
        orderBy: 'created_at ASC');
    return rows.map(_anchorFromRow).toList();
  }

  /// 按 id 批量取锚点（渲染预取缓存用，避免逐 marker 查库）。
  Future<List<TaskAnchor>> anchorsByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final db = await database;
    final result = <TaskAnchor>[];
    for (var i = 0; i < ids.length; i += kMessageHashLookupChunk) {
      final end = i + kMessageHashLookupChunk <= ids.length
          ? i + kMessageHashLookupChunk
          : ids.length;
      final part = ids.sublist(i, end);
      final rows = await db.query('task_anchors',
          where: 'id IN (${List.filled(part.length, '?').join(',')})',
          whereArgs: part);
      result.addAll(rows.map(_anchorFromRow));
    }
    return result;
  }

  /// 全量锚点（存档导出用）。
  Future<List<TaskAnchor>> allAnchors() async {
    final db = await database;
    final rows =
        await db.query('task_anchors', orderBy: 'created_at ASC, id ASC');
    return rows.map(_anchorFromRow).toList();
  }

  Future<void> deleteAnchor(String id) async {
    final db = await database;
    await db.delete('task_anchors', where: 'id = ?', whereArgs: [id]);
  }

  /// 全量映射 messageId → taskIds（消息列表一次取回，避免 N+1 查询）。
  Future<Map<String, List<String>>> messageAnchorTaskIds() async {
    final db = await database;
    final rows = await db.query('task_anchors',
        columns: ['target_id', 'task_id'],
        where: "target_type = 'message'",
        orderBy: 'created_at ASC');
    final map = <String, List<String>>{};
    for (final r in rows) {
      map
          .putIfAbsent(r['target_id'] as String, () => [])
          .add(r['task_id'] as String);
    }
    return map;
  }

  /// 全量映射 taskId → messageIds（任务详情展示「来源消息」用）。
  Future<Map<String, List<String>>> taskAnchorMessageIds() async {
    final db = await database;
    final rows = await db.query('task_anchors',
        columns: ['task_id', 'target_id'],
        where: "target_type = 'message'",
        orderBy: 'created_at ASC');
    final map = <String, List<String>>{};
    for (final r in rows) {
      map
          .putIfAbsent(r['task_id'] as String, () => [])
          .add(r['target_id'] as String);
    }
    return map;
  }

  /// 某个任务的来源消息（可能多条）。
  Future<List<Message>> messagesForTask(String taskId) async {
    final ids = await taskAnchorMessageIds();
    final list = ids[taskId] ?? const <String>[];
    if (list.isEmpty) return const [];
    return getMessagesByIds(list);
  }

  Future<void> deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.transaction((txn) async {
      // 锚点行级联删除（应用层；sqflite 默认不开外键）。
      await txn.delete('task_anchors',
          where: "target_type = 'message' AND target_id IN ($placeholders)",
          whereArgs: ids);
      await txn.delete('messages', where: 'id IN ($placeholders)', whereArgs: ids);
    });
  }

  /// 撤销删除用：整体回插（replace 覆盖同 id 残留）。
  Future<void> restoreMessages(List<Message> messages) async {
    if (messages.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final m in messages) {
      batch.insert('messages', m.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  // ---- v2: tasks ----

  Future<void> insertTask(Task task) async {
    final db = await database;
    await db.insert('tasks', task.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _rescheduleReminders();
  }

  /// 全字段更新并自动刷新 updated_at。
  Future<void> updateTask(Task task) async {
    final db = await database;
    await db.update(
      'tasks',
      task
          .copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch)
          .toRow(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
    _rescheduleReminders();
  }

  Future<Task?> getTaskById(String id) async {
    final db = await database;
    final rows =
        await db.query('tasks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Task.fromRow(rows.first);
  }

  /// 按 id 批量取任务（锚点 chip 联查标题/状态用）。
  Future<List<Task>> tasksByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows =
        await db.query('tasks', where: 'id IN ($placeholders)', whereArgs: ids);
    return rows.map(Task.fromRow).toList();
  }

  Future<List<Task>> getTasks(
      {String? status,
      int limit = defaultTaskLimit,
      int offset = 0}) async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: status != null ? 'status = ?' : null,
      whereArgs: status != null ? [status] : null,
      orderBy: 'start_at IS NULL, start_at ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Task.fromRow).toList();
  }

  /// 全部「进行中」任务（任务复用查询；写操作量小，不做分页）。
  /// 已完成/已放弃的任务不参与复用：同一件事再次出现时应当新建。
  Future<List<Task>> getActiveTasks() async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: 'status = ?',
      whereArgs: [TaskStatus.active],
      orderBy: 'created_at ASC',
    );
    return rows.map(Task.fromRow).toList();
  }

  /// 与 [getMessages] 同条件的总条数（用于提示「仅显示前 N 条」）。
  Future<int> countMessages(
      {String? status, String? packageName, List<String>? priorities}) async {
    final db = await database;
    final wheres = <String>[];
    final args = <Object?>[];
    if (status != null) {
      wheres.add('status = ?');
      args.add(status);
    }
    if (packageName != null) {
      wheres.add('package_name = ?');
      args.add(packageName);
    }
    if (priorities != null && priorities.isNotEmpty) {
      wheres.add(
          'priority IN (${List.filled(priorities.length, '?').join(',')})');
      args.addAll(priorities);
    }
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM messages'
      '${wheres.isEmpty ? '' : ' WHERE ${wheres.join(' AND ')}'}',
      args.isEmpty ? null : args,
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// 与 [getTasks] 同条件的总条数。
  Future<int> countTasks({String? status}) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM tasks${status != null ? ' WHERE status = ?' : ''}',
      status != null ? [status] : null,
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// 与半开区间 [startMs, endMs) 有交集的任务（start_at 非空）。
  /// （v2.4：is_annual 逐年平移下线，一律按普通区间判断。）
  Future<List<Task>> getTasksOverlapping(int startMs, int endMs,
      {String status = 'active'}) async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: 'status = ? AND start_at IS NOT NULL AND '
          'start_at < ? AND ((end_at IS NULL AND start_at >= ?) OR end_at > ?)',
      whereArgs: [status, endMs, startMs, startMs],
      orderBy: 'start_at ASC',
    );
    return rows.map(Task.fromRow).toList();
  }

  /// 无时间任务（"我的待办"）：优先级 important > normal > minor，再按创建时间。
  Future<List<Task>> getUntimedTasks() async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: "start_at IS NULL AND status = 'active'",
      orderBy: "CASE priority WHEN 'important' THEN 0 WHEN 'normal' THEN 1 "
          'ELSE 2 END, created_at ASC',
    );
    return rows.map(Task.fromRow).toList();
  }

  /// 子任务（设计 §1.2：parent_id 仅一级）。
  Future<List<Task>> getChildTasks(String parentId) async {
    final db = await database;
    final rows = await db.query('tasks',
        where: 'parent_id = ?', whereArgs: [parentId], orderBy: 'start_at ASC');
    return rows.map(Task.fromRow).toList();
  }

  /// 全部父任务的直接子任务进度：parentId -> (done, total)（设计 §3，v2.3）。
  Future<Map<String, (int, int)>> getSubtaskProgress() async {
    final db = await database;
    final rows = await db.query('tasks',
        columns: ['parent_id', 'status'], where: 'parent_id IS NOT NULL');
    final result = <String, (int, int)>{};
    for (final r in rows) {
      final p = r['parent_id'] as String;
      final cur = result[p] ?? (0, 0);
      result[p] = (
        cur.$1 + (r['status'] == TaskStatus.done ? 1 : 0),
        cur.$2 + 1,
      );
    }
    return result;
  }

  Future<void> setTaskStatus(List<String> ids, String status) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('tasks', {'status': status},
        where: 'id IN ($placeholders)', whereArgs: ids);
    _rescheduleReminders();
  }

  /// 删除任务：先把该任务所有锚点残迹化（正文 marker 替换为 label 纯文本，
  /// 删除锚点行，details §1.5），再删任务行，同一事务。
  ///
  /// 需要可撤销的调用方：删除前先 [snapshotTaskDeletion]，撤销时
  /// [restoreTaskDeletionSnapshot] + 回插任务行。
  Future<void> deleteTasks(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.transaction((txn) async {
      for (final id in ids) {
        await residualizeAnchorsForTaskInto(txn, id);
      }
      await txn.delete('tasks', where: 'id IN ($placeholders)', whereArgs: ids);
    });
    _rescheduleReminders();
  }

  /// 删除任务前的完整快照（撤销用，details §1.5）：[taskIds] 全部任务的
  /// 锚点行 + 受影响正文（message/note，按目标去重）的原文与留痕原值。
  /// 同一正文含多个被删任务的锚点时只记一份原文，整段回写天然正确。
  Future<TaskDeletionSnapshot> snapshotTaskDeletion(
      List<String> taskIds) async {
    final db = await database;
    final anchors = <TaskAnchor>[];
    final seenTasks = <String>{};
    for (final id in taskIds) {
      if (!seenTasks.add(id)) continue;
      final rows = await db.query('task_anchors',
          where: 'task_id = ?', whereArgs: [id], orderBy: 'created_at ASC');
      anchors.addAll(rows.map(_anchorFromRow));
    }
    final bodies = <TaskDeletionBodySnapshot>[];
    final seenTargets = <String>{};
    for (final a in anchors) {
      if (a.targetType == AnchorTargetType.file) continue; // 文件锚点不入正文
      if (!seenTargets.add('${a.targetType}|${a.targetId}')) continue;
      if (a.targetType == AnchorTargetType.message) {
        final rows = await db.query('messages',
            columns: ['body', 'edited_at'],
            where: 'id = ?',
            whereArgs: [a.targetId],
            limit: 1);
        if (rows.isEmpty) continue;
        bodies.add(TaskDeletionBodySnapshot(
          targetType: a.targetType,
          targetId: a.targetId,
          content: rows.first['body'] as String,
          editedAt: (rows.first['edited_at'] as num?)?.toInt(),
        ));
      } else if (a.targetType == AnchorTargetType.note) {
        final rows = await db.query('notes',
            columns: ['content', 'updated_at'],
            where: 'id = ?',
            whereArgs: [a.targetId],
            limit: 1);
        if (rows.isEmpty) continue;
        bodies.add(TaskDeletionBodySnapshot(
          targetType: a.targetType,
          targetId: a.targetId,
          content: rows.first['content'] as String,
          editedAt: (rows.first['updated_at'] as num?)?.toInt(),
        ));
      }
    }
    return TaskDeletionSnapshot(anchors: anchors, bodies: bodies);
  }

  /// 撤销删除：正文原文整段回写（marker 精确复原；message 的 content_hash
  /// 由原文重算一并复原；edited_at / updated_at 写回删除前原值），
  /// 锚点行原样回插。任务行本身由调用方回插。目标已删除时跳过其正文。
  Future<void> restoreTaskDeletionSnapshot(TaskDeletionSnapshot snap) async {
    if (snap.anchors.isEmpty && snap.bodies.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final b in snap.bodies) {
        if (b.targetType == AnchorTargetType.message) {
          final rows = await txn.query('messages',
              columns: ['package_name', 'title', 'posted_at'],
              where: 'id = ?',
              whereArgs: [b.targetId],
              limit: 1);
          if (rows.isEmpty) continue;
          final r = rows.first;
          await txn.update(
            'messages',
            {
              'body': b.content,
              'edited_at': b.editedAt,
              'content_hash': computeContentHash(
                  r['package_name'] as String,
                  r['title'] as String,
                  b.content,
                  (r['posted_at'] as num).toInt()),
            },
            where: 'id = ?',
            whereArgs: [b.targetId],
          );
        } else if (b.targetType == AnchorTargetType.note) {
          await txn.update(
            'notes',
            {'content': b.content, 'updated_at': b.editedAt},
            where: 'id = ?',
            whereArgs: [b.targetId],
          );
        }
      }
      for (final a in snap.anchors) {
        await txn.insert('task_anchors', _anchorToRow(a),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Timer? _rescheduleTimer;
  bool _rescheduling = false;
  bool _rescheduleAgain = false;

  /// 任务写操作后重排本地提醒。
  ///
  /// **合并 + 单飞**（2026-10-20 性能修复）：原实现每次写任务都 fire-and-forget 一次
  /// `rescheduleAll()`——它要取消上一轮 N 个提醒再逐个 zonedSchedule（2N 次平台通道
  /// 调用）且无互斥。AI 批量确认时等于上百次并发全量重排，直接把界面拖卡。
  void _rescheduleReminders() {
    _rescheduleTimer?.cancel();
    _rescheduleTimer = Timer(const Duration(milliseconds: 400), _runReschedule);
  }

  Future<void> _runReschedule() async {
    if (_rescheduling) {
      _rescheduleAgain = true; // 跑到一半又来了写操作：等这轮结束再补一次
      return;
    }
    _rescheduling = true;
    try {
      await ReminderService.instance.rescheduleAll();
    } catch (e, st) {
      AppLog.instance.warn('db.reschedule', e, st);
    } finally {
      _rescheduling = false;
      if (_rescheduleAgain) {
        _rescheduleAgain = false;
        _rescheduleReminders();
      }
    }
  }

  // ---- v2: 笔记三级 ----

  Future<List<Notebook>> getNotebooks() async {
    final db = await database;
    final rows = await db.query('notebooks', orderBy: 'sort ASC');
    return rows.map(Notebook.fromRow).toList();
  }

  Future<void> insertNotebook(Notebook notebook) async {
    final db = await database;
    await db.insert('notebooks', notebook.toRow());
  }

  Future<void> renameNotebook(String id, String name) async {
    final db = await database;
    await db.update('notebooks', {'name': name},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 级联删除：笔记本 + 其下全部章节 + 章节下全部笔记（含笔记锚点行），一个事务。
  Future<void> deleteNotebook(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      const noteIds =
          'SELECT id FROM notes WHERE chapter_id IN (SELECT id FROM chapters WHERE notebook_id = ?)';
      await txn.delete('task_anchors',
          where: "target_type = 'note' AND target_id IN ($noteIds)",
          whereArgs: [id]);
      await txn.delete('notes',
          where:
              'chapter_id IN (SELECT id FROM chapters WHERE notebook_id = ?)',
          whereArgs: [id]);
      await txn.delete('chapters', where: 'notebook_id = ?', whereArgs: [id]);
      await txn.delete('notebooks', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Chapter>> getChapters(String notebookId) async {
    final db = await database;
    final rows = await db.query('chapters',
        where: 'notebook_id = ?', whereArgs: [notebookId], orderBy: 'sort ASC');
    return rows.map(Chapter.fromRow).toList();
  }

  Future<void> insertChapter(Chapter chapter) async {
    final db = await database;
    await db.insert('chapters', chapter.toRow());
  }

  Future<void> renameChapter(String id, String name) async {
    final db = await database;
    await db
        .update('chapters', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  /// 级联删除：章节 + 其下全部笔记（含笔记锚点行）。
  Future<void> deleteChapter(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('task_anchors',
          where:
              "target_type = 'note' AND target_id IN (SELECT id FROM notes WHERE chapter_id = ?)",
          whereArgs: [id]);
      await txn.delete('notes', where: 'chapter_id = ?', whereArgs: [id]);
      await txn.delete('chapters', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Note>> getNotes(String chapterId) async {
    final db = await database;
    final rows = await db.query('notes',
        where: 'chapter_id = ?',
        whereArgs: [chapterId],
        orderBy: 'updated_at DESC');
    return rows.map(Note.fromRow).toList();
  }

  Future<Note?> getNoteById(String id) async {
    final db = await database;
    final rows =
        await db.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Note.fromRow(rows.first);
  }

  Future<void> insertNote(Note note) async {
    final db = await database;
    await db.insert('notes', note.toRow());
  }

  /// 全字段更新并自动刷新 updated_at。
  Future<void> updateNote(Note note) async {
    final db = await database;
    await db.update(
      'notes',
      note.copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch).toRow(),
      where: 'id = ?',
      whereArgs: [note.id],
    );
  }

  Future<void> deleteNote(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('task_anchors',
          where: "target_type = 'note' AND target_id = ?", whereArgs: [id]);
      await txn.delete('notes', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ---- v8：文件区（files，design-v3 §1.3） ----

  Future<void> insertFile(LibraryFile file) async {
    final db = await database;
    await db.insert('files', file.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<LibraryFile>> getFiles() async {
    final db = await database;
    final rows = await db.query('files', orderBy: 'created_at DESC');
    return rows.map(LibraryFile.fromRow).toList();
  }

  /// 某个文件夹（v9，'' = 根目录）下的直接文件，按创建时间倒序。
  Future<List<LibraryFile>> getFilesInFolder(String folder) async {
    final db = await database;
    final rows = await db.query('files',
        where: 'folder = ?', whereArgs: [folder], orderBy: 'created_at DESC');
    return rows.map(LibraryFile.fromRow).toList();
  }

  /// 某个文件夹及其全部后代文件夹下的文件（2026-11-01 文件夹整选用）。
  Future<List<LibraryFile>> getFilesUnderFolder(String folder) async {
    if (folder.isEmpty) return getFiles();
    final db = await database;
    final rows = await db.query('files',
        where: 'folder = ? OR folder LIKE ?',
        whereArgs: [folder, '$folder/%'],
        orderBy: 'created_at DESC');
    return rows.map(LibraryFile.fromRow).toList();
  }

  /// 全部非空文件夹路径（去重，按字典序；文件夹是虚拟的，由文件 folder 字段派生）。
  Future<List<String>> getFileFolders() async {
    final db = await database;
    final rows = await db.rawQuery(
        "SELECT DISTINCT folder FROM files WHERE folder != '' ORDER BY folder ASC");
    return [for (final r in rows) r['folder'] as String];
  }

  // ---- v10：library_folders（空文件夹持久化） ----

  /// 持久化的文件夹路径（含空文件夹），按字典序。
  Future<List<String>> getLibraryFolders() async {
    final db = await database;
    final rows = await db.query('library_folders', orderBy: 'path ASC');
    return [for (final r in rows) r['path'] as String];
  }

  /// 新建文件夹落表（含祖先路径一并补齐，幂等）。
  Future<void> insertLibraryFolder(String path) async {
    if (path.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    var cur = path;
    while (cur.isNotEmpty) {
      await db.insert('library_folders', {'path': cur, 'created_at': now},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      final i = cur.lastIndexOf('/');
      cur = i < 0 ? '' : cur.substring(0, i);
    }
  }

  /// 删除文件夹：删掉该路径及其全部后代（子文件夹跟随消失；
  /// 其中文件由服务层先上移，不在此处理）。
  Future<void> deleteLibraryFolderTree(String path) async {
    if (path.isEmpty) return;
    final db = await database;
    await db.delete('library_folders',
        where: 'path = ? OR path LIKE ?', whereArgs: [path, '$path/%']);
  }

  /// 文件夹重命名：整棵子树换前缀（与 files.folder 的换前缀同语义）。
  Future<void> renameLibraryFolderTree(String from, String to) async {
    if (from.isEmpty || from == to) return;
    final db = await database;
    final rows = await db.query('library_folders',
        where: 'path = ? OR path LIKE ?', whereArgs: [from, '$from/%']);
    for (final r in rows) {
      final oldPath = r['path'] as String;
      final newPath = '$to${oldPath.substring(from.length)}';
      await db.delete('library_folders',
          where: 'path = ?', whereArgs: [oldPath]);
      await db.insert(
          'library_folders',
          {
            'path': newPath,
            'created_at': r['created_at'] as int,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  /// 批量移动文件到目标文件夹（v9；'' = 根目录）。
  Future<void> moveFilesToFolder(List<String> ids, String folder) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('files', {'folder': folder},
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<LibraryFile?> getFileById(String id) async {
    final db = await database;
    final rows =
        await db.query('files', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : LibraryFile.fromRow(rows.first);
  }

  /// 按 id 批量取文件（笔记 `![name](file://id)` 渲染联查用）。
  Future<List<LibraryFile>> filesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows =
        await db.query('files', where: 'id IN ($placeholders)', whereArgs: ids);
    return rows.map(LibraryFile.fromRow).toList();
  }

  Future<void> renameFile(String id, String name) async {
    final db = await database;
    await db.update('files', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  /// 删除文件元数据（引用检查在 UI 层做）；其锚点行级联删除（应用层）。
  Future<void> deleteFile(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('task_anchors',
          where: "target_type = 'file' AND target_id = ?", whereArgs: [id]);
      await txn.delete('files', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ---- v8：助理对话（conversations / chat_messages，design-v3 §1.4） ----

  Future<void> insertConversation(Conversation conversation) async {
    final db = await database;
    await db.insert('conversations', conversation.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Conversation>> getConversations() async {
    final db = await database;
    final rows = await db.query('conversations', orderBy: 'updated_at DESC');
    return rows.map(Conversation.fromRow).toList();
  }

  Future<Conversation?> getConversationById(String id) async {
    final db = await database;
    final rows = await db.query('conversations',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Conversation.fromRow(rows.first);
  }

  Future<void> renameConversation(String id, String title) async {
    final db = await database;
    await db.update(
        'conversations',
        {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id]);
  }

  Future<void> setConversationModel(String id, String? modelConfigId) async {
    final db = await database;
    await db.update('conversations', {'model_config_id': modelConfigId},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 绑定了某个模型配置的对话数（v4 批次 C：删除端点前的确认文案用，
  /// 删除后这些对话回退默认路由）。
  Future<int> countConversationsByModelConfig(String modelConfigId) async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM conversations WHERE model_config_id = ?',
        [modelConfigId]);
    final v = rows.first['c'];
    return v is int ? v : 0;
  }

  /// 刷新 updated_at（有新消息时把对话顶到列表前）。
  Future<void> touchConversation(String id) async {
    final db = await database;
    await db.update('conversations',
        {'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 整份覆盖草稿附件（v9；对话页附件选择器与移除 chip 的写透路径）。
  Future<void> setConversationDraftAttachments(
      String id, List<ChatAttachment> attachments) async {
    final db = await database;
    await db.update(
        'conversations',
        {'draft_attachments': jsonEncode(attachments.map((e) => e.toJson()).toList())},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 追加草稿附件（v9，库页「发送给助理」用）：按 type:id 去重，返回追加后的全量。
  Future<List<ChatAttachment>> appendConversationDraftAttachments(
      String id, List<ChatAttachment> items) async {
    final db = await database;
    final rows = await db.query('conversations',
        columns: ['draft_attachments'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return const [];
    final current = rows.first['draft_attachments'] == null
        ? <ChatAttachment>[]
        : (jsonDecode(rows.first['draft_attachments'] as String) as List)
            .map((e) => ChatAttachment.fromJson(e as Map<String, dynamic>))
            .toList();
    final seen = {for (final a in current) '${a.type}:${a.id}'};
    for (final a in items) {
      if (seen.add('${a.type}:${a.id}')) current.add(a);
    }
    await db.update(
        'conversations',
        {'draft_attachments': jsonEncode(current.map((e) => e.toJson()).toList())},
        where: 'id = ?', whereArgs: [id]);
    return current;
  }

  /// 删除对话：chat_messages 级联删（应用层）；change_proposals 松耦合，
  /// conversation_id 置空保留在待确认区（design-v3 §1.4）。
  Future<void> deleteConversation(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('chat_messages',
          where: 'conversation_id = ?', whereArgs: [id]);
      await txn.update('change_proposals', {'conversation_id': null},
          where: 'conversation_id = ?', whereArgs: [id]);
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> insertChatMessage(ChatMessage message) async {
    final db = await database;
    await db.insert('chat_messages', message.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<ChatMessage?> getChatMessageById(String id) async {
    final db = await database;
    final rows = await db.query('chat_messages',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ChatMessage.fromRow(rows.first);
  }

  Future<List<ChatMessage>> getChatMessages(String conversationId) async {
    final db = await database;
    final rows = await db.query('chat_messages',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
        orderBy: 'created_at ASC');
    return rows.map(ChatMessage.fromRow).toList();
  }

  /// 流式输出结束/编辑时整份覆盖内容。
  Future<void> updateChatMessageContent(String id, String content) async {
    final db = await database;
    await db.update('chat_messages', {'content': content},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateChatMessageStatus(String id, String status) async {
    final db = await database;
    await db.update('chat_messages', {'status': status},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 按 id 批量删除消息（2026-11-01：编辑/撤回/重试的截断）。
  Future<void> deleteChatMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('chat_messages',
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  /// 撤销这些 assistant 批次里仍 pending 的提案（编辑/撤回/重试联动，
  /// 置 rejected 留痕；applied 的不动——回滚走撤销队列）。
  Future<void> rejectPendingProposalsByBatchIds(List<String> batchIds) async {
    if (batchIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(batchIds.length, '?').join(',');
    await db.update(
      'change_proposals',
      {
        'status': 'rejected',
        'resolved_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: "status = 'pending' AND batch_id IN ($placeholders)",
      whereArgs: batchIds,
    );
  }

  // ---- v8：变更提案（change_proposals，待确认区，design-v3 §1.4） ----

  static ChangeProposal _proposalFromRow(Map<String, Object?> r) =>
      ChangeProposal(
        id: r['id'] as String,
        conversationId: r['conversation_id'] as String?,
        batchId: r['batch_id'] as String?,
        tool: r['tool'] as String,
        summary: r['summary'] as String,
        payload:
            (jsonDecode(r['payload'] as String) as Map).cast<String, dynamic>(),
        status: r['status'] as String,
        createdAt: (r['created_at'] as num).toInt(),
        resolvedAt: (r['resolved_at'] as num?)?.toInt(),
      );

  static Map<String, Object?> _proposalToRow(ChangeProposal p) => {
        'id': p.id,
        'conversation_id': p.conversationId,
        'batch_id': p.batchId,
        'tool': p.tool,
        'summary': p.summary,
        'payload': jsonEncode(p.payload),
        'status': p.status,
        'created_at': p.createdAt,
        'resolved_at': p.resolvedAt,
      };

  Future<void> insertProposal(ChangeProposal proposal) async {
    final db = await database;
    await db.insert('change_proposals', _proposalToRow(proposal),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<ChangeProposal?> getProposalById(String id) async {
    final db = await database;
    final rows = await db.query('change_proposals',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _proposalFromRow(rows.first);
  }

  /// 按状态过滤（null = 全部），按创建时间升序。
  Future<List<ChangeProposal>> getProposals({String? status}) async {
    final db = await database;
    final rows = await db.query('change_proposals',
        where: status != null ? 'status = ?' : null,
        whereArgs: status != null ? [status] : null,
        orderBy: 'created_at ASC');
    return rows.map(_proposalFromRow).toList();
  }

  Future<List<ChangeProposal>> proposalsForConversation(
      String conversationId) async {
    final db = await database;
    final rows = await db.query('change_proposals',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
        orderBy: 'created_at ASC');
    return rows.map(_proposalFromRow).toList();
  }

  /// 同一 AI 回合（batch）的全部提案（待确认区分组用，details §3.2）。
  Future<List<ChangeProposal>> proposalsForBatch(String batchId) async {
    final db = await database;
    final rows = await db.query('change_proposals',
        where: 'batch_id = ?', whereArgs: [batchId], orderBy: 'created_at ASC');
    return rows.map(_proposalFromRow).toList();
  }

  /// 提案状态流转（design-v3 §1.4）：pending→approved/rejected→applied/failed。
  /// applied→pending 为「撤销已应用的变更」（details §3.2 历史区撤销入口）：
  /// 逆操作由 proposal_executor 先执行，再把提案退回待确认区。
  /// 非法流转或不存在的 id 返回 false；流转成功打 resolved_at。
  Future<bool> transitionProposal(String id, String to) async {
    const allowed = {
      ProposalStatus.pending: {ProposalStatus.approved, ProposalStatus.rejected},
      ProposalStatus.approved: {ProposalStatus.applied, ProposalStatus.failed},
      ProposalStatus.applied: {ProposalStatus.pending},
    };
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query('change_proposals',
          columns: ['status'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return false;
      final from = rows.first['status'] as String;
      if (!(allowed[from]?.contains(to) ?? false)) return false;
      await txn.update(
          'change_proposals',
          {
            'status': to,
            'resolved_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [id]);
      return true;
    });
  }
}
