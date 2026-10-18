# ============================================================
#  dsh Docker 镜像（修正版）
#  基于 Melanrabbit/DSH-DOCKER 原 Dockerfile，修掉两个必崩的 bug，
#  并解决「桥接网络下界面 403」的问题。详细说明见 README.md。
# ============================================================

# ===== 第一阶段：构建阶段 =====
# 使用完整的 Node.js 24 镜像，自带编译工具链
FROM node:24-trixie AS builder

# 设置 npm 国内镜像源，加速依赖下载
RUN npm config set registry https://registry.npmmirror.com

# 接收版本号参数
ARG DSH_VERSION=latest

# 安装官方 dsh，并显式允许必要的安装脚本执行
# （这 5 个就是依赖树里全部带 install/postinstall 脚本的包，且都含原生模块，别删）
RUN npm install --global --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs "@deepseek-ai/dsh@${DSH_VERSION}"

# ===== 第二阶段：运行阶段 =====
# 使用精简版镜像，减小最终体积
FROM node:24-trixie-slim

# 安装运行时需要的工具（面向 coding agent 的常用命令）
# 注意：不需要装系统 ripgrep —— dsh 的搜索工具用的是 npm 包里自带的 rg
# （@vscode/ripgrep + 平台专属包，二进制直接打在 tarball 里，不依赖 postinstall）。
#
# gosu + passwd 是给入口脚本用的：gosu 负责降权（不像 su/sudo 那样引入 TTY 和
# 信号转发问题），passwd 提供 usermod/groupmod —— 用来把 node 用户的 uid/gid
# 改成 PUID/PGID。两者体积都很小，gosu 在 Debian trixie 是官方包（1.17-3）。
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates \
      jq less unzip zip file xz-utils procps rsync openssh-client \
      gosu passwd \
 && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的全局 node_modules
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules

# ── 修复 1：断链的 dsh 命令 ────────────────────────────────────────────
# 原写法 `ln -sf .../dsh/bin/dsh.js` 指向不存在的文件：该 npm 包里没有
# bin/ 目录，真实入口是 lib/bin.js。悬空软链会让 node 基础镜像的
# docker-entrypoint.sh 判定「dsh 不是可执行命令」，把命令改写成
# `node dsh web ...`，随即以 `Cannot find module '/workspace/dsh'` 退出。
# 这里从 package.json 的 bin 字段读取真实路径，并在构建期校验软链能解析到
# 真实文件 —— 以后再变包结构会「构建失败」，而不是静默变成重启循环。
RUN BIN="$(node -p "require('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json').bin.dsh")" \
 && ln -sf "/usr/local/lib/node_modules/@deepseek-ai/dsh/${BIN}" /usr/local/bin/dsh \
 && test -f "$(readlink -f /usr/local/bin/dsh)" \
 && echo "dsh entrypoint -> $(readlink -f /usr/local/bin/dsh)"

# ── 修复 2：监听地址只走配置层 + 桥接网络下的可信 Host（0.2.1 起变了）────
# 为什么不能用 --host 0.0.0.0：CLI 会直接拒绝通配地址并以退出码 1 退出。
#
# 为什么也不能在 patch 里写 0.0.0.0：
#   * 0.2.0-rc.2 的 webserver schema 是 z.union(["127.0.0.1", "0.0.0.0"]），能写；
#   * 0.2.1-rc.2 改成「必须是某个本机网卡的具体 IP 字面量」，通配地址直接抛错
#     （webserver: host "0.0.0.0" is an unspecified (wildcard) address ...），
#     配置校验不过 → 容器根本起不来（实测确认）。
# 所以绑定地址改成读环境变量 DSH_HOST：入口脚本在容器里按默认路由挑出那张网卡的
# IPv4（桥接网络下 docker 正是把 3080 转发到这个地址）再导出；想自己指定就在
# compose 里设 DSH_HOST=<容器内的本机地址> 覆盖。
#
# 放在 /etc/dsh（而不是 $DSH_HOME）是为了不被挂载卷遮住。
# 另外补一条 connection 行：把环境变量 DSH_TRUSTED_HOSTS 里的地址追加进
# 可信 Host 列表 —— 用桥接网络 + 端口映射时，容器看到的网卡 IP 是 172.x，
# 宿主机 IP 不在自动派生出来的列表里，不加这个所有 /api 都会 403。
# 0.2.1 把 webRuntime 这个服务删了（相关派生逻辑并入 webStartup），旧表达式
# `ctx.webRuntime.trustedHosts` 会让 connection 以 "cannot get property
# webRuntime without inject" 起不来（实测确认）；这里改用不抛异常的 ctx.get()。
#
# 上游 bundle 的 webserver 行还有 tls / compression 几项，而 patch 是整段替换
# config，所以这里照抄一份，否则会被打回 schema 默认值（丢掉 gzip 压缩）。
#
#   DSH_HOST           绑定地址，容器内的本机 IP；不设则由入口脚本探测
#   DSH_PORT           监听端口，默认 3080
#   DSH_TRUSTED_HOSTS  额外可信地址，逗号分隔；用 host 网络时不需要
#   DSH_COOKIE_MAX_AGE_DAYS
#                      浏览器登录 cookie 的有效期（天），默认 365（上游默认只有 30）。
#                      见下面 cookieMaxAgeDays 的说明。
RUN mkdir -p /etc/dsh \
 && printf '%s\n' \
      '# 绑定一个具体的本机地址（0.2.1 起不再允许 0.0.0.0）' \
      '- id: webserver' \
      '  config:' \
      "    host: !!js process.env.DSH_HOST ?? ctx.get('webStartup')?.host ?? '127.0.0.1'" \
      "    port: !!js Number(process.env.DSH_PORT ?? ctx.get('webStartup')?.port ?? 3080)" \
      "    tls: !!js ctx.get('webStartup')?.tls" \
      '    compression: gzip' \
      '    compressionLevel: 1' \
      '    compressionThresholdBytes: 1024' \
      '# 桥接网络部署时，把 DSH_TRUSTED_HOSTS 里声明的地址也加入可信 Host' \
      '- id: connection' \
      '  config:' \
      "    trustedHosts: !!js (process.env.DSH_TRUSTED_HOSTS ?? '').split(',').map((s) => s.trim()).filter(Boolean).concat(ctx.get('webStartup')?.trustedHosts ?? [])" \
      '# 登录 cookie 有效期（上游 schema 默认 30 天，到期就得重新贴一次启动 token）。' \
      '# 注意 cookie 是按「host:port」签名并命名的：换地址访问就等于换了一份 cookie，' \
      '# 所以固定用同一个地址（建议直接收藏 http://<NAS_IP>:<端口>/）。' \
      '    cookieMaxAgeDays: !!js Number(process.env.DSH_COOKIE_MAX_AGE_DAYS ?? 365)' \
      > /etc/dsh/webserver.patch.yml \
 && mkdir -p /home/node/.dsh /workspace \
 && chown -R node:node /home/node/.dsh /workspace

# ── 修复 3：明文 http 下 crypto.randomUUID 缺失导致的页面白屏（继续保留）────
# crypto.randomUUID 只在「安全上下文」（https / localhost / 127.0.0.1）存在。
# 用 http://<局域网IP>:3080 访问时它不存在，0.2.0 的设置页一渲染就抛
#   TypeError: crypto.randomUUID is not a function
# 整个面板随之崩成白屏（浏览器控制台会看到 slot entry crashed in 'settings.section'）。
#
# 已核实：0.2.1 的 dsh-web-frontend/dist 里 randomUUID 出现 0 次，但**第三方
# 客户端插件还在用**（本机已装的 @xmanrui/dsh-im、@mars-sea/dsh-commandcode-
# provider 的 client.js 里都有）。这段 shim 挂在 index.html 上，是页面级兜底，
# 对任何后装的客户端插件都生效，而本机就是明文 http + 局域网访问，所以继续保留。
# 飞牛的 fnOS 打包版也是往 index.html 注入同样的兼容代码（已对比确认），区别是：
# 优先用 crypto.getRandomValues 生成真正的 v4 UUID，拿不到才退回 Math.random。
# 注：navigator.clipboard 同样只在安全上下文存在，所以复制按钮在明文 http 下
#     仍可能无效；要完全干净就用 https 反代，或 SSH 隧道从 127.0.0.1 访问。
RUN set -eu; \
    HTML="$(find /usr/local/lib/node_modules -path '*dsh-web-frontend/dist/index.html' -print -quit)"; \
    if [ -z "$HTML" ]; then echo "ERROR: 没找到 dsh-web-frontend/dist/index.html"; exit 1; fi; \
    DIST="$(dirname "$HTML")"; \
    printf '%s\n' \
      '(function () {' \
      '  if (!window.crypto) window.crypto = {};' \
      '  if (crypto.randomUUID) return;' \
      '  crypto.randomUUID = function () {' \
      '    var b = new Uint8Array(16);' \
      '    if (crypto.getRandomValues) crypto.getRandomValues(b);' \
      '    else for (var i = 0; i < 16; i++) b[i] = (Math.random() * 256) | 0;' \
      '    b[6] = (b[6] & 15) | 64;' \
      '    b[8] = (b[8] & 63) | 128;' \
      '    var h = [];' \
      '    for (var j = 0; j < 16; j++) h.push((b[j] + 256).toString(16).slice(1));' \
      '    return h.slice(0, 4).join("") + "-" + h.slice(4, 6).join("") + "-" + h.slice(6, 8).join("") + "-" + h.slice(8, 10).join("") + "-" + h.slice(10, 16).join("");' \
      '  };' \
      '})();' > "$DIST/dsh-secure-context-shim.js"; \
    grep -q 'dsh-secure-context-shim' "$HTML" || sed -i 's#<head>#<head><script src="./dsh-secure-context-shim.js"></script>#' "$HTML"; \
    grep -q 'dsh-secure-context-shim' "$HTML"; \
    grep -q 'crypto.randomUUID = function' "$DIST/dsh-secure-context-shim.js"; \
    echo "index.html patched: crypto.randomUUID shim injected"

# ── 运行时需要 pnpm ───────────────────────────────────────────────────────
# dsh 自己不引导 pnpm：`dsh plugin` 只是把参数转发给 pnpm（缺了会提示
# "pnpm was not found"），GUI 的「设置 → 插件 → 添加插件」更是直接 spawn pnpm
# （缺了报 spawn pnpm ENOENT）。node 官方镜像只带 yarn 的 corepack shim，不含 pnpm。
# 顺带把 npm registry 指到国内镜像，让插件安装更快更稳；不需要就删掉第一行。
RUN npm config set registry https://registry.npmmirror.com \
 && npm install -g pnpm@10 \
 && pnpm --version

# ── 环境收尾 ──────────────────────────────────────────────────────────────
# 1) git 安全检查：宿主机挂进来的目录通常属于别的 uid（NAS 上常见 1001），容器内是
#    1000，git 会以 "detected dubious ownership" 直接拒绝工作 —— 而 dsh 的「本轮
#    改动文件」卡片正是靠 git 快照实现的。写到 system 级（/etc/gitconfig）：因为
#    HOME=/workspace，写到 global 级会落进工作区里。
# 2) 缓存与运行时目录：HOME=/workspace，不重定向的话 npm/pnpm 会把 .npm/.cache/
#    .local 写进工作区（污染工作区；工作区只读时插件安装会直接失败）。
#    缓存放 DSH_HOME（在卷里，重建不丢），XDG 放 /tmp。与社区镜像的做法一致。
# 3) LANG：不设的话 shell 工具在 C locale 下会把中文文件名/内容输出成八进制转义。
RUN git config --system --add safe.directory '*' \
 && git config --system --get-all safe.directory
ENV NPM_CONFIG_CACHE=/home/node/.dsh/npm-cache
ENV XDG_CACHE_HOME=/tmp/.cache
ENV XDG_CONFIG_HOME=/tmp/.config
ENV XDG_DATA_HOME=/tmp/.local/share
ENV LANG=C.UTF-8

# 设置环境变量
ENV DSH_HOME=/home/node/.dsh
ENV HOME=/workspace
ENV TZ=Asia/Shanghai
ENV DSH_PORT=3080
# 浏览器登录 cookie 有效期（天），见 /etc/dsh/webserver.patch.yml 里的说明
ENV DSH_COOKIE_MAX_AGE_DAYS=365

# ── 运行身份：PUID / PGID ────────────────────────────────────────────────
# 一句话：镜像里 node 用户是 uid/gid 1000，而 NAS 上的共享目录常属于别的 uid
# （飞牛 fnOS 是 1001，权限 0700，连父目录 /vol2/1001 都是 000）。uid 不匹配时
# 容器对那些挂载点连 opendir 都会 EACCES —— 表现就是「只能读不能写」甚至
# 「全部拒绝」。入口脚本以 root 起，把 node 的 uid/gid 改成 PUID/PGID、
# 把 DSH_HOME 与工作区 chown 过去，再用 gosu 降权启动 dsh。这样容器建出来的
# 文件属主就是你在 fnOS 里的那个用户，文件管理器能正常改/删。
#
#   stat -c '%u:%g' /vol2/1001/DOCUMENTS    # 先查挂载目录的属主
#   PUID=1001  PGID=1001                    # 填进 compose 的 environment
#
# 默认 1000:1000 —— 不设时行为与旧镜像完全一致。
ENV PUID=1000
ENV PGID=1000

COPY dsh-entrypoint.sh /usr/local/bin/dsh-entrypoint.sh
RUN chmod 0755 /usr/local/bin/dsh-entrypoint.sh \
 && sh -n /usr/local/bin/dsh-entrypoint.sh \
 && gosu node true \
 && echo "PUID/PGID entrypoint ok, node = $(gosu node id -u):$(gosu node id -g)"

WORKDIR /workspace
EXPOSE 3080

# 构建期冒烟测试 1：确认 CLI 入口真的可执行
RUN dsh --version

# 构建期冒烟测试 2：把 web 服务真起一遍，确认配置层能过、地址能绑上。
# 只做 `dsh --version` 挡不住这类问题：0.2.1 把 webserver.host 的通配地址判死、
# 又把 webRuntime 服务改名成 webStartup，配置校验一失败容器就根本起不来，
# 而 build 依旧是绿的（0.2.0 → 0.2.1 升级时这两个坑都实测踩到了）。
# 所以这里真的拉起服务，等到能 HTTP 应答才算过（认证开着时 / 回 401，因此不校验
# 具体状态码，只要求「不是 000」= 端口上有东西在应答）。
# 用一次性的 HOME/DSH_HOME，测完删掉，避免把 profile 骨架烤进镜像。
RUN set -eu; \
    rm -rf /tmp/dshhome; mkdir -p /tmp/dshhome; \
    HOME=/tmp/dshhome DSH_HOME=/tmp/dshhome \
      dsh web --patch /etc/dsh/webserver.patch.yml --no-open > /tmp/boot.log 2>&1 & \
    BOOT_PID=$!; \
    CODE=000; \
    for i in $(seq 1 60); do \
      CODE="$(curl -s -o /dev/null -m 3 -w '%{http_code}' -H 'Host: 127.0.0.1:3080' http://127.0.0.1:3080/ || true)"; \
      [ "$CODE" != "000" ] && break; \
      kill -0 "$BOOT_PID" 2>/dev/null || break; \
      sleep 1; \
    done; \
    kill "$BOOT_PID" 2>/dev/null || true; \
    wait "$BOOT_PID" 2>/dev/null || true; \
    if [ "$CODE" = "000" ]; then \
      echo "ERROR: 构建期启动冒烟测试失败（HTTP $CODE），日志如下："; \
      cat /tmp/boot.log 2>/dev/null || true; \
      find /tmp/dshhome/logs -name '*.log' -exec cat {} + 2>/dev/null || true; \
      exit 1; \
    fi; \
    rm -rf /tmp/dshhome /tmp/boot.log; \
    echo "构建期启动冒烟测试通过：HTTP $CODE"

# ⚠️ 这里不能再写 `USER node`：入口脚本需要 root 才能 usermod/chown，
#    它会自己用 gosu 降权到 node。写死 USER node 会让 PUID/PGID 彻底失效。
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint.sh"]

# ⚠️ 顺序不能改：--patch 必须紧跟 "web"，写在 --no-open 之后会被当成未知参数。
CMD ["dsh", "web", "--patch", "/etc/dsh/webserver.patch.yml", "--no-open"]
