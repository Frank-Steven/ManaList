package dev.msgrepo.mobile

import android.app.Notification
import android.content.ComponentName
import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import android.os.Handler
import android.os.Looper

/**
 * 通知采集服务。监听到的通知提取为一条 JSON，原子写入应用私有目录
 * filesDir/queue/<yyyy-MM-dd>/<uuid>.json（先写 .tmp 再 rename），
 * 由 Dart 侧轮询读取并删除，避免与 Dart 端 SQLite 产生并发写冲突。
 *
 * 折叠标记清洗（P3-13）：只对 FLAG_GROUP_SUMMARY 的系统摘要通知去掉「(N条新消息)」
 * 与「[N条]」；普通通知原样保留（昵称里含该串是真实场景，不能误伤）。
 *
 * 采集过滤：读取 Dart 侧 shared_preferences 写入的配置（SharedPreferences 文件
 * "FlutterSharedPreferences"，key "flutter.app_filter_config"，值为
 * {"mode": "all"|"allowlist"|"blacklist", "packages": [...]}）。allowlist 模式
 * 只放行 packages 中的应用；blacklist 模式拦截 packages 中的应用；被拦截的
 * 直接丢弃、不进队列。
 *
 * 已见应用：无论是否放行，把 {packageName, appName, lastSeenAt} 更新到
 * filesDir/seen_apps.json（顶层为 packageName -> 条目 的 JSON 对象，
 * 原子写 tmp+rename），供 Dart 设置页列出候选应用。
 */
class NotificationCaptureService : NotificationListenerService() {

    // 同一进程内的去重窗口：NotificationListenerService 与 MainActivity 同属
    // 本应用进程，Listener 重启后窗口清空，最终去重由 Dart 端 contentHash 保证
    private val recentKeys = LinkedHashSet<String>()

    /** 去重窗口的最大长度（内存）与持久化长度（磁盘），见 P3-3。 */
    private val capturePrefs by lazy {
        getSharedPreferences("msgrepo_capture_state", MODE_PRIVATE)
    }

    @Volatile
    private var persistPending = false

    companion object {
        private const val MAX_DEDUP_KEYS = 512
        private const val PERSIST_DEDUP_KEYS = 128
        private const val PREF_DEDUP_KEY = "recent_keys"

        /** O04（2026-10-21）：seen_apps 内存态最多每 2 秒落盘一次。 */
        private const val SEEN_APPS_FLUSH_DELAY_MS = 2000L

        /** O03（2026-10-21）：queueAvailable 桥调用合并窗口。 */
        private const val QUEUE_NOTIFY_DELAY_MS = 200L

        /** 折叠正文前缀：[5条] */
        private val FOLD_PREFIX = Regex("^\\[\\d+条\\]\\s*")

        /** 折叠标题后缀：(5条新消息) */
        private val FOLD_SUFFIX = Regex("\\(\\d+条新消息\\)$")

        /** 折叠正文里的「发送者: 内容」前缀 */
        private val SENDER_PREFIX = Regex("^([^:：\\n]{1,30})[:：]\\s*")
    }



    override fun onCreate() {
        super.onCreate()
        // P3-3：进程被杀后内存去重窗口会丢，这里把上次持久化的 key 读回来
        loadDedupKeys()
    }

    override fun onDestroy() {
        // O04：服务销毁（停止采集/系统回收）前把 seen_apps 内存态强制落盘，
        // 不吃 2 秒节流窗口的亏；顺带撤销还没触发的合并回调，避免空转。
        try {
            seenAppsHandler.removeCallbacks(seenAppsFlushRunnable)
            flushSeenApps()
        } catch (t: Throwable) {
            // 落盘失败不影响销毁流程
        }
        try {
            queueNotifyHandler.removeCallbacks(queueNotifyRunnable)
            synchronized(queueNotifyLock) { queueNotifyPending = false }
        } catch (t: Throwable) {
            // 忽略
        }
        super.onDestroy()
    }

    /** O04：seen_apps 的锁 + 内存态 + 落盘节流状态，见 [recordSeenApp]。 */
    private val seenAppsLock = Any()
    private val seenApps = LinkedHashMap<String, JSONObject>()
    private var seenAppsLoaded = false

    /** 内存态版本号：每次更新 +1；[seenAppsPersistedVersion] 追上即表示已落盘。 */
    private var seenAppsVersion = 0L
    private var seenAppsPersistedVersion = 0L
    private var seenAppsFlushPending = false
    private val seenAppsHandler = Handler(Looper.getMainLooper())
    private val seenAppsFlushRunnable = Runnable { flushSeenApps() }

    /** O03：queueAvailable 的合并状态（200ms 窗口内只调一次 channel）。 */
    private val queueNotifyLock = Any()
    private var queueNotifyPending = false
    private val queueNotifyHandler = Handler(Looper.getMainLooper())
    private val queueNotifyRunnable = Runnable {
        synchronized(queueNotifyLock) { queueNotifyPending = false }
        try {
            MainActivity.bridgeChannel?.invokeMethod("queueAvailable", null)
        } catch (t: Throwable) {
            // 应用进程已退出时没有 channel，属正常情况
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            handle(sbn)
        } catch (t: Throwable) {
            // 监听器绝不能崩溃，否则系统会禁用后频繁重绑
        }
    }

    private fun handle(sbn: StatusBarNotification) {
        val notification = sbn.notification ?: return
        val packageName = sbn.packageName ?: return
        if (packageName == this.packageName) return

        val extras = notification.extras
        val rawTitle =
            extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        // 正文兜底（P3-1）：邮件摘要、长文类通知常把内容放在 EXTRA_BIG_TEXT，
        // 只读 EXTRA_TEXT 会把整条消息丢弃。按 正文 > 大文本 > 副文本 > 多行 依次回退。
        val rawText = extras
            .getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
            .ifBlank {
                extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
                    .orEmpty()
            }
            .ifBlank {
                extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()
                    .orEmpty()
            }
            .ifBlank {
                extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
                    ?.joinToString("\n").orEmpty()
            }

        // 折叠标记清洗（P3-13，2026-10-18 收紧为路线 B）：
        // 只有「系统分组摘要」（FLAG_GROUP_SUMMARY）才可能是折叠产生的标记。
        // 普通单条通知里出现的「(N条新消息)」「[N条]」可能是真实内容
        // （例如用户把昵称改成「Frank（1000条新消息）」），一律原样保留。
        val isGroupSummary =
            (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        val folded = isGroupSummary &&
            (FOLD_PREFIX.containsMatchIn(rawText) ||
                FOLD_SUFFIX.containsMatchIn(rawTitle))

        val title =
            if (folded) FOLD_SUFFIX.replace(rawTitle, "").trim() else rawTitle.trim()
        var text =
            if (folded) FOLD_PREFIX.replace(rawText, "").trim() else rawText.trim()
        if (title.isBlank() && text.isBlank()) return

        // 折叠正文常以「发送者: 内容」开头；只在确实是折叠通知且 sender 未知时拆分，
        // 规则与 Dart 侧 database.dart::_splitFoldedMessages 保持一致。
        var foldedSender: String? = null
        if (folded) {
            val m = SENDER_PREFIX.find(text)
            if (m != null) {
                val name = m.groupValues[1].trim()
                val rest = text.substring(m.range.last + 1).trim()
                if (name.isNotEmpty() && rest.isNotEmpty()) {
                    foldedSender = name
                    text = rest
                }
            }
        }

        val postedAt =
            if (sbn.postTime > 0) sbn.postTime else System.currentTimeMillis()

        val appName = try {
            val info = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(info).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            packageName
        }

        // 无论是否放行都记录"已见应用"，让设置页能列出当前被拦截的应用
        recordSeenApp(packageName, appName, postedAt)

        // 采集层拦截：不允许的应用不进队列、不入库
        if (!isAllowed(packageName)) return

        val conversationTitle =
            extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()

        // 系统折叠机制会把同一应用的多次通知合并成一条（EXTRA_TEXT 形如
        // "[5条]某某: …"）。MessagingStyle 通知在 EXTRA_MESSAGES 里携带逐条
        // 原始消息，拆开后逐条入库，避免不相关内容被绑在一起处理。
        val bundled = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (bundled != null && bundled.isNotEmpty()) {
            for (m in bundled) {
                if (m !is android.os.Bundle) continue
                val bundledSender =
                    m.getCharSequence("sender")?.toString().orEmpty()
                val sender = bundledSender.ifBlank { foldedSender ?: "" }
                val mText = m.getCharSequence("text")?.toString().orEmpty()
                if (mText.isBlank()) continue
                val mTime = m.getLong("time").let { if (it > 0) it else postedAt }
                emit(
                    packageName, appName, notification.channelId, conversationTitle,
                    title, mText, mTime, sender
                )
            }
            return
        }
        emit(
            packageName, appName, notification.channelId, conversationTitle,
            title, text, postedAt, foldedSender
        )
    }

    /** 去重后把一条（拆分后的）消息原子写入队列目录。 */
    private fun emit(
        packageName: String,
        appName: String,
        channelId: String?,
        conversationTitle: String?,
        title: String,
        text: String,
        postedAt: Long,
        sender: String?,
    ) {
        val dedupKey = "$packageName|$title|$sender|$text|$postedAt"
        synchronized(recentKeys) {
            if (!recentKeys.add(dedupKey)) return
            if (recentKeys.size > MAX_DEDUP_KEYS) {
                recentKeys.remove(recentKeys.first())
            }
            // P3-3：进程被杀后内存窗口会丢，导致同一条通知重投时重复入库。
            // 持久化最近的一小批 key（节流写，避免每条通知都落盘）。
            schedulePersistDedupKeys()
        }

        val obj = JSONObject()
        obj.put("packageName", packageName)
        obj.put("appName", appName)
        obj.put("channelId", channelId ?: JSONObject.NULL)
        obj.put("conversationTitle", conversationTitle ?: JSONObject.NULL)
        obj.put("sender", sender ?: JSONObject.NULL)
        obj.put("title", title)
        obj.put("text", text)
        obj.put("postedTime", postedAt)

        writeAtomically(obj)
    }

    /**
     * 按应用过滤。配置缺失/解析失败一律按 mode=all 放行（向后兼容）。
     * mode=allowlist：只放行 packages 中的应用；mode=blacklist：拦截
     * packages 中的应用、其余放行。
     * SharedPreferences 有内存缓存，每次读取开销可忽略。
     */
    private fun isAllowed(packageName: String): Boolean {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val json = prefs.getString("flutter.app_filter_config", null)
                ?: return true
            val config = JSONObject(json)
            val mode = config.optString("mode", "all")
            if (mode != "allowlist" && mode != "blacklist") return true
            val packages = config.optJSONArray("packages")
                ?: return mode == "blacklist"
            var listed = false
            for (i in 0 until packages.length()) {
                if (packages.optString(i) == packageName) {
                    listed = true
                    break
                }
            }
            if (mode == "allowlist") listed else !listed
        } catch (t: Throwable) {
            true
        }
    }

    /**
     * O04（2026-10-21）：记录"已见应用"。
     *
     * 原来每条通知都要 readText(整个 seen_apps.json) → JSONObject → 改写 → writeText，
     * 而且跑在通知回调（主线程）里；群聊刷屏 / 应用更新广播这类密集场景下是持续的
     * 主线程文件 IO。现在改成：首次使用时读一次到内存，之后只改内存，
     * **最多每 2 秒**整份落盘一次；[onDestroy] 时强制 flush，避免丢。
     *
     * 语义保持不变（供设置页列候选应用）：每个包名一条
     * {packageName, appName, lastSeenAt}，后到的覆盖先到的，文件仍是
     * 「packageName -> 条目」的 JSON 对象 + tmp/rename 原子替换。
     */
    private fun recordSeenApp(packageName: String, appName: String, seenAt: Long) {
        val schedule: Boolean
        synchronized(seenAppsLock) {
            loadSeenAppsLocked()
            val entry = JSONObject()
            entry.put("packageName", packageName)
            entry.put("appName", appName)
            entry.put("lastSeenAt", seenAt)
            seenApps[packageName] = entry
            seenAppsVersion++
            schedule = !seenAppsFlushPending
            if (schedule) seenAppsFlushPending = true
        }
        if (schedule) {
            seenAppsHandler.postDelayed(seenAppsFlushRunnable, SEEN_APPS_FLUSH_DELAY_MS)
        }
    }

    /** 首次调用时把磁盘上的 seen_apps.json 读进内存（只读一次）。 */
    private fun loadSeenAppsLocked() {
        if (seenAppsLoaded) return
        seenAppsLoaded = true
        try {
            val file = File(filesDir, "seen_apps.json")
            if (!file.exists()) return
            val root = JSONObject(file.readText())
            val keys = root.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                val v = root.optJSONObject(k) ?: continue
                seenApps[k] = v
            }
        } catch (t: Throwable) {
            // 读失败从空表开始；下一次落盘会覆盖写（历史条目会丢，与原来解析失败同样处理）
        }
    }

    /** 未落盘的更新是否还有；用于 onDestroy / 测试观察。 */
    private fun seenAppsHasUnsavedChanges(): Boolean =
        synchronized(seenAppsLock) { seenAppsPersistedVersion != seenAppsVersion }

    /** 把内存态整份落盘（节流窗口到了、或服务销毁时调用）。 */
    private fun flushSeenApps() {
        val snapshot = synchronized(seenAppsLock) {
            seenAppsFlushPending = false
            if (seenAppsPersistedVersion == seenAppsVersion) return
            val root = JSONObject()
            for ((pkg, entry) in seenApps) root.put(pkg, entry)
            root.toString() to seenAppsVersion
        }
        if (writeSeenAppsAtomically(snapshot.first)) {
            synchronized(seenAppsLock) {
                if (seenAppsPersistedVersion < snapshot.second) {
                    seenAppsPersistedVersion = snapshot.second
                }
            }
        } else if (seenAppsHasUnsavedChanges()) {
            // 落盘失败：保持内存态，稍后重试（不阻塞采集、不丢内存里的记录）
            val schedule = synchronized(seenAppsLock) {
                if (seenAppsFlushPending) false else {
                    seenAppsFlushPending = true
                    true
                }
            }
            if (schedule) {
                seenAppsHandler.postDelayed(seenAppsFlushRunnable, SEEN_APPS_FLUSH_DELAY_MS)
            }
        }
    }

    /** 原子写（tmp + rename），失败返回 false 由调用方重试。 */
    private fun writeSeenAppsAtomically(text: String): Boolean {
        return try {
            val file = File(filesDir, "seen_apps.json")
            val tmp = File(filesDir, "seen_apps.json.tmp")
            tmp.writeText(text)
            if (tmp.renameTo(file)) {
                true
            } else {
                file.writeText(text)
                tmp.delete()
                true
            }
        } catch (t: Throwable) {
            false
        }
    }

    private fun writeAtomically(obj: JSONObject) {
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        val dir = File(filesDir, "queue/$day")
        if (!dir.exists()) dir.mkdirs()
        val fileName = "${UUID.randomUUID()}.json"
        val tmp = File(dir, "$fileName.tmp")
        val target = File(dir, fileName)
        tmp.writeText(obj.toString())
        if (!tmp.renameTo(target)) {
            target.writeText(obj.toString())
            tmp.delete()
        }
        notifyQueueAvailable()
    }

    /**
     * 写入成功后在主线程通知 Dart 拉取队列（失败静默：20s 轮询仍是兜底）。
     *
     * O03（2026-10-21）：按 [QUEUE_NOTIFY_DELAY_MS] 合并。一条通知仍是一个独立
     * 队列文件（不丢、各自带 postTime），但密集到达时原来**每个文件**都调一次
     * channel → Dart 侧被反复唤醒、每次都要全目录扫描；现在同一窗口内只调一次，
     * 而 Dart 的拉取本来就是「扫全目录」，合并不影响完整性。
     */
    private fun notifyQueueAvailable() {
        val schedule = synchronized(queueNotifyLock) {
            if (queueNotifyPending) false else {
                queueNotifyPending = true
                true
            }
        }
        if (schedule) {
            queueNotifyHandler.postDelayed(queueNotifyRunnable, QUEUE_NOTIFY_DELAY_MS)
        }
    }

    /** 节流持久化去重窗口：最多每 2 秒落盘一次，且只存最近的 PERSIST_DEDUP_KEYS 条。 */
    private fun schedulePersistDedupKeys() {
        if (persistPending) return
        persistPending = true
        Handler(Looper.getMainLooper()).postDelayed({
            persistPending = false
            try {
                val tail = synchronized(recentKeys) {
                    recentKeys.toList().takeLast(PERSIST_DEDUP_KEYS)
                }
                capturePrefs.edit().putStringSet(PREF_DEDUP_KEY, HashSet(tail)).apply()
            } catch (t: Throwable) {
                // 持久化失败不影响采集
            }
        }, 2000L)
    }

    private fun loadDedupKeys() {
        try {
            val saved = capturePrefs.getStringSet(PREF_DEDUP_KEY, null) ?: return
            synchronized(recentKeys) { recentKeys.addAll(saved) }
        } catch (t: Throwable) {
            // 读失败从空窗口开始
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // 不需要处理移除事件
    }

    /**
     * 系统解绑（常见于被省电策略杀进程/权限被回收前）：主动请求系统重新绑定，
     * 提升监听存活率（v2.6）。requestRebind 仅在已授权且进程存活时有效；
     * 真正的保活靠电池优化白名单 + ROM 自启动引导（设置页入口）。
     */
    override fun onListenerDisconnected() {
        try {
            requestRebind(ComponentName(this, NotificationCaptureService::class.java))
        } catch (t: Throwable) {
            // 请求失败说明系统暂不允许重绑，等待系统下次自动绑定
        }
    }

    override fun onListenerConnected() {
        // 绑定成功：无需额外动作（队列为文件，Dart 侧轮询自取）
    }
}
