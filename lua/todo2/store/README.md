# Todo2 存储模块 API 文档

## 模块概述

`todo2.store` 模块提供了 TODO 与代码双向链接的存储管理系统，支持基本的状态管理、文件索引和数据清理功能。

## 基础 API

### 1. 初始化

#### `setup()`
初始化存储模块。

**返回值**: `table` - 存储模块实例

**示例**:
```lua
local store = require("todo2.store")
store.setup()
```

### 2. 路径处理

#### `_normalize_path(path)`
规范化文件路径。

**参数**:
- `path` (`string`): 原始文件路径

**返回值**: `string` - 规范化后的路径

**示例**:
```lua
local norm_path = store._normalize_path("./test.lua")
```

### 3. 上下文管理

#### `build_context(prev, curr, next)`
构建上下文指纹。

**参数**:
- `prev` (`string`): 上一行内容
- `curr` (`string`): 当前行内容
- `next` (`string`): 下一行内容

**返回值**: `table` - 上下文对象

**示例**:
```lua
local ctx = store.build_context("function test()", "  print('hello')", "end")
```

#### `context_match(old_ctx, new_ctx)`
匹配两个上下文。

**参数**:
- `old_ctx` (`table`): 旧上下文
- `new_ctx` (`table`): 新上下文

**返回值**: `boolean` - 是否匹配

**示例**:
```lua
local is_match = store.context_match(old_ctx, new_ctx)
```

## 链接管理 API

### 4. TODO 链接操作

#### `add_todo_link(id, data)`
添加 TODO 链接。

**参数**:
- `id` (`string`): 链接唯一标识符
- `data` (`table`): 链接数据，包含以下字段：
  - `path` (`string`): 文件路径（必需）
  - `line` (`number`): 行号（必需）
  - `content` (`string`|`nil`): 内容
  - `status` (`string`|`nil`): 状态（normal/urgent/waiting/completed）
  - `created_at` (`number`|`nil`): 创建时间戳
  - `context` (`table`|`nil`): 上下文

**返回值**: `boolean` - 是否成功

**示例**:
```lua
store.add_todo_link("todo_001", {
  path = "src/main.lua",
  line = 10,
  content = "实现用户登录功能",
  status = "urgent"
})
```

#### `get_todo_link(id, opts)`
获取 TODO 链接。

**参数**:
- `id` (`string`): 链接ID
- `opts` (`table`|`nil`): 选项
  - `force_relocate` (`boolean`|`nil`): 是否强制重定位

**返回值**: `table`|`nil` - 链接数据

**示例**:
```lua
local todo = store.get_todo_link("todo_001")
```

#### `delete_todo_link(id)`
删除 TODO 链接。

**参数**:
- `id` (`string`): 链接ID

**示例**:
```lua
store.delete_todo_link("todo_001")
```

### 5. 代码链接操作

#### `add_code_link(id, data)`
添加代码链接。

**参数**:
- `id` (`string`): 链接唯一标识符
- `data` (`table`): 链接数据，格式同 `add_todo_link`

**返回值**: `boolean` - 是否成功

**示例**:
```lua
store.add_code_link("code_001", {
  path = "src/main.lua",
  line = 15,
  content = "用户登录实现",
  status = "completed"
})
```

#### `get_code_link(id, opts)`
获取代码链接。

**参数**:
- `id` (`string`): 链接ID
- `opts` (`table`|`nil`): 选项（同 `get_todo_link`）

**返回值**: `table`|`nil` - 链接数据

**示例**:
```lua
local code = store.get_code_link("code_001")
```

#### `delete_code_link(id)`
删除代码链接。

**参数**:
- `id` (`string`): 链接ID

**示例**:
```lua
store.delete_code_link("code_001")
```

### 6. 批量链接操作

#### `get_all_todo_links()`
获取所有 TODO 链接。

**返回值**: `table<string, table>` - ID 到链接的映射表

**示例**:
```lua
local all_todos = store.get_all_todo_links()
for id, todo in pairs(all_todos) do
  print(id, todo.content)
end
```

#### `get_all_code_links()`
获取所有代码链接。

**返回值**: `table<string, table>` - ID 到链接的映射表

**示例**:
```lua
local all_codes = store.get_all_code_links()
```

## 状态管理 API

### 7. 状态更新

#### `update_status(id, status, link_type)`
更新链接状态。

**参数**:
- `id` (`string`): 链接ID
- `status` (`string`): 新状态（normal/urgent/waiting/completed）
- `link_type` (`string`|`nil`): 链接类型（"todo" 或 "code"），nil 表示自动检测

**返回值**: `table`|`nil` - 更新后的链接

**示例**:
```lua
-- 标记为完成
local updated = store.update_status("todo_001", "completed")

-- 标记为紧急
store.update_status("todo_001", "urgent", "todo")
```

### 8. 快捷状态方法

#### `mark_completed(id, link_type)`
标记为完成。

**参数**:
- `id` (`string`): 链接ID
- `link_type` (`string`|`nil`): 链接类型

**返回值**: `table`|`nil` - 更新后的链接

**示例**:
```lua
store.mark_completed("todo_001")
```

#### `mark_urgent(id, link_type)`
标记为紧急。

**参数**:
- `id` (`string`): 链接ID
- `link_type` (`string`|`nil`): 链接类型

**返回值**: `table`|`nil` - 更新后的链接

**示例**:
```lua
store.mark_urgent("todo_001")
```

#### `mark_waiting(id, link_type)`
标记为等待。

**参数**:
- `id` (`string`): 链接ID
- `link_type` (`string`|`nil`): 链接类型

**返回值**: `table`|`nil` - 更新后的链接

**示例**:
```lua
store.mark_waiting("todo_001")
```

#### `mark_normal(id, link_type)`
标记为正常。

**参数**:
- `id` (`string`): 链接ID
- `link_type` (`string`|`nil`): 链接类型

**返回值**: `table`|`nil` - 更新后的链接

**示例**:
```lua
store.mark_normal("todo_001")
```

### 9. 状态恢复

#### `restore_previous_status(id, link_type)`
恢复到上一次状态（主要用于从完成状态恢复）。

**参数**:
- `id` (`string`): 链接ID
- `link_type` (`string`|`nil`): 链接类型

**返回值**: `table`|`nil` - 恢复后的链接

**示例**:
```lua
-- 如果之前是紧急状态，完成后再恢复
store.mark_completed("todo_001")
store.restore_previous_status("todo_001")  -- 恢复到紧急状态
```

### 10. 状态筛选与统计

#### `filter_by_status(status, link_type)`
根据状态筛选链接。

**参数**:
- `status` (`string`): 要筛选的状态
- `link_type` (`string`|`nil`): 链接类型（"todo"、"code" 或 nil 表示两者）

**返回值**: `table<string, table>` - 筛选结果

**示例**:
```lua
-- 获取所有紧急的 TODO
local urgent_todos = store.filter_by_status("urgent", "todo")

-- 获取所有完成的任务（包括TODO和代码）
local completed_all = store.filter_by_status("completed")
```

#### `get_status_stats(link_type)`
获取状态统计信息。

**参数**:
- `link_type` (`string`|`nil`): 链接类型

**返回值**: `table` - 统计信息，包含：
  - `total` (`number`): 总链接数
  - `normal` (`number`): 正常状态数
  - `urgent` (`number`): 紧急状态数
  - `waiting` (`number`): 等待状态数
  - `completed` (`number`): 完成状态数

**示例**:
```lua
local stats = store.get_status_stats("todo")
print("完成率:", math.floor(stats.completed / stats.total * 100), "%")
```

## 索引与查询 API

### 11. 文件索引

#### `find_todo_links_by_file(filepath)`
查找指定文件的 TODO 链接。

**参数**:
- `filepath` (`string`): 文件路径

**返回值**: `table[]` - TODO 链接数组

**示例**:
```lua
local todos = store.find_todo_links_by_file("src/main.lua")
```

#### `find_code_links_by_file(filepath)`
查找指定文件的代码链接。

**参数**:
- `filepath` (`string`): 文件路径

**返回值**: `table[]` - 代码链接数组

**示例**:
```lua
local codes = store.find_code_links_by_file("src/main.lua")
```

## 清理与维护 API

### 12. 数据清理

#### `cleanup_expired(days)`
清理过期链接。

**参数**:
- `days` (`number`): 过期天数

**返回值**: `number` - 清理的数量

**示例**:
```lua
-- 清理30天前的链接
local cleaned = store.cleanup_expired(30)
```

#### `cleanup_completed(days)`
清理已完成的链接。

**参数**:
- `days` (`number`|`nil`): 完成天数，nil 表示清理所有完成链接

**返回值**: `number` - 清理的数量

**示例**:
```lua
-- 清理所有已完成的链接
local cleaned = store.cleanup_completed()

-- 清理7天前完成的链接
local cleaned_old = store.cleanup_completed(7)
```

### 13. 数据验证

#### `validate_all_links(opts)`
验证所有链接的完整性。

**参数**:
- `opts` (`table`|`nil`): 选项
  - `verbose` (`boolean`|`nil`): 是否输出详细信息

**返回值**: `table` - 验证结果，包含：
  - `total_code` (`number`): 总代码链接数
  - `total_todo` (`number`): 总 TODO 链接数
  - `orphan_code` (`number`): 孤立的代码链接数
  - `orphan_todo` (`number`): 孤立的 TODO 链接数
  - `missing_files` (`number`): 缺失文件数
  - `broken_links` (`number`): 损坏链接数

**示例**:
```lua
local report = store.validate_all_links()
print("损坏链接:", report.broken_links)
```

#### `repair_links(opts)`
尝试修复损坏的链接。

**参数**:
- `opts` (`table`|`nil`): 选项
  - `verbose` (`boolean`|`nil`): 是否输出详细信息
  - `dry_run` (`boolean`|`nil`): 是否试运行

**返回值**: `table` - 修复报告

**示例**:
```lua
local report = store.repair_links({ verbose = true })
```

### 14. 索引维护

#### `rebuild_index(link_type)`
重建索引。

**参数**:
- `link_type` (`string`): 链接类型（"todo_to_code" 或 "code_to_todo"）

**返回值**: `boolean` - 是否成功

**示例**:
```lua
store.rebuild_index("todo_to_code")
```

## 高级功能 API

### 15. 统计与监控

#### `get_stats()`
获取存储统计信息。

**返回值**: `table` - 统计信息，包含：
  - `todo_links` (`number`): TODO 链接数
  - `code_links` (`number`): 代码链接数
  - `total_links` (`number`): 总链接数
  - `last_sync` (`number`): 最后同步时间
  - `project_root` (`string`): 项目根目录
  - `version` (`string`): 版本号

**示例**:
```lua
local stats = store.get_stats()
print("总链接数:", stats.total_links)
```

#### `get_project_root()`
获取项目根目录。

**返回值**: `string` - 项目根目录路径

**示例**:
```lua
local root = store.get_project_root()
```

### 16. 数据备份与恢复

#### `export()`
导出所有数据（用于备份）。

**返回值**: `table` - 导出的数据，包含：
  - `meta` (`table`): 元数据
  - `todo_links` (`table`): 所有 TODO 链接
  - `code_links` (`table`): 所有代码链接
  - `export_time` (`number`): 导出时间
  - `export_version` (`string`): 导出版本

**示例**:
```lua
local backup = store.export()
local json = vim.fn.json_encode(backup)
vim.fn.writefile({ json }, "todo2_backup.json")
```

#### `import(data, opts)`
导入数据（从备份恢复）。

**参数**:
- `data` (`table`): 要导入的数据
- `opts` (`table`|`nil`): 选项
  - `overwrite` (`boolean`|`nil`): 是否覆盖现有数据

**返回值**: `boolean` - 是否成功

**示例**:
```lua
local json = vim.fn.readfile("todo2_backup.json")[1]
local backup = vim.fn.json_decode(json)
store.import(backup, { overwrite = true })
```

### 17. 数据完整性检查

#### `get_integrity_report()`
获取数据完整性报告。

**返回值**: `table` - 报告数据，包含：
  - `total_links` (`number`): 总链接数
  - `links_without_status` (`number`): 没有状态的链接数
  - `completed_without_time` (`number`): 完成但没有完成时间的链接数

**示例**:
```lua
local report = store.get_integrity_report()
print("需要修复的链接:", report.links_without_status)
```

#### `fix_integrity_issues()`
修复数据完整性问题。

**返回值**: `table` - 修复报告，包含：
  - `fixed_status` (`number`): 修复的状态数量
  - `fixed_completion_time` (`number`): 修复的完成时间数量

**示例**:
```lua
local report = store.fix_integrity_issues()
print("修复了", report.fixed_status, "个链接的状态")
```

### 18. 向后兼容

#### `migrate_status_fields()`
迁移状态字段（向后兼容）。

**返回值**: `number` - 迁移的数量

**示例**:
```lua
local migrated = store.migrate_status_fields()
print("迁移了", migrated, "个链接")
```

## 链接数据结构

每个链接对象包含以下字段：

```lua
{
  id = "todo_001",                    -- 唯一标识符
  type = "todo_to_code",              -- 链接类型
  path = "/project/src/main.lua",     -- 文件路径
  line = 10,                          -- 行号
  content = "实现登录功能",           -- 内容
  created_at = 1690000000,            -- 创建时间戳
  updated_at = 1690000000,            -- 更新时间戳
  completed_at = 1690000000,          -- 完成时间戳（仅完成状态有）
  status = "completed",               -- 状态（normal/urgent/waiting/completed）
  previous_status = "urgent",         -- 上一次状态
  active = true,                      -- 是否活跃
  context = { ... }                   -- 上下文信息
}
```

## 状态流转

任何状态都可以直接切换到任何其他状态：

```
normal ↔ urgent ↔ waiting ↔ completed
```

- 当状态变为 `completed` 时，自动设置 `completed_at`
- 当从 `completed` 恢复时，可以使用 `restore_previous_status()` 恢复到之前的状态

## 错误处理

所有 API 都包含错误包装器，出现错误时会：
1. 记录错误日志到 Neovim 通知系统
2. 返回 `nil` 或 `false`（根据函数类型）

## 使用示例

### 完整工作流示例

```lua
local store = require("todo2.store")
store.setup()

-- 1. 添加 TODO
store.add_todo_link("todo_001", {
  path = "src/auth.lua",
  line = 25,
  content = "实现用户认证",
  status = "urgent"
})

-- 2. 添加对应的代码实现
store.add_code_link("code_001", {
  path = "src/auth.lua",
  line = 30,
  content = "用户认证实现",
  status = "waiting"
})

-- 3. 更新状态
store.mark_completed("todo_001")
store.mark_completed("code_001")

-- 4. 查询统计
local stats = store.get_status_stats()
print("完成的任务:", stats.completed)

-- 5. 清理旧数据
store.cleanup_expired(30)

-- 6. 数据完整性检查
local report = store.get_integrity_report()
if report.links_without_status > 0 then
  store.fix_integrity_issues()
end

-- 7. 备份数据
local backup = store.export()
```

