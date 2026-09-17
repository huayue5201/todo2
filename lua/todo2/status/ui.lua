-- lua/todo2/status/ui.lua
-- 最终版：纯数据 UI，支持 TODO 和代码文件

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local core_status = require("todo2.core.status")
local status_utils = require("todo2.status.utils")
local cursor = require("todo2.task.cursor")

---------------------------------------------------------------------
-- 工具：获取当前行的任务信息（支持 TODO 和代码文件）
---------------------------------------------------------------------
local function get_current_task_info()
	local id = cursor.get_id()
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
