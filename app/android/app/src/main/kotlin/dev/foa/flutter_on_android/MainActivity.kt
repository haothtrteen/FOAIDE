package dev.foa.flutter_on_android

import android.os.Build
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

    // ---------------- 环境信息 ----------------

    private fun envInfo(): Map<String, Any?> {
        val rootfs = File(filesDir, ROOTFS_REL)
        return mapOf(
            "filesDir" to filesDir.absolutePath,
            "cacheDir" to cacheDir.absolutePath,
            "nativeLibraryDir" to applicationInfo.nativeLibraryDir,
            "rootfsPath" to rootfs.absolutePath,
            "rootfsInstalled" to File(rootfs, "bin/sh").exists(),
            "prootPath" to findProot()?.absolutePath,
            "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
            "androidSdk" to Build.VERSION.SDK_INT,
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
        )
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

        // proot -R = 绑定 /dev /proc /sys 等推荐目录；-0 = 模拟 root；TERM=dumb 避免控制序列
        val cmd = listOf(
            proot.absolutePath,
            "-R", rootfs.absolutePath,
            "-0",
            "-w", "/root",
            "/usr/bin/env", "-i",
            "HOME=/root", "TERM=dumb",
            "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "/bin/sh", "-c", command,
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
}
