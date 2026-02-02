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
-- 导入类型模块
---------------------------------------------------------------------
local types = require("todo2.store.types")

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
	local store, events = get_modules() -- ✅ 获取存储和事件模块

	-- ⭐ 关键修复：同时更新两种链接类型
	store.update_status(id, new_status, "todo")
	store.update_status(id, new_status, "code")

	-- ⭐ 强制清除统一缓存
	local cache = require("todo2.cache")
	cache.clear_on_status_change(id)

	-- ⭐ 使用改进的事件系统，避免循环
	if events then
		-- 构建事件数据
		local event_data = {
			source = source or "status_update",
			ids = { id },
			timestamp = os.time() * 1000, -- ⭐ 添加毫秒级时间戳
		}

		-- 如果有链接信息，添加文件路径
		if link and link.path then
			event_data.file = link.path
		end

		-- 如果有缓冲区句柄，添加
		if bufnr then
			event_data.bufnr = bufnr
		end

		-- 立即触发事件
		events.on_state_changed(event_data)
	end

	return true
end
---------------------------------------------------------------------
-- 状态流转验证
---------------------------------------------------------------------

--- 检查状态是否可以从当前状态切换到目标状态
--- @param current_status string 当前状态
--- @param target_status string 目标状态
--- @return boolean 是否可以切换
function M.is_valid_transition(current_status, target_status)
	if current_status == target_status then
		return true
	end

	-- 完成状态与其他状态互斥
	if current_status == types.STATUS.COMPLETED then
		-- 完成状态可以切换到任何活跃状态
		return target_status == types.STATUS.NORMAL
			or target_status == types.STATUS.URGENT
			or target_status == types.STATUS.WAITING
	end

	if target_status == types.STATUS.COMPLETED then
		-- 任何活跃状态都可以切换到完成状态
		return current_status == types.STATUS.NORMAL
			or current_status == types.STATUS.URGENT
			or current_status == types.STATUS.WAITING
	end

	-- 活跃状态之间可以自由切换
	return true
end

--- 获取可用的状态流转列表
--- @param current_status string 当前状态
--- @return table 可用状态列表
function M.get_available_transitions(current_status)
	local available = {}

	if current_status == types.STATUS.COMPLETED then
		-- 完成状态只能切换到活跃状态
		table.insert(available, types.STATUS.NORMAL)
		table.insert(available, types.STATUS.URGENT)
		table.insert(available, types.STATUS.WAITING)
	else
		-- 活跃状态可以切换到其他活跃状态或完成状态
		if current_status ~= types.STATUS.NORMAL then
			table.insert(available, types.STATUS.NORMAL)
		end
		if current_status ~= types.STATUS.URGENT then
			table.insert(available, types.STATUS.URGENT)
		end
		if current_status ~= types.STATUS.WAITING then
			table.insert(available, types.STATUS.WAITING)
		end
		table.insert(available, types.STATUS.COMPLETED)
	end

	return available
end

--- 检查状态是否可手动切换
--- @param status string 状态
--- @return boolean
function M.is_user_switchable(status)
	-- 活跃状态可以手动切换，完成状态不能
	return status == types.STATUS.NORMAL or status == types.STATUS.URGENT or status == types.STATUS.WAITING
end

--- 获取下一个状态（用于循环切换）
--- @param current_status string 当前状态
--- @return string 下一个状态
function M.get_next_status(current_status)
	if current_status == types.STATUS.NORMAL then
		return types.STATUS.URGENT
	elseif current_status == types.STATUS.URGENT then
		return types.STATUS.WAITING
	elseif current_status == types.STATUS.WAITING then
		return types.STATUS.NORMAL
	else
		return types.STATUS.NORMAL
	end
end

--- 获取状态循环顺序
--- @return table 状态循环顺序数组
function M.get_cycle_order()
	return {
		types.STATUS.NORMAL,
		types.STATUS.URGENT,
		types.STATUS.WAITING,
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
		return false
	end

	local current_status = link_info.link.status or types.STATUS.NORMAL

	-- 检查当前状态是否可手动切换
	if not M.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return false
	end

	-- 获取当前状态配置用于显示
	local current_config = status_mod.get_config(current_status)

	-- 获取下一个状态
	local next_status = M.get_next_status(current_status)
	local next_config = status_mod.get_config(next_status)

	-- ❌ 删除这一行（调试函数调用）
	-- debug_status_change(link_info.id, current_status, next_status, "cycle_status")

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

--- 显示状态选择菜单（显示所有可用状态）
function M.show_status_menu()
	local link_info = get_current_link_info()
	if not link_info then
		vim.notify("当前行没有找到链接标记", vim.log.levels.WARN)
		return
	end

	local current_status = link_info.link.status or types.STATUS.NORMAL

	-- 检查当前状态是否可手动切换
	if not M.is_user_switchable(current_status) then
		vim.notify("已完成的任务不能手动切换状态", vim.log.levels.WARN)
		return
	end

	-- 获取可用的状态流转列表
	local available_transitions = M.get_available_transitions(current_status)

	if #available_transitions == 0 then
		vim.notify("没有可用的状态切换选项", vim.log.levels.INFO)
		return
	end

	-- 构建菜单项
	local items = {}
	for _, status in ipairs(available_transitions) do
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

		-- 验证状态流转是否合法
		if not M.is_valid_transition(current_status, choice.value) then
			vim.notify("无效的状态流转", vim.log.levels.ERROR)
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
	return link_info.link.status or types.STATUS.NORMAL
end

--- 获取当前任务状态配置
--- @return table|nil
function M.get_current_status_config()
	local link_info = get_current_link_info()
	if not link_info then
		return nil
	end
	local status = link_info.link.status or types.STATUS.NORMAL
	return status_mod.get_config(status)
end

--- 获取状态配置（包装器）
--- @param status string
--- @return table
function M.get_config(status)
	return status_mod.get_config(status)
end

return M
