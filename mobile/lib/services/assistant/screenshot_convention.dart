// F03 Step3/4：截图整理约定（**唯一事实源**）。
//
// 同一段文案有两个消费者：
// 1. UI 横幅（chat_page 的 _buildScreenshotsHint）—— 告诉用户助理会怎么整理；
// 2. 模型系统前言（assistant_service 组装请求时注入）—— 真正约束模型行为。
// 两层共用本文件，避免文案漂移；本文件属 services 层，**禁止导入 ui/**（UI 反过来导入这里）。

/// 整理约定原文：单张成条、能确定时间出待办、纯信息出笔记、不跨图合并、敏感信息提示。
const String kScreenshotsConvention =
    '每张截图单独成条：能确定时间的出待办（task.create），纯信息出笔记（note.create），'
    '不跨图合并。截图可能含敏感信息，远程模型会离开设备。';

/// 旧调用名（原定义在 chat_page，已下沉到 services；保留别名减少改动面）。
String screenshotsConventionHint() => kScreenshotsConvention;

/// 注入系统前言时使用的带标题段落（前置空行，与工具说明书分隔）。
const String kScreenshotConventionPreamble =
    '\n[截图整理约定]\n$kScreenshotsConvention';

/// 组装系统前言 —— **唯一拼接点**。
///
/// 约定只进模型侧前言，**不参与用户消息正文**：用户气泡与落库 content
/// 仍是用户原话（或 UI 层的默认指令），因此这里不接收任何用户文本。
String systemPreambleWithConvention(
  String toolSpec, {
  required bool hasScreenshots,
}) =>
    '[系统说明]\n$toolSpec'
    '${hasScreenshots ? kScreenshotConventionPreamble : ''}';
