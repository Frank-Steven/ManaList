/// v3 库·文件区模型（design-v3 §1.3 files 表）。
///
/// 文件本体由 attachment_store 管理（沙盒路径），本表只存元数据；
/// 笔记 attachments、任务锚点（target_type='file'）、助理附件都引用这里的 id。
///
/// DB v9：新增 [folder] 路径式文件夹（如 `工作/截图`，'' = 根目录）；
/// 文件夹是虚拟的，只落在文件的 folder 字段上，无独立文件夹表。
class FileSource {
  static const userUpload = 'user_upload';
  static const aiGenerated = 'ai_generated';
  static const noteExport = 'note_export';
}

class LibraryFile {
  final String id;
  final String name;
  final String? mimeType;

  /// 文件大小（字节）；未知为 null。
  final int? size;

  /// attachment_store 管理的沙盒路径。
  final String localPath;
  final String source;

  /// 所在文件夹路径（'' = 根目录），DB v9 起。
  final String folder;
  final int createdAt;

  const LibraryFile({
    required this.id,
    required this.name,
    this.mimeType,
    this.size,
    required this.localPath,
    required this.source,
    this.folder = '',
    required this.createdAt,
  });

  factory LibraryFile.fromRow(Map<String, Object?> row) => LibraryFile(
        id: row['id'] as String,
        name: row['name'] as String,
        mimeType: row['mime_type'] as String?,
        size: (row['size'] as num?)?.toInt(),
        localPath: row['local_path'] as String,
        source: row['source'] as String,
        folder: row['folder'] as String? ?? '',
        createdAt: (row['created_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'mime_type': mimeType,
        'size': size,
        'local_path': localPath,
        'source': source,
        'folder': folder,
        'created_at': createdAt,
      };

  LibraryFile copyWith({
    String? id,
    String? name,
    String? Function()? mimeType,
    int? Function()? size,
    String? localPath,
    String? source,
    String? folder,
    int? createdAt,
  }) =>
      LibraryFile(
        id: id ?? this.id,
        name: name ?? this.name,
        mimeType: mimeType != null ? mimeType() : this.mimeType,
        size: size != null ? size() : this.size,
        localPath: localPath ?? this.localPath,
        source: source ?? this.source,
        folder: folder ?? this.folder,
        createdAt: createdAt ?? this.createdAt,
      );
}
