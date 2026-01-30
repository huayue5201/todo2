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
-- 模块缓存
---------------------------------------------------------------------
local store_module, events_module

--- 获取常用模块（带缓存）
--- @return table, table 存储模块, 事件模块
local function get_modules()
	if not store_module then
		store_module = module.get("store")
	end
	if not events_module then
		events_module = module.get("core.events")
	end
	return store_module, events_module
end

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

	local id

	-- 不管是TODO文件还是代码文件，都尝试匹配两种标记
	-- 首先尝试匹配代码标记（TAG:ref:id）
	local tag, tag_id = line:match("(%u+):ref:(%w+)")
	if tag_id then
		id = tag_id
	else
		-- 然后尝试匹配TODO标记（{#id}）
		id = line:match("{#(%w+)}")
	end

	if not id then
		return nil
	end

	local store = get_modules()
	local link
	-- 在代码侧，我们需要获取TODO链接来获取状态信息
	-- 在TODO侧，我们也获取TODO链接
	link = store.get_todo_link(id)
	if not link then
		-- 如果找不到TODO链接，尝试代码链接（向后兼容）
		link = store.get_code_link(id)
		if not link then
			return nil
		end
		-- 如果是代码链接，我们需要知道它是代码链接
		return {
			id = id,
			link_type = "code",
			link = link,
			bufnr = bufnr,
			is_todo = is_todo,
			path = path,
			tag = tag,
		}
	end

	return {
		id = id,
		link_type = "todo",
		link = link,
		bufnr = bufnr,
		is_todo = is_todo,
		path = path,
		tag = tag,
	}
end

--- 统一的状态更新函数（内部使用）
--- @param id string 链接ID
--- @param new_status string 新状态
--- @param link_type string 链接类型（"todo" 或 "code"）
--- @param link table 链接对象（可选，用于获取路径等信息）
--- @param bufnr number 缓冲区句柄（可选）
--- @param source string 事件来源
local function update_status_and_trigger(id, new_status, link_type, link, bufnr, source)
	local store, events = get_modules()

	-- 确定要更新哪个链接类型
	local update_link_type = link_type
	if link_type == "code" then
		update_link_type = "todo" -- 代码链接的状态存储在TODO链接中
	end

	-- 更新状态
	store.update_status(id, new_status, update_link_type)

	-- 构建事件数据
	local event_data = {
		source = source or "status_update",
		ids = { id },
	}

	-- 如果有链接信息，添加文件路径
	if link and link.path then
		event_data.file = link.path
	end

	-- 如果有缓冲区句柄，添加
	if bufnr then
		event_data.bufnr = bufnr
	end

	-- 触发事件
	events.on_state_changed(event_data)

	return true
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
		return false
	end

	local current_status = link_info.link.status or "normal"

	-- 检查当前状态是否可手动切换
	if not status_mod.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return false
	end

	-- 获取当前状态配置用于显示
	local current_config = status_mod.get_config(current_status)

	-- 获取下一个状态
	local next_status = status_mod.get_next_status(current_status)
	local next_config = status_mod.get_config(next_status)

	-- 使用统一更新函数
	local success = update_status_and_trigger(
		link_info.id,
		next_status,
		link_info.link_type,
		link_info.link,
		link_info.bufnr,
		"cycle_status"
	)

	if success then
		vim.notify(
			string.format(
				"状态已切换: %s%s → %s%s",
				current_config.icon,
				current_config.label,
				next_config.icon,
				next_config.label
			),
			vim.log.levels.INFO
		)
	end

	return success
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

		-- 使用统一更新函数
		update_status_and_trigger(
			link_info.id,
			choice.value,
			link_info.link_type,
			link_info.link,
			link_info.bufnr,
			"status_menu"
		)

		local chosen_config = status_mod.get_config(choice.value)
		vim.notify(string.format("已切换到: %s%s", chosen_config.icon, chosen_config.label), vim.log.levels.INFO)
	end)
end

--- 公共状态更新函数（可用于其他模块）
--- @param id string 链接ID
--- @param new_status string 新状态
--- @param link_type string 链接类型（"todo" 或 "code"）
--- @param link table 链接对象（可选）
--- @param bufnr number 缓冲区句柄（可选）
--- @param source string 事件来源（可选）
function M.update_status(id, new_status, link_type, link, bufnr, source)
	return update_status_and_trigger(id, new_status, link_type, link, bufnr, source or "external")
end

--- 获取当前链接信息（用于调试或外部模块）
--- @return table|nil
function M.get_current_link_info()
	return get_current_link_info()
end

--- 判断当前行是否有可操作的状态标记
--- @return boolean
function M.has_status_mark()
	local link_info = get_current_link_info()
	return link_info ~= nil
end

--- 获取当前任务状态
--- @return string|nil 状态名称
function M.get_current_status()
	local link_info = get_current_link_info()
	if not link_info then
		return nil
	end
	return link_info.link.status or "normal"
end

--- 获取当前任务状态配置
--- @return table|nil
function M.get_current_status_config()
	local link_info = get_current_link_info()
	if not link_info then
		return nil
	end
	local status = link_info.link.status or "normal"
	return status_mod.get_config(status)
end

return M
