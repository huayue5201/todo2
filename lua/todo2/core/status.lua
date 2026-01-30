--- File: /Users/lijia/todo2/lua/todo2/core/status.lua ---
-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 状态管理核心模块

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")
local status_mod = require("todo2.status")

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------

--- 获取当前行的链接信息
--- @return table|nil
local function get_current_link_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.fn.getline(".")

	-- 判断文件类型
	local path = vim.api.nvim_buf_get_name(bufnr)
	local is_todo = path:match("%.todo%.md$")

	local id, link_type

	if is_todo then
		-- TODO文件：匹配 {#id}
		id = line:match("{#(%w+)}")
		link_type = "todo"
	else
		-- 代码文件：匹配 TAG:ref:id
		local _, tag_id = line:match("(%u+):ref:(%w+)")
		if tag_id then
			id = tag_id
			link_type = "code"
		end
	end

	if not id then
		return nil
	end

	local store = module.get("store")
	local link
	if link_type == "todo" then
		link = store.get_todo_link(id)
	else
		link = store.get_code_link(id)
	end

	if not link then
		return nil
	end

	return {
		id = id,
		link_type = link_type,
		link = link,
		bufnr = bufnr,
		is_todo = is_todo,
		path = path,
	}
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

--- 获取状态显示文本（图标 + 时间戳）
--- @param link table
--- @return string
function M.get_status_display(link)
	return status_mod.get_status_display(link)
end

--- 获取状态高亮组名
--- @param status string
--- @return string
function M.get_status_highlight(status)
	return status_mod.get_highlight(status)
end

--- 获取时间显示文本
--- @param link table
--- @return string
function M.get_time_display(link)
	return status_mod.get_time_display(link)
end

--- 循环切换状态（只能切换正常/紧急/等待）
--- @desc 正常 → 紧急 → 等待 → 正常（循环）
function M.cycle_status()
	local link_info = get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return
	end

	local current_status = link_info.link.status or "normal"

	-- 检查当前状态是否可手动切换
	if not status_mod.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return
	end

	local next_status = status_mod.get_next_status(current_status)

	local store = module.get("store")
	store.update_status(link_info.id, next_status, link_info.link_type)

	-- 触发事件
	local events = module.get("core.events")
	events.on_state_changed({
		source = "cycle_status",
		file = link_info.link.path,
		bufnr = link_info.bufnr,
		ids = { link_info.id },
	})

	vim.notify(string.format("状态已切换: %s → %s", current_status, next_status), vim.log.levels.INFO)
end

--- 显示状态选择菜单（只显示正常/紧急/等待）
function M.show_status_menu()
	local link_info = get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return
	end

	local current_status = link_info.link.status or "normal"

	-- 检查当前状态是否可手动切换
	if not status_mod.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return
	end

	-- 构建菜单项（只包含用户可切换的状态）
	local items = {}
	local order = status_mod.get_cycle_order()

	for _, status in ipairs(order) do
		local config = status_mod.get_config(status)
		local time_str = M.get_time_display(link_info.link)
		local time_info = time_str and string.format(" (%s)", time_str) or ""

		local prefix = current_status == status and "▶ " or "  "
		local label = string.format("%s%s%s %s", prefix, config.icon, time_info, config.label)

		table.insert(items, {
			value = status,
			label = label,
			is_current = current_status == status,
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

		local store = module.get("store")
		store.update_status(link_info.id, choice.value, link_info.link_type)

		-- 触发事件
		local events = module.get("core.events")
		events.on_state_changed({
			source = "status_menu",
			file = link_info.link.path,
			bufnr = link_info.bufnr,
			ids = { link_info.id },
		})
	end)
end

return M
