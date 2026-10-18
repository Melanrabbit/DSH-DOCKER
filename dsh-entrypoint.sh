#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# dsh 容器入口脚本：按 PUID / PGID 调整运行身份后再启动 dsh
#
# 为什么需要它
#   镜像里的 node 用户是 uid/gid 1000，而 NAS 上的共享目录通常属于另一个 uid
#   —— 飞牛 fnOS 的用户目录是 1001，权限 0700（连父目录 /vol2/1001 都是 000）。
#   uid 对不上时，容器对这些挂载点连 opendir 都会 EACCES，挂载形同虚设，
#   报错是「只能读不能写」甚至「全部拒绝」。
#
#   这里在启动时把 node 用户的 uid/gid 改成 PUID/PGID，并把 DSH_HOME 与工作区
#   一并 chown 过去，然后用 gosu 降权启动 dsh。这样容器建出来的文件属主就是你
#   在 fnOS 里的那个用户，文件管理器里能正常查看/修改/删除。
#
# 用法（compose）
#   environment:
#     - PUID=1001        # stat -c %u <挂载的宿主机目录>
#     - PGID=1001        # stat -c %g <挂载的宿主机目录>
#
# 兼容性
#   * 不设 PUID/PGID 时默认 1000:1000，行为与旧镜像完全一致。
#   * 若用 compose 的 `user:` 指定了非 root 身份，本脚本不介入，原样启动
#     （那样没有权限改 uid/chown）。要改身份请用 PUID/PGID，不要用 user:。
#   * 想完全不降权（整容器跑 root）就把 entrypoint 覆盖成直接执行 dsh。
# ─────────────────────────────────────────────────────────────────────────────
set -eu

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# 非 root 启动：没有 CAP_CHOWN/CAP_SETUID，改不了身份，原样启动。
# 注意：以 root 启动时本脚本一定会降权到 node（其 uid = PUID）。
if [ "$(id -u)" != "0" ]; then
  exec "$@"
fi

CUR_UID="$(id -u node)"
CUR_GID="$(id -g node)"
TARGET_UID="${PUID:-$CUR_UID}"
TARGET_GID="${PGID:-$CUR_GID}"

# 只接受纯数字，避免把非法值喂给 usermod 后留下一半改一半没改的状态
case "$TARGET_UID" in
  "" | *[!0-9]*)
    log "PUID 必须是非负整数，收到：'$TARGET_UID'"
    exit 64
    ;;
esac
case "$TARGET_GID" in
  "" | *[!0-9]*)
    log "PGID 必须是非负整数，收到：'$TARGET_GID'"
    exit 64
    ;;
esac

# -o 表示允许与已有 uid/gid 重复，避免撞上镜像里的系统账号时直接失败
if [ "$TARGET_GID" != "$CUR_GID" ]; then
  groupmod -o -g "$TARGET_GID" node
  log "node 的 gid：$CUR_GID -> $TARGET_GID"
fi

if [ "$TARGET_UID" != "$CUR_UID" ]; then
  usermod -o -u "$TARGET_UID" node
  log "node 的 uid：$CUR_UID -> $TARGET_UID"
fi

# 数据卷里的文件属主可能还是上一次运行的 uid，不一致就整棵修正。
# 只在顶层属主不匹配时才递归，正常重启不会有额外开销。
for DIR in /home/node/.dsh /workspace; do
  [ -d "$DIR" ] || continue
  CUR_OWNER="$(stat -c '%u:%g' "$DIR")"
  if [ "$CUR_OWNER" != "$TARGET_UID:$TARGET_GID" ]; then
    log "修正属主：$DIR（$CUR_OWNER -> $TARGET_UID:$TARGET_GID）"
    chown -R "$TARGET_UID:$TARGET_GID" "$DIR"
  fi
done

# ── 监听地址：0.2.1 起上游不再接受「绑所有网卡」──────────────────────────────
# 0.2.0 还能在 patch 层写 host: '0.0.0.0'；0.2.1 的 webserver schema 会把通配地址
# 直接判死（"is an unspecified (wildcard) address ..."）并让容器根本起不来，
# 只接受「某个本机网卡的具体 IP」。桥接网络下 docker 把 3080 转发到容器自己的
# eth0 地址，所以这里按默认路由挑出容器地址，交给 /etc/dsh/webserver.patch.yml
# 里那条 !!js 读走（见 Dockerfile 修复 2）。
# 想自己固定就设 DSH_HOST：必须是容器内部的本机地址，不是 NAS 的 IP。
if [ -z "${DSH_HOST:-}" ]; then
  DSH_HOST="$(node -e '
    const os = require("os"), fs = require("fs");
    const ifaces = os.networkInterfaces();
    const ipv4 = (name) => ((ifaces[name] || []).find((i) => i.family === "IPv4" && !i.internal) || {}).address;
    let name = "";
    try {
      for (const line of fs.readFileSync("/proc/net/route", "utf8").split("\n").slice(1)) {
        const col = line.trim().split(/\s+/);
        if (col[1] === "00000000" && col[7] === "00000000") { name = col[0]; break; }
      }
    } catch (e) {}
    let addr = name ? ipv4(name) : "";
    if (!addr) for (const key of Object.keys(ifaces)) { addr = ipv4(key); if (addr) break; }
    process.stdout.write(addr || "");
  ')"
fi

if [ -z "${DSH_HOST:-}" ]; then
  log "ERROR: 探测不到可绑定的本机 IP。请在 compose 的 environment 里显式设置"
  log "       DSH_HOST=<容器内的本机地址>（用 network_mode: host 时填宿主机 IP）"
  exit 1
fi
export DSH_HOST
log "监听地址：$DSH_HOST:${DSH_PORT:-3080}"

# ── 可选：关掉 dsh 自带的浏览器 token 认证 ───────────────────────────────────
# 打开 DSH_DISABLE_AUTH=1 后，isAuthenticated() 直接返回 true，访问 WebUI 不再
# 需要启动日志里那条又长又难记的 ?token=。这正是飞牛 fnOS 打包版的做法
# （它的源码里就是 `return true; /* fnos-fpk: browser token auth off */`）。
#
# 0.2.1 起这个补丁要打两处：签名多了 secure（isAuthenticated(request, secure)），
# 而且 /api 还多了一层 authenticateApi()（它要求 cookie 载荷 version === 2，
# 浏览器 cookie 是 version 1，所以对浏览器只会返回 undefined）。只打前者的话，
# 走 authenticateApi 的路径依旧会被拒。
#
# ⚠️ 关掉之后，/api 上就只剩 Host/Origin 信任围栏了，而那个是**防 DNS
#    rebinding / CSRF 的，不是认证** —— 任何人只要能把 Host 头写成你白名单里的
#    值就能进来。所以只在下面两种情况用：
#      * 端口不对外（只有内网 / 只有你能连到的网络）；
#      * 前面有反向代理做真正的认证，且 dsh 端口没有被直接暴露。
#    绝对不要「关掉认证」+「直接把 3080 映射到公网」。
#
# 默认不开。补丁是幂等的，容器重建后新文件会被重新打一次。
if [ "${DSH_DISABLE_AUTH:-0}" = "1" ]; then
  PATCHED=0
  for F in $(find /usr/local/lib/node_modules -path '*/@deepseek-ai/dsh-client-connection/lib/index.js'); do
    DSH_AUTH_TARGET="$F" node -e '
      const fs = require("fs");
      const p = process.env.DSH_AUTH_TARGET;
      let s = fs.readFileSync(p, "utf8");
      const MARK = "/* dsh-docker: auth off */";
      // 0.2.0: isAuthenticated(request) { ... }
      // 0.2.1: isAuthenticated(request, secure = false) 且 /api 还走 authenticateApi
      // 两个正则都用 [^)]* 兼容两种签名，以后上游再加参数也不用改。
      const reAuth = /(isAuthenticated\s*\(\s*request[^)]*\)\s*\{)/;
      const reApi = /(authenticateApi\s*\(\s*request[^)]*\)\s*\{)/;
      const doneAuth = /isAuthenticated\s*\(\s*request[^)]*\)\s*\{\s*return true;/;
      const doneApi = /authenticateApi\s*\(\s*request[^)]*\)\s*\{\s*return "dsh-docker-auth-off";/;
      if (!reAuth.test(s)) {
        console.error("ERROR: 没找到 isAuthenticated(request...)，上游代码结构变了，补丁未生效");
        process.exit(1);
      }
      // 幂等：各自独立判断，已经打好的一处不动，缺的那处补上（可自愈半成品状态）。
      let changed = false;
      if (!doneAuth.test(s)) { s = s.replace(reAuth, "$1 return true; " + MARK); changed = true; }
      if (reApi.test(s) && !doneApi.test(s)) { s = s.replace(reApi, "$1 return \"dsh-docker-auth-off\"; " + MARK); changed = true; }
      if (!changed) { console.log("auth 已是关闭状态"); process.exit(0); }
      fs.writeFileSync(p, s);
      const out = fs.readFileSync(p, "utf8");
      if (!doneAuth.test(out)) {
        console.error("ERROR: isAuthenticated 写入后校验失败");
        process.exit(1);
      }
      if (reApi.test(out) && !doneApi.test(out)) {
        console.error("ERROR: authenticateApi 存在但写入后校验失败");
        process.exit(1);
      }
      console.log("已关闭浏览器认证: " + p);
    ' || exit 1
    PATCHED=1
  done
  if [ "$PATCHED" -ne 1 ]; then
    log "ERROR: DSH_DISABLE_AUTH=1 但没找到 dsh-client-connection/lib/index.js"
    exit 1
  fi
  log "警告：已关闭 dsh 浏览器认证，请确保本端口不对外暴露（仅内网 / 仅在反代之后）"
fi

log "以 node（$(id -u node):$(id -g node)）启动：$*"
exec gosu node "$@"
