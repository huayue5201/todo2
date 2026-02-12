-- lua/todo2/status/ui.lua
--- @module todo2.status.ui
--- @brief 状态UI交互模块（适配原子性操作）

local M = {}

local module = require("todo2.module")
local types = require("todo2.store.types")

-- 核心状态业务逻辑
local core_status = require("todo2.core.status")

-- 状态工具函数（配置读取、格式化）
local status_utils = require("todo2.status.utils")

---------------------------------------------------------------------
-- UI交互函数（调用 core.status 实现状态变更）
---------------------------------------------------------------------

--- 循环切换状态（两端同时更新）
--- @return boolean
function M.cycle_status()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return false
	end

	local current_status = link_info.link.status or types.STATUS.NORMAL

	-- 检查是否可手动切换
	if not core_status.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return false
	end

	-- 获取下一个状态（不包含完成状态）
	local next_status = core_status.get_next_user_status(current_status)

	-- 更新状态（两端同时更新）
	local success = core_status.update_active_status(link_info.id, next_status, "cycle_status")

	if success then
		local current_cfg = status_utils.get(current_status)
		local next_cfg = status_utils.get(next_status)
		vim.notify(
			string.format(
				"状态已切换: %s%s → %s%s",
				current_cfg.icon or "",
				current_cfg.label or current_status,
				next_cfg.icon or "",
				next_cfg.label or next_status
			),
			vim.log.levels.INFO
		)
	end

	return success
end

--- 显示状态选择菜单（两端同时更新）
--- ⭐ 修改：只允许选择活跃状态，过滤 completed/archived
function M.show_status_menu()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return
	end

	local current_status = link_info.link.status or types.STATUS.NORMAL

	if not core_status.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return
	end

	-- 获取可用的状态流转（可能包含 completed）
	local all_transitions = core_status.get_available_transitions(current_status)

	-- ⭐ 过滤：只保留活跃状态（normal/urgent/waiting）
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

	-- 构建菜单项
	local items = {}
	for _, status in ipairs(active_transitions) do
		local cfg = status_utils.get(status)
		local time_str = status_utils.get_time_display(link_info.link)
		local time_info = (time_str ~= "" and string.format(" (%s)", time_str)) or ""

		local prefix = (current_status == status) and "▶ " or "  "
		local icon = cfg.icon or ""
		local label = cfg.label or status

		-- 左侧固定宽度显示名称（使用中文/英文标签）
		local status_name = label
		-- 右侧完整显示：前缀 + 图标 + 时间 + 标签
		local right_side = string.format("%s%s%s %s", prefix, icon, time_info, label)

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

		if not core_status.is_valid_transition(current_status, choice.value) then
			vim.notify("无效的状态流转", vim.log.levels.ERROR)
			return
		end

		local success = core_status.update_active_status(link_info.id, choice.value, "status_menu")

		if success then
			local cfg = status_utils.get(choice.value)
			vim.notify(
				string.format("已切换到: %s%s", cfg.icon or "", cfg.label or choice.value),
				vim.log.levels.INFO
			)
		end
	end)
end

--- 判断当前行是否有状态标记
function M.has_status_mark()
	return core_status.get_current_link_info() ~= nil
end

--- 获取当前任务状态（纯查询）
function M.get_current_status()
	local info = core_status.get_current_link_info()
	return info and info.link.status or nil
end

--- 获取当前任务状态配置
function M.get_current_status_config()
	local status = M.get_current_status()
	return status and status_utils.get(status) or nil
end

--- 标记任务为完成（两端同时标记）
function M.mark_completed()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return false
	end

	local store = module.get("store")
	if not store or not store.link then
		vim.notify("无法获取存储模块", vim.log.levels.ERROR)
		return false
	end

	local success = store.link.mark_completed(link_info.id) ~= nil
	if success then
		vim.notify("任务已标记为完成", vim.log.levels.INFO)
	end
	return success
end

--- 重新打开任务（两端同时重新打开）
function M.reopen_link()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return false
	end

	local store = module.get("store")
	if not store or not store.link then
		vim.notify("无法获取存储模块", vim.log.levels.ERROR)
		return false
	end

	local success = store.link.reopen_link(link_info.id) ~= nil
	if success then
		vim.notify("任务已重新打开", vim.log.levels.INFO)
	end
	return success
end

return M
