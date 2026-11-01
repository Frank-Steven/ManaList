import 'dart:convert';

/// v2 笔记三级模型，对应设计文档 §1.3 的 notebooks / chapters / notes 表。
/// v3（DB v8）：notes 增加 attachments 列（JSON 数组，引用 files.id）。
class Notebook {
  final String id;
  final String name;
  final int sort;
  final int createdAt;

  const Notebook({
    required this.id,
    required this.name,
    this.sort = 0,
    required this.createdAt,
  });

  factory Notebook.fromRow(Map<String, Object?> row) => Notebook(
        id: row['id'] as String,
        name: row['name'] as String,
        sort: (row['sort'] as num).toInt(),
        createdAt: (row['created_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'sort': sort,
        'created_at': createdAt,
      };

  Notebook copyWith({String? id, String? name, int? sort, int? createdAt}) =>
      Notebook(
        id: id ?? this.id,
        name: name ?? this.name,
        sort: sort ?? this.sort,
        createdAt: createdAt ?? this.createdAt,
      );
}

class Chapter {
  final String id;
  final String notebookId;
  final String name;
  final int sort;
  final int createdAt;

  const Chapter({
    required this.id,
    required this.notebookId,
    required this.name,
    this.sort = 0,
    required this.createdAt,
  });

  factory Chapter.fromRow(Map<String, Object?> row) => Chapter(
        id: row['id'] as String,
        notebookId: row['notebook_id'] as String,
        name: row['name'] as String,
        sort: (row['sort'] as num).toInt(),
        createdAt: (row['created_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'notebook_id': notebookId,
        'name': name,
        'sort': sort,
        'created_at': createdAt,
      };

  Chapter copyWith({
    String? id,
    String? notebookId,
    String? name,
    int? sort,
    int? createdAt,
  }) =>
      Chapter(
        id: id ?? this.id,
        notebookId: notebookId ?? this.notebookId,
        name: name ?? this.name,
        sort: sort ?? this.sort,
        createdAt: createdAt ?? this.createdAt,
      );
}

class Note {
  final String id;
  final String chapterId;
  final String title;
  final String content;
  final String contentFormat;

  /// 附件文件 id 列表（引用 files.id，DB v8 新增列；旧库行缺省为空）。
  final List<String> attachments;
  final int createdAt;
  final int updatedAt;

  const Note({
    required this.id,
    required this.chapterId,
    required this.title,
    this.content = '',
    this.contentFormat = 'plain',
    this.attachments = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory Note.fromRow(Map<String, Object?> row) => Note(
        id: row['id'] as String,
        chapterId: row['chapter_id'] as String,
        title: row['title'] as String,
        content: row['content'] as String,
        contentFormat: row['content_format'] as String,
        attachments: row['attachments'] == null
            ? const []
            : (jsonDecode(row['attachments'] as String) as List)
                .map((e) => e.toString())
                .toList(),
        createdAt: (row['created_at'] as num).toInt(),
        updatedAt: (row['updated_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'chapter_id': chapterId,
        'title': title,
        'content': content,
        'content_format': contentFormat,
        'attachments': jsonEncode(attachments),
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  Note copyWith({
    String? id,
    String? chapterId,
    String? title,
    String? content,
    String? contentFormat,
    List<String>? attachments,
    int? createdAt,
    int? updatedAt,
  }) =>
      Note(
        id: id ?? this.id,
        chapterId: chapterId ?? this.chapterId,
        title: title ?? this.title,
        content: content ?? this.content,
        contentFormat: contentFormat ?? this.contentFormat,
        attachments: attachments ?? this.attachments,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
