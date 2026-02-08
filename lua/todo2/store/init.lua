-- lua/todo2/store/init.lua
-- 存储模块主入口，统一导出所有功能

local M = {}

---------------------------------------------------------------------
-- 模块导出
---------------------------------------------------------------------

-- 基础模块
M.link = require("todo2.store.link")
M.index = require("todo2.store.index")
M.types = require("todo2.store.types")
M.meta = require("todo2.store.meta")

-- 清理功能
M.cleanup = require("todo2.store.cleanup")

-- 工具模块
M.locator = require("todo2.store.locator")
M.context = require("todo2.store.context")
M.consistency = require("todo2.store.consistency")
M.state_machine = require("todo2.store.state_machine")
M.autofix = require("todo2.store.autofix")
M.utils = require("todo2.store.utils")

-- 存储后端
M.nvim_store = require("todo2.store.nvim_store")

---------------------------------------------------------------------
-- 简化API（向前兼容）
---------------------------------------------------------------------

--- 获取所有代码链接（简化调用）
--- @return table<string, table>
function M.get_all_code_links()
	return M.link.get_all_code()
end

--- 获取所有TODO链接（简化调用）
--- @return table<string, table>
function M.get_all_todo_links()
	return M.link.get_all_todo()
end

--- 获取项目根目录
--- @return string
function M.get_project_root()
	return M.meta.get_project_root()
end

--- 验证所有链接
--- @param opts table|nil
--- @return table
function M.validate_all_links(opts)
	return M.cleanup.validate_all(opts)
end

--- 尝试修复链接
--- @param opts table|nil
--- @return table
function M.repair_links(opts)
	return M.cleanup.repair_links(opts)
end

--- 清理过期链接
--- @param days number
--- @return number
function M.cleanup_expired(days)
	return M.cleanup.cleanup(days)
end

--- 清理已完成链接
--- @param days number|nil
--- @return number
function M.cleanup_completed(days)
	return M.cleanup.cleanup_completed(days)
end

return M
