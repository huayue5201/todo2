-- lua/todo2/ui/status.lua
-- 状态 UI：图标/标签/时间显示 + 状态选择菜单

local M = {}

local config = require("todo2.config")
local time_utils = require("todo2.utils.time")
local core_status = require("todo2.core.status")
local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local cursor = require("todo2.task.cursor")
local render_highlights = require("todo2.render.highlights")

---------------------------------------------------------------------
-- 状态配置（图标 / label / 颜色）
---------------------------------------------------------------------
function M.get(status)
	local definitions = config.get("status_icons", {})
	local def = definitions[status] or definitions.normal or {}

	return {
		icon = def.icon or "●",
		label = def.label or status,
		color = def.color or "#888888",
		hl_group = def.hl_group or ("TodoStatus" .. status:gsub("^%l", string.upper)),
	}
end

function M.get_icon(status)
	return M.get(status).icon
end

function M.get_label(status)
	return M.get(status).label
end

---------------------------------------------------------------------
-- 循环顺序（统一来自 core/status，避免两套状态机）
---------------------------------------------------------------------
function M.get_user_cycle_order()
	return core_status.CYCLE_ORDER
end

function M.get_next_user_status(current)
	return core_status.get_next(current)
end

---------------------------------------------------------------------
-- 时间显示（用于菜单右侧）
---------------------------------------------------------------------
function M.get_time_display(link)
	if not link then
		return ""
	end

	return time_utils.get_time_display({
		created_at = link.created_at,
		completed_at = link.completed_at,
		archived_at = link.archived_at,
		updated_at = link.updated_at,
		status = link.status,
	}, "compact")
end

---------------------------------------------------------------------
-- UI 显示组件（图标 + 时间）
---------------------------------------------------------------------
function M.get_display_components(link, status)
	local s = status or (link and link.status) or "normal"
	local cfg = M.get(s)
	local time_str = M.get_time_display(link)

	return {
		icon = cfg.icon,
		icon_highlight = cfg.hl_group,
		time = time_str,
		time_highlight = "TodoTime",
	}
end

---------------------------------------------------------------------
-- 显示状态选择菜单（纯数据）
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

	return { id = id, status = task.core.status, task = task }
end

function M.show_status_menu()
	local info = get_current_task_info()
	if not info then
		vim.notify("当前行不是任务", vim.log.levels.WARN)
		return
	end

	local current = info.status or types.STATUS.NORMAL
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

---------------------------------------------------------------------
-- 高亮 + 初始化（统一由 render.highlights 负责）
---------------------------------------------------------------------
function M.setup_highlights()
	return render_highlights.setup()
end

function M.setup()
	M.setup_highlights()
	return M
end

return M
