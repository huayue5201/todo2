-- lua/todo2/store/meta.lua
-- 纯功能平移：使用新接口获取统计

local M = {}

local types = require("todo2.store.types")
local query = require("todo2.store.link.query")

---------------------------------------------------------------------
-- 扫描所有任务并返回统计
---------------------------------------------------------------------
function M.get_stats()
	local all_tasks = query.get_all_tasks()

	local stats = {
		total_links = 0,
		todo_links = 0,
		code_links = 0,
		archived_todo_links = 0,
		archived_code_links = 0,
	}

	for _, task in pairs(all_tasks) do
		if task.locations.todo then
			stats.todo_links = stats.todo_links + 1
			if types.is_archived_status(task.core.status) then
				stats.archived_todo_links = stats.archived_todo_links + 1
			end
		end

		if task.locations.code then
			stats.code_links = stats.code_links + 1
			if types.is_archived_status(task.core.status) then
				stats.archived_code_links = stats.archived_code_links + 1
			end
		end
	end

	stats.total_links = stats.todo_links + stats.code_links
	return stats
end

---------------------------------------------------------------------
-- 获取项目根目录（保持原功能）
---------------------------------------------------------------------
function M.get_project_root()
	-- 直接从配置获取
	local config = require("todo2.config")
	local root = config.get("project_root")
	if root and root ~= "" then
		return root
	end

	-- 回退到当前目录
	return vim.fn.getcwd()
end

---------------------------------------------------------------------
-- 初始化
---------------------------------------------------------------------
function M.init()
	return M.get_stats()
end

return M
