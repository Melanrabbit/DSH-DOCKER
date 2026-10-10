#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# dsh 容器入口脚本：按 PUID / PGID 调整运行身份后再启动 dsh
#
# 为什么需要它
#   镜像里的 node 用户是 uid/gid 1000，而 NAS 上的共享目录通常属于另一个 uid
#   —— 飞牛 fnOS 的用户目录是 1001，权限 0700（连父目录 /vol2/1001 都是 000）。
#   uid 对不上时，容器对这些挂载点连 opendir 都会 EACCES，挂载形同虚设，
#   报错是「只能读不能写」甚至「全部拒绝」。
#
#   这里在启动时把 node 用户的 uid/gid 改成 PUID/PGID，并把 DSH_HOME 与工作区
#   一并 chown 过去，然后用 gosu 降权启动 dsh。这样容器建出来的文件属主就是你
#   在 fnOS 里的那个用户，文件管理器里能正常查看/修改/删除。
#
# 用法（compose）
#   environment:
#     - PUID=1001        # stat -c %u <挂载的宿主机目录>
#     - PGID=1001        # stat -c %g <挂载的宿主机目录>
#
# 兼容性
#   * 不设 PUID/PGID 时默认 1000:1000，行为与旧镜像完全一致。
#   * 若用 compose 的 `user:` 指定了非 root 身份，本脚本不介入，原样启动
#     （那样没有权限改 uid/chown）。要改身份请用 PUID/PGID，不要用 user:。
#   * 想完全不降权（整容器跑 root）就把 entrypoint 覆盖成直接执行 dsh。
# ─────────────────────────────────────────────────────────────────────────────
set -eu

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# 非 root 启动：没有 CAP_CHOWN/CAP_SETUID，改不了身份，原样启动。
# 注意：以 root 启动时本脚本一定会降权到 node（其 uid = PUID）。
if [ "$(id -u)" != "0" ]; then
  exec "$@"
fi

CUR_UID="$(id -u node)"
CUR_GID="$(id -g node)"
TARGET_UID="${PUID:-$CUR_UID}"
TARGET_GID="${PGID:-$CUR_GID}"

# 只接受纯数字，避免把非法值喂给 usermod 后留下一半改一半没改的状态
case "$TARGET_UID" in
  "" | *[!0-9]*)
    log "PUID 必须是非负整数，收到：'$TARGET_UID'"
    exit 64
    ;;
esac
case "$TARGET_GID" in
  "" | *[!0-9]*)
    log "PGID 必须是非负整数，收到：'$TARGET_GID'"
    exit 64
    ;;
esac

# -o 表示允许与已有 uid/gid 重复，避免撞上镜像里的系统账号时直接失败
if [ "$TARGET_GID" != "$CUR_GID" ]; then
  groupmod -o -g "$TARGET_GID" node
  log "node 的 gid：$CUR_GID -> $TARGET_GID"
fi

if [ "$TARGET_UID" != "$CUR_UID" ]; then
  usermod -o -u "$TARGET_UID" node
  log "node 的 uid：$CUR_UID -> $TARGET_UID"
fi

# 数据卷里的文件属主可能还是上一次运行的 uid，不一致就整棵修正。
# 只在顶层属主不匹配时才递归，正常重启不会有额外开销。
for DIR in /home/node/.dsh /workspace; do
  [ -d "$DIR" ] || continue
  CUR_OWNER="$(stat -c '%u:%g' "$DIR")"
  if [ "$CUR_OWNER" != "$TARGET_UID:$TARGET_GID" ]; then
    log "修正属主：$DIR（$CUR_OWNER -> $TARGET_UID:$TARGET_GID）"
    chown -R "$TARGET_UID:$TARGET_GID" "$DIR"
  fi
done

log "以 node（$(id -u node):$(id -g node)）启动：$*"
exec gosu node "$@"
