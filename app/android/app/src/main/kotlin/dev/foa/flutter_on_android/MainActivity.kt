package dev.foa.flutter_on_android

import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Step 1 核心：proot 桥。
 *
 * 架构决策（详见 dev-handbook/01-环境搭建.md）：
 * - Dart 不直接 Process.start 二进制（不可靠），统一走 MethodChannel → Kotlin ProcessBuilder；
 * - proot 双路径定位：优先 nativeLibraryDir/libproot.so（jniLibs，W^X 安全），
 *   其次 filesDir/tools/proot（assets 拷贝，需要 targetSdk 28）；
 * - rootfs 用系统自带 toybox tar 解压（保留权限/符号链接，Dart archive 包做不到）；
 * - 所有命令执行记录结构化结果（exitCode/stdout/stderr/duration），由 Dart 侧落日志。
 *
 * ⚠️ 前提：android/app/build.gradle 中 targetSdk 必须为 28。
 *    Android 10+ 禁止 targetSdk≥29 的应用 execve() 自身数据目录中的文件（W^X 限制），
 *    rootfs 内的 guest 二进制由内核真实执行，必须走 targetSdk 28 兼容域。
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "dev.foa/proot"
        // FileProvider authority 后缀。完整 authority = "<当前包名>.fileprovider"，
        // 由 [fileProviderAuthority] 从 packageName 动态推导——**不要在别处再写死
        // 完整包名字符串**。历史上这里与 Manifest 各写死了一份
        // "dev.foa.flutter_on_android.fileprovider"，一旦改 applicationId，两处
        // 不同步就会导致"点安装 APK"时 FileProvider.getUriForFile 抛
        // IllegalArgumentException，且崩在安装那一刻、极难定位。
        // Manifest 侧用 ${applicationId} 占位符，与本处同源（都是真实包名）。
        const val FILE_PROVIDER_SUFFIX = ".fileprovider"
        const val ROOTFS_REL = "rootfs/debian"
        // Step 2：项目代码区（容器内 /root/projects ↔ 真实 filesDir/rootfs/debian/root/projects）。
        // 所有文件操作只允许此区域，防止误改 rootfs 系统文件。
        const val PROJECTS_REL = "rootfs/debian/root/projects"
        // Step 4 文件浏览器：导入文件的容器落脚点（↔ filesDir/rootfs/debian/root/imports）。
        // 与 SDK 安装的导入区 filesDir/imports（pickInstallFile）分开——容器内可见，
        // 导入后可直接解压/浏览；SDK 导入区是内部缓存，文件浏览器不展示。
        const val IMPORTS_GUEST = "/root/imports"
        // 注意：原生 AssetManager 的路径相对 APK 的 assets/ 根，
        // 而 Flutter 打包的资产全部位于 flutter_assets/ 子目录下，
        // 因此必须带 flutter_assets/ 前缀（Bug 208：曾漏前缀导致真机
        // FileNotFoundException，assets 里明明有文件却报"资产缺失"）
        const val ASSET_ROOTFS = "flutter_assets/assets/rootfs/debian-minbase-arm64.tar.gz"
        const val ASSET_PROOT = "flutter_assets/assets/tools/proot-arm64"
        const val ASSET_LOADER = "flutter_assets/assets/tools/proot-loader" // Termux proot 的 ptrace loader
        // Bug 210：proot（Termux bionic 构建）readelf -d 显示 NEEDED
        // libtalloc.so.2 / libandroid-shmem.so，系统目录均不存在 → 随 assets 分发
        const val ASSET_LIBTALLOC = "flutter_assets/assets/tools/libtalloc.so.2"
        const val ASSET_LIBSHMEM = "flutter_assets/assets/tools/libandroid-shmem.so"
        const val LIB_PROOT = "libproot.so" // jniLibs 分发名
        // Step 5 项目工作区迁移：外部存储下用户可见的项目目录名
        // （/storage/emulated/0/Android/data/<pkg>/projects，文件管理器/USB 可见）；
        // 构建位置仍是容器 /root/projects（= filesDir，可执行，W^X 安全）。
        const val PROJECTS_EXTERNAL_NAME = "projects"
        // toExternal 方向跳过这些构建缓存目录，避免污染用户可见区
        val PROJECT_CACHE_DIRS = setOf("build", ".gradle", ".dart_tool")
        // 原生 arm64 后端：容器内原生产物目录，以及"是否已落位 bionic 版
        // gen_snapshot"的判定文件（存在即给 proot 追加 /system、/apex 挂载）。
        const val NATIVE_GEN_SNAPSHOT_REL = "opt/foa-native/gen_snapshot"
        val NATIVE_BIONIC_BINDS = listOf("/system", "/apex", "/linkerconfig")

        // ---------------- proroot（容器层替代，alpha.61 接入） ----------------
        // proroot 用 LD_PRELOAD + 二进制补丁替代 proot 的 ptrace 路径翻译，
        // 省掉每次系统调用的两次上下文切换。**它只优化容器层**：
        // QEMU 指令翻译与 dart/gradle 计算不受影响。
        //
        // 落位目录：filesDir/proroot/。放这里而不是 jniLibs 的原因——
        // jniLibs 的 .so 会被 Android 校验并当作"库"加载，而 proroot 的
        // 5 个 .so 里只有 libproroot.so 是启动器、其余是运行时组件，
        // 混在 jniLibs 里反而要靠 rename 绕过（现有 proot 就是这么做的，
        // 代价是名字对不上、排查困难）。用户可通过「导入 proroot」按钮
        // 从文件管理器把这 5 个 .so 一次性放进来。
        const val PROROOT_DIR = "proroot"

        /** proroot 需要的 5 个 .so（缺一不可，顺序即加载顺序）。 */
        val PROROOT_SO_FILES = listOf(
            "libproroot.so",
            "libproroot-runtime.so",
            "libproroot-linker.so",
            "libproroot-bridge.so",
            "libproroot-stub-loader.so",
        )
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    // Step 3：本地安装兜底——系统文件选择器（ACTION_OPEN_DOCUMENT）的挂起结果。
    // 原生层把用户所选文件拷贝到 filesDir/imports 后再回给 Dart，避免 SAF 的
    // content:// URI 在 proot 子进程里不可读（proot 只能读真实文件路径）。
    private var pendingPickResult: MethodChannel.Result? = null
    private val pickRequestCode = 0x2001
    // Step 4 文件浏览器：导入（任意文件 → /root/imports）与导出（文件 → SAF 目标）的挂起状态。
    private var pendingImportResult: MethodChannel.Result? = null
    private val importRequestCode = 0x2002
    private var pendingExportResult: MethodChannel.Result? = null
    private var pendingExportSource: File? = null
    private val exportRequestCode = 0x2003
    // alpha.61 proroot 导入：目录选择器挂起结果
    private var pendingProrootResult: MethodChannel.Result? = null
    private val prorootRequestCode = 0x2004

    // alpha.31 构建前台服务：Dart 通道引用（原生 → Dart 反向 invoke：点通知回构建页）
    private var dartChannel: MethodChannel? = null
    // 冷启动点通知进来：Dart handler 未注册前先存着，Dart 就绪后 takeNavigate 拉取
    @Volatile private var pendingNavigate = false

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        // Bug 457：Android 15+（SDK_INT>=35）上 Flutter 引擎会跳过
        // Window.setStatusBarColor/setNavigationBarColor，浅色主题会出现
        // 「顶栏浅色、状态栏深色」的割裂（透出 windowBackground）。
        // 这里在原生侧按当前主题兜底设色——它在引擎设色之后仍生效，
        // 是那类设备上唯一能让系统栏跟上主题的途径。
        applySystemBarColorsForTheme()
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        dartChannel = channel
        // 冷启动导航意图：onCreate 的 intent 可能带「点通知回构建页」标记
        pendingNavigate = intent?.getStringExtra(BuildService.EXTRA_NAVIGATE) == BuildService.NAV_BUILD
        channel.setMethodCallHandler { call, result ->
            // 全部放到后台线程执行，避免 ANR。
            executor.execute {
                try {
                    when (call.method) {
                        "envInfo" -> result.success(envInfo())
                        "exec" -> {
                            val command = call.argument<String>("command") ?: ""
                            val timeoutSec = (call.argument<Number>("timeoutSec") ?: 180).toLong()
                            val bare = call.argument<Boolean>("bare") == true
                            val proroot = call.argument<Boolean>("proroot") == true
                            result.success(exec(command, timeoutSec, bare, proroot))
                        }
                        // ---- Step 6 构建：流式执行（长任务，轮询增量输出 + 可取消）----
                        "execStream" -> {
                            val command = call.argument<String>("command") ?: ""
                            val timeoutSec = (call.argument<Number>("timeoutSec") ?: 7200).toLong()
                            val bare = call.argument<Boolean>("bare") == true
                            val proroot = call.argument<Boolean>("proroot") == true
                            result.success(execStream(command, timeoutSec, bare, proroot))
                        }
                        // ---- proroot 容器层（alpha.61）----
                        // 四件套：查状态 / 从 SAF 导入 / 清空 / 冒烟测试。
                        // 冒烟测试必须真跑——proroot 要求 Ubuntu arm64，
                        // 而本项目用 Debian，属未验证组合，光看文件在不在
                        // 判断不了能不能用。
                        "prorootStatus" -> result.success(prorootStatus())
                        "prorootRemove" -> result.success(prorootRemove())
                        "prorootProbe" -> result.success(prorootProbe())
                        "prorootImport" -> {
                            // 走系统目录选择器，用户选一个含 .so 的目录。
                            // 原生侧不能自己开 Activity 并等结果（会阻塞
                            // 这个后台线程），所以像 pickInstallFile 那样
                            // 挂起 result、主线程起 Activity。
                            pendingProrootResult = result
                            runOnUiThread {
                                try {
                                    val intent = android.content.Intent(
                                        android.content.Intent.ACTION_OPEN_DOCUMENT_TREE
                                    )
                                    intent.addFlags(
                                        android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
                                    )
                                    startActivityForResult(intent, prorootRequestCode)
                                } catch (e: Exception) {
                                    pendingProrootResult = null
                                    result.success(fail(-500, "无法打开目录选择器：${e.message}"))
                                }
                            }
                        }
                        "execStreamPoll" -> {
                            val id = (call.argument<Number>("id") ?: -1L).toLong()
                            val offset = (call.argument<Number>("offset") ?: 0).toInt()
                            result.success(execStreamPoll(id, offset))
                        }
                        "execStreamStop" -> {
                            val id = (call.argument<Number>("id") ?: -1L).toLong()
                            result.success(execStreamStop(id))
                        }
                        "installApk" -> installApkAsync(result, call.argument<String>("path") ?: "")
                        "installRootfs" -> result.success(installRootfs())
                        // ---- Bug 430 · 可交互 PTY 终端 ----
                        // 五件套：起会话 / 写按键 / 轮询输出 / 停止 / 改窗口尺寸。
                        // 走真正的 pty（foa_pty 中继器），vim/top/apt 进度条、
                        // Ctrl+C、方向键历史、tab 补全全部可用。
                        "ptyStart" -> {
                            val bare = call.argument<Boolean>("bare") == true
                            val cols = (call.argument<Number>("cols") ?: 80).toInt()
                            val rows = (call.argument<Number>("rows") ?: 24).toInt()
                            result.success(ptyStart(bare, cols, rows))
                        }
                        "ptyWrite" -> {
                            val id = (call.argument<Number>("id") ?: -1L).toLong()
                            val text = call.argument<String>("text") ?: ""
                            result.success(ptyWrite(id, text))
                        }
                        "ptyPoll" -> {
                            val id = (call.argument<Number>("id") ?: -1L).toLong()
                            val offset = (call.argument<Number>("offset") ?: 0).toInt()
                            result.success(ptyPoll(id, offset))
                        }
                        "ptyStop" -> {
                            val id = (call.argument<Number>("id") ?: -1L).toLong()
                            result.success(ptyStop(id))
                        }
                        "ptyResize" -> {
                            val id = (call.argument<Number>("id") ?: -1L).toLong()
                            val cols = (call.argument<Number>("cols") ?: 80).toInt()
                            val rows = (call.argument<Number>("rows") ?: 24).toInt()
                            result.success(ptyResize(id, cols, rows))
                        }
                        // ---- Step 3 · 本地安装兜底：系统文件选择器 ----
                        "pickInstallFile" -> {
                            pendingPickResult = result
                            // startActivityForResult 必须在主线程调用
                            runOnUiThread {
                                try {
                                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                        addCategory(Intent.CATEGORY_OPENABLE)
                                        type = "*/*"
                                        putExtra(
                                            Intent.EXTRA_MIME_TYPES,
                                            arrayOf(
                                                "application/gzip",
                                                "application/x-gzip",
                                                "application/x-tar",
                                                "application/octet-stream",
                                            ),
                                        )
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    startActivityForResult(intent, pickRequestCode)
                                } catch (e: Exception) {
                                    pendingPickResult = null
                                    result.success(
                                        mapOf("ok" to false, "error" to "无法打开文件选择器: ${e.message}"),
                                    )
                                }
                            }
                        }
                        // ---- Step 2 文件操作（全部限定在 /root/projects 内）----
                        "fileList" -> {
                            val path = call.argument<String>("path") ?: "/root/projects"
                            result.success(fileList(path))
                        }
                        "fileRead" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(fileRead(path))
                        }
                        "fileWrite" -> {
                            val path = call.argument<String>("path") ?: ""
                            val content = call.argument<String>("content") ?: ""
                            result.success(fileWrite(path, content))
                        }
                        "fileMkdir" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(fileMkdir(path))
                        }
                        "fileRename" -> {
                            val path = call.argument<String>("path") ?: ""
                            val newName = call.argument<String>("newName") ?: ""
                            result.success(fileRename(path, newName))
                        }
                        "fileDelete" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(fileDelete(path))
                        }
                        // ---- Step 4 文件浏览器（rootfs 全路径白名单，与编辑器 file* 的
                        //      /root/projects 白名单独立；浏览+CRUD+导入导出）----
                        "fsBrowse" -> {
                            val path = call.argument<String>("path") ?: "/"
                            result.success(fsBrowse(path))
                        }
                        "fsMkdir" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(fsMkdir(path))
                        }
                        "fsRename" -> {
                            val path = call.argument<String>("path") ?: ""
                            val newName = call.argument<String>("newName") ?: ""
                            result.success(fsRename(path, newName))
                        }
                        "fsDelete" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(fsDelete(path))
                        }
                        "fsCopy" -> {
                            result.success(
                                fsCopy(
                                    call.argument<String>("src") ?: "",
                                    call.argument<String>("dst") ?: "",
                                ),
                            )
                        }
                        "fsMove" -> {
                            result.success(
                                fsMove(
                                    call.argument<String>("src") ?: "",
                                    call.argument<String>("dst") ?: "",
                                ),
                            )
                        }
                        // ---- Step 4 宿主域（真实路径）：/data 与 Android/data 白名单 ----
                        "hostBrowse" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(hostBrowse(path))
                        }
                        "hostMkdir" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(hostMkdir(path))
                        }
                        "hostRename" -> {
                            val path = call.argument<String>("path") ?: ""
                            val newName = call.argument<String>("newName") ?: ""
                            result.success(hostRename(path, newName))
                        }
                        "hostDelete" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(hostDelete(path))
                        }
                        "hostCopy" -> {
                            result.success(
                                hostCopy(
                                    call.argument<String>("src") ?: "",
                                    call.argument<String>("dst") ?: "",
                                ),
                            )
                        }
                        "hostMove" -> {
                            result.success(
                                hostMove(
                                    call.argument<String>("src") ?: "",
                                    call.argument<String>("dst") ?: "",
                                ),
                            )
                        }
                        // ---- Step 5 项目工作区同步（外部存储 ↔ 容器 /root/projects）----
                        "syncProjects" -> {
                            val direction = call.argument<String>("direction") ?: "toContainer"
                            result.success(syncProjects(direction))
                        }
                        "pickImportFile" -> {
                            pendingImportResult = result
                            runOnUiThread {
                                try {
                                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                        addCategory(Intent.CATEGORY_OPENABLE)
                                        type = "*/*" // 任意文件（不限 SDK 安装包）
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    startActivityForResult(intent, importRequestCode)
                                } catch (e: Exception) {
                                    pendingImportResult = null
                                    result.success(
                                        mapOf("ok" to false, "error" to "无法打开文件选择器: ${e.message}"),
                                    )
                                }
                            }
                        }
                        "exportFile" -> exportFile(
                            result,
                            call.argument<String>("path") ?: "",
                            call.argument<String>("displayName") ?: "export.bin",
                        )
                        // ---- alpha.31 构建前台服务：通知栏进度 + 点击回构建页 ----
                        "notificationsEnabled" -> result.success(notificationEnabled())
                        "notifyStart" -> {
                            BuildService.start(this, call.argument<String>("title") ?: "构建中")
                            result.success(true)
                        }
                        "notifyProgress" -> {
                            BuildService.update(
                                this,
                                call.argument<String>("text") ?: "",
                                (call.argument<Number>("percent") ?: 0).toInt(),
                            )
                            result.success(true)
                        }
                        "notifyStop" -> {
                            BuildService.finish(this, call.argument<String>("text") ?: "")
                            result.success(true)
                        }
                        "takeNavigate" -> result.success(pendingNavigate.also { pendingNavigate = false })
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("ERR_${call.method}", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    override fun onDestroy() {
        /*
         * PTY 会话必须显式收掉：shim + proot + shell 是一串真实子进程，
         * Activity 销毁（用户按返回键退出）后若放任它们存活，会残留
         * 僵尸 shell 与占用的 /dev/pts，并在下次进入时表现为「终端打不开」。
         * 同理清理临时尺寸控制文件。
         */
        try {
            ptyRegistry.stopAll()
        } catch (_: Exception) {
        }
        try {
            // ⚠️ 这里必须写成 `java.io.File(filesDir, "tmp")` 的函数调用形式。
            // 写成 `File(File(...))` 时，Kotlin 会把外层 `File` 解析成
            // **File 类的构造器引用**（不是 java.io.File 的工厂函数），
            // 于是报 "None of the following candidates is applicable"
            // 并连带 listFiles/name/delete 全部 Unresolved（Bug 440）。
            // 显式限定 java.io.File 可消除歧义。
            val tmpDir = java.io.File(filesDir, "tmp")
            tmpDir.listFiles()?.forEach { f ->
                if (f.name.startsWith("pty-size-")) f.delete()
            }
        } catch (_: Exception) {
        }
        executor.shutdownNow()
        super.onDestroy()
    }

    /** 通知点击回跳（singleTop：App 前台时走这里）→ 转发给 Flutter 导航。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getStringExtra(BuildService.EXTRA_NAVIGATE) == BuildService.NAV_BUILD) {
            pendingNavigate = true
            // 主线程（onNewIntent）→ invokeMethod 安全；Dart 未就绪时引擎
            // 内部丢弃，pendingNavigate 兜底（Dart 就绪后 takeNavigate 拉取）
            dartChannel?.invokeMethod("navigate", null)
        }
    }

    /** 通知是否可用（Android 13+ 用户可关；targetSdk<33 默认授权）。 */
    private fun notificationEnabled(): Boolean =
        try {
            getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        } catch (_: Exception) {
            true
        }

    /** 文件选择器回调：拷贝所选文件到 filesDir/imports（后台线程），再回结果。 */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == pickRequestCode) {
            val r = pendingPickResult
            pendingPickResult = null
            if (resultCode != RESULT_OK || data?.data == null) {
                r?.success(mapOf("ok" to false, "error" to "已取消选择"))
                return
            }
            val uri = data.data!!
            // 183MB 级拷贝放后台线程，避免阻塞主线程（ANR）
            executor.execute {
                try {
                    val importDir = File(filesDir, "imports").apply { mkdirs() }
                    val displayName = queryDisplayName(uri) ?: "jdk_install.tar.gz"
                    val safe = displayName.replace(Regex("[^A-Za-z0-9._-]"), "_")
                    val dest = File(importDir, safe)
                    val input = contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("无法读取所选文件")
                    input.use { ins ->
                        dest.outputStream().use { out -> ins.copyTo(out, 1 shl 16) }
                    }
                    r?.success(
                        mapOf(
                            "ok" to true,
                            "path" to dest.absolutePath,
                            "name" to dest.name,
                            "size" to dest.length(),
                        ),
                    )
                } catch (e: Exception) {
                    r?.success(mapOf("ok" to false, "error" to "复制文件失败: ${e.message}"))
                }
            }
            return
        }
        // Step 4 文件浏览器 · 导入：拷贝到容器 /root/imports（真实 filesDir/rootfs/debian/root/imports），
        // 返回容器路径——Dart 侧直接可见、可解压/导出，无需二次映射。
        if (requestCode == importRequestCode) {
            val r = pendingImportResult
            pendingImportResult = null
            if (resultCode != RESULT_OK || data?.data == null) {
                r?.success(mapOf("ok" to false, "error" to "已取消选择"))
                return
            }
            val uri = data.data!!
            executor.execute {
                try {
                    val importDir = File(File(filesDir, ROOTFS_REL), IMPORTS_GUEST.removePrefix("/"))
                        .apply { mkdirs() }
                    val displayName = queryDisplayName(uri) ?: "import.bin"
                    val safe = displayName.replace(Regex("[^A-Za-z0-9._-]"), "_")
                    val dest = File(importDir, safe)
                    val input = contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("无法读取所选文件")
                    input.use { ins ->
                        dest.outputStream().use { out -> ins.copyTo(out, 1 shl 16) }
                    }
                    r?.success(
                        mapOf(
                            "ok" to true,
                            "path" to "$IMPORTS_GUEST/${dest.name}",
                            "name" to dest.name,
                            "size" to dest.length(),
                        ),
                    )
                } catch (e: Exception) {
                    r?.success(mapOf("ok" to false, "error" to "复制文件失败: ${e.message}"))
                }
            }
            return
        }
        // Step 4 文件浏览器 · 导出：把 pendingExportSource 写入用户选择的 SAF 目标。
        if (requestCode == exportRequestCode) {
            val r = pendingExportResult
            val src = pendingExportSource
            pendingExportResult = null
            pendingExportSource = null
            if (resultCode != RESULT_OK || data?.data == null) {
                r?.success(mapOf("ok" to false, "error" to "已取消导出"))
                return
            }
            val uri = data.data!!
            executor.execute {
                try {
                    val srcFile = src ?: throw IllegalStateException("导出源文件丢失")
                    val out = contentResolver.openOutputStream(uri)
                        ?: throw IllegalStateException("无法写入目标位置")
                    srcFile.inputStream().use { ins ->
                        out.use { o -> ins.copyTo(o, 1 shl 16) }
                    }
                    r?.success(mapOf("ok" to true, "size" to srcFile.length()))
                } catch (e: Exception) {
                    r?.success(mapOf("ok" to false, "error" to "导出失败: ${e.message}"))
                }
            }
            return
        }
        // alpha.61 proroot 导入：用户选了一个**目录**（ACTION_OPEN_DOCUMENT_TREE
        // 返回的是 tree URI，不是文件），先把整个目录递归拷到应用私有的
        // 临时区，再交给 prorootInstall 按文件名认领。
        if (requestCode == prorootRequestCode) {
            val r = pendingProrootResult
            pendingProrootResult = null
            if (resultCode != RESULT_OK || data?.data == null) {
                r?.success(mapOf("ok" to false, "error" to "已取消选择"))
                return
            }
            val treeUri = data.data!!
            executor.execute {
                try {
                    val stage = File(filesDir, "proroot-import")
                    stage.deleteRecursively()
                    stage.mkdirs()
                    val n = copyTree(treeUri, stage)
                    if (n == 0) {
                        r?.success(
                            mapOf(
                                "ok" to false,
                                "error" to "所选目录里没有可读取的文件",
                            ),
                        )
                        return@execute
                    }
                    r?.success(prorootInstall(stage.absolutePath))
                    stage.deleteRecursively()
                } catch (e: Exception) {
                    r?.success(mapOf("ok" to false, "error" to "导入失败: ${e.message}"))
                }
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * 递归拷贝 SAF 目录树到真实目录，返回拷贝的文件数。
     *
     * ACTION_OPEN_DOCUMENT_TREE 只给一个 tree URI，里面有什么得自己走
     * DocumentsContract 遍历——不能像普通文件那样 openInputStream 一次搞定。
     * 拷贝而不是原地读：SAF 的 URI 在子进程里不可读（proroot 只能读真实
     * 文件路径），与 Step 3/4 的处理方式一致。
     */
    private fun copyTree(treeUri: Uri, dest: File): Int {
        var count = 0
        val rootId = android.provider.DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri, rootId,
        )
        val proj = arrayOf(
            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        val stack = ArrayDeque<Pair<Uri, File>>()
        stack.addLast(childrenUri to dest)
        while (stack.isNotEmpty()) {
            val (cur, outDir) = stack.removeLast()
            contentResolver.query(cur, proj, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val name = c.getString(1) ?: continue
                    val mime = c.getString(2) ?: ""
                    val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
                    val childDocUri =
                        android.provider.DocumentsContract.buildDocumentUriUsingTree(
                            treeUri, id,
                        )
                    if (mime == android.provider.DocumentsContract.Document.MIME_TYPE_DIR) {
                        val sub = File(outDir, safe).apply { mkdirs() }
                        stack.addLast(
                            android.provider.DocumentsContract
                                .buildChildDocumentsUriUsingTree(treeUri, id) to sub,
                        )
                    } else {
                        outDir.mkdirs()
                        try {
                            contentResolver.openInputStream(childDocUri)?.use { ins ->
                                File(outDir, safe).outputStream()
                                    .use { o -> ins.copyTo(o, 1 shl 16) }
                            }
                            count++
                        } catch (_: Exception) {
                            // 单个文件读不了不影响其余（SAF 权限面常见）
                        }
                    }
                }
            }
        }
        return count
    }

    private fun queryDisplayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }

    // ---------------- 环境信息 ----------------

    private fun envInfo(): Map<String, Any?> {
        val rootfs = File(filesDir, ROOTFS_REL)
        val avf = avfCapability()
        return mapOf(
            "filesDir" to filesDir.absolutePath,
            // 真实包名（runtime 取，非编译期常量）：将来改 applicationId 或
            // 加 applicationIdSuffix（dev/prod 双分身）时，这里自动跟随。
            // Dart 侧禁止自己拼 /data/data/<pkg>，一律用这个值。
            "packageName" to packageName,
            "cacheDir" to cacheDir.absolutePath,
            "nativeLibraryDir" to applicationInfo.nativeLibraryDir,
            "rootfsPath" to rootfs.absolutePath,
            "rootfsInstalled" to File(rootfs, "bin/sh").exists(),
            // Step 4 文件浏览器宿主域根：内部 filesDir + 外部 Android/data/<pkg>
            "externalDataDir" to externalDataDir()?.absolutePath,
            "prootPath" to findProot()?.absolutePath,
            "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
            "androidSdk" to Build.VERSION.SDK_INT,
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            // AVF（Android 虚拟化框架）能力检测：只用于「告知用户可否走 AVF 路线」，
            // 不尝试创建/驱动 VM——普通 App（untrusted_app 域）没有该系统服务的 API 权限。
            "avfSupported" to avf.supported,
            "avfTerminalInstalled" to avf.terminalInstalled,
            "avfReason" to avf.reason,
        )
    }

    /** AVF 能力探测结果。 */
    private data class AvfCapability(
        val supported: Boolean,
        val terminalInstalled: Boolean,
        val reason: String,
    )

    /**
     * 探测本机是否具备 AVF（Android Virtualization Framework）Linux 开发环境。
     *
     * 判据（全部只读，无副作用）：
     * 1. API ≥ 33（AVF 自 Android 13 引入）；
     * 2. 存在虚拟化终端 App（com.android.virtualization.terminal，Pixel 的「Linux 开发环境」）；
     * 3. 内核暴露 pKVM 支持（/proc/version 或只读系统属性）。
     *
     * ⚠️ 本函数**只做检测与引导**。不创建 VM、不启动 VM、不调用 virtmgr ——
     *    这些是特权系统服务的职责，普通应用无 API 可及（详见 AVF集成可行性评估.md）。
     *    目的是告诉用户「你的设备能不能走 AVF 这条更快的路」，避免瞎折腾。
     */
    private fun avfCapability(): AvfCapability {
        if (Build.VERSION.SDK_INT < 33) {
            return AvfCapability(false, false, "需要 Android 13+（当前 API ${Build.VERSION.SDK_INT}）")
        }
        val terminal = try {
            packageManager.getPackageInfo("com.android.virtualization.terminal", 0)
            true
        } catch (_: Exception) {
            false
        }
        // pKVM 支持：内核启动参数/版本串里带 pkvm 或 hypervisor 标识
        val kernelEvidences = try {
            File("/proc/version").readText().lowercase()
        } catch (_: Exception) {
            ""
        }
        val hasPkvm = kernelEvidences.contains("pkvm") || kernelEvidences.contains("hypervisor")
        return when {
            terminal && hasPkvm ->
                AvfCapability(true, true, "设备支持 AVF，且已安装 Linux 开发环境终端")
            terminal ->
                AvfCapability(true, true, "已安装 Linux 开发环境终端（pKVM 标识未在 /proc/version 出现，可能被内核隐藏）")
            hasPkvm ->
                AvfCapability(true, false, "设备具备虚拟化能力，但未找到 Linux 开发环境入口")
            else ->
                AvfCapability(false, false, "本机未检测到 AVF 支持（需 pKVM 硬件 + 厂商开放入口）")
        }
    }

    /** 外部存储的 app 专属目录：/storage/emulated/0/Android/data/<pkg>（getExternalFilesDir 的父级）。 */
    private fun externalDataDir(): File? =
        getExternalFilesDir(null)?.parentFile

    /**
     * FileProvider authority：**从真实包名推导**，与 Manifest 的
     * `${applicationId}.fileprovider` 同源。
     *
     * 用 `packageName`（Application 提供的当前进程包名）而非
     * `BuildConfig.APPLICATION_ID`：前者在任何构建变体/调试后缀下都是
     * 运行时真值，后者在 applicationIdSuffix 场景需额外留意。
     *
     * 历史教训：本处与 Manifest 曾各自写死一份完整包名字符串，改包名时
     * 只要漏改一处，安装 APK 就会在 getUriForFile 抛 IllegalArgumentException。
     */
    private val fileProviderAuthority: String
        get() = "$packageName$FILE_PROVIDER_SUFFIX"

    /**
     * Bug 457：按当前系统深/浅色给状态栏与导航栏设色（原生兜底）。
     *
     * 为什么需要：Flutter 引擎（3.47.4 实测字节码）在
     * `SDK_INT >= 35` 时无条件跳过 `Window.setStatusBarColor`，因此 Dart 侧
     * 的 `SystemChrome`/`systemOverlayStyle` 颜色在这类设备上不生效，
     * 系统栏回落窗口背景色（styles.xml 的 #101418 深色）→ 浅色主题割裂。
     *
     * 颜色值必须与 `lib/core/theme.dart` 的 `FoaTheme.overlayFor()` 一致
     * （深色 #101418 / 浅色 #F5F7F8）。两边不一致会重新引入本 bug。
     *
     * 用 `resources.configuration.uiMode` 读系统深色标志——与
     * `AppCompatDelegate`/Material 的判定一致。注意：本 App 的主题由 Dart 侧
     * `ThemeController` 控制（可能≠系统），故此处只解决"系统栏与窗口背景"
     * 这一层的一致性；Dart 侧切主题后仍会走 `AnnotatedRegion` 覆盖
     * （在 < 35 的设备上有效）。二者叠加不会互相打架，因为目标值同源。
     */
    private fun applySystemBarColorsForTheme() {
        val night = (resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES
        val color = if (night) 0xFF101418.toInt() else 0xFFF5F7F8.toInt()
        runOnUiThread {
            window?.statusBarColor = color
            window?.navigationBarColor = color
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val controller = androidx.core.view.WindowInsetsControllerCompat(
                    window, window.decorView
                )
                // 深色背景 → 浅色图标；浅色背景 → 深色图标
                controller.isAppearanceLightStatusBars = !night
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    controller.isAppearanceLightNavigationBars = !night
                }
            }
        }
    }

    /** proot 定位：jniLibs 优先（不受 W^X 限制），assets 拷贝兜底（需 targetSdk 28） */
    private fun findProot(): File? {
        val fromLibs = File(applicationInfo.nativeLibraryDir, LIB_PROOT)
        if (fromLibs.exists()) return fromLibs
        val fromAssets = File(filesDir, "tools/proot")
        if (fromAssets.exists() && fromAssets.canExecute()) return fromAssets
        return null
    }

    /**
     * proot 的 ptrace loader（Termux 构建版必需，其默认路径硬编码为 com.termux）。
     * 实测 proot 认 PROOT_LOADER 环境变量（指向不存在的 loader 会直接 fatal error），
     * 因此无需重编译 proot——启动时把该变量指向 filesDir/tools/loader 即可。
     */
    private fun findLoader(): File? {
        val f = File(filesDir, "tools/loader")
        return if (f.exists()) f else null
    }

    // ---------------- 命令执行 ----------------

    /**
     * 幂等同步 proot 运行时依赖到 filesDir/tools/：
     * proot 本体（兜底）+ ptrace loader + libtalloc.so.2 + libandroid-shmem.so。
     *
     * 必须在每次 exec() 前调用，不能只在 installRootfs() 里做——后者对
     * 已安装 rootfs 的用户会提前返回（Bug 210 场景：旧版本升级用户 rootfs
     * 在位但动态库缺失，终端报 CANNOT LINK EXECUTABLE）。
     * 文件已存在时零拷贝，仅 4 次 File.exists() 开销。
     *
     * @return 本次实际落盘的文件名列表（供安装日志统计）
     */
    private fun ensureProotRuntime(): List<String> {
        val tools = File(filesDir, "tools").apply { mkdirs() }
        val synced = mutableListOf<String>()
        fun sync(asset: String, name: String, executable: Boolean) {
            val dest = File(tools, name)
            if (dest.exists()) return
            try {
                assets.open(asset).use { input ->
                    dest.outputStream().use { output -> input.copyTo(output, 1 shl 16) }
                }
                // 动态库只需可读；二进制需可执行（W^X：filesDir 在 targetSdk 28 下可执行）
                if (executable) dest.setExecutable(true, false) else dest.setReadable(true, false)
                synced.add(name)
            } catch (_: Exception) {
                // 资产缺失不在此时报错，由 exec()/installRootfs() 的兜底提示统一处理
            }
        }
        sync(ASSET_PROOT, "proot", executable = true)
        sync(ASSET_LOADER, "loader", executable = true)
        sync(ASSET_LIBTALLOC, "libtalloc.so.2", executable = false)
        sync(ASSET_LIBSHMEM, "libandroid-shmem.so", executable = false)
        return synced
    }

    /**
     * 构建 proot 命令（Step 1 定稿；Step 6 流式执行复用）。
     * proot/rootfs 未就绪时返回 ProotCmd(null, error)。
     */
    private data class ProotCmd(val cmd: List<String>?, val error: Map<String, Any>?)

    private fun buildProotCmd(command: String): ProotCmd {
        // 先补齐依赖再定位 proot：findProot() 的 assets 兜底路径依赖本次同步
        ensureProotRuntime()
        val proot = findProot()
            ?: return ProotCmd(null, fail(-404, "proot 二进制未找到。\n请先运行 ./tools/fetch_assets.sh，并参考 SETUP_ANDROID.md 把它放进 jniLibs 或 assets。"))
        val rootfs = File(filesDir, ROOTFS_REL)
        if (!File(rootfs, "bin/sh").exists()) {
            return ProotCmd(null, fail(-403, "rootfs 未安装：请回到主页点击「初始化环境」。"))
        }

        // proot 参数（Bug 404）：不用 -R！-R 会绑定宿主系统文件（/etc/passwd、
        // /etc/group、/tmp 等推荐路径），Android 宿主没有这些文件 → 容器内 apt
        // 找不到 _apt 用户、apt-key 写 /tmp 失败、源签名验证失败。
        // 改用 -0 -r + 显式绑定 /dev /proc /sys：容器内全部使用 rootfs 自身文件。
        // --link2symlink（Bug 407）：Android 沙箱禁 link()，dpkg 解压含硬链接的包
        // （如 unzip 的 zipinfo→unzip）报 Permission denied、status-old 备份也失败；
        // 该参数把硬链接转为符号链接，apt/dpkg 正常。
        // -0 = 模拟 root；TERM=dumb 避免控制序列
        // 注入 1（Bug 402 根因）：rootfs 打包时烤入了构建机内网 resolv.conf（如 10.x），
        // 真机容器内 glibc 解析失败 → apt/pub/gradle 全部网络失败。每次 exec 幂等修正：
        // 若 resolv.conf 无公共 DNS 则写入阿里/腾讯/谷歌三行，已有则不动。
        // 详见 dev-handbook 04 十节 10.6。
        // 注入 2：加载 /etc/profile.d/foa-env.sh（镜像配置器写入的 Flutter/Dart 镜像、
        // ANDROID_HOME/JAVA_HOME/GRADLE_USER_HOME/PATH），构建命令自动生效。
        val boot = "if ! grep -qE '^nameserver (223\\.5\\.5\\.5|119\\.29\\.29\\.29|8\\.8\\.8\\.8|114\\.114\\.114\\.114|1\\.1\\.1\\.1)' /etc/resolv.conf 2>/dev/null; then printf 'nameserver 223.5.5.5\\nnameserver 119.29.29.29\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf; fi; [ -f /etc/profile.d/foa-env.sh ] && . /etc/profile.d/foa-env.sh; "
        val argv = mutableListOf(
            proot.absolutePath,
            "-0",
            "-r", rootfs.absolutePath,
            "-b", "/dev",
            "-b", "/proc",
            "-b", "/sys",
        )
        // 原生 arm64 后端（2026-09-18）：Termux 移植来的 gen_snapshot 是
        // **bionic 链接**的——INTERP 指向 /system/bin/linker64，libc.so 来自
        // /apex/com.android.runtime/lib64/bionic。而容器 rootfs 是 glibc 的
        // Debian，压根没有 /system 与 /apex：直接跑会报
        // "No such file or directory"（连解释器都找不到）或
        // "CANNOT LINK EXECUTABLE ... library not found"。
        // 因此只要 /opt/foa-native/gen_snapshot 落位，就把 Android 运行时目录
        // 只读挂进容器（仅新增挂载点，不动 rootfs 自己的文件，Debian 程序
        // 不会去 /system 找库，无副作用）。未落位时行为与以前完全一致。
        if (File(rootfs, NATIVE_GEN_SNAPSHOT_REL).exists()) {
            for (p in NATIVE_BIONIC_BINDS) {
                if (File(p).exists()) {
                    argv.add("-b")
                    argv.add(p)
                }
            }
        }
        argv.addAll(
            listOf(
                "--link2symlink",
                "-w", "/root",
                "/usr/bin/env", "-i",
                "HOME=/root", "TERM=dumb",
                "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
                "/bin/sh", "-c", boot + command,
            )
        )
        return ProotCmd(argv, null)
    }

    /**
     * proot 进程需要的 LD_LIBRARY_PATH（Bug 210：filesDir/tools 里的
     * libtalloc.so.2 / libandroid-shmem.so）。
     *
     * 落位了 bionic 原生产物时，额外追加 Android 运行时库搜索路径——
     * bionic 的 linker 默认搜索路径由 /linkerconfig 决定，容器里拿不到
     * （proot 不实现 linkerconfig），显式给一份最稳。
     */
    private fun libraryPath(): String {
        val base = File(filesDir, "tools").absolutePath
        if (!File(File(filesDir, ROOTFS_REL), NATIVE_GEN_SNAPSHOT_REL).exists()) {
            return base
        }
        val extra = listOf(
            "/apex/com.android.runtime/lib64/bionic",
            "/apex/com.android.art/lib64",
            "/system/lib64",
            "/vendor/lib64",
        ).filter { File(it).exists() }.joinToString(":")
        return if (extra.isEmpty()) base else "$base:$extra"
    }

    // ==================== proroot（容器层替代） ====================

    /** proroot 落位目录（filesDir/proroot）。 */
    private fun prorootDir(): File = File(filesDir, PROROOT_DIR)

    /**
     * 已落位的 proroot .so（按 [PROROOT_SO_FILES] 顺序）。
     * 不检查"数量够不够"，而是返回实际存在的列表——由调用方判断完整性，
     * 这样报错能说清**缺哪几个**，而不是笼统的"没装好"。
     */
    private fun prorootPresent(): List<File> {
        val dir = prorootDir()
        if (!dir.isDirectory) return emptyList()
        return PROROOT_SO_FILES.map { File(dir, it) }.filter { it.isFile }
    }

    private fun prorootMissing(): List<String> {
        val dir = prorootDir()
        return PROROOT_SO_FILES.filter { !File(dir, it).isFile }
    }

    /** 文件是否是可执行的 ELF（魔数 0x7F 'E' 'L' 'F'）。 */
    private fun isElf(f: File): Boolean {
        return try {
            f.inputStream().use { ins ->
                val h = ByteArray(4)
                if (ins.read(h) != 4) return false
                h[0] == 0x7F.toByte() && h[1] == 'E'.code.toByte() &&
                    h[2] == 'L'.code.toByte() && h[3] == 'F'.code.toByte()
            }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * proroot 就绪状态（供 UI 决定开关能不能开）。
     *
     * 返回 map 而不是布尔：UI 要能显示"缺 3 个文件""有 1 个不是 ELF"
     * 这类可操作的信息，只给一个 false 用户没法自己修。
     */
    private fun prorootStatus(): Map<String, Any?> {
        val present = prorootPresent()
        val missing = prorootMissing()
        val notElf = present.filter { !isElf(it) }.map { it.name }
        val dir = prorootDir()
        return mapOf(
            "ok" to true,
            "installed" to missing.isEmpty(),
            "dir" to dir.absolutePath,
            "present" to present.map { it.name },
            "missing" to missing,
            "notElf" to notElf,
            "abi" to (android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"),
            "api" to android.os.Build.VERSION.SDK_INT,
            "rootfsReady" to File(File(filesDir, ROOTFS_REL), "bin/sh").exists(),
        )
    }

    /**
     * 从 SAF 导入的临时目录把 proroot 的 .so 搬进 filesDir/proroot/。
     *
     * 为什么不让用户直接拷到 filesDir：Android 11+ 的
     * /data/data/<pkg> 对文件管理器不可见，用户**没有别的办法**把文件
     * 放进去。所以走"用户选文件 → 原生拷进来"，与 Step 3 的
     * 本地安装兜底同一套路。
     *
     * 拷完立刻验 ELF 魔数：用户很可能误选了 zip 或 arm64-v8a 之外的构建，
     * 提前说清比等他打开开关再报 exec format error 好得多。
     */
    private fun prorootInstall(srcDirPath: String): Map<String, Any> {
        val src = File(srcDirPath)
        if (!src.isDirectory) return fail(-400, "导入路径不存在：$srcDirPath")
        val dir = prorootDir().apply { mkdirs() }
        val copied = mutableListOf<String>()
        for (name in PROROOT_SO_FILES) {
            // 递归找同名文件：用户解压后往往多一层目录（proroot-x.y/libproroot.so）
            val hit = src.walkTopDown().firstOrNull { it.isFile && it.name == name }
                ?: continue
            val dst = File(dir, name)
            hit.copyTo(dst, overwrite = true)
            dst.setExecutable(true, false)
            copied.add(name)
        }
        val missing = prorootMissing()
        val bad = prorootPresent().filter { !isElf(it) }.map { it.name }
        return mapOf(
            "ok" to (missing.isEmpty() && bad.isEmpty()),
            "copied" to copied,
            "missing" to missing,
            "notElf" to bad,
            "error" to when {
                copied.isEmpty() -> "没有在所选目录里找到任何 proroot 文件（${PROROOT_SO_FILES.joinToString()}）"
                bad.isNotEmpty() -> "以下文件不是可执行的 arm64 ELF，可能是下载损坏或架构不对：${bad.joinToString()}"
                missing.isNotEmpty() -> "还缺 ${missing.size} 个文件：${missing.joinToString()}"
                else -> null
            },
        )
    }

    /**
     * 清空 proroot 落位目录（用户想换一个版本/彻底退出时用）。
     */
    private fun prorootRemove(): Map<String, Any> {
        val dir = prorootDir()
        val n = if (dir.isDirectory) dir.listFiles()?.size ?: 0 else 0
        dir.deleteRecursively()
        return mapOf("ok" to true, "removed" to n)
    }

    /**
     * **冒烟测试**：在容器里真的跑一次 proroot。
     *
     * 这一步是整个接入的关键——proroot 要求 Ubuntu arm64 rootfs（glibc），
     * 本项目是 Debian 12 bookworm，属**未验证组合**。光看"文件在不在"
     * 判断不了能不能用，必须真跑。测试命令 `uname -a` 只依赖普通系统调用，
     * 能过就说明容器层立起来了。
     *
     * 超时给 25 秒：起不来的情况通常是 linker 直接失败（毫秒级），
     * 给太久只会让用户干等。
     */
    private fun prorootProbe(): Map<String, Any> {
        val rootfs = File(filesDir, ROOTFS_REL)
        if (!File(rootfs, "bin/sh").exists()) {
            return fail(-403, "rootfs 未安装：请先回主页初始化环境")
        }
        val built = buildProrootCmd("uname -a; echo FOA_PROBE_OK")
        if (built.cmd == null) return built.error!!
        return try {
            val pb = ProcessBuilder(built.cmd)
            applyProrootEnv(pb)
            pb.redirectErrorStream(true)
            val proc = pb.start()
            val outBuf = StringBuilder()
            val reader = proc.inputStream.bufferedReader(Charsets.UTF_8)
            val buf = CharArray(4096)
            // 边读边判超时：proroot 挂死时 waitFor 会一直等，必须先读后等
            val deadline = System.currentTimeMillis() + 25_000
            while (System.currentTimeMillis() < deadline) {
                if (reader.ready()) {
                    val n = reader.read(buf)
                    if (n > 0) outBuf.append(buf, 0, n)
                } else if (!proc.isAlive) {
                    // 进程已退出，把剩余读完
                    try {
                        val rest = reader.readText()
                        outBuf.append(rest)
                    } catch (_: Exception) { }
                    break
                } else {
                    Thread.sleep(50)
                }
            }
            val finished = !proc.isAlive
            if (!finished) proc.destroyForcibly()
            val out = outBuf.toString()
            mapOf(
                "ok" to (finished && out.contains("FOA_PROBE_OK")),
                "exitCode" to (if (finished) proc.exitValue() else -999),
                "output" to out.take(4000),
                "cmd" to built.cmd.joinToString(" "),
                "error" to if (!finished) {
                    "proroot 启动超时（25 秒未返回）。这个 rootfs 大概率不兼容——proroot 官方要求 Ubuntu arm64（glibc）。"
                } else if (!out.contains("FOA_PROBE_OK")) {
                    "proroot 进程退出了但没跑通命令，输出见下。常见原因：glibc 版本不匹配、缺少 /lib64/ld-linux-aarch64.so.1。"
                } else null,
            )
        } catch (e: Exception) {
            mapOf(
                "ok" to false,
                "error" to "启动 proroot 失败：${e.message}",
                "cmd" to built.cmd.joinToString(" "),
            )
        }
    }

    /** proroot 进程需要的环境（与 proot 不同：不是 ptrace，不需要 PROOT_* 变量）。 */
    private fun applyProrootEnv(pb: ProcessBuilder) {
        val env = pb.environment()
        val dir = prorootDir()
        // proroot 的运行时组件在同一目录，靠自身 rpath + 这里兜底
        env["LD_LIBRARY_PATH"] = dir.absolutePath + ":" + libraryPath()
        // 与 proot 同款：临时目录重定向到应用私有可写目录
        val tmpDir = File(filesDir, "tmp").apply { mkdirs() }
        env["TMPDIR"] = tmpDir.absolutePath
        env["TERM"] = "dumb"
        // TMPDIR 被 proroot-runtime 读取；有版本用 PROOT_TMP_DIR 同名逻辑，
        // 两个都设上，成本为零，避免依赖具体实现细节
        env["PROOT_TMP_DIR"] = tmpDir.absolutePath
    }

    /**
     * 构建 proroot 命令。
     *
     * **argv 与 proot 不一样**（这是接入时最容易踩的坑）：
     * - proot：`proot -0 -r <rootfs> -b /dev -b /proc -b /sys --link2symlink -w /root /usr/bin/env -i ...`
     * - proroot：`libproroot.so -r <rootfs> -0 --link2symlink -w /root ...`
     *   顺序与取值都不同（-r 在 -0 之前），且不需要显式 -b /dev 等
     *   （proroot 的 bridge 组件自动处理关键挂载）。
     *
     * 与 proot 路径一致的部分仍然复用：resolv.conf 幂等修正、foa-env.sh
     * 加载、"原生 gen_snapshot 落位就挂 bionic 目录"。
     */
    private fun buildProrootCmd(command: String): ProotCmd {
        val missing = prorootMissing()
        if (missing.isNotEmpty()) {
            return ProotCmd(
                null,
                fail(
                    -404,
                    "proroot 未就绪：缺少 ${missing.size} 个文件（${missing.joinToString()}）。\n" +
                        "请在「工具链」页用「导入 proroot」把这 ${PROROOT_SO_FILES.size} 个 .so 放进应用。",
                ),
            )
        }
        val launcher = File(prorootDir(), "libproroot.so")
        if (!launcher.canExecute()) {
            launcher.setExecutable(true, false)
        }
        val rootfs = File(filesDir, ROOTFS_REL)
        if (!File(rootfs, "bin/sh").exists()) {
            return ProotCmd(null, fail(-403, "rootfs 未安装：请回到主页点击「初始化环境」。"))
        }

        // 与 proot 完全同款的两段注入（原因见 buildProotCmd 注释）
        val boot = "if ! grep -qE '^nameserver (223\\.5\\.5\\.5|119\\.29\\.29\\.29|8\\.8\\.8\\.8|114\\.114\\.114\\.114|1\\.1\\.1\\.1)' /etc/resolv.conf 2>/dev/null; then printf 'nameserver 223.5.5.5\\nnameserver 119.29.29.29\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf; fi; [ -f /etc/profile.d/foa-env.sh ] && . /etc/profile.d/foa-env.sh; "

        val argv = mutableListOf(
            launcher.absolutePath,
            "-r", rootfs.absolutePath,
            "-0",
            "--link2symlink",
            "-w", "/root",
        )
        // 原生 bionic gen_snapshot 落位时才挂 Android 运行时目录
        // （原因同 proot：bionic 二进制的 INTERP 指向 /system/bin/linker64）
        if (File(rootfs, NATIVE_GEN_SNAPSHOT_REL).exists()) {
            for (p in NATIVE_BIONIC_BINDS) {
                if (File(p).exists()) {
                    argv.add("-b")
                    argv.add(p)
                }
            }
        }
        argv.addAll(
            listOf(
                "/usr/bin/env", "-i",
                "HOME=/root", "TERM=dumb",
                "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
                "/bin/sh", "-c", boot + command,
            )
        )
        return ProotCmd(argv, null)
    }

    private fun exec(
        command: String,
        timeoutSec: Long,
        bare: Boolean = false,
        proroot: Boolean = false,
    ): Map<String, Any> {
        val start = System.currentTimeMillis()
        if (bare) return execBare(command, timeoutSec)
        val built = if (proroot) buildProrootCmd(command) else buildProotCmd(command)
        if (built.cmd == null) return built.error!!

        return try {
            val pb = ProcessBuilder(built.cmd)
            if (proroot) {
                // proroot 不是 ptrace，不需要 PROOT_LOADER / libtalloc /
                // libandroid-shmem 那一套（它靠 LD_PRELOAD 做路径翻译）。
                applyProrootEnv(pb)
            } else {
                // Termux 构建的 proot 默认 loader 路径指向 com.termux 包，
                // 用 PROOT_LOADER 重定向到本应用私有目录（实测有效）。
                findLoader()?.let { pb.environment()["PROOT_LOADER"] = it.absolutePath }
                // Bug 210：proot 的 DT_NEEDED 含 libtalloc.so.2 / libandroid-shmem.so，
                // Android 系统目录没有这两个库 → 注入 LD_LIBRARY_PATH 让 linker
                // 到 filesDir/tools 找（对主二进制的依赖查找同样生效）。
                // 若落位了 bionic 原生产物，还会追加 Android 运行时库目录（见 libraryPath）。
                pb.environment()["LD_LIBRARY_PATH"] = libraryPath()
                // Bug 211：Termux 版 proot 编译时把临时目录硬编码为
                // /data/data/com.termux/files/usr/tmp/，其他应用无写权限 →
                // proot error: can't create glue rootfs。PROOT_TMP_DIR 重定向到
                // 本应用私有可写目录（proot 官方推荐做法，日志也这么提示）。
                val tmpDir = File(filesDir, "tmp").apply { mkdirs() }
                pb.environment()["PROOT_TMP_DIR"] = tmpDir.absolutePath
            }
            val proc = pb.start()
            // 双线程读流，防止管道缓冲区满导致死锁
            // 注意：submit 的 lambda 在 Callable/Runnable 重载间有歧义（Kotlin 2.4 报
            // Future<*>! 类型不匹配），必须显式 Callable<String>
            val pool = Executors.newFixedThreadPool(2)
            val stdoutF: Future<String> = pool.submit(Callable { proc.inputStream.bufferedReader().readText() })
            val stderrF: Future<String> = pool.submit(Callable { proc.errorStream.bufferedReader().readText() })
            val finished = proc.waitFor(timeoutSec, TimeUnit.SECONDS)
            val exitCode = if (finished) proc.exitValue() else { proc.destroyForcibly(); -999 }
            val stdout = try { stdoutF.get(5, TimeUnit.SECONDS) } catch (_: Exception) { "" }
            val stderr = try { stderrF.get(5, TimeUnit.SECONDS) } catch (_: Exception) { "" }
            pool.shutdownNow()
            mapOf(
                "exitCode" to exitCode,
                "stdout" to stdout,
                "stderr" to stderr,
                "durationMs" to (System.currentTimeMillis() - start),
            )
        } catch (e: Exception) {
            val msg = e.message ?: ""
            val hint = if (msg.contains("Permission", true) || msg.contains("EACCES", true)) {
                "\n提示：疑似 W^X 限制（Android 10+ 禁止 targetSdk≥29 的应用执行数据目录二进制）。" +
                    "请确认 android/app/build.gradle 中 targetSdk 为 28 后重新构建。"
            } else ""
            fail(-500, "启动 proot 失败: $msg$hint")
        }
    }

    // ---------------- Step 6 · 流式执行（构建日志） ----------------

    /** 运行中的流式命令：进程 + 合并输出缓冲（stdout/stderr 单流保时序）。 */
    private class StreamingCmd(val process: Process, val buffer: StringBuffer) {
        val lock = Any()
        @Volatile var finished = false
        @Volatile var exitCode: Int? = null
    }

    private val streamingCmds = ConcurrentHashMap<Long, StreamingCmd>()
    private val streamSeq = AtomicLong(0)

    /**
     * 启动流式命令（构建用，超时默认 2h）。
     * 输出合并进内存缓冲（redirectErrorStream），Dart 侧轮询取增量；
     * 读取在独立线程，不阻塞 MethodChannel 的单线程 executor。
     */
    /**
     * Termux 裸原生后端（2026-09-18）：**不经 proot**，宿主 /system/bin/sh
     * 直跑命令。bionic 二进制（Termux 主仓的 openjdk/aapt/Flutter 移植）
     * 放在 <rootfs>/opt/foa-termux/usr —— 宿主与容器看同一目录，bare 模式
     * 按宿主路径 exec（W^X：targetSdk 28 保留 filesDir 子树 execve）。
     *
     * 环境注入对齐容器 foa-env.sh + Termux 惯例：
     * - PREFIX / LD_LIBRARY_PATH：bionic 二进制的库搜索（libtermux-exec 若在则预载，
     *   兜底改写脚本里残留的 com.termux 绝对路径）；
     * - JAVA_HOME / ANDROID_HOME：termux JDK + 容器 SDK 目录（jars/android.jar
     *   架构无关，跨后端复用）；GRADLE_USER_HOME 指向容器缓存（零重下）；
     * - 国内镜像（pub/flutter storage）与 foa-env.sh 同款。
     * 命令里可再 export 覆盖。
     */
    private fun bareEnvironment(pb: ProcessBuilder) {
        val termux = File(File(filesDir, ROOTFS_REL), "opt/foa-termux/usr")
        val env = pb.environment()
        env["TERM"] = "dumb"
        env["HOME"] = File(filesDir, "home").apply { mkdirs() }.absolutePath
        env["TMPDIR"] = File(filesDir, "tmp").apply { mkdirs() }.absolutePath
        if (termux.isDirectory) {
            env["PREFIX"] = termux.absolutePath
            env["PATH"] = "${termux.absolutePath}/bin:/system/bin:/system/xbin"
            env["LD_LIBRARY_PATH"] = "${termux.absolutePath}/lib"
            val exec = File(termux, "lib/libtermux-exec.so")
            if (exec.isFile) env["LD_PRELOAD"] = exec.absolutePath
            val jdk = File(termux, "lib/jvm/java-17-openjdk")
            if (jdk.isDirectory) env["JAVA_HOME"] = jdk.absolutePath
            // 容器侧的构建缓存与 SDK 组件（架构无关）跨后端复用
            val rootfs = File(filesDir, ROOTFS_REL)
            env["GRADLE_USER_HOME"] = File(rootfs, "root/.gradle").absolutePath
            val sdk = File(rootfs, "opt/android-sdk")
            if (sdk.isDirectory) env["ANDROID_HOME"] = sdk.absolutePath
        }
        // 国内镜像（与容器 /etc/profile.d/foa-env.sh 同款）
        env["PUB_HOSTED_URL"] = "https://pub.flutter-io.cn"
        env["FLUTTER_STORAGE_BASE_URL"] = "https://storage.flutter-io.cn"
    }

    /** bare 执行：/system/bin/sh -c <command>，env 见 bareEnvironment。 */
    private fun execBare(command: String, timeoutSec: Long): Map<String, Any> {
        val start = System.currentTimeMillis()
        return try {
            val pb = ProcessBuilder("/system/bin/sh", "-c", command)
            bareEnvironment(pb)
            val proc = pb.start()
            val stdout = StringBuilder()
            val stderr = StringBuilder()
            // 双线程读流防死锁：copyTo 只吃 OutputStream，StringBuilder
            // 场景用 bufferededReader 逐行收集（进程 destroy 时流关闭自然结束）
            val tOut = Thread {
                try { proc.inputStream.bufferedReader().forEachLine { stdout.appendLine(it) } }
                catch (_: Exception) { }
            }
            val tErr = Thread {
                try { proc.errorStream.bufferedReader().forEachLine { stderr.appendLine(it) } }
                catch (_: Exception) { }
            }
            tOut.start(); tErr.start()
            val finished = proc.waitFor(timeoutSec, TimeUnit.SECONDS)
            tOut.join(5_000); tErr.join(5_000)
            mapOf(
                "ok" to finished,
                "exitCode" to (if (finished) proc.exitValue() else -999),
                "stdout" to stdout.toString(),
                "stderr" to stderr.toString(),
                "durationMs" to (System.currentTimeMillis() - start),
            )
        } catch (e: Exception) {
            fail(-500, "bare 执行失败: ${e.message}")
        }
    }

    private fun execStream(
        command: String,
        timeoutSec: Long,
        bare: Boolean = false,
        proroot: Boolean = false,
    ): Map<String, Any> {
        if (bare) {
            // Termux 裸原生模式：同样走流式通道，但不套 proot
            return try {
                val pb = ProcessBuilder("/system/bin/sh", "-c", command)
                bareEnvironment(pb)
                pb.redirectErrorStream(true) // 合并：gradle/flutter 多线程输出交错，单流保时序
                val proc = pb.start()
                val id = streamSeq.incrementAndGet()
                val sc = StreamingCmd(proc, StringBuffer())
                streamingCmds[id] = sc
                Thread {
                    try {
                        val reader = proc.inputStream.bufferedReader(Charsets.UTF_8)
                        val buf = CharArray(8192)
                        while (true) {
                            val n = try { reader.read(buf) } catch (_: Exception) { -1 }
                            if (n <= 0) break
                            synchronized(sc.lock) { sc.buffer.append(buf, 0, n) }
                        }
                        val finished = proc.waitFor(timeoutSec, TimeUnit.SECONDS)
                        sc.exitCode = if (finished) proc.exitValue() else {
                            proc.destroyForcibly()
                            -999
                        }
                    } catch (_: Exception) {
                        if (sc.exitCode == null) sc.exitCode = -500
                    } finally {
                        sc.finished = true
                    }
                }.apply { name = "foa-stream-$id" }.start()
                mapOf("ok" to true, "id" to id)
            } catch (e: Exception) {
                fail(-500, "启动 bare 命令失败: ${e.message}")
            }
        }
        val built = if (proroot) buildProrootCmd(command) else buildProotCmd(command)
        if (built.cmd == null) return built.error!!
        return try {
            val pb = ProcessBuilder(built.cmd)
            if (proroot) {
                applyProrootEnv(pb)
            } else {
                findLoader()?.let { pb.environment()["PROOT_LOADER"] = it.absolutePath }
                pb.environment()["LD_LIBRARY_PATH"] = libraryPath()
                val tmpDir = File(filesDir, "tmp").apply { mkdirs() }
                pb.environment()["PROOT_TMP_DIR"] = tmpDir.absolutePath
            }
            pb.redirectErrorStream(true) // 合并：gradle/flutter 多线程输出交错，单流保时序
            val proc = pb.start()
            val id = streamSeq.incrementAndGet()
            val sc = StreamingCmd(proc, StringBuffer())
            streamingCmds[id] = sc
            Thread {
                try {
                    val reader = proc.inputStream.bufferedReader(Charsets.UTF_8)
                    val buf = CharArray(8192)
                    while (true) {
                        val n = try { reader.read(buf) } catch (_: Exception) { -1 }
                        if (n <= 0) break
                        synchronized(sc.lock) { sc.buffer.append(buf, 0, n) }
                    }
                    val finished = proc.waitFor(timeoutSec, TimeUnit.SECONDS)
                    sc.exitCode = if (finished) proc.exitValue() else {
                        proc.destroyForcibly()
                        -999
                    }
                } catch (_: Exception) {
                    if (sc.exitCode == null) sc.exitCode = -500
                } finally {
                    sc.finished = true
                }
            }.apply { name = "foa-stream-$id" }.start()
            mapOf("ok" to true, "id" to id)
        } catch (e: Exception) {
            fail(-500, "启动 proot 失败: ${e.message}")
        }
    }

    /** 轮询增量输出：返回自 offset 起的新增文本（锁内快照，读尽后清理任务）。 */
    private fun execStreamPoll(id: Long, offset: Int): Map<String, Any?> {
        val sc = streamingCmds[id] ?: return mapOf<String, Any?>(
            "ok" to false, "error" to "未知任务 id=$id")
        val chunk: String
        val len: Int
        synchronized(sc.lock) {
            len = sc.buffer.length
            chunk = if (offset >= len) "" else sc.buffer.substring(offset, len)
        }
        if (sc.finished && offset >= len) streamingCmds.remove(id)
        return mapOf<String, Any?>(
            "ok" to true,
            "running" to !sc.finished,
            "chunk" to chunk,
            "len" to len,
            "exitCode" to sc.exitCode,
        )
    }

    /** 取消：SIGTERM → 短等 → 强杀，再关流让读取线程退出（防 gradle daemon 继承管道卡死）。 */
    private fun execStreamStop(id: Long): Map<String, Any?> {
        val sc = streamingCmds[id]
            ?: return mapOf<String, Any?>("ok" to true, "killed" to false)
        return try {
            sc.process.destroy()
            if (!sc.finished && !sc.process.waitFor(3, TimeUnit.SECONDS)) {
                sc.process.destroyForcibly()
            }
            try { sc.process.inputStream.close() } catch (_: Exception) {}
            mapOf<String, Any?>("ok" to true, "killed" to true)
        } catch (e: Exception) {
            mapOf<String, Any?>("ok" to false, "error" to e.message)
        }
    }

    // ---------------- Bug 430 · 可交互 PTY 终端 ----------------

    private val ptyRegistry = PtyRegistry()

    /**
     * 启动一个可交互 PTY 会话。
     *
     * 组装顺序：foa_pty(中继) → proot 或 /system/bin/sh(真 shell)。
     * foa_pty 是纯 bionic 的小中继器（只依赖 libc/libdl，随 APK 分发），
     * 它把 Java 给的管道与真 tty 对接，于是被它 exec 的 proot/shell
     * 拿到的是货真价实的 pty（isatty=真）。
     *
     * bare=true 时跳过 proot，直接在宿主 /system/bin/sh 里跑
     * （Termux 裸原生后端），与构建链的后端选择保持一致。
     */
    private fun ptyStart(bare: Boolean, cols: Int, rows: Int): Map<String, Any> {
        val shim = PtyCmd.ensureBinary(assets, filesDir)
            ?: return fail(-404, "PTY 中继器未落位（assets/tools/foa_pty 缺失）。")

        val colsC = if (cols in 20..400) cols else 80
        val rowsC = if (rows in 5..200) rows else 24

        val argv = mutableListOf<String>()
        argv.add(shim.absolutePath)
        argv.add(rowsC.toString())
        argv.add(colsC.toString())

        if (bare) {
            argv.add("/system/bin/sh")
            argv.add("-i")
        } else {
            val rootfs = File(filesDir, ROOTFS_REL)
            if (!File(rootfs, "bin/sh").exists()) {
                return fail(-403, "rootfs 未安装：请回主页点击「初始化环境」，"
                    + "或改用 Termux 裸原生后端。")
            }
            val built = buildProotCmd("")
            val base = built.cmd ?: return built.error!!
            /*
             * buildProotCmd 的末尾是 `/usr/bin/env -i ... /bin/sh -c "<boot><command>"`，
             * 交互式终端要的是**不带 -c 的登录 shell**。这里从末尾的
             * `-c` 往前**连同它的 `/bin/sh` 前缀一起**截掉，再重新收尾。
             *
             * ⚠️ Bug 433：此前只截到 `-c` 之前（base.subList(0, tailIdx)），
             * 于是 head 末尾残留一个孤立的 `/bin/sh`。重新拼接后实际传给
             * proot 的是：
             *     ... /bin/sh  /usr/bin/env -i HOME=... /bin/sh -c "boot; exec /bin/sh -i"
             * 即外层 sh 把 `/usr/bin/env` 当**脚本文件路径**去执行（还要把
             * 后续参数当作位置参数），必然起不来；PTY 里没有任何输出 →
             * 界面永久停在「正在启动终端…」（真机 2026-09-19 反馈）。
             * 正确做法：截掉 `-c` 时把紧邻其前的 `/bin/sh` 也一并去掉。
             *
             * 保留 proot 参数与绑定，改成 `-i` 交互 shell；
             * boot 注入（resolv.conf 修复 + foa-env.sh）本身需要执行，
             * 因此退一步用 `-c "<boot>exec /bin/sh -i"` —— exec 让
             * shell 顶替掉外层进程，fd 0/1/2 已绑定 tty，交互体验不受影响。
             */
            val tailIdx = base.indexOfLast { it == "-c" }
            var headEnd = if (tailIdx > 0) tailIdx else base.size
            // 若 `-c` 前紧邻 `/bin/sh`（或其它 sh 路径），一并截掉
            if (headEnd - 1 >= 0 &&
                (base[headEnd - 1] == "/bin/sh" || base[headEnd - 1].endsWith("/sh"))
            ) {
                headEnd -= 1
            }
            val head = base.subList(0, headEnd)
            val boot = "if ! grep -qE '^nameserver (223\\.5\\.5\\.5|119\\.29\\.29\\.29|8\\.8\\.8\\.8|114\\.114\\.114\\.114|1\\.1\\.1\\.1)' /etc/resolv.conf 2>/dev/null; then printf 'nameserver 223.5.5.5\\nnameserver 119.29.29.29\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf; fi; [ -f /etc/profile.d/foa-env.sh ] && . /etc/profile.d/foa-env.sh; "
            argv.addAll(head)
            /*
             * TERM 用 xterm-256color：buildProotCmd 里写死 TERM=dumb 是为了
             * 构建日志干净，交互终端则必须给足能力，否则 vim/top 全屏渲染、
             * 方向键、颜色全部退化。这里改 env 里的 TERM。
             */
            argv.add("/usr/bin/env")
            argv.add("-i")
            argv.add("HOME=/root")
            argv.add("TERM=xterm-256color")
            argv.add("PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin")
            argv.add("/bin/sh")
            argv.add("-c")
            argv.add(boot + "exec /bin/sh -i")
        }

        return try {
            val pb = ProcessBuilder(argv)
            if (!bare) {
                findLoader()?.let { pb.environment()["PROOT_LOADER"] = it.absolutePath }
                pb.environment()["LD_LIBRARY_PATH"] = libraryPath()
                val tmpDir = File(filesDir, "tmp").apply { mkdirs() }
                pb.environment()["PROOT_TMP_DIR"] = tmpDir.absolutePath
            } else {
                bareEnvironment(pb)
            }
            /*
             * ⚠️ 千万别 redirectErrorStream(true)：pty 已把 stdout/stderr
             * 合到同一个终端（stderr 本身就是 slave 的 dup2），再合并会把
             * shim 自身的诊断输出也混进屏幕。分开读反而更干净——shim 的
             * stderr 只有致命错误（openpty 失败等），单独收集便于上报。
             */
            pb.redirectErrorStream(false)
            val proc = pb.start()

            val id = ptyRegistry.nextId()

            /*
             * 尺寸控制文件按会话隔离（pty-size-<id>）：多开终端时各自
             * 独立重排。先写入初始尺寸，shim 启动时即可读到一致值。
             */
            val sizeFile = File(File(filesDir, "tmp").apply { mkdirs() }, "pty-size-$id")
            try {
                sizeFile.writeText("$rowsC $colsC")
            } catch (_: Exception) {
            }
            pb.environment()["FOA_PTY_SIZE_FILE"] = sizeFile.absolutePath
            pb.environment()["TERM"] = "xterm-256color"

            val session = PtySession(id, proc, if (bare) "termux" else "proot")
            ptyRegistry.put(session)

            Thread {
                PtyRegistry.pump(proc.inputStream, session)
                // ⚠️ Bug 440：Process.waitFor() 返回的是**退出码 Int**，
                // 不是 Boolean。原先写 `val finished = proc.waitFor()` 再
                // `if (finished) ...` 编译不过（Int 不能当条件）。
                // 这里直接取退出码：waitFor() 正常返回即代表进程已结束，
                // 抛出 InterruptedException（线程被中断）才走 -500 兜底。
                val code = try {
                    proc.waitFor()
                } catch (_: InterruptedException) {
                    -500
                }
                // waitFor() 返回后仍可能有少量输出在管道里，给读取线程
                // 一点时间把尾巴抽干，避免最后几行丢失。
                try {
                    Thread.sleep(60)
                } catch (_: InterruptedException) {
                }
                session.exitCode = code
                session.finished = true
            }.apply { name = "foa-pty-$id" }.start()

            // shim 的 stderr 单独收集（正常情况下为空）
            Thread {
                try {
                    proc.errorStream.bufferedReader(Charsets.UTF_8).use { r ->
                        val sb = StringBuilder()
                        var line = r.readLine()
                        while (line != null) {
                            sb.append(line).append('\n')
                            line = r.readLine()
                        }
                        if (sb.isNotEmpty()) {
                            synchronized(session.lock) {
                                session.buffer.append("\n[pty-relay] ").append(sb)
                            }
                        }
                    }
                } catch (_: Exception) {
                }
            }.apply { name = "foa-pty-err-$id" }.start()

            mapOf(
                "ok" to true,
                "id" to id,
                "backend" to session.backend,
                "cols" to colsC,
                "rows" to rowsC,
            )
        } catch (e: Exception) {
            fail(-500, "启动 PTY 失败: ${e.message}")
        }
    }

    private fun ptyWrite(id: Long, text: String): Map<String, Any?> {
        val s = ptyRegistry.get(id)
            ?: return mapOf<String, Any?>("ok" to false, "error" to "未知会话 id=$id")
        if (s.finished) return mapOf<String, Any?>("ok" to false, "error" to "会话已结束")
        s.write(text)
        return mapOf<String, Any?>("ok" to true)
    }

    /** 轮询增量：返回自 offset 起的新增屏幕文本（含 ANSI 转义，Dart 侧渲染）。 */
    private fun ptyPoll(id: Long, offset: Int): Map<String, Any?> {
        val s = ptyRegistry.get(id)
            ?: return mapOf<String, Any?>("ok" to false, "error" to "未知会话 id=$id")
        val chunk: String
        val len: Int
        synchronized(s.lock) {
            len = s.buffer.length
            chunk = if (offset >= len) "" else s.buffer.substring(offset, len)
        }
        return mapOf<String, Any?>(
            "ok" to true,
            "running" to !s.finished,
            "chunk" to chunk,
            "len" to len,
            "exitCode" to s.exitCode,
            "backend" to s.backend,
        )
    }

    private fun ptyStop(id: Long): Map<String, Any?> {
        val s = ptyRegistry.get(id)
            ?: return mapOf<String, Any?>("ok" to true, "killed" to false)
        val killed = s.stop()
        return mapOf<String, Any?>("ok" to true, "killed" to killed)
    }

    /**
     * 窗口尺寸变化：vim/top 等全屏程序据此重排。
     *
     * master fd 在 foa_pty 进程手里，Java 碰不到，所以走「控制文件」：
     * 把 "<rows> <cols>" 写进 FOA_PTY_SIZE_FILE 指定的文件，shim 主循环
     * 每 200ms 检查一次，变化即 ioctl(TIOCSWINSZ)。实测生效
     * （stty size 从 24 80 变 31 120，无需重启会话）。
     */
    private fun ptyResize(id: Long, cols: Int, rows: Int): Map<String, Any?> {
        val s = ptyRegistry.get(id)
            ?: return mapOf<String, Any?>("ok" to false, "error" to "未知会话 id=$id")
        val c = if (cols in 20..1000) cols else 80
        val r = if (rows in 5..500) rows else 24
        return try {
            // 文件名与 ptyStart 写入的一致：pty-size-<id>
            val f = File(File(filesDir, "tmp"), "pty-size-$id")
            f.parentFile?.mkdirs()
            f.writeText("$r $c")
            mapOf<String, Any?>("ok" to true, "cols" to c, "rows" to r)
        } catch (e: Exception) {
            mapOf<String, Any?>("ok" to false, "error" to e.message)
        }
    }

    // ---------------- Step 6 · APK 安装 ----------------

    private var pendingInstallResult: MethodChannel.Result? = null

    /**
     * 安装 APK：FileProvider 授权 content:// 给系统安装器（ACTION_VIEW，
     * application/vnd.android.package-archive）。real 必须是宿主白名单路径
     * （filesDir 内，含 rootfs 下的构建产物）；startActivity 必须主线程。
     */
    private fun installApkAsync(result: MethodChannel.Result, real: String) {
        val f = resolveHostPath(real) ?: return result.success(fileFail("路径不在白名单内: $real"))
        if (!f.exists() || !f.isFile) return result.success(fileFail("APK 不存在: $real"))
        val uri = try {
            FileProvider.getUriForFile(this, fileProviderAuthority, f)
        } catch (e: Exception) {
            return result.success(fileFail("FileProvider 授权失败: ${e.message}"))
        }
        pendingInstallResult = result
        runOnUiThread {
            try {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
                pendingInstallResult?.success(mapOf("ok" to true))
            } catch (e: Exception) {
                pendingInstallResult?.success(fileFail("拉起安装器失败: ${e.message}"))
            } finally {
                pendingInstallResult = null
            }
        }
    }

    private fun fail(code: Int, message: String): Map<String, Any> =
        mapOf("exitCode" to code, "stdout" to "", "stderr" to message, "durationMs" to 0L)

    // ---------------- rootfs 安装 ----------------

    /**
     * 安装 rootfs（幂等）：
     * 1. assets 拷贝 tarball 到 cacheDir
     * 2. toybox tar -xzf 解压到 staging（保留权限与符号链接）
     * 3. 兼容 ./bin 与 ./debian/bin 两种 tarball 层级，落位到 filesDir/rootfs/debian
     * 4. 顺带把 assets 里的 proot 拷到 filesDir/tools/proot（兜底）
     */
    private fun installRootfs(): Map<String, Any> {
        val start = System.currentTimeMillis()
        val rootfs = File(filesDir, ROOTFS_REL)

        if (File(rootfs, "bin/sh").exists()) {
            return mapOf("ok" to true, "alreadyInstalled" to true, "durationMs" to 0L, "files" to 0)
        }

        val parent = rootfs.parentFile!!.apply { mkdirs() }
        val staging = File(parent, "debian.staging")
        if (staging.exists()) staging.deleteRecursively()

        // 1) assets → cache
        val tmp = File(cacheDir, "rootfs.tar.gz")
        try {
            assets.open(ASSET_ROOTFS).use { input ->
                tmp.outputStream().use { output -> input.copyTo(output, 1 shl 16) }
            }
        } catch (e: Exception) {
            return mapOf("ok" to false, "error" to "读取 rootfs 资产失败（$ASSET_ROOTFS）：${e.message}\n" +
                "请先运行 ./tools/fetch_assets.sh rootfs 下载资产，再 flutter run 重新构建。")
        }

        // 2) tar 解压
        staging.mkdirs()
        try {
            val proc = ProcessBuilder("tar", "-xzf", tmp.absolutePath, "-C", staging.absolutePath).start()
            val err = proc.errorStream.bufferedReader().readText()
            if (proc.waitFor() != 0) {
                // Android 沙箱不允许 mknod()/部分机型 link()，toybox tar 可能对
                // GNU 扩展头吐 warning——退出码非 0 不代表失败。以关键文件为准：
                // bin/sh（经 usr-merge symlink 解析）+ dpkg 存在即视为安装成功。
                // （rootfs tarball 生成侧已做 Android 友好重打包，见 Bug 209，
                //  这里是兜底防御。）
                val shOk = File(staging, "bin/sh").exists() || File(File(staging, "debian"), "bin/sh").exists()
                val dpkgOk = File(staging, "usr/bin/dpkg").exists() || File(File(staging, "debian"), "usr/bin/dpkg").exists()
                if (!shOk || !dpkgOk) {
                    staging.deleteRecursively()
                    return mapOf("ok" to false, "error" to "tar 解压失败: ${err.take(500)}")
                }
                // 关键文件在，继续（stderr 仅记录）
                android.util.Log.w("FoaInstaller", "tar non-zero exit but key files present: ${err.take(300)}")
            }
        } catch (e: Exception) {
            return mapOf("ok" to false, "error" to "tar 不可用或执行失败: ${e.message}")
        } finally {
            tmp.delete()
        }

        // 3) 层级兼容 + 落位
        val resolved = when {
            File(staging, "bin").exists() -> staging
            File(File(staging, "debian"), "bin").exists() -> File(staging, "debian")
            else -> null
        }
        if (resolved == null) {
            staging.deleteRecursively()
            return mapOf("ok" to false, "error" to "tarball 结构不符合预期（找不到 bin/），请确认是 Debian arm64 rootfs")
        }
        resolved.renameTo(rootfs)
        if (resolved != staging) staging.deleteRecursively()

        // 4) proot 运行时依赖兜底拷贝（本体 + loader + 动态库；exec 前亦会幂等补齐）
        val synced = ensureProotRuntime()
        val prootCopied = "proot" in synced
        if (findProot() == null) {
            return mapOf("ok" to false, "error" to "proot 资产缺失：请运行 ./tools/fetch_assets.sh proot 后重新构建")
        }

        return mapOf(
            "ok" to true,
            "alreadyInstalled" to false,
            "durationMs" to (System.currentTimeMillis() - start),
            "files" to rootfs.walkBottomUp().count(),
            "prootCopiedFromAssets" to prootCopied,
        )
    }

    // ---------------- Step 2 · 文件操作（限定 /root/projects）----------------

    private fun projectsRoot(): File = File(filesDir, PROJECTS_REL).apply { mkdirs() }

    /**
     * 容器内路径（/root/projects/...）→ 真实路径（filesDir/rootfs/debian/root/projects/...）。
     * 严格白名单：
     * - 必须以 /root/projects 开头（Step 2 只允许编辑项目区，防误改 rootfs 系统文件）；
     * - canonicalize 后必须仍在 projects 根内（防 `..` 逃逸）。
     * 非法路径返回 null，调用方以"ok=false + error"返回。
     */
    private fun resolveGuestPath(guest: String): File? {
        if (!guest.startsWith("/root/projects")) return null
        val rel = guest.removePrefix("/root/projects").removePrefix("/")
        val root = projectsRoot().canonicalFile
        val target = File(root, rel).canonicalFile
        val inRoot = target == root || target.path.startsWith(root.path + File.separator)
        return if (inRoot) target else null
    }

    private fun fileFail(msg: String): Map<String, Any> =
        mapOf("ok" to false, "error" to msg)

    private fun fileList(guest: String): Map<String, Any> {
        val dir = resolveGuestPath(guest) ?: return fileFail("非法路径（仅允许 /root/projects 内）: $guest")
        if (!dir.isDirectory) return fileFail("不是目录: $guest")
        val entries = dir.listFiles()?.sortedBy { it.name }?.map { f ->
            mapOf(
                "name" to f.name,
                "isDir" to f.isDirectory,
                // 符号链接视为文件（不跟随，防循环）；体积用于排序/展示
                "size" to (if (f.isFile) f.length() else 0L),
                "mtime" to f.lastModified(),
            )
        } ?: emptyList()
        return mapOf("ok" to true, "path" to guest, "entries" to entries)
    }

    private fun fileRead(guest: String): Map<String, Any> {
        val f = resolveGuestPath(guest) ?: return fileFail("非法路径（仅允许 /root/projects 内）: $guest")
        if (!f.isFile) return fileFail("不是文件: $guest")
        // 代码文件 MVP 上限 2MB（500 行 Dart 远小于此）；超出提示而非 OOM
        if (f.length() > 2L * 1024 * 1024) return fileFail("文件过大（>2MB），暂不支持打开: $guest")
        return try {
            val content = f.readText()
            mapOf("ok" to true, "content" to content, "size" to content.length)
        } catch (e: Exception) {
            fileFail("读取失败: ${e.message}")
        }
    }

    private fun fileWrite(guest: String, content: String): Map<String, Any> {
        val f = resolveGuestPath(guest) ?: return fileFail("非法路径（仅允许 /root/projects 内）: $guest")
        // 防御：rootfs 解压后部分文件 owner=root，app 非 owner 写不进去；
        // setWritable 对 owner 生效，owner 是本应用时可自愈（失败会抛异常返回）
        if (f.exists() && !f.canWrite()) f.setWritable(true, false)
        return try {
            f.parentFile?.mkdirs()
            f.writeText(content)
            mapOf("ok" to true, "size" to content.length)
        } catch (e: Exception) {
            fileFail("写入失败: ${e.message}")
        }
    }

    private fun fileMkdir(guest: String): Map<String, Any> {
        val f = resolveGuestPath(guest) ?: return fileFail("非法路径（仅允许 /root/projects 内）: $guest")
        return if (f.exists()) fileFail("已存在: $guest")
        else if (f.mkdirs()) mapOf("ok" to true)
        else fileFail("创建目录失败: $guest")
    }

    private fun fileRename(guest: String, newName: String): Map<String, Any> {
        if (newName.isBlank() || newName.contains('/') || newName == "." || newName == "..") {
            return fileFail("非法文件名: $newName")
        }
        val f = resolveGuestPath(guest) ?: return fileFail("非法路径（仅允许 /root/projects 内）: $guest")
        if (!f.exists()) return fileFail("不存在: $guest")
        val dest = File(f.parentFile, newName)
        if (dest.exists()) return fileFail("目标已存在: $newName")
        return if (f.renameTo(dest)) mapOf("ok" to true)
        else fileFail("重命名失败: $guest → $newName")
    }

    private fun fileDelete(guest: String): Map<String, Any> {
        val f = resolveGuestPath(guest) ?: return fileFail("非法路径（仅允许 /root/projects 内）: $guest")
        if (!f.exists()) return fileFail("不存在: $guest")
        return if (f.deleteRecursively()) mapOf("ok" to true)
        else fileFail("删除失败: $guest")
    }

    // ---------------- Step 4 · 文件浏览器（rootfs 全路径白名单）----------------

    /**
     * 容器内任意路径（/...）→ 真实路径（filesDir/rootfs/debian/...）。
     * 白名单：rootfs 根内；禁止操作根自身（"/"）；canonicalize 后必须仍在
     * rootfs 内（防 `..` 逃逸到 filesDir 其他区域）。与编辑器的 resolveGuestPath
     * （/root/projects 严格白名单）独立——文件浏览器是"浏览整个 app 数据"的入口。
     */
    private fun resolveRootfsPath(guest: String): File? {
        if (!guest.startsWith("/") || guest == "/") return null
        val root = File(filesDir, ROOTFS_REL).canonicalFile
        val target = File(root, guest.removePrefix("/")).canonicalFile
        val inRoot = target == root || target.path.startsWith(root.path + File.separator)
        return if (inRoot) target else null
    }

    private fun rootfsRoot(): File? {
        val root = File(filesDir, ROOTFS_REL)
        return if (File(root, "bin/sh").exists()) root else null
    }

    private fun fsBrowse(guest: String): Map<String, Any> {
        val dir = if (guest == "/") rootfsRoot()
        else resolveRootfsPath(guest) ?: return fileFail("非法路径（仅允许 rootfs 内）: $guest")
        if (dir == null) return fileFail("rootfs 未安装：请回到主页点击「初始化环境」。")
        if (!dir.isDirectory) return fileFail("不是目录: $guest")
        val entries = dir.listFiles()?.sortedBy { it.name }?.map { f ->
            mapOf(
                "name" to f.name,
                "isDir" to f.isDirectory,
                "size" to (if (f.isFile) f.length() else 0L),
                "mtime" to f.lastModified(),
            )
        } ?: emptyList()
        return mapOf("ok" to true, "path" to guest, "entries" to entries)
    }

    private fun fsMkdir(guest: String): Map<String, Any> {
        val f = resolveRootfsPath(guest) ?: return fileFail("非法路径（仅允许 rootfs 内）: $guest")
        return if (f.exists()) fileFail("已存在: $guest")
        else if (f.mkdirs()) mapOf("ok" to true)
        else fileFail("创建目录失败: $guest")
    }

    private fun fsRename(guest: String, newName: String): Map<String, Any> {
        if (newName.isBlank() || newName.contains('/') || newName == "." || newName == "..") {
            return fileFail("非法文件名: $newName")
        }
        val f = resolveRootfsPath(guest) ?: return fileFail("非法路径（仅允许 rootfs 内）: $guest")
        if (!f.exists()) return fileFail("不存在: $guest")
        val dest = File(f.parentFile, newName)
        if (dest.exists()) return fileFail("目标已存在: $newName")
        return if (f.renameTo(dest)) mapOf("ok" to true)
        else fileFail("重命名失败: $guest → $newName")
    }

    private fun fsDelete(guest: String): Map<String, Any> {
        val f = resolveRootfsPath(guest) ?: return fileFail("非法路径（仅允许 rootfs 内）: $guest")
        if (!f.exists()) return fileFail("不存在: $guest")
        // rootfs 根自身已由 resolveRootfsPath 拒绝（guest != "/"）；递归删除由
        // Dart 侧二次确认（AlertDialog），原生层不再设额外保护。
        return if (f.deleteRecursively()) mapOf("ok" to true)
        else fileFail("删除失败: $guest")
    }

    private fun fsCopy(srcGuest: String, dstGuest: String): Map<String, Any> {
        val src = resolveRootfsPath(srcGuest) ?: return fileFail("非法源路径（仅允许 rootfs 内）: $srcGuest")
        val dst = resolveRootfsPath(dstGuest) ?: return fileFail("非法目标路径（仅允许 rootfs 内）: $dstGuest")
        return copyEntry(src, dst)
    }

    private fun fsMove(srcGuest: String, dstGuest: String): Map<String, Any> {
        val src = resolveRootfsPath(srcGuest) ?: return fileFail("非法源路径（仅允许 rootfs 内）: $srcGuest")
        val dst = resolveRootfsPath(dstGuest) ?: return fileFail("非法目标路径（仅允许 rootfs 内）: $dstGuest")
        return moveEntry(src, dst)
    }

    // ---------------- Step 4 · 宿主域（真实路径：filesDir / Android/data/<pkg>）----------------

    private fun hostRoots(): List<File> {
        val roots = mutableListOf(filesDir)
        externalDataDir()?.let { roots.add(it) }
        return roots
    }

    /** 宿主域路径白名单校验：canonicalize 后必须在 filesDir 或 Android/data/<pkg> 内。 */
    private fun resolveHostPath(real: String): File? {
        if (real.isBlank()) return null
        val target = File(real).canonicalFile
        return hostRoots().firstOrNull { root ->
            val r = root.canonicalFile
            target == r || target.path.startsWith(r.path + File.separator)
        }?.let { target }
    }

    private fun hostBrowse(real: String): Map<String, Any> {
        val dir = resolveHostPath(real) ?: return fileFail("非法路径（仅允许 app 自有目录）: $real")
        if (!dir.isDirectory) return fileFail("不是目录: $real")
        val entries = dir.listFiles()?.sortedBy { it.name }?.map { f ->
            mapOf(
                "name" to f.name,
                "isDir" to f.isDirectory,
                "size" to (if (f.isFile) f.length() else 0L),
                "mtime" to f.lastModified(),
            )
        } ?: emptyList()
        return mapOf("ok" to true, "path" to real, "entries" to entries)
    }

    private fun hostMkdir(real: String): Map<String, Any> {
        val f = resolveHostPath(real) ?: return fileFail("非法路径（仅允许 app 自有目录）: $real")
        return if (f.exists()) fileFail("已存在: $real")
        else if (f.mkdirs()) mapOf("ok" to true)
        else fileFail("创建目录失败: $real")
    }

    private fun hostRename(real: String, newName: String): Map<String, Any> {
        if (newName.isBlank() || newName.contains('/') || newName == "." || newName == "..") {
            return fileFail("非法文件名: $newName")
        }
        val f = resolveHostPath(real) ?: return fileFail("非法路径（仅允许 app 自有目录）: $real")
        if (!f.exists()) return fileFail("不存在: $real")
        val dest = File(f.parentFile, newName)
        if (dest.exists()) return fileFail("目标已存在: $newName")
        return if (f.renameTo(dest)) mapOf("ok" to true)
        else fileFail("重命名失败: $real → $newName")
    }

    private fun hostDelete(real: String): Map<String, Any> {
        val f = resolveHostPath(real) ?: return fileFail("非法路径（仅允许 app 自有目录）: $real")
        if (!f.exists()) return fileFail("不存在: $real")
        return if (f.deleteRecursively()) mapOf("ok" to true)
        else fileFail("删除失败: $real")
    }

    private fun hostCopy(srcReal: String, dstReal: String): Map<String, Any> {
        val src = resolveHostPath(srcReal) ?: return fileFail("非法源路径（仅允许 app 自有目录）: $srcReal")
        val dst = resolveHostPath(dstReal) ?: return fileFail("非法目标路径（仅允许 app 自有目录）: $dstReal")
        return copyEntry(src, dst)
    }

    private fun hostMove(srcReal: String, dstReal: String): Map<String, Any> {
        val src = resolveHostPath(srcReal) ?: return fileFail("非法源路径（仅允许 app 自有目录）: $srcReal")
        val dst = resolveHostPath(dstReal) ?: return fileFail("非法目标路径（仅允许 app 自有目录）: $dstReal")
        return moveEntry(src, dst)
    }

    // ---------------- 通用复制 / 移动（容器域与宿主域共用）----------------

    /** 复制文件或目录到目标（含递归）；禁止复制到自身子目录内（无限递归）。 */
    private fun copyEntry(src: File, dst: File): Map<String, Any> {
        if (!src.exists()) return fileFail("源不存在: ${src.path}")
        if (dst.exists()) return fileFail("目标已存在: ${dst.path}")
        if (dst.canonicalFile.path.startsWith(src.canonicalFile.path + File.separator)) {
            return fileFail("不能复制到自身子目录内: ${src.path} → ${dst.path}")
        }
        return try {
            if (src.isDirectory) src.copyRecursively(dst, overwrite = false)
            else src.copyTo(dst, overwrite = false)
            mapOf("ok" to true)
        } catch (e: Exception) {
            fileFail("复制失败: ${e.message}")
        }
    }

    /** 移动：优先 renameTo（同分区原子）；跨分区失败回退 复制+删除（保留源目录树）。 */
    private fun moveEntry(src: File, dst: File): Map<String, Any> {
        if (!src.exists()) return fileFail("源不存在: ${src.path}")
        if (dst.exists()) return fileFail("目标已存在: ${dst.path}")
        if (dst.canonicalFile.path.startsWith(src.canonicalFile.path + File.separator)) {
            return fileFail("不能移动到自身子目录内: ${src.path} → ${dst.path}")
        }
        if (src.renameTo(dst)) return mapOf("ok" to true)
        // 跨分区（如 /data/data ↔ /storage/emulated/0）：复制后删除源
        return try {
            if (src.isDirectory) src.copyRecursively(dst, overwrite = false)
            else src.copyTo(dst, overwrite = false)
            if (!src.deleteRecursively()) fileFail("已复制但源删除失败: ${src.path}") else mapOf("ok" to true)
        } catch (e: Exception) {
            fileFail("移动失败: ${e.message}")
        }
    }

    // ---------------- Step 5 · 项目工作区迁移（外部存储 ↔ 容器）----------------

    /** 外部存储项目工作区：Android/data/<pkg>/projects（用户可见可改；无外部存储时为 null）。 */
    private fun externalProjectsDir(): File? {
        val ext = externalDataDir() ?: return null
        return File(ext, PROJECTS_EXTERNAL_NAME)
    }

    /**
     * 项目目录双向同步。
     *
     * 背景（W^X / SELinux / FUSE，详见 foa-build-verify §十三）：
     * - 构建必须在容器内 /root/projects（= filesDir，targetSdk 28 下可执行）进行；
     * - 用户编辑在外部工作区（/sdcard/Android/data/<pkg>/projects，文件管理器/USB 可见）；
     * - 本方法负责两处互拷：编辑后 toContainer 同步进容器再构建；
     *   toExternal 把容器项目导出到用户可见区（首次迁移 / 备份）。
     *
     * direction: "toContainer"（外部 → 容器）| "toExternal"（容器 → 外部）
     * 策略：全量拷贝 + 覆盖同名，不删除目标多余文件（防误删用户数据）；
     * toExternal 跳过 build/.gradle/.dart_tool 缓存目录（walk 遇子树整体跳过）。
     */
    private fun syncProjects(direction: String): Map<String, Any> {
        val ext = externalProjectsDir() ?: return fileFail("当前设备无外部存储，无法使用项目工作区")
        val container = projectsRoot()
        val (src, dst) = if (direction == "toExternal") container to ext else ext to container
        if (!src.exists() || !src.isDirectory) {
            return fileFail(
                if (direction == "toExternal") "容器项目区为空（$PROJECTS_REL），没有可导出的项目。"
                else "外部工作区为空。\n请先把项目文件放到\n${ext.path}\n（文件管理器/USB 可见），再点「外部 → 容器」。",
            )
        }
        try {
            dst.mkdirs()
            var files = 0
            var bytes = 0L
            var skipped = 0
            src.walkTopDown().forEach { f ->
                if (f.isDirectory) return@forEach
                val rel = f.relativeTo(src).path
                val parts = rel.split(File.separatorChar)
                // toExternal：跳过构建缓存目录（保留源文件，防污染用户可见区）
                if (direction == "toExternal" && parts.any { it in PROJECT_CACHE_DIRS }) {
                    skipped++
                    return@forEach
                }
                val out = File(dst, rel)
                out.parentFile?.mkdirs()
                // rootfs 解压文件 owner=root 可能只读；FUSE 文件也可能缺写位 → 幂等补写
                if (out.exists() && !out.canWrite()) out.setWritable(true, false)
                f.copyTo(out, overwrite = true)
                files++
                bytes += f.length()
            }
            return mapOf(
                "ok" to true,
                "direction" to direction,
                "files" to files,
                "bytes" to bytes,
                "skipped" to skipped,
            )
        } catch (e: Exception) {
            return fileFail("同步失败: ${e.message}")
        }
    }

    /** 导出：校验源文件后挂起 result，拉起 SAF 保存对话框（主线程）。 */
    private fun exportFile(result: MethodChannel.Result, guest: String, displayName: String) {
        // 兼容容器路径（rootfs 内）与宿主路径（filesDir / Android/data 内）
        val f = resolveRootfsPath(guest) ?: resolveHostPath(guest)
        if (f == null || !f.isFile) {
            result.success(fileFail("非法路径或不是文件: $guest"))
            return
        }
        pendingExportResult = result
        pendingExportSource = f
        runOnUiThread {
            try {
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_TITLE, displayName)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }
                startActivityForResult(intent, exportRequestCode)
            } catch (e: Exception) {
                pendingExportResult = null
                pendingExportSource = null
                result.success(fileFail("无法打开保存对话框: ${e.message}"))
            }
        }
    }
}
