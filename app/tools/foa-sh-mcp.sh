#!/bin/sh
# foa-sh-mcp.sh —— 纯终端版 MCP 服务（不用 App）
#
# ## 为什么需要它
#
# App 自带的 MCP 服务（`lib/mcp/mcp_server.dart`）跑在 **App 进程内**，
# 只在点「远程协助 → 启动隧道」时才会拉起。想用**终端手工起的隧道**
# 时，8977 端口就没有人在听 —— cloudflared 日志一切正常，
# 但公网访问得到 **502 Bad gateway**（隧道通、回源失败）。
#
# 这个脚本用 **纯 shell 补上那个缺口**：在 8977 上开一个最小 HTTP 服务，
# 提供与 App 版**同名同参数**的 7 个工具，走同一套 MCP 协议
# （Streamable HTTP，POST /mcp，JSON 响应，不用 SSE）。
#
# ## 能力差距（先说清楚，别指望它等于 App 版）
#
# | 工具 | App 版 | 本脚本 |
# |---|---|---|
# | foa_info / foa_diag | 结构化，Kotlin 侧采集 | 简化版（读 /proc、跑标准命令） |
# | run_command | 经 proot executor + 单飞锁 | 直接 /bin/sh -c，**无单飞锁** |
# | read_file / write_file / list_dir | 走 FsBridge（不占 executor） | 直接文件 IO |
# | list_projects | 读 App 的项目目录 | 读 $FOA_PROJECTS_ROOT |
#
# 本脚本**没有**：单飞锁、审计日志、完整命令黑名单（只留了最小几个）。
# 它是**排障/应急通道**，不是 App 版的替代品。
#
# ## 已知局限（实测确认，别在需要这些的场景用它）
#
# | 局限 | 表现 | 为什么 |
# |---|---|---|
# | 不支持 chunked / keep-alive | 每次连接都 `Connection: close` | 手工解析只做了 Content-Length 定长 body |
# | 参数解析只认扁平结构 | 深层嵌套的 JSON 参数会漏 | minbase 没有 python/jq，只有 grep/awk |
# | 无单飞锁 | 两条命令可能同时跑 | App 版有 `McpExecGuard`，这里没实现 |
#
# **关于并发**：走 `socat ... fork` 时天然支持并发（实测 5/5 全过）；
# 只有退到 nc 兜底路径才是"单进程顺序服务"。见下面「依赖」一节。
#
# ## 用法
#
#   FOA_MCP_TOKEN=你的令牌 sh foa-sh-mcp.sh
#   FOA_MCP_PORT=8899 FOA_MCP_TOKEN=xxx sh foa-sh-mcp.sh
#
# 起完再另开一个终端：
#   /opt/foa-bin/cloudflared tunnel --url http://127.0.0.1:8977 --protocol http2 --no-autoupdate 2>&1
#
# ## 依赖：优先 socat，退回"只要有 /bin/sh"
#
# 这个脚本的依赖史本身就是一段教训：
#
# **第一版用 `nc`**（netcat）收 TCP 连接，真机上报：
#     ✗ 找不到 nc。试：apt-get install -y netcat-openbsd（或 busybox nc）
# Debian **minbase** rootfs 里没有 netcat，而让用户为了一个应急通道先
# `apt-get install` 是**把前置条件推给用户**，正是本项目反复踩的那类错
# （见 Bug 471b：下载器假设父目录已存在）。而且 `nc -l` 还有更阴的问题：
# **stdin 一 EOF 就立刻退出**，客户端发完请求半关闭写端 → nc 死 →
# 响应写进已关闭的管道 → `Empty reply from server`。要修得用 FIFO 撑住
# stdin，很绕。
#
# **现在优先 `socat`**：它的 `TCP-LISTEN:PORT,reuseaddr,fork` 语义最清楚、
# 天然支持并发，每个连接交给本脚本的 `--serve-one` 子进程处理，
# 没有 EOF 那一堆麻烦。socat 在 Debian 里有，装上约 300KB。
#
# **没有 socat 也不致命**：仍然可以用 nc（带 FIFO 兜底）跑起来。
# 两者都没有时脚本会**明确报错并给出可操作建议**，而不是静默失败
# ——静默失败正是这个脚本存在的原因（让用户对着 502 猜半天）。
#
# 读写逻辑本身不依赖任何监听工具：全部用 shell 的 fd 重定向与
# `head -c` 完成。监听只是个"把连接递进来"的薄壳。

set -u

# ---------------------------------------------------------------------------
# ⚠️ 尽早分流：--serve-one = socat 拉起的"单连接"子进程
#
# 这个判断必须在**最前面**。它原先放在文件底部，前面那段"启动横幅 +
# 挑监听器"会先跑 —— 结果 socat 拉起的每个子进程都会：
#   ① 打印一遍启动横幅（日志刷屏）；
#   ② 因为环境里没有端口信息而走到"挑监听器"分支并**卡住不处理连接**；
#   ③ 客户端拿到超时/空响应。
# 实测踩到（`curl: Operation timed out after 8002 ms with 0 bytes received`）。
# 修法：进单连接模式就直奔主题，绝不碰横幅与监听器逻辑。
#
# 注：`run_single_connection` 在文件后面才定义，但 shell 是**执行到才解析**，
# 函数在被调用前定义好即可 —— 所以这里调用是安全的。
# ---------------------------------------------------------------------------

PORT="${FOA_MCP_PORT:-8977}"
TOKEN="${FOA_MCP_TOKEN:-}"
PROJECTS_ROOT="${FOA_PROJECTS_ROOT:-/data/user/work/projects}"
WORK_DIR="${FOA_WORK_DIR:-/data/user/work}"
# SOCAT 兜底（可选）：minbase 没有，但用户装了就用，更稳。
SOCAT_BIN="${FOA_SOCAT_BIN:-socat}"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }

# ---------------------------------------------------------------------------
# 常量：临时目录
# ---------------------------------------------------------------------------
TMPBASE="${TMPDIR:-/tmp}/foa-sh-mcp.$$"
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="/tmp/foa-sh-mcp.$$"
mkdir -p "$TMPBASE" 2>/dev/null || { log "✗ 无法创建临时目录 $TMPBASE"; exit 1; }

cleanup() {
  # 收尾：杀掉可能残留的后台子进程，清掉临时目录
  [ -n "${REQ_PID:-}" ] && kill "$REQ_PID" 2>/dev/null
  [ -n "${FIFO_HOLD_PID:-}" ] && kill "$FIFO_HOLD_PID" 2>/dev/null
  [ -n "${SOCAT_PID:-}" ] && kill "$SOCAT_PID" 2>/dev/null
  rm -rf "$TMPBASE" 2>/dev/null
  exit 0
}
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# JSON 字符串转义
#
# 顺序很重要：**先转义反斜杠**，否则后面插入的 \" 会被再转义一次。
# 控制字符（\n \t \r）用 awk 逐行处理：shell 的变量替换对付不了它们。
# ---------------------------------------------------------------------------
json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' \
    | awk 'BEGIN{ORS=""} {if(NR>1) printf "\\n"; printf "%s", $0}'
}

# JSON 字符串 → 真实字节：还原 \" \\ \n \t \r \/
#
# ⚠️ **不做这一步会写出错文件**：JSON 里的换行是 `\n` 两个字符，
# 直接落盘就变成字面量反斜杠+n。实测踩到过（write_file 写出的文件
# `od -c` 显示 `\ n` 而不是真换行）。
#
# 顺序讲究：**先还原 \n，最后还原 \\**。反过来会把 `\\n`
# （JSON 语义 = 反斜杠 + n，共 2 字节）错误地变成真换行。
json_unescape() {
  printf '%s' "$1" | sed \
    -e 's/\\n/\
/g' \
    -e 's/\\t/	/g' \
    -e 's/\\r//g' \
    -e 's|\\/|/|g' \
    -e 's/\\"/"/g' \
    -e 's/\\\\/\\/g'
}

# 取某个 HTTP 头（大小写不敏感）
header() {
  printf '%s\n' "$1" | grep -i "^$2:" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
}

# ---------------------------------------------------------------------------
# 从 JSON 里抽字段
#
# 不用 python/jq —— minbase 里没有。用 grep+sed 处理**本项目会遇到的**
# 扁平/一层嵌套结构。复杂 payload 会退化（见头部"已知局限"）。
#
# ⚠️⚠️ 这里有一个**必须记住**的坑：不能写成
#       grep -o "\"$2\"...\"[^\"]*\""
#   `[^"]*` 会在**转义的引号** `\"` 处停下 —— 于是
#       {"content":"a\nb\tc\"d\\e"}
#   只抽出 `a\nb\tc\`，后面的 `d\e` **整段丢失**。
#   实测踩到：write_file 写 `a\nb\tc\"d\\e`，落盘成了 `a\nb\tc\`，
#   而且因为内容"看起来"只是短了点，非常难往"提取阶段截断"上想。
#
# 正确做法：逐字符扫描，区分"这个引号是结束符还是被转义的"。
# 纯 sed 难以表达，改用一个小 awk —— awk 是 POSIX 必备，minbase 里有。
# ---------------------------------------------------------------------------
json_str_field() {
  printf '%s' "$1" | awk -v key="$2" '
    BEGIN { klen = length(key); pat = "\"" key "\"" }
    {
      line = $0; n = length(line)
      # 找 "key" 后面跟可选的空白 + 冒号 + 可选空白 + 开引号
      pos = 0
      while ((i = index(substr(line, pos + 1), pat)) > 0) {
        p = pos + i                 # pat（= "key"，含两侧引号）起始位置（1-based）
        # pat 的长度是 klen + 2（两个引号），所以冒号从 p + klen + 2 开始找。
        # ⚠️ 曾经写成 p + klen + 1 —— 那会停在 key 的**收尾引号**上，
        # `substr(...) != ":"` 判定失败 → 一直 continue → 函数返回空串。
        # 表征是"所有字符串字段都取不到值"，method 变成空、启动日志出现
        # `→  (id=3)`，非常容易误判成协议层问题。
        q = p + klen + 2
        # 跳过空白，要求是冒号，再跳空白，要求是引号
        while (q <= n && substr(line, q, 1) ~ /[ \t\r\n]/) q++
        if (q > n || substr(line, q, 1) != ":") { pos = p; continue }
        q++
        while (q <= n && substr(line, q, 1) ~ /[ \t\r\n]/) q++
        if (q > n || substr(line, q, 1) != "\"") { pos = p; continue }
        q++                          # 越过开引号，开始读值
        out = ""; esc = 0
        while (q <= n) {
          ch = substr(line, q, 1)
          if (esc) { out = out "\\" ch; esc = 0; q++; continue }
          if (ch == "\\") { esc = 1; q++; continue }
          if (ch == "\"") break      # 真正的结束引号
          out = out ch; q++
        }
        # 若收尾处在转义态（值被截断），补回那个孤立的反斜杠
        if (esc) out = out "\\"
        print out
        exit
      }
    }
  '
}

json_num_field() {
  printf '%s' "$1" \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" \
    | head -1 | sed 's/.*:[[:space:]]*//'
}

# ---------------------------------------------------------------------------
# 工具实现
# ---------------------------------------------------------------------------

tool_foa_info() {
  local uni cpu mem sh_v
  uni=$(uname -a 2>/dev/null)
  cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*:[[:space:]]*//')
  [ -z "$cpu" ] && cpu=$(grep -m1 -i 'Hardware\|Processor' /proc/cpuinfo 2>/dev/null | sed 's/.*:[[:space:]]*//')
  [ -z "$cpu" ] && cpu='(未知)'
  mem=$(awk '/MemTotal/{printf "%.1f MB", $2/1024}' /proc/meminfo 2>/dev/null)
  sh_v=$(/bin/sh --version 2>&1 | head -1)

  printf 'FOA 终端版 MCP（纯 shell）\n'
  printf 'uname: %s\n' "$uni"
  printf 'CPU: %s\n' "$cpu"
  printf '内存总量: %s\n' "$mem"
  printf '工作目录: %s\n' "$WORK_DIR"
  printf '项目根: %s\n' "$PROJECTS_ROOT"
  printf 'shell: %s\n' "$sh_v"
  printf 'MCP 端口: %s\n' "$PORT"
}

tool_foa_diag() {
  printf '=== FOA 环境诊断（终端版）===\n'
  printf '\n[1] 架构\n'; uname -m
  printf '\n[2] glibc 版本\n'
  local libc=''
  for c in /lib/aarch64-linux-gnu/libc.so.6 /lib/arm-linux-gnueabihf/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6; do
    [ -f "$c" ] && { libc="$c"; break; }
  done
  if [ -n "$libc" ]; then "$libc" 2>/dev/null | head -1; else echo '(未找到 libc.so.6)'; fi
  printf '\n[3] 内存\n'
  awk '/MemTotal|MemAvailable/{printf "%s %.1f MB\n", $1, $2/1024}' /proc/meminfo 2>/dev/null
  printf '\n[4] DNS 配置\n'; cat /etc/resolv.conf 2>/dev/null || echo '(无 /etc/resolv.conf)'
  printf '\n[5] 磁盘\n'; df -h / 2>/dev/null | tail -2
  printf '\n[6] 关键工具\n'
  for t in wget curl git python3 socat readelf nc; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '  %-10s %s\n' "$t" "$(command -v "$t")"
    else
      printf '  %-10s (缺失)\n' "$t"
    fi
  done
  printf '\n[7] 网络连通性\n'
  if command -v wget >/dev/null 2>&1; then
    if wget -q -T 8 -O /dev/null https://mirrors.tuna.tsinghua.edu.cn 2>/dev/null; then
      echo '  清华镜像: 通'
    else
      echo '  清华镜像: 不通'
    fi
  else
    echo '  (无 wget，跳过)'
  fi
  printf '\n[8] 相关进程（/proc 遍历，minbase 无 ps）\n'
  local found=0 c
  for p in /proc/[0-9]*; do
    [ -r "$p/comm" ] || continue
    c=$(cat "$p/comm" 2>/dev/null) || continue
    case "$c" in
      cloudflared|dart|flutter*|java|gradle*|foa-sh-mcp)
        printf '  %-6s %s\n' "$(basename "$p")" "$c"; found=1 ;;
    esac
  done
  [ "$found" = 0 ] && echo '  (无相关进程)'
  printf '\n[9] 运行时长\n'
  awk '{printf "  开机 %.1f 小时\n", $1/3600}' /proc/uptime 2>/dev/null
}

tool_run_command() {
  local cmd="$FOA_ARG_CMD"
  case "$cmd" in
    *"rm -rf /"*|*"mkfs"*|*"dd if=/dev/zero of=/dev/"*|*"> /dev/sd"*)
      printf 'REJECTED: 该命令被黑名单拦截（破坏性操作）'; return 1 ;;
  esac
  cd "$WORK_DIR" 2>/dev/null || cd / 2>/dev/null
  /bin/sh -c "$cmd" 2>&1
  printf '\n[exit=%s]\n' "$?"
}

tool_read_file() {
  local p="$FOA_ARG_PATH"
  [ -f "$p" ] || { printf 'ERROR: 文件不存在：%s' "$p"; return 1; }
  head -c 524288 "$p"          # 限 512KB，别把大文件塞进一个 JSON 响应
  return 0
}

tool_write_file() {
  local p="$FOA_ARG_PATH" c="$FOA_ARG_CONTENT"
  mkdir -p "$(dirname "$p")" 2>/dev/null || true
  if printf '%s' "$c" > "$p" 2>/dev/null; then
    printf 'OK: 已写入 %s（%s 字节）' "$p" "$(wc -c < "$p" 2>/dev/null)"
    return 0
  fi
  printf 'ERROR: 写入失败：%s' "$p"; return 1
}

tool_list_dir() {
  local p="$FOA_ARG_PATH"
  [ -z "$p" ] && p="$WORK_DIR"
  [ -d "$p" ] || { printf 'ERROR: 目录不存在：%s' "$p"; return 1; }
  ls -la "$p" 2>&1
  return 0
}

tool_list_projects() {
  [ -d "$PROJECTS_ROOT" ] || { printf '(项目根不存在：%s)' "$PROJECTS_ROOT"; return 0; }
  ls -1 "$PROJECTS_ROOT" 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# JSON-RPC 组装
# ---------------------------------------------------------------------------
rpc_result() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "$1" "$2"; }
rpc_error()  { printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}' "$1" "$2" "$(json_escape "$3")"; }

tools_list_json() {
  cat <<'EOF'
{"tools":[
{"name":"foa_info","description":"查看设备/环境信息（终端版）","inputSchema":{"type":"object","properties":{}}},
{"name":"foa_diag","description":"环境诊断报告（终端版，9 项）","inputSchema":{"type":"object","properties":{}}},
{"name":"run_command","description":"在容器内执行 shell 命令","inputSchema":{"type":"object","properties":{"cmd":{"type":"string","description":"要执行的命令"}},"required":["cmd"]}},
{"name":"read_file","description":"读取文件内容（最多 512KB）","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},
{"name":"write_file","description":"覆盖写入文件","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
{"name":"list_dir","description":"列出目录内容","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"list_projects","description":"列出项目","inputSchema":{"type":"object","properties":{}}}
]}
EOF
}

# ---------------------------------------------------------------------------
# 处理一个 MCP 请求 → 输出响应 body（空 = 通知类，无响应）
# ---------------------------------------------------------------------------
handle_body() {
  local body="$1"
  local id method
  id=$(json_num_field "$body" "id")
  [ -z "$id" ] && { id=$(json_str_field "$body" "id"); [ -n "$id" ] && id="\"$id\""; }
  [ -z "$id" ] && id=null
  method=$(json_str_field "$body" "method")

  log "→ $method (id=$id)"

  case "$method" in
    initialize)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"foa-sh-mcp","version":"1.0.0"}}}' "$id"
      ;;
    notifications/*)
      printf ''          # 通知不需要响应
      ;;
    tools/list)
      rpc_result "$id" "$(tools_list_json)"
      ;;
    ping)
      rpc_result "$id" '{}'
      ;;
    tools/call)
      local tname
      tname=$(json_str_field "$body" "name")
      # 参数一律经 json_unescape 还原转义（否则 content 里的 \n 会写成字面量）
      #
      # 参数名必须与 App 版（`mcp_server.dart` 第 471 行 `args['command']`）
      # **逐字一致**。曾经写成 "cmd" —— 于是客户端按工具清单发的 "command"
      # 永远取不到值，run_command 变成执行空串（返回空输出、exit=0），
      # 黑名单也永远命中不了。同一个协议两个名字，是最难查的那类 bug。
      FOA_ARG_CMD=$(json_unescape "$(json_str_field "$body" "command")")
      FOA_ARG_PATH=$(json_unescape "$(json_str_field "$body" "path")")
      FOA_ARG_CONTENT=$(json_unescape "$(json_str_field "$body" "content")")

      # 空 command 直接拒绝，别静默执行空串（上面那个 bug 的表征就是它）
      if [ "$tname" = "run_command" ] && [ -z "$FOA_ARG_CMD" ]; then
        rpc_result "$id" '{"content":[{"type":"text","text":"ERROR: 缺少 command 参数"}],"isError":true}'
        return 0
      fi

      local out rc=0
      case "$tname" in
        foa_info)      out=$(tool_foa_info) ;;
        foa_diag)      out=$(tool_foa_diag) ;;
        run_command)   out=$(tool_run_command) || rc=1 ;;
        read_file)     out=$(tool_read_file) || rc=1 ;;
        write_file)    out=$(tool_write_file) || rc=1 ;;
        list_dir)      out=$(tool_list_dir) || rc=1 ;;
        list_projects) out=$(tool_list_projects) ;;
        *)
          # ⚠️ 工具层错误必须走 **result + isError**，不能用 JSON-RPC 的 error。
          # 协议里 -32602 是"请求本身不合法"（连工具名都解析不出来）；
          # "工具名不认识"属于**工具调用失败**，客户端要能看到 isError 才好
          # 向用户解释。App 版就是这么做的，两边行为必须一样。
          rpc_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":\"ERROR: 未知工具：$(json_escape "$tname")\"}],\"isError\":true}"
          return 0
          ;;
      esac
      local err_flag=""
      [ "$rc" != 0 ] && err_flag=',"isError":true'
      rpc_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":\"$(json_escape "$out")\"}]$err_flag}"
      ;;
    *)
      rpc_error "$id" -32601 "不支持的方法：$method"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 处理一个连接：读请求（从 $1 指定的文件）→ 写响应（到 $2 指定的 FIFO）
# ---------------------------------------------------------------------------
serve_connection() {
  local reqfile="$1"
  local fifo_in="$2"

  local reqline
  IFS= read -r reqline < "$reqfile" || return 0
  reqline=$(printf '%s' "$reqline" | tr -d '\r')
  [ -z "$reqline" ] && return 0

  local method path
  method=$(printf '%s' "$reqline" | awk '{print $1}')
  path=$(printf '%s' "$reqline" | awk '{print $2}')

  # 头
  local headers clen=0
  headers=$(sed -n '2,/^\r*$/p' "$reqfile" 2>/dev/null)
  clen=$(printf '%s\n' "$headers" | grep -i '^Content-Length:' | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '\r')
  [ -z "$clen" ] && clen=0

  # 写响应（带 Content-Length，Connection: close）
  respond() {
    printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
      "$1" "$(printf '%s' "$2" | wc -c)" "$2" > "$fifo_in"
  }

  # ---- 路由 ----
  if [ "$path" = "/health" ]; then
    respond "200 OK" '{"ok":true,"server":"foa-sh-mcp"}'
    return 0
  fi
  case "$path" in
    /mcp|/mcp\?*) ;;
    *) respond "404 Not Found" '{"error":"只支持 POST /mcp"}'; return 0 ;;
  esac

  # ---- 鉴权 ----
  if [ -n "$TOKEN" ]; then
    local got
    got=$(header "$headers" "Authorization" | sed 's/^[Bb]earer[[:space:]]*//')
    if [ -z "$got" ]; then
      got=$(printf '%s' "$path" | sed -n 's/.*[?&]token=\([^&]*\).*/\1/p')
    fi
    if [ "$got" != "$TOKEN" ]; then
      log "✗ 鉴权失败（path=$path）"
      respond "401 Unauthorized" '{"error":"invalid token"}'
      return 0
    fi
  fi

  if [ "$method" != "POST" ]; then
    respond "405 Method Not Allowed" '{"error":"只支持 POST"}'
    return 0
  fi

  # ---- 读 body（空行之后的部分）----
  local body="" blank
  if [ "$clen" -gt 0 ] 2>/dev/null; then
    blank=$(grep -n -m1 '^[[:space:]]*$' "$reqfile" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$blank" ]; then
      body=$(sed -n "$((blank+1)),\$p" "$reqfile" 2>/dev/null | tr -d '\r')
    fi
  fi

  local out
  out=$(handle_body "$body")
  if [ -z "$out" ]; then
    printf 'HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' > "$fifo_in"
  else
    respond "200 OK" "$out"
  fi
}

# ---------------------------------------------------------------------------
# 收一个连接（不依赖 nc）
#
# ## 怎么在没有 nc / socat / python 的情况下收 TCP
#
# 用 **shell 重定向连 `/dev/tcp`**。这不是 POSIX 标准，但 **dash 与 bash
# 都支持**（Android 的 /system/bin/sh 是 mksh，也支持）。
# 用法：
#
#     exec 3<>/dev/tcp/127.0.0.1/8977
#
# 但 `/dev/tcp` **只能"连出去"，不能"监听"**。所以这里的分工是：
#
#   - **监听**：只能靠外部程序。优先 `socat`（若用户装了），
#     否则用**一个极小的辅助进程**——见下面 pick_listener() 的说明。
#   - **读写**：全部用 shell 的 fd 重定向完成。
#
# ⚠️ 如果设备上既没有 socat 也没有任何别的监听工具，本脚本会**明确报错
# 并给出可操作的建议**，而不是静默失败（静默失败正是这个脚本存在的原因：
# 让用户对着一个 502 猜半天）。
# ---------------------------------------------------------------------------

# ---- 单连接模式（供 socat EXEC 调用）----
run_single_connection() {
  # 这一模式下：stdin = 客户端发来的请求，stdout = 要发回客户端的响应。
  # 用文件暂存请求（要多次读：找空行、取 body），响应直接写 stdout。
  #
  # ⚠️ **不能用 `cat > file` 读请求**：`cat` 会一直读到 stdin **EOF** 才返回，
  # 而 HTTP 客户端（socat 转发的连接）发完请求会**保持连接打开等响应** ——
  # 于是 `cat` 永远不返回、我们永远不回响应、客户端超时。
  # 实测踩到（`curl: Operation timed out after 8002 ms with 0 bytes received`）。
  #
  # 修法：**按 HTTP 协议边界读**，而不是按 EOF 读：
  #   ① 逐行读请求行 + 头，直到空行为止；
  #   ② 从空行后的第一行起，读 Content-Length 指定字节数。
  # 这样读到足够就立刻返回，不等 EOF。
  local reqf="$TMPBASE/single.$$.req"
  : > "$reqf"

  local reqline method path headers clen body
  IFS= read -r reqline || { rm -f "$reqf"; return 0; }
  reqline=$(printf '%s' "$reqline" | tr -d '\r')
  [ -z "$reqline" ] && { rm -f "$reqf"; return 0; }
  printf '%s\n' "$reqline" >> "$reqf"
  method=$(printf '%s' "$reqline" | awk '{print $1}')
  path=$(printf '%s' "$reqline" | awk '{print $2}')

  # 读头直到空行
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '\r')
    printf '%s\n' "$line" >> "$reqf"
    [ -z "$line" ] && break
  done
  headers=$(sed -n '2,/^$/p' "$reqf" 2>/dev/null)
  clen=$(printf '%s\n' "$headers" | grep -i '^Content-Length:' | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '\r')
  [ -z "$clen" ] && clen=0

  emit() {
    printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
      "$1" "$(printf '%s' "$2" | wc -c)" "$2"
  }

  if [ "$path" = "/health" ]; then
    emit "200 OK" '{"ok":true,"server":"foa-sh-mcp"}'; rm -f "$reqf"; return 0
  fi
  case "$path" in
    /mcp|/mcp\?*) ;;
    *) emit "404 Not Found" '{"error":"只支持 POST /mcp"}'; rm -f "$reqf"; return 0 ;;
  esac

  if [ -n "$TOKEN" ]; then
    local got
    got=$(header "$headers" "Authorization" | sed 's/^[Bb]earer[[:space:]]*//')
    [ -z "$got" ] && got=$(printf '%s' "$path" | sed -n 's/.*[?&]token=\([^&]*\).*/\1/p')
    if [ "$got" != "$TOKEN" ]; then
      log "✗ 鉴权失败（path=$path）"
      emit "401 Unauthorized" '{"error":"invalid token"}'; rm -f "$reqf"; return 0
    fi
  fi

  if [ "$method" != "POST" ]; then
    emit "405 Method Not Allowed" '{"error":"只支持 POST"}'; rm -f "$reqf"; return 0
  fi

  # ---- 读 body：按 Content-Length 精确读，**不等 EOF** ----
  #
  # 请求头已经逐行消费掉了，body 紧跟在后面、还在 stdin 上。
  # 用 `head -c` 精确取 N 字节：够 N 就立刻返回，不会挂住。
  # （若这里改用"读整个文件"的写法，就会退回成 cat 那套 EOF 依赖。）
  body=""
  if [ "$clen" -gt 0 ] 2>/dev/null; then
    body=$(head -c "$clen" 2>/dev/null | tr -d '\r')
  fi

  local out
  out=$(handle_body "$body")
  if [ -z "$out" ]; then
    printf 'HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
  else
    emit "200 OK" "$out"
  fi
  rm -f "$reqf" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# ⚠️ 分流必须放在**这里** —— `run_single_connection` 定义之后、启动横幅之前。
#
# 教训：我一开始把这个 `if` 放在文件最前面（"尽早分流"），结果报
#   `run_single_connection: not found`
# 原因是 shell 解析 `if ... fi` 这个**复合命令**时会整体读入，此时函数尚未
# 定义。所以"尽早"不是指位置尽量靠前，而是指**在横幅/监听器之前、
# 在函数定义之后**——这两个条件之间只有这一个位置。
#
# 它必须早于横幅的原因（实测）：
#   ① socat 拉起的每个子进程都会打印一遍启动横幅 → 日志刷屏；
#   ② 子进程会继续走到"挑监听器"并**卡在那里不处理连接** → 客户端超时
#      （`curl: Operation timed out after 8002 ms with 0 bytes received`）。
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--serve-one" ]; then
  run_single_connection
  exit $?
fi

# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------
log "FOA 终端版 MCP 服务"
log "  端口: $PORT"
if [ -n "$TOKEN" ]; then
  log "  鉴权: 已启用（Authorization: Bearer <令牌>）"
else
  log "  鉴权: ⚠️ 未启用 —— 任何能访问本端口的人都可执行命令，仅限本地调试！"
fi
log "  工具: foa_info / foa_diag / run_command / read_file / write_file / list_dir / list_projects"
log ""

# ---- 挑一个能用的监听器 ----
# 顺序：socat → nc → 都没有则报错退出。
# 为什么优先 socat：它的 TCP-LISTEN 语义最清楚，且能配合 fork 做并发；
# nc 次之（各版本参数不统一，且 stdin EOF 就退出，要额外用 FIFO 撑住）。
LISTENER=""
if command -v "$SOCAT_BIN" >/dev/null 2>&1; then
  LISTENER="socat"
elif command -v nc >/dev/null 2>&1; then
  LISTENER="nc"
fi

if [ -z "$LISTENER" ]; then
  log "✗ 既没有 socat 也没有 nc，无法监听 TCP 端口。"
  log ""
  log "  这是**环境缺工具**，不是脚本坏了。三选一："
  log "    ① 装 socat（推荐，约 300KB）：apt-get install -y socat"
  log "    ② 装 netcat：apt-get install -y netcat-openbsd"
  log "    ③ 不装任何东西，改走 App 里的「远程协助 → 启动隧道」"
  log "       （App 那条路把 MCP 服务跑在自己进程内，不需要这些工具）"
  log ""
  log "  ⚠️ 注意 rootfs 是 minbase，apt 源没配好的话先跑一次："
  log "       apt-get update"
  exit 1
fi

log "  监听器: $LISTENER"
log ""
log "  另开一个终端起隧道："
log "    /opt/foa-bin/cloudflared tunnel --url http://127.0.0.1:$PORT --protocol http2 --no-autoupdate 2>&1"
log ""
log "  本地自检（不用等隧道）："
log "    wget -qO- http://127.0.0.1:$PORT/health"
log ""

# ---------------------------------------------------------------------------
# 主循环（按监听器分两条实现）
#
# ## socat 路径（推荐）
#
# socat 的 `fork` 让每个连接独立处理，天然支持并发，也没有 nc 那个
# "stdin EOF 就退出"的毛病：
#
#     socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:...
#
# 但我们不希望为每个连接起一个 shell 去跑整个脚本（那样要传状态），
# 所以用 EXEC 调本脚本的 `--serve-one` 模式：socat 把连接接到该子进程的
# stdin/stdout，子进程只做"读请求写响应"，非常干净。
#
# ## nc 路径（兜底）
#
# nc 各版本参数不一，且 `-l` 在收到 stdin EOF 时立刻退出。修法是：
#   - 用 FIFO 撑住 nc 的 stdin（持有一个读端 fd，让它永远等不到 EOF）；
#   - 请求从 nc 的 stdout 重定向到文件，我们轮询该文件；
#   - 响应写进 FIFO → nc 读出来 → 发给客户端。
# 并**先挂下一个 listener 再处理当前请求**，消除"关旧开新"之间的空窗
# （否则客户端连发第二个请求会 Connection refused，表现为
#  "第一个成功、后面全失败"——实测踩过）。
# ---------------------------------------------------------------------------


# （`--serve-one` 的分流已在文件最前面处理，见 SERVING_ONE）

if [ "$LISTENER" = "socat" ]; then
  # socat 自己做监听与 fork；每个连接交给本脚本的 --serve-one 子进程。
  #
  # ⚠️ 这里**必须用绝对路径**：socat 的 EXEC 是自己 fork/exec 一个程序，
  # 不经 shell 做参数展开。原先写 `EXEC:/bin/sh $0 --serve-one` 里那个
  # `$0` 在 socat 看来就是字面量 `$0`（不是我们的脚本路径），
  # 结果子进程起不来 → 客户端拿到 "Empty reply from server"（实测踩到）。
  # 用绝对路径 + 显式 `/bin/sh` 就没有任何展开歧义。
  SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  case "$SELF" in
    /*) ;;
    *) SELF="$(pwd)/$SELF" ;;
  esac
  if [ ! -f "$SELF" ]; then
    log "✗ 无法确定脚本自身路径（$SELF）——socat 模式需要绝对路径。"
    log "  绕过办法：cd 到脚本所在目录再执行，或用绝对路径调用本脚本。"
    exit 1
  fi
  log "  脚本路径: $SELF"
  log ""
  exec "$SOCAT_BIN" \
    "TCP-LISTEN:$PORT,reuseaddr,fork" \
    "EXEC:/bin/sh $SELF --serve-one"
else
  # ---- nc 兜底路径 ----
  arm_listener() {
    CUR_DIR="$TMPBASE/c.$$.$(date +%s%N 2>/dev/null || date +%s)"
    mkdir -p "$CUR_DIR" 2>/dev/null || return 1
    mkfifo "$CUR_DIR/fifo_in" 2>/dev/null || { rm -rf "$CUR_DIR"; return 1; }
    # 持有 fifo_in 的读端：让 nc 永远看不到 EOF。
    # 没有这一句，nc 会在我们写响应之前就因 stdin EOF 退出，
    # 客户端只会看到 "Empty reply from server"。
    exec 8<> "$CUR_DIR/fifo_in" || return 1
    nc -l -p "$PORT" <&8 > "$CUR_DIR/req" 2>/dev/null &
    CUR_NC=$!
    return 0
  }
  drop_listener() {
    kill "$CUR_NC" 2>/dev/null
    wait "$CUR_NC" 2>/dev/null
    exec 8<&- 2>/dev/null || true
    rm -rf "$CUR_DIR" 2>/dev/null
  }

  arm_listener || { log "✗ 无法挂起监听"; exit 1; }

  while :; do
    waited=0
    while [ "$waited" -lt 300 ]; do
      [ -s "$CUR_DIR/req" ] && break
      kill -0 "$CUR_NC" 2>/dev/null || break
      sleep 0.1
      waited=$((waited + 1))
    done

    if [ ! -s "$CUR_DIR/req" ]; then
      drop_listener
      arm_listener || { log "✗ 无法挂起监听"; sleep 1; }
      continue
    fi

    # 先把下一个 listener 挂好（消除"关旧开新"的空窗），再处理当前请求
    SERVING_DIR="$CUR_DIR"; SERVING_NC="$CUR_NC"
    if arm_listener; then
      NEXT_DIR="$CUR_DIR"; NEXT_NC="$CUR_NC"
    else
      NEXT_DIR=""; NEXT_NC=""
      log "⚠️ 预挂下一个 listener 失败，本次请求后可能有短暂空窗"
    fi
    CUR_DIR="$SERVING_DIR"; CUR_NC="$SERVING_NC"

    serve_connection "$CUR_DIR/req" "$CUR_DIR/fifo_in"

    sleep 0.2                 # 让 nc 把响应发完再关
    drop_listener

    if [ -n "$NEXT_DIR" ]; then
      CUR_DIR="$NEXT_DIR"; CUR_NC="$NEXT_NC"
    else
      arm_listener || { log "✗ 无法挂起监听"; sleep 1; }
    fi
  done
fi
