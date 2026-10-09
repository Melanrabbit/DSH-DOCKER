# ===== 第一阶段：构建阶段 =====
# 使用完整的 Node.js 22 镜像，自带编译工具链
FROM node:22-bookworm AS builder

# 设置 npm 国内镜像源，加速依赖下载
RUN npm config set registry https://registry.npmmirror.com

# 接收版本号参数
ARG DSH_VERSION=latest

# 全局安装官方 dsh，npm 会自动从源码编译 node-pty 等原生模块
RUN npm install -g @deepseek-ai/dsh@${DSH_VERSION}

# ===== 第二阶段：运行阶段 =====
# 使用精简版镜像，减小最终体积
FROM node:22-bookworm-slim

# 安装运行时可能需要的少量依赖（如 git）
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的全局 node_modules
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
# 复制 dsh 可执行文件链接
COPY --from=builder /usr/local/bin/dsh /usr/local/bin/dsh

# 设置环境变量
ENV DSH_HOME=/home/node/.dsh
ENV HOME=/workspace
ENV TZ=Asia/Shanghai

# 创建数据和挂载目录，并设置归属用户
RUN mkdir -p /home/node/.dsh /workspace && chown -R node:node /home/node/.dsh /workspace

# 切换到非 root 用户运行
USER node
WORKDIR /workspace
EXPOSE 3080

# 使用 dsh 命令启动，监听所有网卡
CMD ["dsh", "web", "--host", "0.0.0.0"]
