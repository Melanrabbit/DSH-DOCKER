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

## 这个镜像修了什么

1. **断链的 `dsh` 命令** —— 上游软链指向不存在的 `bin/dsh.js`，会让容器陷入重启循环（`Cannot find module '/workspace/dsh'`）。改为从 `package.json` 的 `bin` 字段解析真实入口，并在构建期校验。
2. **设置页不可用 / 白屏** —— 上游按 `ctx.remote.$host.isLoopback` 决定设置持久化，用局域网 IP 访问时退化成浏览器内存态。这里对齐飞牛 fnOS 打包版的做法，固定为 `"host"`。
3. **`--host 0.0.0.0` 被拒 + 桥接网络下 `/api` 403** —— 监听地址与可信 Host 改由 `--patch` 覆盖层提供（`DSH_TRUSTED_HOSTS`）。
4. **明文 http 下 `crypto.randomUUID` 缺失** —— 注入兼容代码，修掉「设置 → 账户」卡片导致的设置面板白屏。
5. **运行身份** —— `PUID`/`PGID` 支持，见上一节。

另外镜像内预装了 `pnpm`（GUI 的「添加插件」依赖它）以及常见 CLI 工具（git / jq / rsync / unzip / openssh-client 等）。
