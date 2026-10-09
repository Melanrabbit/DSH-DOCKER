# ===== 第一阶段：构建阶段 =====
FROM node:22-bookworm AS builder

# 设置 npm 国内镜像源
RUN npm config set registry https://registry.npmmirror.com

ARG DSH_VERSION=latest

# 全局安装官方 dsh，npm 会自动编译原生模块
RUN npm install -g @deepseek-ai/dsh@${DSH_VERSION}

# ===== 第二阶段：运行阶段 =====
FROM node:22-bookworm-slim

# 安装运行时需要的少量工具
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的全局 node_modules
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules

# 手动创建 dsh 启动脚本，直接从包入口加载
RUN printf '#!/bin/sh\nexec node /usr/local/lib/node_modules/@deepseek-ai/dsh/bin/dsh.js "$@"\n' > /usr/local/bin/dsh && chmod +x /usr/local/bin/dsh

# 设置环境变量
ENV DSH_HOME=/home/node/.dsh
ENV HOME=/workspace
ENV TZ=Asia/Shanghai

# 创建数据和挂载目录
RUN mkdir -p /home/node/.dsh /workspace && chown -R node:node /home/node/.dsh /workspace

USER node
WORKDIR /workspace
EXPOSE 3080

CMD ["dsh", "web", "--host", "0.0.0.0"]
