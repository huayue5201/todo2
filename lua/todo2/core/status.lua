-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 核心状态管理模块（适配新版store，保持API不变）

local M = {}

local module = require("todo2.module")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 模块缓存
---------------------------------------------------------------------
local store_module, state_machine_module, events_module

local function get_modules()
	if not store_module then
		store_module = module.get("store")
	end
	if not state_machine_module then
		state_machine_module = module.get("store.state_machine")
	end
	if not events_module then
		events_module = module.get("core.events")
	end
	return store_module, state_machine_module, events_module
end

---------------------------------------------------------------------
-- 核心状态更新函数（适配新版store）
---------------------------------------------------------------------

--- 更新状态（适配新版store的双向同步）
--- @param id string 链接ID
--- @param new_status string 新状态
--- @param link_type string|nil 链接类型，nil表示双向同步
--- @param source string 事件来源
--- @return boolean 是否成功
function M.update_status(id, new_status, link_type, source)
	local store, state_machine, events = get_modules()

	if not store or not store.link then
		vim.notify("无法获取存储模块", vim.log.levels.ERROR)
		return false
	end

	-- 验证状态值
	local valid_statuses = {
		[types.STATUS.NORMAL] = true,
		[types.STATUS.URGENT] = true,
		[types.STATUS.WAITING] = true,
		[types.STATUS.COMPLETED] = true,
		[types.STATUS.ARCHIVED] = true,
	}

	if not valid_statuses[new_status] then
		vim.notify("无效的状态: " .. new_status, vim.log.levels.ERROR)
		return false
	end

	-- 如果state_machine模块可用，验证状态流转
	if state_machine then
		-- 获取当前链接状态
		local current_link
		if not link_type or link_type == "todo" then
			current_link = store.link.get_todo(id, { verify_line = true })
		end

		if not current_link and (not link_type or link_type == "code") then
			current_link = store.link.get_code(id, { verify_line = true })
		end

		if current_link then
			local current_status = current_link.status or types.STATUS.NORMAL
			if not state_machine.is_transition_allowed(current_status, new_status) then
				vim.notify(
					string.format("不允许的状态流转: %s -> %s", current_status, new_status),
					vim.log.levels.WARN
				)
				return false
			end
		end
	end

	-- ⭐ 使用 store.link.update_status（它内部会调用 state_machine）
	local success = store.link.update_status(id, new_status, link_type)

	if success and events then
		events.on_state_changed({
			source = source or "status_update",
			ids = { id },
			timestamp = os.time() * 1000,
		})
	end

	return success
end

---------------------------------------------------------------------
-- 状态流转验证（委托给 store.state_machine）
---------------------------------------------------------------------

function M.is_valid_transition(current_status, target_status)
	local _, state_machine = get_modules()
	if state_machine and state_machine.is_transition_allowed then
		return state_machine.is_transition_allowed(current_status, target_status)
	end

	-- 兼容旧逻辑
	local valid_statuses = {
		[types.STATUS.NORMAL] = true,
		[types.STATUS.URGENT] = true,
		[types.STATUS.WAITING] = true,
		[types.STATUS.COMPLETED] = true,
	}
	return valid_statuses[target_status] == true
end

function M.get_available_transitions(current_status)
	local _, state_machine = get_modules()
	if state_machine and state_machine.get_available_transitions then
		return state_machine.get_available_transitions(current_status)
	end

	-- 默认返回活跃状态
	return { "normal", "urgent", "waiting" }
end

function M.is_user_switchable(status)
	local _, state_machine = get_modules()
	if state_machine and state_machine.is_user_switchable then
		return state_machine.is_user_switchable(status)
	end

	-- 默认逻辑：已完成状态不能手动切换
	return status ~= types.STATUS.COMPLETED and status ~= types.STATUS.ARCHIVED
end

---------------------------------------------------------------------
-- 状态流转顺序（兼容现有调用）
---------------------------------------------------------------------

function M.get_next_status(current_status, include_completed)
	local _, state_machine = get_modules()
	if state_machine and state_machine.get_next_user_status then
		return state_machine.get_next_user_status(current_status, include_completed or false)
	end

	-- 兼容旧逻辑
	if include_completed then
		local order = { "normal", "urgent", "waiting", "completed" }
		for i, status in ipairs(order) do
			if current_status == status then
				return order[i % #order + 1]
			end
		end
	else
		local order = { "normal", "urgent", "waiting" }
		for i, status in ipairs(order) do
			if current_status == status then
				return order[i % #order + 1]
			end
		end
	end

	return "normal"
end

---------------------------------------------------------------------
-- 链接信息获取（增强错误处理）
---------------------------------------------------------------------

--- 获取当前行的链接信息（不含UI逻辑）
--- @return table|nil
function M.get_current_link_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.fn.getline(".")
	local path = vim.api.nvim_buf_get_name(bufnr)

	-- 解析链接ID
	local id, link_type, tag
	local tag, tag_id = line:match("(%u+):ref:(%w+)")
	if tag_id then
		id = tag_id
		link_type = "code"
	else
		id = line:match("{#(%w+)}")
		link_type = "todo"
	end

	if not id then
		return nil
	end

	-- 获取存储模块
	local store, _ = get_modules()
	if not store or not store.link then
		vim.notify("无法获取存储模块", vim.log.levels.WARN)
		return nil
	end

	local link
	if link_type == "todo" then
		link = store.link.get_todo(id, { verify_line = true })
	else
		link = store.link.get_code(id, { verify_line = true })
	end

	if not link then
		return nil
	end

	return {
		id = id,
		link_type = link_type,
		link = link,
		bufnr = bufnr,
		path = path,
		tag = tag,
	}
end

return M
