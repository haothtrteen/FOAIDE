package dev.foa.flutter_on_android

import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * 可交互 PTY 会话（Bug 430）。
 *
 * 为什么需要它
 * ------------
 * Android/JVM 没有 pty API：`ProcessBuilder` 只能给出单向管道，
 * 子进程拿不到 tty，于是 `apt` 的进度条、`vim`/`top` 全屏程序、
 * Ctrl+C 中断、方向键历史、tab 补全全部失效。此前「终端」页只能
 * 预设命令跑批，用户明确反馈「没有可交互执行命令的界面」。
 *
 * 解法：随 APK 分发一个 10KB 的 C 中继器 `foa_pty`（纯 bionic，
 * 只依赖 libc/libdl，见 `platform/android/pty/foa_pty.c`）。
 * 它用 openpty() 建真 tty、setsid+TIOCSCTTY+tcsetpgrp 建立前台
 * 进程组（Ctrl+C 生效的关键），然后把「本进程 stdin/stdout」与
 * 「pty master」双向对接。
 *
 * 进程树形如：
 *
 *     Java(ProcessBuilder)  ──pipe──▶  foa_pty  ──pty──▶  proot/sh
 *        写入 = 键盘                     中继               真 tty
 *        读出 = 屏幕
 *
 * 于是子进程看到的是货真价实的终端，proot 也照常工作（它只是被
 * foa_pty 作为子进程 exec，不感知 pty 的存在）。
 *
 * 与 StreamingCmd 的关系
 * ----------------------
 * 输出读取/增量轮询/超时清理三者复用同一套思路，但 PTY 会话多一个
 * **可写通道**（stdin），且要支持 `resize`（窗口尺寸变化时发
 * TIOCSWINSZ，全屏程序才能重排），故单独成类。
 */
class PtySession(
    val id: Long,
    private val process: Process,
    val backend: String,
) {
    val buffer = StringBuffer()
    val lock = Any()

    /** 供 Dart 侧写入按键的通道（Java → foa_pty stdin）。 */
    val input: OutputStream = process.outputStream

    @Volatile
    var finished = false

    @Volatile
    var exitCode: Int? = null

    /** 子进程已写入但尚未被 Dart 轮询取走的字符数（仅用于展示统计）。 */
    @Volatile
    var bytesOut = 0L

    /** 从屏幕输出里刮出的「当前工作目录」提示（供 UI 显示）。 */
    // ⚠️ Bug 440：初值必须用**双引号**的空字符串 ""，不是单引号 ''。
    // '' 是空字符字面量，Kotlin 会直接报 Empty character literal 编译失败。
    @Volatile
    var lastCwdHint: String = ""

    fun write(text: String) {
        try {
            input.write(text.toByteArray(Charsets.UTF_8))
            input.flush()
        } catch (_: Exception) {
            // 会话已结束：静默忽略，UI 由 finished 状态反映
        }
    }

    fun closeInput() {
        try {
            input.close()
        } catch (_: Exception) {
        }
    }

    fun stop(): Boolean {
        return try {
            process.destroy()
            if (!finished && !process.waitFor(3, TimeUnit.SECONDS)) {
                process.destroyForcibly()
            }
            try {
                process.inputStream.close()
            } catch (_: Exception) {
            }
            true
        } catch (_: Exception) {
            false
        }
    }
}

/**
 * PTY 会话池：id → 会话，配合 MethodChannel 的
 * ptyStart / ptyWrite / ptyPoll / ptyStop / ptyResize 五个方法。
 */
class PtyRegistry {
    private val sessions = ConcurrentHashMap<Long, PtySession>()
    private val seq = AtomicLong(0)

    fun nextId(): Long = seq.incrementAndGet()

    fun put(s: PtySession) {
        sessions[s.id] = s
    }

    fun get(id: Long): PtySession? = sessions[id]

    fun remove(id: Long) {
        sessions.remove(id)
    }

    fun stopAll() {
        for ((_, s) in sessions) {
            s.stop()
        }
        sessions.clear()
    }

    /**
     * 回收已结束且被读取干净的会话。会话在结束时**不立即移除**——
     * Dart 侧还要靠最后一次 poll 拿到 exitCode，过早移除会让 UI
     * 永远显示「运行中」。由调用方在确认读取完毕后显式 remove()。
     */
    fun reapFinished(): Int {
        var n = 0
        for ((_, s) in sessions) {
            if (s.finished) n++
        }
        return n
    }

    companion object {
        /** 把 InputStream 持续读入会话缓冲（独立线程调用，不阻塞通道）。 */
        fun pump(stream: InputStream, s: PtySession) {
            try {
                val buf = ByteArray(8192)
                while (true) {
                    val n = try {
                        stream.read(buf)
                    } catch (_: Exception) {
                        -1
                    }
                    if (n <= 0) break
                    val chunk = String(buf, 0, n, Charsets.UTF_8)
                    synchronized(s.lock) {
                        s.buffer.append(chunk)
                        s.bytesOut += n
                    }
                }
            } catch (_: Exception) {
                // 进程结束/管道关闭：正常退出路径
            }
        }
    }
}

/** 供 MainActivity 组装 PTY 启动命令的小工具。 */
object PtyCmd {
    /**
     * 拷贝 `foa_pty` 到 filesDir/tools 并返回可执行文件；
     * 取自 assets（APK 内置），首次使用时落位。
     */
    fun ensureBinary(assets: android.content.res.AssetManager, filesDir: File): File? {
        val dest = File(File(filesDir, "tools"), "foa_pty")
        if (dest.exists() && dest.canExecute()) return dest
        return try {
            dest.parentFile?.mkdirs()
            assets.open("flutter_assets/assets/tools/foa_pty").use { input ->
                dest.outputStream().use { output -> input.copyTo(output, 1 shl 16) }
            }
            dest.setExecutable(true, false)
            if (dest.canExecute()) dest else null
        } catch (_: Exception) {
            null
        }
    }
}
