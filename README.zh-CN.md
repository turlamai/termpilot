# TermPilot

**中文** · [English](README.md)

AI 原生的 SSH 客户端，覆盖 macOS、Windows 与 Linux。

[![CI](https://github.com/turlamai/termpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/termpilot/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/turlamai/termpilot)](https://github.com/turlamai/termpilot/releases) [![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

> 📖 **产品主页**：[termpilot.jrtx.site](https://termpilot.jrtx.site)

TermPilot 是本地优先的桌面 SSH 客户端，功能对齐 Termius 并超出：六种连接类型（SSH、本地终端、telnet、mosh、串口、SFTP）、主机管理（分组/标签）、基于系统 OpenSSH 的真实终端会话（agent 认证、ProxyJump、known_hosts 开箱即用）、Snippets、端口转发，以及 AI 助手——生成命令、解释输出，用你自己的模型 API key，发送前先脱敏。

**Human-first. Agent-native. Local by design.**

## 从这里开始

TermPilot 处于早期开发阶段（v0.6.0 开发预览）。架构已经验证——Racket 引擎经 GLZ1 把真实 PTY 会话流式推送给 xterm.js 前端——仓库当前交付的是可工作的产品核心：六种连接类型全量、主机/密钥/转发/Snippet 管理、带脱敏的 AI 面板，以及下文的 agent 面。

- 产品规格（功能矩阵 + 界面布局）：[docs/PRODUCT-SPEC.md](docs/PRODUCT-SPEC.md)
- 架构：[ARCHITECTURE.md](ARCHITECTURE.md)
- 开发约定：[AGENTS.md](AGENTS.md)
- 定价意向：[PRICING.zh-CN.md](PRICING.zh-CN.md) · [English](PRICING.md)

## 工作方式

```
apps/desktop   Vite + React + TypeScript 前端，xterm.js 终端
backend/       Racket CS 引擎，Glaze 承载（GLZ1 类型化 RPC + 流）
  pty/         伪终端：script(1) forkpty 桥（Unix）、ConPTY（Windows）
  ssh.rkt      OpenSSH sidecar 编排——传输层接缝
  ai/          BYOK 预设、脱敏、Switchboard LLM 调用
  store.rkt    主机 / Snippets（SQLite）
packages/core  共享 TypeScript 桥（类型化 RPC + 流式客户端）
```

- **真终端**——每个会话一个伪终端，agent 密码提示、TUI 程序、口令输入与原生终端行为一致。
- **系统 OpenSSH 作传输**——agent 转发、ProxyJump、config 兼容、新算法跟进全部免费获得。引擎层是干净接缝：将来可换进程内 SSH 栈而不动会话、存储与 UI。
- **AI 只提议、绝不执行**——命令草稿与输出解释只有你确认后才进终端。每条 AI 发送路径都先脱敏（私钥、token、凭据），脱敏预览展示将离开本机的确切内容。
- **你的 key、你的 provider**——BYOK 预设覆盖 GLM、DeepSeek、Qwen、Kimi、豆包、SiliconFlow、OpenAI、Anthropic 与本地 Ollama。key 存于应用数据目录的 0600 设置文件，由 Racket 引擎持有，永不进入 WebView。

## Agent 面

Agent-native 意味着编码 agent 与 UI 获得同样的真相：一个确定性 CLI 和一个 MCP 服务器（stdio JSON-RPC）——都走同一个本地存储，不调 `run` 就没有网络，退出码从不说谎，`--json` 出 JSON：

```bash
racket cli.rkt hosts --json                      # 主机档案
racket cli.rkt run web-1 "systemctl is-active nginx"   # 一次性命令，走系统 ssh
                                                 #   加 --timeout N 限时（超时退出码 124）
racket cli.rkt logs                              # 会话日志文件（应用内按会话开启）
racket cli.rkt evidence web-1-0000000001.log     # 有界尾部 + sha1——可引用的失败证据
echo "<输出>" | racket cli.rkt summarize -       # 交接摘要（需 BYOK key）
racket mcp.rkt                                   # MCP：list_hosts、run_command、list_snippets、
                                                 #     list_logs、failure_evidence、session_summary
```

evidence 与 summarize 是 agent 的反馈闭环：`run` 失败后，`evidence` 给出有界、带指纹的转储供 agent 引用；`summarize` 把长会话压缩成交接文本。两者都基于应用可选开启后落盘的会话日志工作。

## 开发

```bash
pnpm install
pnpm build          # 前端 → apps/desktop/dist
raco glaze dev      # 原生窗口（或 TERMPILOT_TRANSPORT=http）
raco test backend/  # 单测 + PTY 冒烟
raco glaze schema check
```

## 许可

[AGPL-3.0](LICENSE)——源码保持开放与传染。官方分发、更新与服务是另一重权利；商业模型意向见 [PRICING.zh-CN.md](PRICING.zh-CN.md)。
