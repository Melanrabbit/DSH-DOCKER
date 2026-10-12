# DSH-DOCKER
服务器自动化DSH服务

镜像：`ghcr.io/melanrabbit/dsh-docker:latest`（GitHub Actions 每天 03:00 北京时间自动跟随 npm 上的 dsh 版本重建）

---

## 挂载宿主机目录后没权限？用 PUID / PGID

镜像里的 `node` 用户是 **uid/gid 1000**，而 NAS 上的共享目录通常属于别的用户
（飞牛 fnOS 是 **1001**，权限 `0700`，连父目录 `/vol2/1001` 都是 `d---------`）。
uid 对不上时，容器对这些挂载点**连目录都进不去** —— 报错看着像「只能读、不能写」，
其实读写全被拒。

先查目录属主：

```bash
stat -c '%u:%g' /vol2/1001/DOCUMENTS
# 1001:1001
```

再把这两个数字填进 compose 的 `PUID` / `PGID`：

```yaml
services:
  dsh:
    image: ghcr.io/melanrabbit/dsh-docker:latest
    container_name: deepseek-harness
    restart: unless-stopped
    ports:
      - "3080:3080"
    volumes:
      - dsh-home:/home/node/.dsh
      - dsh-workspace:/workspace
      - /vol1/1001/APPDATA:/APPDATA:ro
      - /vol2/1001/DOCUMENTS:/DOCUMENTS
      - /vol2/1001/LIBRARY:/LIBRARY:ro
      - /vol3/1001/TFR:/TFR
    environment:
      - PUID=1001
      - PGID=1001
      - TZ=Asia/Shanghai
      - DSH_TRUSTED_HOSTS=192.168.110.110

volumes:
  dsh-home:
  dsh-workspace:
```

启动后在会话里跑 `id`，应该是 `uid=1001`；容器在共享目录里建的文件属主就是你本人，
fnOS 文件管理器里能正常查看 / 修改 / 删除。

### 几点说明

| 事项 | 说明 |
| --- | --- |
| **只读挂载** | 想只读就在那一行末尾加 `:ro`（如 `- /vol2/1001/LIBRARY:/LIBRARY:ro`）。这和 UID 无关，随时可改 |
| **默认值** | 不设 `PUID`/`PGID` 就是 `1000:1000`，行为与旧镜像完全一致 |
| **两个数据卷** | 入口脚本会把 `/home/node/.dsh` 和 `/workspace` 的属主改成 `PUID:PGID`。只在顶层属主不一致时才递归 chown，正常重启没有额外开销<br>⚠️ 如果你把 `/workspace` 直接绑到宿主机目录，**那个目录会被 chown** |
| **别用 `user:`** | compose 的 `user:` 会让容器以非 root 启动，入口脚本就没权限 usermod/chown，`PUID`/`PGID` 会静默失效。要改身份**只用 `PUID`/`PGID`** |
| **想整容器跑 root** | 覆盖 entrypoint：`entrypoint: ["dsh", "web", "--patch", "/etc/dsh/webserver.patch.yml", "--no-open"]`。但这样建出来的文件属主是 root，fnOS 里改不动，不推荐 |
| **不需要 `SHELL`** | 入口脚本走 usermod，容器内存在 uid=1001 的 passwd 条目，所以 `os.userInfo()` 不会抛异常（`dsh-subprocess-local` 里那处未加保护的调用是安全的） |

---

## 为什么老是要贴那个 `?token=`

dsh 的浏览器认证分两层，搞清楚就不烦了：

| | 是什么 | 有效多久 |
| --- | --- | --- |
| **启动 token** | 进程内随机生成，启动日志里那条 `http://…/?token=…` | **只用于首次登录**，每次重启都换（换是正常的） |
| **登录 cookie** | 用 `?token=` 换来的 `dsh-auth-…` cookie，HttpOnly，签名密钥持久化在 `DSH_HOME/.credentials.yaml` | 上游默认 **30 天**，本镜像默认改成 **365 天** |

所以：

- **重启容器不需要重新贴 token**（密钥在卷里，cookie 依然有效）—— 如果你每次都要重贴，八成是下面第 2 条。
- **cookie 是按 `host:port` 绑定并命名的**（`cookieName = dsh-auth-<sha256(authority)>`，这个 authority 还写进了签名载荷）。所以在 `192.168.110.110:3080`、`localhost:3080`、反代域名/端口之间来回换，每次都等于换了一份 cookie，就得重贴 token。**固定收藏一个地址**。
- 有效期到了要重贴一次，想更久就调大（单位：天）：

```yaml
    environment:
      - DSH_COOKIE_MAX_AGE_DAYS=3650     # 10 年，基本等于不用再贴
```

> ⚠️ 这个 token 是本镜像的**安全底线**：dsh 能执行任意命令、读写你挂进来的目录，拦截就靠它。别为了省事把端口暴露到公网，也别去绕开它。

---

## 镜像更新后，我这边怎么知道 / 怎么更新

**Docker 不会自动发现 `latest` 变了** —— `latest` 只是个标签名，本地不 `docker pull` 就一直是旧的那份。

现行流程：GitHub Actions 每天 03:00（北京时间）自动构建并推送 `latest` + `:<dsh版本>`。要更新就：

1. 在飞牛 Docker 界面里**重新拉取** `ghcr.io/melanrabbit/dsh-docker:latest`，然后**重建容器**；
2. 或者命令行 `docker compose pull && docker compose up -d`。

什么时候值得更新：

| 信号 | 说明 |
| --- | --- |
| `:<dsh版本>` 标签变了 | dsh 上游发新版了，通常值得跟 |
| 仓库有新 commit | 镜像自身的修复（比如这次的 PUID/PGID），**`latest` 会变但版本号不变**，光看版本号看不出来 |
| 仅仅「Actions 又跑了一次」 | **不代表有变化**。定时任务每天都构建，即使代码和 dsh 版本都没动 |

想省事可以在 NAS 上跑一个 [Watchtower](https://github.com/containrrr/watchtower)，定时检查并自动 pull + 重建带指定 label 的容器。代价是镜像一旦有问题你也不知道，建议配合仓库的 Actions 页面一起看。

---

## 这个镜像修了什么

1. **断链的 `dsh` 命令** —— 上游软链指向不存在的 `bin/dsh.js`，会让容器陷入重启循环（`Cannot find module '/workspace/dsh'`）。改为从 `package.json` 的 `bin` 字段解析真实入口，并在构建期校验。
2. **设置页不可用 / 白屏** —— 上游按 `ctx.remote.$host.isLoopback` 决定设置持久化，用局域网 IP 访问时退化成浏览器内存态。这里对齐飞牛 fnOS 打包版的做法，固定为 `"host"`。
3. **`--host 0.0.0.0` 被拒 + 桥接网络下 `/api` 403** —— 监听地址与可信 Host 改由 `--patch` 覆盖层提供（`DSH_TRUSTED_HOSTS`）。
4. **明文 http 下 `crypto.randomUUID` 缺失** —— 注入兼容代码，修掉「设置 → 账户」卡片导致的设置面板白屏。
5. **运行身份** —— `PUID`/`PGID` 支持，见上一节。

另外镜像内预装了 `pnpm`（GUI 的「添加插件」依赖它）以及常见 CLI 工具（git / jq / rsync / unzip / openssh-client 等）。
