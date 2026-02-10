-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 核心状态管理模块（适配原子性操作）

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
-- 更新活跃状态（两端同时更新）
---------------------------------------------------------------------

--- 更新活跃状态
--- @param id string 链接ID
--- @param new_status string 新状态，必须是 normal/urgent/waiting
--- @param source string 事件来源
--- @return boolean 是否成功
function M.update_active_status(id, new_status, source)
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
	}

	if not valid_statuses[new_status] then
		vim.notify("活跃状态只能是: normal, urgent 或 waiting", vim.log.levels.ERROR)
		return false
	end

	-- 获取链接以检查是否已完成
	-- 注意：现在两端都必须存在，所以获取一端即可
	local todo_link = store.link.get_todo(id, { verify_line = true })
	local code_link = store.link.get_code(id, { verify_line = true })

	-- 检查链接对完整性
	if not todo_link and not code_link then
		vim.notify("找不到链接: " .. id, vim.log.levels.ERROR)
		return false
	end

	-- 使用TODO链接作为检查依据（如果存在）
	local check_link = todo_link or code_link

	-- 检查任务是否已完成（已完成的任务不能设置活跃状态）
	if check_link and check_link.completed then
		vim.notify("已完成的任务不能设置活跃状态", vim.log.levels.WARN)
		return false
	end

	-- 如果state_machine模块可用，验证状态流转
	if state_machine and state_machine.is_transition_allowed then
		local current_status = check_link and check_link.status or types.STATUS.NORMAL
		if not state_machine.is_transition_allowed(current_status, new_status) then
			vim.notify(
				string.format("不允许的状态流转: %s -> %s", current_status, new_status),
				vim.log.levels.WARN
			)
			return false
		end
	end

	-- 更新活跃状态（两端同时更新）
	local result = store.link.update_active_status(id, new_status)
	local success = result ~= nil

	if success and events then
		events.on_state_changed({
			source = source or "active_status_update",
			ids = { id },
			timestamp = os.time() * 1000,
		})
	end

	return success
end

---------------------------------------------------------------------
-- 状态流转验证
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
		[types.STATUS.COMPLETED] = true, -- 可以从活跃状态到完成
	}
	return valid_statuses[target_status] == true
end

function M.get_available_transitions(current_status)
	local _, state_machine = get_modules()
	if state_machine and state_machine.get_available_transitions then
		return state_machine.get_available_transitions(current_status)
	end

	-- 默认返回活跃状态和完成状态
	if current_status == types.STATUS.COMPLETED then
		-- 已完成可以重新打开为活跃状态
		return { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING }
	else
		-- 活跃状态可以切换到其他活跃状态或完成
		return { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.COMPLETED }
	end
end

--- 获取下一个状态
--- @param current_status string 当前状态
--- @param include_completed boolean 是否包含完成状态
--- @return string 下一个状态
function M.get_next_status(current_status, include_completed)
	local _, state_machine = get_modules()
	if state_machine and state_machine.get_next_user_status then
		return state_machine.get_next_user_status(current_status)
	end

	-- 兼容旧逻辑
	local order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING }

	if include_completed then
		-- 如果包含完成状态，则在循环中加入完成状态
		order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.COMPLETED }
	end

	for i, status in ipairs(order) do
		if current_status == status then
			return order[i % #order + 1]
		end
	end
	return types.STATUS.NORMAL
end

--- 检查状态是否可手动切换
--- @param status string 状态
--- @return boolean
function M.is_user_switchable(status)
	local _, state_machine = get_modules()
	if state_machine and state_machine.is_active_status then
		return state_machine.is_active_status(status)
	end

	-- 默认逻辑：只有活跃状态可以手动切换
	return status == types.STATUS.NORMAL or status == types.STATUS.URGENT or status == types.STATUS.WAITING
end

---------------------------------------------------------------------
-- 链接信息获取
---------------------------------------------------------------------

--- 获取当前行的链接信息
--- @return table|nil 链接信息
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
		link_type = link_type, -- 保留link_type供UI使用
		link = link,
		bufnr = bufnr,
		path = path,
		tag = tag,
	}
end

---------------------------------------------------------------------
-- 任务操作判断
---------------------------------------------------------------------

--- 获取任务可用的操作
--- @param task_id string 任务ID
--- @return table 可用操作信息
function M.get_available_actions(task_id)
	local store, _, _ = get_modules()

	if not store or not store.link then
		return {}
	end

	local todo_link = store.link.get_todo(task_id)
	if not todo_link then
		return {}
	end

	local actions = {}

	if not todo_link.completed then
		-- 未完成任务：可以切换活跃状态
		actions.type = "active"
		actions.current_status = todo_link.status
		actions.available_statuses = {
			types.STATUS.NORMAL,
			types.STATUS.URGENT,
			types.STATUS.WAITING,
		}
		actions.can_complete = true
		actions.can_archive = false
		actions.can_reopen = false
		actions.can_unarchive = false
	else
		-- 已完成任务
		actions.type = "completed"
		actions.can_complete = false
		actions.can_reopen = true

		if todo_link.archived then
			-- 已归档任务
			actions.archived = true
			actions.archived_at = todo_link.archived_at
			actions.can_archive = false
			actions.can_unarchive = true
		else
			-- 已完成但未归档
			actions.archived = false
			actions.can_archive = true
			actions.can_unarchive = false
		end
	end

	return actions
end

--- 检查任务是否已完成
--- @param task_id string 任务ID
--- @return boolean 是否完成
function M.is_task_completed(task_id)
	local store, _, _ = get_modules()
	if not store or not store.link then
		return false
	end

	-- 使用新的原子性检查函数
	return store.link.is_completed(task_id)
end

--- 检查任务是否已归档
--- @param task_id string 任务ID
--- @return boolean 是否归档
function M.is_task_archived(task_id)
	local store, _, _ = get_modules()
	if not store or not store.link then
		return false
	end

	-- 使用新的原子性检查函数
	return store.link.is_archived(task_id)
end

---------------------------------------------------------------------
-- 向后兼容函数（适配原子性操作）
---------------------------------------------------------------------

--- 更新状态（兼容旧接口，但内部使用原子性操作）
--- @param id string 链接ID
--- @param new_status string 新状态
--- @param source string 事件来源
--- @return boolean 是否成功
function M.update_status(id, new_status, source)
	local store, _, events = get_modules()

	if not store or not store.link then
		return false
	end

	local result
	local success = false

	-- 根据状态类型调用相应的原子性操作
	if new_status == types.STATUS.COMPLETED then
		result = store.link.mark_completed(id)
	elseif new_status == types.STATUS.ARCHIVED then
		result = store.link.mark_archived(id, "compat")
	elseif
		new_status == types.STATUS.NORMAL
		or new_status == types.STATUS.URGENT
		or new_status == types.STATUS.WAITING
	then
		-- 活跃状态更新
		result = store.link.update_active_status(id, new_status)
	else
		vim.notify("无效的状态: " .. new_status, vim.log.levels.ERROR)
		return false
	end

	success = result ~= nil

	if success and events then
		events.on_state_changed({
			source = source or "status_update",
			ids = { id },
			timestamp = os.time() * 1000,
		})
	end

	return success
end

--- 重新打开任务（适配原子性操作）
--- @param id string 链接ID
--- @param source string 事件来源
--- @return boolean 是否成功
function M.restore_previous_status(id, source)
	local store, _, events = get_modules()

	if not store or not store.link then
		return false
	end

	local result = store.link.reopen_link(id)
	local success = result ~= nil

	if success and events then
		events.on_state_changed({
			source = source or "restore_previous_status",
			ids = { id },
			timestamp = os.time() * 1000,
		})
	end

	return success
end

return M
