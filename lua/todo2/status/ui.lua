-- lua/todo2/status/ui.lua
--- @module todo2.status.ui
--- @brief 状态UI交互模块（适配原子性操作）

local M = {}

local module = require("todo2.module")
local types = require("todo2.store.types")

-- 导入核心模块
local core_status = require("todo2.core.status")

-- 使用新的配置模块
local config = require("todo2.config")

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------

--- 获取状态定义
--- @param status string 状态名称
--- @return table 状态配置
local function get_status_definition(status)
	local definitions = config.get("status_definitions") or {}
	return definitions[status] or definitions.normal or {}
end

--- 获取时间显示字符串
--- @param link table 链接信息
--- @return string|nil 时间字符串
local function get_time_display(link)
	if not link or not link.updated_at then
		return nil
	end

	local timestamp_format = config.get("timestamp_format") or "%Y/%m/%d %H:%M"

	-- 将时间戳转换为可读格式
	local success, result = pcall(function()
		local time = link.updated_at
		if type(time) == "number" then
			return os.date(timestamp_format, time)
		else
			return tostring(time)
		end
	end)

	return success and result or nil
end

---------------------------------------------------------------------
-- UI交互函数（适配原子性操作）
---------------------------------------------------------------------

--- 循环切换状态（用户操作，两端同时切换）
--- @return boolean 是否成功
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
	local next_status = core_status.get_next_status(current_status, false)

	-- 更新状态（两端同时更新）
	local success = core_status.update_active_status(link_info.id, next_status, "cycle_status")

	if success then
		local current_config = get_status_definition(current_status)
		local next_config = get_status_definition(next_status)
		vim.notify(
			string.format(
				"状态已切换: %s%s → %s%s",
				current_config.icon or "",
				current_config.label or current_status,
				next_config.icon or "",
				next_config.label or next_status
			),
			vim.log.levels.INFO
		)
	end

	return success
end

--- 显示状态选择菜单（两端同时更新）
function M.show_status_menu()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return
	end

	local current_status = link_info.link.status or types.STATUS.NORMAL

	-- 检查是否可手动切换
	if not core_status.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return
	end

	-- 获取可用的状态流转
	local available_transitions = core_status.get_available_transitions(current_status)

	if #available_transitions == 0 then
		vim.notify("没有可用的状态切换选项", vim.log.levels.INFO)
		return
	end

	-- 构建菜单项
	local items = {}
	for _, status in ipairs(available_transitions) do
		local config = get_status_definition(status)
		local time_str = get_time_display(link_info.link)
		local time_info = time_str and string.format(" (%s)", time_str) or ""

		local prefix = current_status == status and "▶ " or "  "
		local label = string.format("%s%s%s %s", prefix, config.icon or "", time_info, config.label or status)

		table.insert(items, {
			value = status,
			label = label,
		})
	end

	-- 显示选择菜单
	vim.ui.select(items, {
		prompt = "选择任务状态:",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if not choice then
			return
		end

		-- 验证状态流转
		if not core_status.is_valid_transition(current_status, choice.value) then
			vim.notify("无效的状态流转", vim.log.levels.ERROR)
			return
		end

		-- 更新状态（两端同时更新）
		local success = core_status.update_active_status(link_info.id, choice.value, "status_menu")

		if success then
			local chosen_config = get_status_definition(choice.value)
			vim.notify(
				string.format("已切换到: %s%s", chosen_config.icon or "", chosen_config.label or choice.value),
				vim.log.levels.INFO
			)
		end
	end)
end

--- 判断当前行是否有状态标记
--- @return boolean
function M.has_status_mark()
	return core_status.get_current_link_info() ~= nil
end

--- 获取当前任务状态
--- @return string|nil 状态名称
function M.get_current_status()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		return nil
	end
	return link_info.link.status or types.STATUS.NORMAL
end

--- 获取当前任务状态配置
--- @return table|nil 配置表
function M.get_current_status_config()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		return nil
	end
	local status = link_info.link.status or types.STATUS.NORMAL
	return get_status_definition(status)
end

--- 获取分离的显示组件（用于渲染器）
--- @param link table 链接信息
--- @return table 显示组件
function M.get_display_components(link)
	if not link then
		return {}
	end

	local status = link.status or types.STATUS.NORMAL
	local config = get_status_definition(status)
	local time_str = get_time_display(link)

	return {
		icon = config.icon or "",
		icon_highlight = config.hl_group or "TodoStatus" .. status:sub(1, 1):upper() .. status:sub(2),
		time = time_str or "",
		time_highlight = "Comment", -- 可以使用配置中的颜色
	}
end

--- 标记任务为完成（两端同时标记）
--- @return boolean 是否成功
function M.mark_completed()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return false
	end

	-- 调用存储模块
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
--- @return boolean 是否成功
function M.reopen_link()
	local link_info = core_status.get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return false
	end

	-- 调用存储模块
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
