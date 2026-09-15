# Pulse Agent

[Pulse 探针面板](https://github.com/gokele/pulse-releases)的采集端。装在你要监控的每台机器上，向面板上报状态。

一个静态二进制，不依赖运行时、不需要容器、没有配置文件。

---

## 它做什么

- **上报机器状态** —— CPU、内存、交换分区、磁盘、实时网速、累计流量、系统负载、进程数、TCP/UDP 连接数、开机时长
- **执行 Ping 探测** —— 面板上配好的 ICMP / TCP / HTTP 任务，由 Agent 去跑并把延迟和丢包报回来

默认每 3 秒上报一次，节奏在面板后台调，改完下一个周期生效。

Ping 任务也是面板下发的：**Agent 这一端零配置**，加任务、改目标、改间隔都在后台点，不用登机器。

---

## 安装

先在面板后台新建节点，点它的「安装命令」，把给出的命令粘到目标机器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/gokele/pulse-agnes/main/install.sh \
  | sudo bash -s -- --server <面板地址> --id <节点ID> --token <该节点的密钥>
```

卸载：

```bash
curl -fsSL https://raw.githubusercontent.com/gokele/pulse-agnes/main/install.sh \
  | sudo bash -s -- --uninstall
```

脚本会自己判断架构，从本仓库的 [Releases](../../releases) 下载对应的二进制，**比对 `checksums.txt` 里的 SHA-256**，对不上就放弃安装。装成 systemd 服务，开机自启。

机器访问不了 GitHub 的话，可以用 `--binary-url` 指定一个可达的镜像地址（此时会跳过校验和比对）。

看日志：

```bash
journalctl -u pulse-agent -f
```

### 手动装

不想用脚本也行。从 [Releases](../../releases) 下载对应架构的二进制，给上执行权限，用环境变量或命令行参数告诉它面板地址和密钥即可：

```bash
curl -fsSL -O https://github.com/gokele/pulse-agnes/releases/latest/download/pulse-agent-linux-amd64
curl -fsSL -O https://github.com/gokele/pulse-agnes/releases/latest/download/checksums.txt
sha256sum -c checksums.txt --ignore-missing

chmod +x pulse-agent-linux-amd64   # ← 必须。GitHub 附件不保留执行位，下下来是 644
./pulse-agent-linux-amd64 --server https://面板地址 --id 节点ID --token 节点密钥
```

ICMP 需要 `CAP_NET_RAW`。用脚本装的已经配好；手动跑的话要么用 root，要么给二进制加上这项能力：

```bash
sudo setcap cap_net_raw+ep ./pulse-agent-linux-amd64
```

---

## 支持的平台

| | |
|---|---|
| 系统 | Linux |
| 架构 | x86_64（amd64）、arm64、armv7 |
| 内存占用 | 二十几 MB |
| 二进制大小 | 约 7 MB |

暂不发布 Windows / macOS 版本。

---

## 安全

- **每台机器一把独立密钥**，不是全局 token。密钥在面板后台创建节点时生成，只对这一个节点有效；在后台重新生成之后，机器上的 Agent 需要用新命令重装。
- **没在后台建过的节点，上报会被拒绝**，不存在自动注册。
- **以非 root 的专用账号运行**，systemd 单元只保留 ICMP 需要的那一项权限（`CAP_NET_RAW`），文件系统只读。
- **采集全部走 `/proc`**，不执行任何外部命令。
- 只对面板发起出站请求，**不监听任何端口**。

---

## 自动更新

面板后台可以开启（默认关闭）。开启后，版本落后于本仓库最新 Release 的 Agent 会自行更新：

1. 从本仓库下载对应架构的新二进制
2. **校验 SHA-256**，和 Release 里的 `checksums.txt` 比对
3. **试运行**新二进制，确认它能正常启动并报出预期的版本号
4. 三步全过才替换自己并重启；任何一步不通过，保留原版本继续跑

不开启的话，面板会在节点列表里把版本落后的 Agent 标出来，你自己决定什么时候重装。

---

## 已经装好的怎么更新

**开了自动更新**（面板「站点设置 → Agent 自动更新」）：什么都不用做。Agent 在下一个上报周期就会收到通知，自己下载、校验、替换、重启。

**没开自动更新**：把安装命令原样再跑一遍就是升级 —— 换掉二进制并重启服务，节点 ID 与密钥照旧，历史数据不受影响。

```bash
curl -fsSL https://raw.githubusercontent.com/gokele/pulse-agnes/main/install.sh \
  | sudo bash -s -- --server <面板地址> --id <节点ID> --token <该节点的密钥>
```

命令在面板后台每个节点的「安装命令」里都能直接复制。升级过程只有一次重启的间隔，面板上该节点会短暂显示离线。

---

## 版本

**Agent 和面板各自发版**，版本号不需要一致。

面板升级不会把各台机器上的 Agent 一起换掉 —— 只有 Agent 真的出了新版本，节点才会被提示或自动更新。所以你看到面板是一个版本号、Agent 是另一个，这是正常的。

---

## 下载

所有版本在 [Releases](../../releases)。每个版本包含：

- `pulse-agent-linux-amd64`
- `pulse-agent-linux-arm64`
- `pulse-agent-linux-armv7`
- `checksums.txt` —— 上述文件的 SHA-256

下载后建议核对一下：

```bash
sha256sum -c checksums.txt --ignore-missing
```

面板本身不分发任何文件，只负责接收上报。
