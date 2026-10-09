# 使用官方的 Node.js 24 镜像（非 slim 版，自带编译工具链）
FROM node:24-trixie

# 设置 npm 国内镜像源
RUN npm config set registry https://registry.npmmirror.com

# 设置环境变量
ENV DSH_HOME=/home/node/.dsh
ENV HOME=/workspace
ENV TZ=Asia/Shanghai

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    git \
    curl \
    python3 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# 接收版本号参数
ARG DSH_VERSION=latest

# 核心步骤：使用 npm 完整安装 dsh，并允许编译原生模块
RUN npm install --global --omit=dev --no-audit --no-fund \
    --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
    "@deepseek-ai/dsh@${DSH_VERSION}"

# 创建数据和挂载目录
RUN mkdir -p /home/node/.dsh /workspace && chown -R node:node /home/node/.dsh /workspace

# 切换到非 root 用户
USER node
WORKDIR /workspace

# 暴露端口
EXPOSE 3080

# 启动 dsh，监听所有网卡
CMD ["dsh", "web", "--host", "0.0.0.0"]
