-- lua/todo2/status/ui.lua
-- 最终版：纯数据 UI，支持 TODO 和代码文件

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local core_status = require("todo2.core.status")
local status_utils = require("todo2.status.utils")
local line_analyzer = require("todo2.utils.line_analyzer")
local index = require("todo2.store.index")

---------------------------------------------------------------------
-- 工具：获取当前行的任务信息（支持 TODO 和代码文件）
---------------------------------------------------------------------
local function get_current_task_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo = filename:match("%.todo%.md$") ~= nil

	local id = nil

	if is_todo then
		-- TODO 文件：从行解析
		local analysis = line_analyzer.analyze_current_line()
		id = analysis and analysis.id or nil
	else
		-- 代码文件：从索引查询
		local path = filename
		if path == "" then
			return nil
		end
		local tasks = index.find_code_links_by_file(path)
		for _, task in ipairs(tasks) do
			if task.locations.code and task.locations.code.line == lnum then
				id = task.id
				break
			end
		end
	end

	if not id then
		return nil
	end

	local task = core.get_task(id)
	if not task then
		return nil
	end

	return {
		id = id,
		status = task.core.status,
		task = task,
	}
end

---------------------------------------------------------------------
-- 显示状态选择菜单（纯数据）
---------------------------------------------------------------------
function M.show_status_menu()
	local info = get_current_task_info()
	if not info then
		vim.notify("当前行不是任务", vim.log.levels.WARN)
		return
	end

	local current = info.status or types.STATUS.NORMAL

	local all_statuses = status_utils.get_user_cycle_order()
	local items = {}

	for _, st in ipairs(all_statuses) do
		local cfg = status_utils.get(st)
		local prefix = (st == current) and "▶ " or "  "
		local right = string.format("%s%s %s", prefix, cfg.icon, cfg.label)

		table.insert(items, {
			value = st,
			status_name = cfg.label,
			right_side = right,
		})
	end

	vim.ui.select(items, {
		prompt = "选择任务状态：",
		format_item = function(item)
			return string.format("%-20s • %s", item.status_name, item.right_side)
		end,
	}, function(choice)
		if not choice then
			return
		end

		core_status.update(info.id, choice.value, "status_menu")
	end)
end

return M
