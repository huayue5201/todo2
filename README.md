# 📘 todo2.nvim — 代码 ↔ TODO 双向链接系统

一个为工程师设计的 **代码 ↔ TODO 文件双向链接系统**。
它让任务“属于代码”，而不是散落在 TODO 文件里；让 TODO 文件成为代码的自然延伸。

核心理念：

- **代码是任务的来源**
- **TODO 文件是任务的管理界面**
- **两者保持实时同步**
- **所有 UI 渲染由事件驱动，不依赖 autocmd**
- **所有行号定位由上下文 + 增量追踪保证稳定**

---

## ✨ 功能特性

### 🔗 代码 ↔ TODO 双向链接
在代码中写：

```lua
-- TODO:ref:ab12cd
```

在 TODO 文件中自动生成：

```
- [ ] {#ab12cd} 新任务
```

两者始终保持同步：

- 内容同步
- 标签同步
- 状态同步
- 行号自动重定位
- 删除自动清理

---

### 🏷️ 多标签体系（可配置）
支持任意标签：

- TODO
- FIXME
- NOTE
- IDEA
- BUG
- 自定义标签

每个标签可配置：

- 图标
- 颜色
- 渲染样式
- 关键字（用于代码扫描）

---

### 🧭 智能跳转（代码 ↔ TODO）
- `gj`：智能跳转
- 自动识别当前行是否为代码标记
- 自动跳转到对应 TODO 行
- 支持从 TODO 跳回代码

---

### 🎨 代码侧渲染（事件驱动）
渲染内容包括：

- 图标
- 颜色
- 状态（完成/未完成/归档）
- 任务内容（来自 TODO 文件）

渲染由事件系统驱动：

- 不依赖 autocmd
- 不依赖手动刷新
- 不依赖 buffer 切换
- 任何状态变化都会自动更新

---

### ⚡ 智能 `<CR>`（不干扰默认行为）
在代码文件中：

- 当前行是 `TAG:ref:<id>` → 切换 TODO 状态
- 当前行不是任务标记 → 执行默认 `<CR>`

完全不污染默认行为。

---

### 📝 TODO 文件管理
支持：

- 创建 TODO 文件
- 删除 TODO 文件（自动清理孤立链接）
- 浮窗 / 分屏 / 编辑模式打开
- 项目级 TODO 文件选择器
- 自动保存（InsertLeave）

---

### 🧹 自动修复（autofix）
保存文件时自动执行：

- 代码标记扫描
- TODO 文件解析
- 链接同步（新增/更新/删除）
- 孤立链接清理
- 行号自动修复
- 上下文更新

所有修复均为 **无侵入、无闪烁、无卡顿**。

---

### 🧠 上下文定位（context-based locator）
每个链接都带有：

- 上下文窗口
- 结构路径（函数/方法/类）
- 指纹（window hash + struct hash）

用于：

- 行号重定位
- 文件移动后的自动恢复
- 上下文过期更新
- 自动重定位（BufEnter）

---

### 🪄 行号实时追踪（on_bytes）
通过 Neovim 的 `on_bytes`：

- 实时追踪插入/删除
- 自动更新所有受影响的行号
- 不依赖 parser
- 不依赖 verification
- 不依赖 autofix

这是 todo2 的“实时行号修复引擎”。

---

### 📦 可逆归档（Archive）
支持：

- 归档整棵任务树
- 自动创建归档区域
- 替换 `[ ]` / `[x]` → `[>]`
- 删除代码标记
- 保存快照（含上下文）
- 从快照恢复（unarchive）
- 恢复代码标记
- 恢复原始行号

归档是 **可逆的**，不是软删除。

---

### 🧹 孤立清理（dangling cleanup）
自动清理：

- 文件中已不存在的 TODO
- 文件中已不存在的代码标记
- 存储中的孤立链接
- 过期归档（默认 30 天）

---

## 🚀 安装

使用 lazy.nvim：

```lua
{
    "yourname/todo2.nvim",
    config = function()
        require("todo2").setup()
    end
}
```

---

## ⚙️ 配置示例

```lua
require("todo2").setup({
    render = {
        tags = {
            TODO = { icon = "", color = "yellow" },
            FIXME = { icon = "", color = "red" },
            NOTE = { icon = "", color = "blue" },
        },
    },
    auto_relocate = true,
    autofix = {
        on_save = true,
        show_progress = false,
    },
})
```

---

## ⌨️ 默认按键

### 全局

| 按键 | 功能 |
|------|------|
| `<leader>tda` | 创建代码 ↔ TODO 链接 |
| `gj` | 智能跳转（代码 ↔ TODO） |
| `<leader>tdq` | 显示所有双链（QuickFix） |
| `<leader>tdl` | 显示当前文件双链（LocList） |
| `<leader>tdr` | 修复当前 buffer 孤立标记 |
| `<leader>tdw` | 显示双链统计 |

### TODO 文件管理

| 按键 | 功能 |
|------|------|
| `<leader>tdf` | 浮窗打开 TODO 文件 |
| `<leader>tds` | 水平分割打开 |
| `<leader>tdv` | 垂直分割打开 |
| `<leader>tde` | 编辑模式打开 |
| `<leader>tdn` | 创建 TODO 文件 |
| `<leader>tdd` | 删除 TODO 文件 |

### TODO 文件内部 UI

| 按键 | 功能 |
|------|------|
| `q` | 关闭窗口 |
| `<C-r>` | 刷新 |
| `<CR>` | 切换任务状态 |
| `<C-CR>` | 插入模式切换状态 |
| `v + <CR>` | 批量切换状态 |
| `<leader>nt` | 新建任务 |
| `<leader>nT` | 新建子任务 |
| `<leader>ns` | 新建平级任务 |

---

## 🧠 工作流示例

### 1. 在代码中创建任务
按 `<leader>tda`：

1. 选择标签
2. 选择 TODO 文件
3. 插入代码标记
4. 自动跳转到 TODO 文件并创建任务

---

### 2. 在代码中切换任务状态
光标放在：

```
-- TODO:ref:ab12cd
```

按 `<CR>`：

- 切换 `[ ]` ↔ `[x]`
- 自动更新代码渲染
- 不跳转、不打断工作流

---

### 3. 删除 TODO 文件
按 `<leader>tdd`：

- 删除文件
- 清理 store
- 删除代码中的孤立标签
- 自动刷新渲染

---

## 🧩 架构概览

```
todo2/
  core/
    status.lua
    archive.lua
    parser.lua
    events.lua
  store/
    link/
      core.lua
      status.lua
      archive.lua
      query.lua
      line.lua
    index.lua
    context.lua
    locator.lua
    cleanup.lua
    verification.lua
    meta.lua
  render/
    scheduler.lua
    renderer.lua
  ui/
    todo_window.lua
    picker.lua
  manager/
    autocmd.lua
    commands.lua
```

特点：

- **事件驱动渲染**
- **上下文定位 + 增量追踪**
- **无软删除**
- **可逆归档**
- **自动修复（autofix）**
- **模块化、可扩展**

---

## 📄 许可证

MIT License
