-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 核心状态管理模块（移除 completed 字段）

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local types = require("todo2.store.types")
local store = require("todo2.store")
local state_machine = require("todo2.store.state_machine")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- 统一状态流转函数（推荐使用）
---------------------------------------------------------------------
--- 智能状态流转（统一入口）
--- @param id string 链接ID
--- @param target_status string 目标状态
--- @param source string 事件来源
--- @return boolean 是否成功
function M.transition_status(id, target_status, source)
	if not store or not store.link then
		return false
	end

	local todo_link = store.link.get_todo(id, { verify_line = true })
	if not todo_link then
		vim.notify("找不到链接: " .. id, vim.log.levels.ERROR)
		return false
	end

	local current_status = todo_link.status

	if state_machine and not state_machine.is_transition_allowed(current_status, target_status) then
		vim.notify(
			string.format("不允许的状态流转: %s → %s", current_status, target_status),
			vim.log.levels.WARN
		)
		return false
	end

	local result = nil

	if target_status == types.STATUS.COMPLETED then
		result = store.link.mark_completed(id)
	elseif target_status == types.STATUS.ARCHIVED then
		result = store.link.mark_archived(id, source or "transition")
	elseif types.is_active_status(target_status) then
		if types.is_completed_status(current_status) then
			local reopened = store.link.reopen_link(id)
			if reopened then
				local reopened_link = store.link.get_todo(id, { verify_line = true })
				if reopened_link and reopened_link.status ~= target_status then
					result = store.link.update_active_status(id, target_status)
				else
					result = reopened
				end
			end
		else
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
	if not store or not store.link then
		vim.notify("无法获取存储模块", vim.log.levels.ERROR)
		return false
	end

	if not types.is_active_status(new_status) then
		vim.notify("活跃状态只能是: normal, urgent 或 waiting", vim.log.levels.ERROR)
		return false
	end

	local todo_link = store.link.get_todo(id, { verify_line = true })
	if not todo_link then
		vim.notify("找不到链接: " .. id, vim.log.levels.ERROR)
		return false
	end

	if types.is_completed_status(todo_link.status) then
		vim.notify("检测到已完成任务，自动重新打开...", vim.log.levels.INFO)
		local reopened = store.link.reopen_link(id)
		if not reopened then
			return false
		end
		return M.update_active_status(id, new_status, source)
	end

	if state_machine and not state_machine.is_transition_allowed(todo_link.status, new_status) then
		vim.notify(
			string.format("不允许的状态流转: %s -> %s", todo_link.status, new_status),
			vim.log.levels.WARN
		)
		return false
	end

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
	if state_machine then
		return state_machine.is_transition_allowed(current_status, target_status)
	end
	return true
end

function M.get_available_transitions(current_status)
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

--- 获取下一个状态（包含完成状态选项）
function M.get_next_status(current_status, include_completed)
	if state_machine then
		if include_completed then
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
	local order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING }
	for i, s in ipairs(order) do
		if current_status == s then
			return order[i % #order + 1]
		end
	end
	return types.STATUS.NORMAL
end

--- ⭐ 新增：获取下一个用户可手动切换的状态（不包含完成状态）
--- 为保持 API 兼容，简单封装 get_next_status
function M.get_next_user_status(current_status)
	return M.get_next_status(current_status, false)
end

function M.is_user_switchable(status)
	return types.is_active_status(status)
end

---------------------------------------------------------------------
-- 链接信息获取
---------------------------------------------------------------------
--- 修复：重复定义局部变量 bug
function M.get_current_link_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.fn.getline(".")
	local path = vim.api.nvim_buf_get_name(bufnr)

	local id, link_type
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
		tag = tag, -- 代码标记中的标签，可能为 nil
	}
end

---------------------------------------------------------------------
-- 任务操作判断
---------------------------------------------------------------------
function M.get_available_actions(task_id)
	if not store or not store.link then
		return {}
	end

	local todo_link = store.link.get_todo(task_id)
	if not todo_link then
		return {}
	end

	local actions = {}

	if types.is_active_status(todo_link.status) then
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
		actions.type = "completed"
		actions.can_complete = false
		actions.can_reopen = true -- reopen_link 对归档也有效（变为 completed）

		if todo_link.status == types.STATUS.ARCHIVED then
			actions.archived = true
			actions.archived_at = todo_link.archived_at
			actions.can_archive = false
			actions.can_unarchive = true -- 专门取消归档（archived -> completed）
		else
			actions.archived = false
			actions.can_archive = true -- completed -> archived
			actions.can_unarchive = false
		end
	end

	return actions
end

function M.is_task_completed(task_id)
	if not store or not store.link then
		return false
	end
	return store.link.is_completed(task_id)
end

function M.is_task_archived(task_id)
	if not store or not store.link then
		return false
	end
	return store.link.is_archived(task_id)
end

return M
