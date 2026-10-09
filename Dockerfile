# ===== 第一阶段：构建阶段 =====
# 使用完整的 Node.js 24 镜像，自带编译工具链
FROM node:24-trixie AS builder

# 设置 npm 国内镜像源，加速依赖下载
RUN npm config set registry https://registry.npmmirror.com

# 接收版本号参数
ARG DSH_VERSION=latest

# 核心：安装官方 dsh，并显式允许必要的安装脚本执行
RUN npm install --global --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs "@deepseek-ai/dsh@${DSH_VERSION}"

# ===== 第二阶段：运行阶段 =====
# 使用精简版镜像，减小最终体积
FROM node:24-trixie-slim

# 安装运行时需要的少量工具
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的全局 node_modules
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules

# 将 dsh 命令链接到 PATH
RUN ln -sf /usr/local/lib/node_modules/@deepseek-ai/dsh/bin/dsh.js /usr/local/bin/dsh

# 设置环境变量
ENV DSH_HOME=/home/node/.dsh
ENV HOME=/workspace
ENV TZ=Asia/Shanghai

# 创建数据和挂载目录
RUN mkdir -p /home/node/.dsh /workspace && chown -R node:node /home/node/.dsh /workspace

USER node
WORKDIR /workspace
EXPOSE 3080

# 启动 dsh，监听所有网卡
CMD ["dsh", "web", "--host", "0.0.0.0"]
