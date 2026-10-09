# ============================================================
#  dsh Docker 镜像（修正版）
#  基于 Melanrabbit/DSH-DOCKER 的原始 Dockerfile。
#  修复了三处会导致「部署后 dsh 不停重启 / 页面打不开」的问题，详见 README.md。
# ============================================================

# ===== 第一阶段：构建阶段 =====
# 使用完整的 Node.js 24 镜像，自带编译工具链
FROM node:24-trixie AS builder

# 设置 npm 国内镜像源，加速依赖下载
RUN npm config set registry https://registry.npmmirror.com

# 接收版本号参数
ARG DSH_VERSION=latest

# 安装官方 dsh，并显式允许必要的安装脚本执行
RUN npm install --global --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs "@deepseek-ai/dsh@${DSH_VERSION}"

# ===== 第二阶段：运行阶段 =====
# 使用精简版镜像，减小最终体积
FROM node:24-trixie-slim

# 安装运行时需要的少量工具
RUN apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的全局 node_modules
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules

# 【修复 1】原写法 `ln -sf .../dsh/bin/dsh.js` 指向一个不存在的文件。
#   @deepseek-ai/dsh 0.2.0-rc.2 的包里没有 bin/ 目录，真实入口是 lib/bin.js
#   （package.json 的 bin 字段：{"dsh":"lib/bin.js"}）。
#   断链会让 node 基础镜像的 docker-entrypoint.sh 判定 "dsh 不是可执行命令"，
#   于是把命令行改写成 `node dsh web --host 0.0.0.0`，node 随即以
#   `Error: Cannot find module '/workspace/dsh'` 退出 → 容器无限重启。
#   这里不硬编码路径，改为从 package.json 的 bin 字段读取，并在构建期校验
#   软链确实解析到真实文件 —— 以后包结构再变会「构建失败」而不是静默重启。
RUN BIN="$(node -p "require('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json').bin.dsh")" \
 && ln -sf "/usr/local/lib/node_modules/@deepseek-ai/dsh/${BIN}" /usr/local/bin/dsh \
 && test -f "$(readlink -f /usr/local/bin/dsh)" \
 && echo "dsh entrypoint -> $(readlink -f /usr/local/bin/dsh)"

# 设置环境变量
ENV DSH_HOME=/home/node/.dsh
ENV HOME=/workspace
ENV TZ=Asia/Shanghai

# 【修复 2】绑定地址不再走 CLI 参数。
#   dsh 0.2.0-rc.2 明确拒绝 `dsh web --host 0.0.0.0`（会直接报错退出，见 README），
#   正确做法是用 patch 覆盖 webserver 行的 config（该行 schema 允许 127.0.0.1 / 0.0.0.0）。
#   这里把 home 级 patch 直接写进镜像，保证开箱即用；如需改端口/绑定地址，
#   用 docker-compose 挂载的 cordis.patch.yml 覆盖即可（优先级更高）。
RUN mkdir -p /home/node/.dsh /workspace \
 && printf '%s\n' \
      '# 覆盖 webserver 行：绑定所有网卡（等价于原来的 --host 0.0.0.0，但走配置层）' \
      '- id: webserver' \
      '  config:' \
      "    host: '0.0.0.0'" \
      '    port: 3080' \
      > /home/node/.dsh/cordis.patch.yml \
 && chown -R node:node /home/node/.dsh /workspace

USER node
WORKDIR /workspace
EXPOSE 3080

# 构建期冒烟测试：确认 CLI 入口真的可执行。
# 这一步能过，容器起来就不会再出现 exec / module-not-found 类的启动失败。
RUN dsh --version

# 【修复 3】不要传 --host 0.0.0.0；容器里没有浏览器，加 --no-open。
CMD ["dsh", "web", "--no-open"]
