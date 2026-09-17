package dev.foa.flutter_on_android

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

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

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            // 全部放到后台线程执行，避免 ANR
            executor.execute {
                try {
                    when (call.method) {
                        "envInfo" -> result.success(envInfo())
                        "exec" -> {
                            val command = call.argument<String>("command") ?: ""
                            val timeoutSec = (call.argument<Number>("timeoutSec") ?: 180).toLong()
                            result.success(exec(command, timeoutSec))
                        }
                        "installRootfs" -> result.success(installRootfs())
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
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("ERR_${call.method}", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
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
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun queryDisplayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }

    // ---------------- 环境信息 ----------------

    private fun envInfo(): Map<String, Any?> {
        val rootfs = File(filesDir, ROOTFS_REL)
        return mapOf(
            "filesDir" to filesDir.absolutePath,
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
        )
    }

    /** 外部存储的 app 专属目录：/storage/emulated/0/Android/data/<pkg>（getExternalFilesDir 的父级）。 */
    private fun externalDataDir(): File? =
        getExternalFilesDir(null)?.parentFile

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

    private fun exec(command: String, timeoutSec: Long): Map<String, Any> {
        val start = System.currentTimeMillis()
        // 先补齐依赖再定位 proot：findProot() 的 assets 兜底路径依赖本次同步
        ensureProotRuntime()
        val proot = findProot()
            ?: return fail(-404, "proot 二进制未找到。\n请先运行 ./tools/fetch_assets.sh，并参考 SETUP_ANDROID.md 把它放进 jniLibs 或 assets。")
        val rootfs = File(filesDir, ROOTFS_REL)
        if (!File(rootfs, "bin/sh").exists()) {
            return fail(-403, "rootfs 未安装：请回到主页点击「初始化环境」。")
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
        val cmd = listOf(
            proot.absolutePath,
            "-0",
            "-r", rootfs.absolutePath,
            "-b", "/dev",
            "-b", "/proc",
            "-b", "/sys",
            "--link2symlink",
            "-w", "/root",
            "/usr/bin/env", "-i",
            "HOME=/root", "TERM=dumb",
            "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "/bin/sh", "-c", boot + command,
        )

        return try {
            val pb = ProcessBuilder(cmd)
            // Termux 构建的 proot 默认 loader 路径指向 com.termux 包，
            // 用 PROOT_LOADER 重定向到本应用私有目录（实测有效）。
            findLoader()?.let { pb.environment()["PROOT_LOADER"] = it.absolutePath }
            // Bug 210：proot 的 DT_NEEDED 含 libtalloc.so.2 / libandroid-shmem.so，
            // Android 系统目录没有这两个库 → 注入 LD_LIBRARY_PATH 让 linker
            // 到 filesDir/tools 找（对主二进制的依赖查找同样生效）。
            pb.environment()["LD_LIBRARY_PATH"] = File(filesDir, "tools").absolutePath
            // Bug 211：Termux 版 proot 编译时把临时目录硬编码为
            // /data/data/com.termux/files/usr/tmp/，其他应用无写权限 →
            // proot error: can't create glue rootfs。PROOT_TMP_DIR 重定向到
            // 本应用私有可写目录（proot 官方推荐做法，日志也这么提示）。
            val tmpDir = File(filesDir, "tmp").apply { mkdirs() }
            pb.environment()["PROOT_TMP_DIR"] = tmpDir.absolutePath
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
