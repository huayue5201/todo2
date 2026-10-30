-- lua/todo2/ui/status.lua
-- 状态 UI：图标/标签/颜色/时间显示 + 状态选择菜单

local M = {}

local core_status = require("todo2.core.status")
local time_utils = require("todo2.utils.time")
local core = require("todo2.store.task.core")
local picker = require("todo2.task.picker")

---------------------------------------------------------------------
-- 状态显示定义（图标 / label / 颜色 / 高亮组）
---------------------------------------------------------------------
function M.get(status)
	local def = core_status.get_definition(status)
	if not def then
		return {
			icon = "●",
			label = status,
			hl_group = "Normal",
		}
	end

	return {
		icon = def.icon,
		label = def.label,
		hl_group = core_status.get_hl_group(status),
	}
end

---------------------------------------------------------------------
-- 循环顺序（标签列表，统一来自 core/status）
---------------------------------------------------------------------
function M.get_user_cycle_order()
	local order = {}
	for _, def in ipairs(core_status.get_cycle()) do
		table.insert(order, def.label)
	end
	return order
end

---------------------------------------------------------------------
-- 时间显示（用于菜单右侧）
---------------------------------------------------------------------
function M.get_time_display(link, format)
	if not link then
		return ""
	end

	return time_utils.get_time_display({
		created_at = link.created_at,
		completed_at = link.completed_at,
		archived_at = link.archived_at,
		updated_at = link.updated_at,
		status = link.status,
	}, format or "compact")
end

---------------------------------------------------------------------
-- 显示状态选择菜单
---------------------------------------------------------------------
--- 取任务信息
---@param id string|nil
---@return table|nil
local function get_task_info(id)
	local task = id and core.get_task(id)
	if not task then
		return nil
	end
	return { id = id, status = task.core.status, task = task }
end

--- 弹出状态选择菜单
---@param info { id: string, status: string, task: table }
---@param on_done? fun() 状态写回后回调（属性面板用它刷新）
local function open_menu(info, on_done)
	local current = info.status or core_status.get_default()
	local all_statuses = M.get_user_cycle_order()
	local items = {}

	for _, st in ipairs(all_statuses) do
		local cfg = M.get(st)
		local prefix = (st == current) and "▶ " or "  "
		local right = string.format("%s%s %s", prefix, cfg.icon, cfg.label)

		table.insert(items, {
			value = st,
			status_name = cfg.label,
			right_side = right,
		})
	end

	vim.ui.select(items, {
		prompt = "Choose task status:",
		format_item = function(item)
			return string.format("%-20s • %s", item.status_name, item.right_side)
		end,
	}, function(choice)
		if not choice then
			return
		end
		core_status.update(info.id, choice.value, "status_menu")
		if on_done then
			on_done()
		end
	end)
end

---@param id? string 省略则对光标处任务弹菜单
---@param on_done? fun() 状态写回后回调
function M.show_status_menu(id, on_done)
	if id then
		local info = get_task_info(id)
		if not info then
			vim.notify("Task does not exist: " .. id, vim.log.levels.WARN)
			return
		end
		open_menu(info, on_done)
		return
	end

	picker.pick({ none_msg = "Current line is not a task" }, function(task)
		open_menu({ id = task.id, status = task.core.status, task = task }, on_done)
	end)
end

return M
