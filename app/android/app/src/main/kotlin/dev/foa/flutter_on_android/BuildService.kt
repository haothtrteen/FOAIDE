package dev.foa.flutter_on_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 构建前台服务（alpha.31）：App 退到桌面 / 锁屏 / 切其他应用时构建继续。
 *
 * 背景：构建进程树（proot/bare 起的 gradle + dart）是 App 进程的子进程，
 * 退到后台后 App 进程优先级跌到 cached，随时被 LMK 连坐整树——幸存的
 * dart 孤儿还持有 flutter 启动锁，下次构建必卡（Bug 420 的源头）。
 * 前台服务把进程优先级抬到 FOREGROUND，10~30 分钟的构建窗口内系统不动它。
 *
 * 分工：
 * - 生命周期：Dart 构建开始 → notifyStart（startForegroundService）；
 *   结束/取消 → finish（更新结果文案 + stopForeground(false) detach +
 *   stopSelf，通知留在通知栏可滑除）；
 * - 进度：update() 由 Dart 按「阶段/百分比变化」节流推送，这里再限频
 *   800ms，防 gradle 刷屏打爆 NotificationManager；
 * - 点击回跳：contentIntent → MainActivity（singleTop）+ EXTRA_NAVIGATE，
 *   App 前台时走 onNewIntent → channel.invokeMethod("navigate")，冷启动时
 *   Dart 就绪后 takeNavigate 拉取（MainActivity.pendingNavigate 暂存）。
 *
 * 权限注记（targetSdk 28）：FOREGROUND_SERVICE（API 28+ 必需）声明即可，
 * 无 foregroundServiceType 强制（那是 targetSdk 34+ 的约束）；
 * POST_NOTIFICATIONS 对 targetSdk<33 的应用在 Android 13+ 由系统自动授予。
 */
class BuildService : Service() {

    companion object {
        const val CHANNEL_ID = "foa_build"
        const val NOTIF_ID = 0xF0A
        const val EXTRA_NAVIGATE = "navigate"
        const val NAV_BUILD = "build"
        private const val EXTRA_TITLE = "title"
        private const val THROTTLE_MS = 800L

        @Volatile private var instance: BuildService? = null
        @Volatile private var lastPushAt = 0L
        @Volatile private var lastText: String? = null
        @Volatile private var lastPct = -1
        @Volatile private var lastTitle: String? = null

        /** 构建开始：启动前台服务（API 26+ 必须 startForegroundService）。 */
        fun start(context: Context, title: String) {
            lastTitle = title
            lastText = null
            lastPct = -1
            val intent = Intent(context, BuildService::class.java)
                .putExtra(EXTRA_TITLE, title)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** 进度更新（安全：服务未运行时静默丢——启动竞态不值得处理）。 */
        fun update(context: Context, text: String, percent: Int) {
            val svc = instance ?: return
            val now = System.currentTimeMillis()
            if (now - lastPushAt < THROTTLE_MS) return
            if (text == lastText && percent == lastPct) return
            lastPushAt = now
            lastText = text
            lastPct = percent
            svc.push(buildNotification(context, text, percent, ongoing = true))
        }

        /** 结束/取消：结果文案 + 停服务（通知 detach 留给用户点回/滑除）。 */
        fun finish(context: Context, text: String) {
            instance?.let { svc ->
                svc.push(buildNotification(context, text, lastPct, ongoing = false))
            }
            lastText = null
            lastPct = -1
            // stopForeground(false)：撤前台状态但保留通知（detach），
            // 再 stopSelf；下一次 start 会重新接管同 id 通知
            instance?.stopForeground(false)
            context.stopService(Intent(context, BuildService::class.java))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            nm.createNotificationChannel(
                // IMPORTANCE_LOW：常驻不响铃、不出 heads-up，下拉才可见
                NotificationChannel(CHANNEL_ID, "构建进度", NotificationManager.IMPORTANCE_LOW)
            )
        }

        private fun buildNotification(
            context: Context,
            text: String,
            percent: Int,
            ongoing: Boolean,
        ): Notification {
            ensureChannel(context)
            val pi = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java)
                    .putExtra(EXTRA_NAVIGATE, NAV_BUILD),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val b = if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return b.setContentTitle(lastTitle ?: "构建")
                .setContentText(text)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pi)
                .setOnlyAlertOnce(true)
                .setOngoing(ongoing)
                // percent<0 = 不确定进度；Dart 侧恒传 0~100，防御性兜底
                .setProgress(100, percent.coerceIn(0, 100), percent < 0)
                .build()
        }
    }

    private fun push(n: Notification) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, n)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "构建中"
        lastTitle = title
        lastPushAt = 0L
        // targetSdk 28：无 type 参数版本（API 29 起才有 type 机制）
        startForeground(
            NOTIF_ID,
            buildNotification(this, "正在准备构建…", 0, ongoing = true),
        )
        // 被杀不重建：进程死亡时构建子进程树已死，重建服务无意义
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }
}
