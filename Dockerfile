# 使用官方 Node.js 22 精简版作为基础镜像
FROM node:22-bookworm-slim

# 设置 dsh 运行所需的环境变量，与 runzhliu 镜像保持一致，方便数据迁移
ENV DSH_HOME=/home/node/.dsh
ENV HOME=/workspace
ENV TZ=Asia/Shanghai

# 安装必要的系统工具（git 等，dsh 插件可能会用到）
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

# 全局安装官方最新的 dsh 核心
RUN npm install -g @deepseek-ai/dsh

# 创建数据和挂载目录，并设置归属用户
RUN mkdir -p /home/node/.dsh /workspace && chown -R node:node /home/node/.dsh /workspace

# 切换到非 root 用户运行（安全加固）
USER node

# 设置工作目录
WORKDIR /workspace

# 暴露 dsh 默认端口
EXPOSE 3080

# 启动 dsh，通过 --host 0.0.0.0 允许容器外访问
CMD ["npx", "@deepseek-ai/dsh", "web", "--host", "0.0.0.0"]