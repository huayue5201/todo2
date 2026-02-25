-- lua/todo2/core/init.lua
--- @module todo2.core
--- @brief 精简版核心模块入口（适配原子性操作）

local M = {}

---------------------------------------------------------------------
-- 模块依赖声明（用于文档）
---------------------------------------------------------------------
M.dependencies = {
	"config",
	"core.parser",
	"core.state_manager",
	"core.stats",
	"core.events",
	"core.autosave",
	"core.archive",
	"core.status",
}

---------------------------------------------------------------------
-- 模块初始化
---------------------------------------------------------------------
function M.setup()
	return M
end

return M
