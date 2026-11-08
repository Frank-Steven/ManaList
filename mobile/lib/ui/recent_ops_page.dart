import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/crdt.dart';
import '../services/database.dart';

/// 最近变更审计视图（crdt.md §5）：op_log 只读列表，
/// 让「谁在什么时候改了什么」可见——人 / 助理（对话名）/ 系统。
class RecentOpsPage extends StatelessWidget {
  const RecentOpsPage({super.key});

  static String _kindLabel(String kind) => switch (kind) {
        OpKind.lwwSet => '赋值',
        OpKind.orAdd => '添加锚点',
        OpKind.orRemove => '移除锚点',
        OpKind.append => '追加',
        OpKind.tombstone => '删除',
        _ => kind,
      };

  static String _actorLabel(String actor, Map<String, String> convTitles) {
    if (actor == OpActor.user) return '你';
    if (actor == OpActor.system) return '系统';
    if (OpActor.isAssistant(actor)) {
      final convId = actor.substring('assistant:'.length);
      final title = convTitles[convId];
      return title == null ? '助理' : '助理·$title';
    }
    return actor;
  }

  static String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.month}-${t.day} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _payloadBrief(Map<String, Object?> op) {
    final raw = op['payload'] as String?;
    if (raw == null) return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded.containsKey('value')) {
        return ' → ${decoded['value']}';
      }
      final s = jsonEncode(decoded);
      return s.length > 60 ? ' ${s.substring(0, 60)}…' : ' $s';
    } catch (_) {
      return '';
    }
  }

  Future<(List<Map<String, Object?>>, Map<String, String>)> _load() async {
    final db = AppDatabase.instance;
    final ops = await db.recentOps(limit: 50);
    final titles = {
      for (final c in await db.getConversations()) c.id: c.title,
    };
    return (ops, titles);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('最近变更')),
      body: FutureBuilder<(List<Map<String, Object?>>, Map<String, String>)>(
        future: _load(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final (ops, titles) = snap.data!;
          if (ops.isEmpty) {
            return const Center(child: Text('暂无记录。'));
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: ops.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
            itemBuilder: (_, i) {
              final op = ops[i];
              final actor = op['actor'] as String;
              final isUser = actor == OpActor.user;
              return ListTile(
                dense: true,
                leading: Icon(
                  isUser
                      ? Icons.person_outline
                      : OpActor.isAssistant(actor)
                          ? Icons.smart_toy_outlined
                          : Icons.settings_suggest_outlined,
                  color: isUser ? cs.primary : cs.onSurfaceVariant,
                ),
                title: Text(
                  '${_actorLabel(actor, titles)} · ${_kindLabel(op['kind'] as String)}',
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  '${op['target']}${_payloadBrief(op)}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                trailing: Text(
                  _fmtTime((op['created_at'] as num).toInt()),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
