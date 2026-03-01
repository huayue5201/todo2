-- lua/todo2/status/ui.lua
--- @module todo2.status.ui

local M = {}

local types = require("todo2.store.types")
local status_utils = require("todo2.status.utils")

-- ⭐ 不要直接 require core.status，改为在函数内延迟加载
local function get_core_status()
	return require("todo2.core.status")
end

---------------------------------------------------------------------
-- UI交互函数
---------------------------------------------------------------------

--- 循环切换状态
--- @return boolean
function M.cycle_status()
	local core_status = get_core_status() -- ⭐ 延迟加载

	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return false
	end

	local current_status = link_info.link.status or types.STATUS.NORMAL

	if not status_utils.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return false
	end

	local next_status = status_utils.get_next_user_status(current_status)
	local success = core_status.update(link_info.id, next_status, "cycle_status")

	if success then
		local current_cfg = status_utils.get(current_status)
		local next_cfg = status_utils.get(next_status)
	end

	return success
end

--- 显示状态选择菜单
function M.show_status_menu()
	local core_status = get_core_status() -- ⭐ 延迟加载

	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return
	end

	local current_status = link_info.link.status or types.STATUS.NORMAL

	if not status_utils.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return
	end

	local all_transitions = core_status.get_allowed(current_status)
	local active_transitions = {}
	for _, status in ipairs(all_transitions) do
		if types.is_active_status(status) then
			table.insert(active_transitions, status)
		end
	end

	if #active_transitions == 0 then
		vim.notify("没有可用的活跃状态可切换", vim.log.levels.INFO)
		return
	end

	local items = {}
	for _, status in ipairs(active_transitions) do
		local cfg = status_utils.get(status)
		local time_str = status_utils.get_time_display(link_info.link)
		local time_info = (time_str ~= "" and string.format(" (%s)", time_str)) or ""

		local prefix = (current_status == status) and "▶ " or "  "
		local status_name = cfg.label
		local right_side = string.format("%s%s%s %s", prefix, cfg.icon, time_info, cfg.label)

		table.insert(items, {
			value = status,
			status_name = status_name,
			right_side = right_side,
		})
	end

	vim.ui.select(items, {
		prompt = "📌 选择任务状态：",
		format_item = function(item)
			return string.format("%-20s • %s", item.status_name, item.right_side)
		end,
	}, function(choice)
		if not choice then
			return
		end

		if not core_status.is_allowed(current_status, choice.value) then
			vim.notify("无效的状态流转", vim.log.levels.ERROR)
			return
		end

		local success = core_status.update(link_info.id, choice.value, "status_menu")

		if success then
			local cfg = status_utils.get(choice.value)
			vim.notify(string.format("已切换到: %s%s", cfg.icon, cfg.label), vim.log.levels.INFO)
		end
	end)
end

--- 判断当前行是否有状态标记
function M.has_status_mark()
	local core_status = get_core_status() -- ⭐ 延迟加载
	return core_status.get_current_link_info() ~= nil
end

--- 获取当前任务状态
function M.get_current_status()
	local core_status = get_core_status() -- ⭐ 延迟加载
	local info = core_status.get_current_link_info()
	return info and info.link.status or nil
end

--- 获取当前任务状态配置
function M.get_current_status_config()
	local status = M.get_current_status()
	return status and status_utils.get(status) or nil
end

--- 标记任务为完成
function M.mark_completed()
	local core_status = get_core_status() -- ⭐ 延迟加载

	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return false
	end

	local success = core_status.update(link_info.id, types.STATUS.COMPLETED, "mark_completed")
	if success then
		vim.notify("任务已标记为完成", vim.log.levels.INFO)
	end
	return success
end

--- 重新打开任务
function M.reopen_link()
	local core_status = get_core_status() -- ⭐ 延迟加载

	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return false
	end

	local success = core_status.update(link_info.id, types.STATUS.NORMAL, "reopen")
	if success then
		vim.notify("任务已重新打开", vim.log.levels.INFO)
	end
	return success
end

return M
