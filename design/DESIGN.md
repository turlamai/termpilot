# TermPilot DESIGN.md — 视觉与交互契约（单一真源）

原型（`design/prototype/`）与实现（`apps/desktop/`）都遵循本文件；改视觉先改这里，再同步实现。
Tokens 提取自 `apps/desktop/src/styles.css` 现行值（1:1 同名），保证原型 → React 实现零翻译成本；
终端前景色为原型推导值，xterm 主题真源在 `packages/core/src/themes.ts`（六主题包）。

## Brief（2026-11-11）

- **现状**：非从零设计。v0.8.0 development preview 已交付可用的产品核心——六种连接类型、主机/密钥/转发/片段管理、⌘K 起草 + 解释选中 + 脱敏全部 shipped，且 `styles.css` 顶部已有成文的设计系统注释（4pt 网格、11/13/15/18 字阶、activity < sidebar < surface < raised 分层、单 accent + 单 danger）。本契约的任务是把既有体系显式化为契约，并按 HIG 补齐状态可见性与对比度护栏。
- **目标**：终端输出是唯一主角，chrome 极简；「AI 提议、用户执行、发送先脱敏」的产品治理在界面上清晰可感；三平台交互逻辑一致（机制随平台惯例）。
- **原型范围**（6 屏 × 亮/暗）：① 工作区（英雄屏：主机侧栏 + 标签 + 分屏终端 + AI 面板解释态）② ⌘K 命令面板（空态/思考中/草稿就绪三态）③ 主机管理 + 新建主机表单 ④ SFTP（上传进行态 + 拖放态 + 完成通知）⑤ 设置（终端主题/BYOK/外观/日志空态）⑥ 快捷键速查（⌘/）。
- **Exit 条件**：6 屏关键状态齐（含空态/进行态/断开态）+ 交互逻辑定稿 + HIG 清单全过 + 用户评审通过。
- **不在范围**：新功能、路由/契约变更（不动 `glaze-schema.json`）、会话摘要/广播/SFTP 目录树扩展（M2 项）、商业/定价 UI、新配色体系。

## 设计原则（HIG 内核 × 本产品）

- **终端至上**：终端输出是每个 pane 的主角；活动栏/侧栏/AI 面板一律 text-dim 退后，pane 聚焦与否只靠文字亮度区分，不加装饰性 chrome。
- **AI 永不静默**：生成有「思考中…」进行态；插入终端必须显式点击；脱敏预览先于发送且给出计数；Esc 永远丢弃；面板永不自动打开（⌘B 显式唤起）。
- **密钥零回显**：API Key 只显示 `__SAVED__` 哨兵与「已保存（输入以更换）」；脱敏预览展示「将离开本机的内容」（占位符），不是原始输出。
- **键盘一等公民**：⌘K / ⌘B / ⌘N / ⌘/ 全部有可见入口与登记；焦点环是设计的 2px accent 轮廓，不是 UA 默认。
- **反馈及时**：延迟徽标、断开态 + 重连 + 失败证据导出、上传进度条、测试连接成功/失败当场可感；toast 底部居中不阻塞。
- **层级克制**：activity < sidebar < surface < raised 四层（既有结构，每层职责明确）；accent 只给交互与状态。

## Tokens（与实现 1:1，提取自 apps/desktop/src/styles.css）

| Token | Dark（默认） | Light | 用途 |
|---|---|---|---|
| `--bg` | `#242629` | `#f2f3f4` | 主画布 |
| `--bg-raised` | `#2c2e32` | `#ffffff` | 控件/浮层/modal |
| `--bg-sidebar` | `#1f2124` | `#e9eaea` | 侧栏/标签条/AI 面板 |
| `--bg-activity` | `#191b1d` | `#212325` | 活动栏（两态皆深） |
| `--text` | `#e3e5e7` | `#242628` | 主文字 |
| `--text-dim` | `#9da1a6` | `#6e7175` | 次级文字 |
| `--accent` | `#5c8fae` | `#38678a` | 选中/焦点环/主按钮/进行态 |
| `--accent-hover` | `#6da0bd` | `#2f5a7b` | accent 悬停 |
| `--border` | `#3a3d41` | `#d4d6d8` | 分隔 |
| `--error` | `#d46a6a` | `#b04a4a` | 危险/失败/断开 |
| `--terminal-bg` | `#141728` | `#f7f8f9` | 终端区（唯一大面积色块） |

- **状态色（lat-badge 既有值 + 亮态推导）**：ok `#4caf78`（亮态 `#2e7d4f`）· warn `#d0a83c`（亮态 `#9a7a20`）· bad 用 `--error`；徽标底取同色 12–14% 透明。亮态加深为原型推导——实现中 lat-badge 未分亮暗，本契约要求补齐。
- **终端前景（原型推导）**：fg / dim / ok / path / err 两态各一套，按 pilot-dark、pilot-light 底色的可读性取值；选中底 = accent 22–35% 透明。
- **字体**：UI = `system-ui, -apple-system, "Segoe UI", Roboto, "PingFang SC", "Microsoft YaHei"`；等宽 = `ui-monospace, Menlo, Consolas, monospace`（终端、地址、命令、kbd 专用）。字阶：caption 11/600 · body 13/400 · title 15/600 · large 18。
- **间距节奏**：4pt 网格 4/8/12/16/20/24。**圆角**：控件 6 · 卡片 8–10 · modal 12。**控件高** 30px。**动效** 120–180ms ease，不过度。

## 组件词汇

`ActivityBar`（7 视图：主机/SFTP/转发/片段/密钥/已知主机/设置）· `Sidebar`（视图专属列表 + 搜索 + New… 动作 + `lat-badge`）· `TabBar`（kind 字符芯片 + 标题 + ⌘K 入口）· `TerminalPane`（聚焦/断开态 + 搜索 + 重连 + 导出失败证据）· `SplitView`（5px 分隔条，hover 变 accent）· `CommandPalette`（⌘K：输入 + 脱敏预览 + 草稿卡 + 插入终端/复制/存为片段/丢弃）· `AiPanel`（解释选中/会话摘要，永不自动打开）· `RedactPreview`（脱敏计数 + 占位明细）· `StatusBar`（原型新增建议：会话连接反馈 + 键盘提示条）· `ShortcutsOverlay`（⌘/ 唤起）· `ConfirmBox`（应用内确认，替代原生 confirm）· `Toast`（底部居中，不阻塞）· `UpdateBanner`（仅提醒，可关闭）。

## 不变式

1. `accent` 只用于：当前选中、焦点环、进行态、主按钮；大面积色块只属于终端区（`terminal-bg`），chrome 层禁止色块与阴影堆叠表达层级。
2. AI 提议，用户执行：任何 AI 产物进入终端前必须经过显式插入动作；发送前必须显示脱敏预览；Esc 丢弃一切草稿。
3. 亮暗成对：dark 是默认工具皮肤，light 镜像同结构；活动栏两态皆深，图标对比恒定；不存在只有单态的界面。
4. 键盘可达：每个高频动作有快捷键且登记在 ShortcutsOverlay；破坏性操作（删主机/删密钥/移除 known_hosts 条目）一律走应用内 ConfirmBox。
5. 敏感数据零回显：API Key 永远是 `__SAVED__` 哨兵；私钥内容、脱敏前的终端输出不得出现在任何面板中。


## 平台渲染差异（glaze 线）

同一 HTML/CSS 三平台共享，交互天然一致；差异仅在 WebView 渲染微差与平台窗口 chrome
（由宿主提供）。三渲染器（WKWebView / WebView2 / WebKitGTK）截图对照纳入平台验收。
