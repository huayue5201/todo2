# 📘 todo2.nvim — 代码 ↔ TODO 双链管理系统

一个为开发者设计的 **代码 ↔ TODO 文件双向链接系统**。
它让你在代码中创建任务引用、在 TODO 文件中管理任务，并保持两者自动同步。

专注于：

- 🧭 **双向跳转**（代码 ↔ TODO）
- 🏷️ **多标签体系**（TODO / FIXME / NOTE / IDEA / BUG / 自定义）
- 🔗 **智能链接管理**（自动行号重定位、孤立清理）
- 📝 **任务文件管理**（创建、删除、选择、浮窗/分屏打开）
- 🎨 **代码侧渲染**（图标、颜色、状态同步）
- ⚡ **零侵入工作流**（智能 `<CR>` 切换状态，不影响默认行为）

---

# ✨ 功能特性

## 🔗 代码 ↔ TODO 双链
在代码中插入：

```
-- TODO:ref:ab12cd
```

在 TODO 文件中自动生成：

```
- [ ] {#ab12cd} 新任务
```

两者保持同步。

---

## 🏷️ 多标签体系
支持任意标签：

- TODO
- FIXME
- NOTE
- IDEA
- BUG
- 你自定义的任何标签

每个标签可配置：

- 图标
- 颜色
- 渲染样式

---

## 🧭 智能跳转
- `gj`：在代码 ↔ TODO 文件之间动态跳转
- 自动识别当前行是否为标签行
- 自动定位到对应 TODO 行

---

## 🎨 代码侧渲染
在代码中渲染：

- 图标
- 颜色
- 状态（完成/未完成）
- 任务内容（来自 TODO 文件）

渲染自动更新，无需手动刷新。

---

## ⚡ 智能 `<CR>`（全局但不干扰默认行为）
在代码文件中：

- 当前行是 `TAG:ref:<id>` → 切换 TODO 状态
- 当前行不是标签行 → 执行 Neovim 默认 `<CR>`

完全不污染默认行为。

---

## 📝 TODO 文件管理
支持：

- 创建 TODO 文件（带命名输入框）
- 删除 TODO 文件（自动清理孤立标签）
- 浮窗打开
- 分屏打开
- 编辑模式打开
- 项目级 TODO 文件选择器

---

## 🧹 孤立标记自动清理
当：

- 删除 TODO 文件
- 删除代码标记
- 手动触发清理

插件会自动：

- 删除 store 中的无效链接
- 删除代码中的孤立标签行
- 刷新渲染

---

# 🚀 安装

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

# ⚙️ 配置

```lua
require("todo2").setup({
    render = {
        tags = {
            TODO = { icon = "", color = "yellow" },
            FIXME = { icon = "", color = "red" },
            NOTE = { icon = "", color = "blue" },
        },
    },
})
```

---

# ⌨️ 默认按键

## 全局按键

| 按键 | 功能 |
|------|------|
| `<leader>tda` | 创建代码 ↔ TODO 链接 |
| `gj` | 动态跳转（代码 ↔ TODO） |
| `<leader>tdq` | 显示所有双链（QuickFix） |
| `<leader>tdl` | 显示当前文件双链（LocList） |
| `<leader>tdr` | 修复当前 buffer 孤立标记 |
| `<leader>tdw` | 显示双链统计 |

## TODO 文件管理

| 按键 | 功能 |
|------|------|
| `<leader>tdf` | 浮窗打开 TODO 文件 |
| `<leader>tds` | 水平分割打开 |
| `<leader>tdv` | 垂直分割打开 |
| `<leader>tde` | 编辑模式打开 |
| `<leader>tdn` | 创建 TODO 文件 |
| `<leader>tdd` | 删除 TODO 文件 |

## TODO 文件内部 UI

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

# 🧠 工作流示例

## 1. 在代码中创建任务
按：

```
<leader>tda
```

选择：

1. 标签（TODO / FIXME / NOTE…）
2. TODO 文件（或新建文件）
3. 插入代码标记
4. 自动跳转到 TODO 文件并创建任务

---

## 2. 在代码中切换任务状态
光标放在：

```
-- TODO:ref:ab12cd
```

按 `<CR>`：

- 不跳转
- 不打断工作流
- TODO 文件自动切换 `[ ]` ↔ `[x]`
- 代码渲染自动更新

---

## 3. 删除 TODO 文件
按：

```
<leader>tdd
```

插件会自动：

- 删除文件
- 清理 store
- 删除代码中的孤立标签
- 刷新渲染

---

# 🧩 扩展性

todo2.nvim 采用模块化架构：

```
todo2/
  link/
  ui/
  store/
  render/
  manager/
```

你可以轻松扩展：

- 自定义标签体系
- 自定义渲染器
- 自定义 UI
- 自定义存储结构

---

# 🛠️ 开发者 API（可选）

```lua
local store = require("todo2.store")
local link = require("todo2.task")
local ui = require("todo2.ui")
local manager = require("todo2.manager")
```

---

# 📄 许可证

MIT License

---
