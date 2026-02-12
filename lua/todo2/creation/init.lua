-- lua/todo2/creation/init.lua
--- @module todo2.creation
--- @brief 统一任务创建模块入口
---
--- 提供从代码创建链接的单一入口，内部通过会话管理器 + 多动作窗口实现
--- 用户在 TODO 浮窗中通过不同确认键选择创建独立任务或子任务

local M = {}
local manager = require("todo2.creation.manager")

--- 从当前代码位置开始一个创建会话
--- @param context? table 可选，预置的上下文（如 code_buf, code_line, selected_tag）
---   若不提供，自动从当前窗口获取
function M.start_session(context)
	return manager.start_session(context)
end

--- 直接打开 TODO 文件并绑定动作（供其他模块直接调用）
--- @param todo_path string TODO文件路径
--- @param context table 代码上下文
function M.open_with_actions(todo_path, context)
	return manager.open_todo_window_with_path(todo_path, context)
end

return M
