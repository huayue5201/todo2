-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 状态管理核心模块

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")
local config = require("todo2.config")

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
	}
end

--- 格式化时间戳
--- @param timestamp number
--- @return string
local function format_timestamp(timestamp)
	if not timestamp then
		return ""
	end

	local cfg = config.get_status()
	local time_str = os.date(cfg.timestamp.format, timestamp)
	return string.format(" %s %s", cfg.timestamp.icon, time_str)
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

--- 获取状态显示文本
--- @param link table
--- @return string
function M.get_status_display(link)
	if not link then
		return ""
	end

	local cfg = config.get_status()
	local status = link.status or "normal"
	local icon_cfg = cfg.icons[status]

	if not icon_cfg then
		return ""
	end

	-- 构建显示文本
	local display = icon_cfg.dot

	-- 添加时间戳
	local timestamp
	if status == "completed" then
		timestamp = link.completed_at
	else
		timestamp = link.created_at
	end

	if timestamp then
		display = display .. format_timestamp(timestamp)
	end

	return display
end

--- 获取状态高亮组名
--- @param status string
--- @return string
function M.get_status_highlight(status)
	local cfg = config.get_status()
	local icon_cfg = cfg.icons[status or "normal"]

	if not icon_cfg then
		return "TodoStatus"
	end

	-- 根据状态返回不同的高亮组
	if status == "urgent" then
		return "TodoStatusUrgent"
	elseif status == "waiting" then
		return "TodoStatusWaiting"
	elseif status == "completed" then
		return "TodoStatusCompleted"
	else
		return "TodoStatusNormal"
	end
end

--- 切换完成状态（与<CR>绑定）
function M.toggle_completion()
	local link_info = get_current_link_info()
	if not link_info then
		return
	end

	local store = module.get("store")
	local current_status = link_info.link.status or "normal"

	if current_status == "completed" then
		-- 从完成状态恢复
		store.restore_previous_status(link_info.id, link_info.link_type)
	else
		-- 标记为完成
		store.mark_completed(link_info.id, link_info.link_type)
	end

	-- 触发事件刷新UI
	local events = module.get("core.events")
	events.on_state_changed({
		source = "toggle_completion",
		file = link_info.link.path,
		bufnr = link_info.bufnr,
		ids = { link_info.id },
	})
end

--- 直接设置状态（用于三种未完成状态）
--- @param status string
local function set_status_direct(status)
	return function()
		local link_info = get_current_link_info()
		if not link_info then
			return
		end

		-- 不允许直接设置为完成状态
		if status == "completed" then
			vim.notify("请使用<CR>切换完成状态", vim.log.levels.WARN)
			return
		end

		local store = module.get("store")
		local current_status = link_info.link.status or "normal"

		-- 如果当前是完成状态，先恢复
		if current_status == "completed" then
			store.restore_previous_status(link_info.id, link_info.link_type)
		end

		-- 切换到目标状态
		store.update_status(link_info.id, status, link_info.link_type)

		-- 触发事件
		local events = module.get("core.events")
		events.on_state_changed({
			source = "set_status_direct",
			file = link_info.link.path,
			bufnr = link_info.bufnr,
			ids = { link_info.id },
		})
	end
end

--- 显示状态选择菜单
function M.show_status_menu()
	local link_info = get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return
	end

	local cfg = config.get_status()
	local current_status = link_info.link.status or "normal"

	-- 构建菜单项
	local items = {}
	local order = { "urgent", "waiting", "normal", "completed" }

	for _, status in ipairs(order) do
		local icon_cfg = cfg.icons[status]

		-- 构建显示文本
		local prefix = current_status == status and "▶ " or "  "
		local label

		if status == "completed" then
			label = string.format("%s✓ 标记为完成", current_status == status and "▶ " or "  ")
		else
			label = string.format("%s%s %s", prefix, icon_cfg.dot, icon_cfg.label)
		end

		table.insert(items, {
			value = status,
			label = label,
			is_current = current_status == status,
		})
	end

	-- 显示选择菜单
	vim.ui.select(items, {
		prompt = cfg.menu.prompt or "选择状态:",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if not choice then
			return
		end

		local new_status = choice.value

		if new_status == "completed" then
			M.toggle_completion()
		else
			set_status_direct(new_status)()
		end
	end)
end

---------------------------------------------------------------------
-- 快捷状态切换函数
---------------------------------------------------------------------
M.set_urgent = set_status_direct("urgent")
M.set_waiting = set_status_direct("waiting")
M.set_normal = set_status_direct("normal")

return M
