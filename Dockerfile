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
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates \
      jq less unzip zip file xz-utils procps rsync openssh-client \
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

# ── 修复 2：设置页在非回环地址下不可用（对齐飞牛 fnOS 打包版的做法）──────
# 上游设计：设置页的持久化按「浏览器地址栏的主机名」决定 ——
#   const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";
# 用局域网 IP（例如 http://192.168.110.110:3080）打开时 isLoopback 为 false，
# 设置页退化成浏览器内存态，报 "settings are unavailable in this browser"，
# 连读取设置的请求都不发，于是「设置 → 模型」等页面完全不可用。
# 飞牛的 fnOS 打包版正是把这一行改成常量 "host"（已逐字节对比确认），
# 所以它的原生实例用局域网 IP 也能进设置页。这里照抄同样的最小改动。
#
# 安全说明：设置文档即 profile 的 patch 文件，能挂载任意插件（≈ 代码执行），
# 上游把设置页限制在回环地址就是为了挡住这条路。本镜像的兜底是启动 token +
# Host/Origin 信任围栏（DSH_TRUSTED_HOSTS），请勿再把端口暴露到公网。
# 注：路径不能硬编码。`npm install -g` 会把依赖装进包自己的 node_modules
# （/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/...），而本地
# 非全局安装是扁平的（.../node_modules/@deepseek-ai/dsh-client-ui-settings），
# 所以这里用 find 定位；找不到就打印实际位置并让构建失败。
RUN set -eu; \
    FOUND=0; \
    for f in $(find /usr/local/lib/node_modules -path '*/@deepseek-ai/dsh-client-ui-settings/lib/client.js'); do \
      echo "settings client bundle: $f"; \
      sed -i 's/ctx\.remote\.\$host\.isLoopback ? "host" : "memory"/"host"/' "$f"; \
      grep -q 'const persistence = "host";' "$f"; \
      FOUND=1; \
    done; \
    if [ "$FOUND" -ne 1 ]; then \
      echo "ERROR: 没找到 dsh-client-ui-settings/lib/client.js，实际安装位置如下："; \
      find /usr/local/lib/node_modules -name 'client.js' -path '*dsh-client-ui-settings*'; \
      exit 1; \
    fi; \
    echo "client-ui-settings: persistence pinned to host (fnOS parity)"

# ── 修复 3：被 CLI 拒绝的 --host 0.0.0.0，以及桥接网络下的 /api 403 ──────
# dsh 0.2.0-rc.2 会直接拒绝 --host 0.0.0.0（"intentionally not supported yet
# for safety"）并以退出码 1 退出。绑定地址改由 patch 层提供：webserver 行的
# schema 允许 "127.0.0.1" / "0.0.0.0" 两个字面量。
#
# 放在 /etc/dsh（而不是 $DSH_HOME）是为了不被挂载卷遮住。
# 另外补一条 connection 行：把环境变量 DSH_TRUSTED_HOSTS 里的地址追加进
# 可信 Host 列表 —— 用桥接网络 + 端口映射时，容器看到的网卡 IP 是 172.x，
# 宿主机 IP 不在自动派生出来的列表里，不加这个所有 /api 都会 403。
#
#   DSH_PORT           监听端口，默认 3080
#   DSH_TRUSTED_HOSTS  额外可信地址，逗号分隔；用 host 网络时不需要
RUN mkdir -p /etc/dsh \
 && printf '%s\n' \
      '# 绑定所有网卡，等价于原来的 --host 0.0.0.0，但走官方支持的配置层' \
      '- id: webserver' \
      '  config:' \
      "    host: '0.0.0.0'" \
      '    port: !!js Number(process.env.DSH_PORT ?? 3080)' \
      '# 桥接网络部署时，把 DSH_TRUSTED_HOSTS 里声明的地址也加入可信 Host' \
      '- id: connection' \
      '  config:' \
      "    trustedHosts: !!js (process.env.DSH_TRUSTED_HOSTS ?? '').split(',').map((s) => s.trim()).filter(Boolean).concat(ctx.webRuntime.trustedHosts)" \
      > /etc/dsh/webserver.patch.yml \
 && mkdir -p /home/node/.dsh /workspace \
 && chown -R node:node /home/node/.dsh /workspace

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

USER node
WORKDIR /workspace
EXPOSE 3080

# 构建期冒烟测试：确认 CLI 入口真的可执行
RUN dsh --version

# ⚠️ 顺序不能改：--patch 必须紧跟 "web"，写在 --no-open 之后会被当成未知参数。
CMD ["dsh", "web", "--patch", "/etc/dsh/webserver.patch.yml", "--no-open"]
