--- File: /Users/lijia/todo2/lua/todo2/core/status.lua ---
-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 核心状态管理模块（移除 completed 字段）

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
-- 统一状态流转函数（推荐使用）
---------------------------------------------------------------------
--- 智能状态流转（统一入口）
--- @param id string 链接ID
--- @param target_status string 目标状态
--- @param source string 事件来源
--- @return boolean 是否成功
function M.transition_status(id, target_status, source)
	local store, state_machine, events = get_modules()
	if not store or not store.link then
		return false
	end

	-- 获取当前状态
	local todo_link = store.link.get_todo(id, { verify_line = true })
	if not todo_link then
		vim.notify("找不到链接: " .. id, vim.log.levels.ERROR)
		return false
	end

	local current_status = todo_link.status

	-- 检查流转是否允许
	if state_machine and not state_machine.is_transition_allowed(current_status, target_status) then
		vim.notify(
			string.format("不允许的状态流转: %s → %s", current_status, target_status),
			vim.log.levels.WARN
		)
		return false
	end

	local result = nil

	-- 根据目标状态调用相应的存储函数
	if target_status == types.STATUS.COMPLETED then
		result = store.link.mark_completed(id)
	elseif target_status == types.STATUS.ARCHIVED then
		result = store.link.mark_archived(id, source or "transition")
	elseif types.is_active_status(target_status) then
		-- 如果是活跃状态，需要先确保任务处于活跃状态
		if types.is_completed_status(current_status) then
			-- 先重新打开
			local reopened = store.link.reopen_link(id)
			if reopened then
				-- 再设置活跃状态（如果目标状态不是重新打开后的默认状态）
				local reopened_link = store.link.get_todo(id, { verify_line = true })
				if reopened_link and reopened_link.status ~= target_status then
					result = store.link.update_active_status(id, target_status)
				else
					result = reopened
				end
			end
		else
			-- 直接设置活跃状态
			result = store.link.update_active_status(id, target_status)
		end
	end

	local success = result ~= nil

	if success and events then
		events.on_state_changed({
			source = source or "transition",
			ids = { id },
			timestamp = os.time() * 1000,
		})
	end

	return success
end

---------------------------------------------------------------------
-- 更新活跃状态（两端同时更新）
---------------------------------------------------------------------
function M.update_active_status(id, new_status, source)
	local store, state_machine, events = get_modules()

	if not store or not store.link then
		vim.notify("无法获取存储模块", vim.log.levels.ERROR)
		return false
	end

	-- 验证状态值
	if not types.is_active_status(new_status) then
		vim.notify("活跃状态只能是: normal, urgent 或 waiting", vim.log.levels.ERROR)
		return false
	end

	-- 获取链接
	local todo_link = store.link.get_todo(id, { verify_line = true })
	if not todo_link then
		vim.notify("找不到链接: " .. id, vim.log.levels.ERROR)
		return false
	end

	-- 如果任务是完成状态，自动重新打开
	if types.is_completed_status(todo_link.status) then
		vim.notify("检测到已完成任务，自动重新打开...", vim.log.levels.INFO)
		local reopened = store.link.reopen_link(id)
		if not reopened then
			return false
		end
		-- 重新打开后，再设置活跃状态
		return M.update_active_status(id, new_status, source)
	end

	-- 验证状态流转
	if state_machine and not state_machine.is_transition_allowed(todo_link.status, new_status) then
		vim.notify(
			string.format("不允许的状态流转: %s -> %s", todo_link.status, new_status),
			vim.log.levels.WARN
		)
		return false
	end

	-- 更新活跃状态
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
	if state_machine then
		return state_machine.is_transition_allowed(current_status, target_status)
	end
	-- 回退逻辑
	return true
end

function M.get_available_transitions(current_status)
	local _, state_machine = get_modules()
	if state_machine then
		return state_machine.get_available_transitions(current_status)
	end
	-- 回退逻辑
	if types.is_completed_status(current_status) then
		return { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.ARCHIVED }
	elseif current_status == types.STATUS.ARCHIVED then
		return { types.STATUS.COMPLETED }
	else
		return { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.COMPLETED }
	end
end

function M.get_next_status(current_status, include_completed)
	local _, state_machine = get_modules()
	if state_machine then
		if include_completed then
			-- 如果需要完成状态，可以简单返回状态机中的某个状态，这里简化
			local order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.COMPLETED }
			for i, s in ipairs(order) do
				if current_status == s then
					return order[i % #order + 1]
				end
			end
			return types.STATUS.NORMAL
		else
			return state_machine.get_next_user_status(current_status)
		end
	end
	-- 回退逻辑
	local order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING }
	for i, s in ipairs(order) do
		if current_status == s then
			return order[i % #order + 1]
		end
	end
	return types.STATUS.NORMAL
end

function M.is_user_switchable(status)
	return types.is_active_status(status)
end

---------------------------------------------------------------------
-- 链接信息获取
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 任务操作判断
---------------------------------------------------------------------
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

	if types.is_active_status(todo_link.status) then
		-- 未完成任务
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
	elseif types.is_completed_status(todo_link.status) then
		-- 已完成任务
		actions.type = "completed"
		actions.can_complete = false
		actions.can_reopen = true

		if todo_link.status == types.STATUS.ARCHIVED then
			-- 已归档
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

function M.is_task_completed(task_id)
	local store, _, _ = get_modules()
	if not store or not store.link then
		return false
	end
	return store.link.is_completed(task_id)
end

function M.is_task_archived(task_id)
	local store, _, _ = get_modules()
	if not store or not store.link then
		return false
	end
	return store.link.is_archived(task_id)
end

---------------------------------------------------------------------
-- 向后兼容函数（适配新数据模型）
---------------------------------------------------------------------
function M.update_status(id, new_status, source)
	return M.transition_status(id, new_status, source)
end

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
