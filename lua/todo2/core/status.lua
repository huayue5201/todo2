-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 核心状态管理模块（统一API）

local M = {}

local types = require("todo2.store.types")
local store = require("todo2.store")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- 状态流转规则
---------------------------------------------------------------------
local STATUS_FLOW = {
	[types.STATUS.NORMAL] = {
		next = { types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.COMPLETED },
	},
	[types.STATUS.URGENT] = {
		next = { types.STATUS.NORMAL, types.STATUS.WAITING, types.STATUS.COMPLETED },
	},
	[types.STATUS.WAITING] = {
		next = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.COMPLETED },
	},
	[types.STATUS.COMPLETED] = {
		next = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.ARCHIVED },
	},
	[types.STATUS.ARCHIVED] = {
		next = { types.STATUS.COMPLETED },
	},
}

---------------------------------------------------------------------
-- 状态查询API
---------------------------------------------------------------------
function M.is_allowed(current, target)
	local flow = STATUS_FLOW[current]
	if not flow then
		return false
	end

	for _, allowed in ipairs(flow.next) do
		if allowed == target then
			return true
		end
	end
	return false
end

function M.get_allowed(current)
	local flow = STATUS_FLOW[current]
	return (flow and flow.next) or {}
end

function M.get_next(current, include_completed)
	local order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING }
	if include_completed then
		table.insert(order, types.STATUS.COMPLETED)
	end

	for i, s in ipairs(order) do
		if current == s then
			return order[i % #order + 1]
		end
	end
	return types.STATUS.NORMAL
end

---------------------------------------------------------------------
-- 状态更新API（唯一入口）
---------------------------------------------------------------------
--- 更新任务状态
--- @param id string 任务ID
--- @param target string 目标状态
--- @param source string|nil 事件来源
--- @return boolean
function M.update(id, target, source)
	if not store or not store.link then
		return false
	end

	local link = store.link.get_todo(id, { verify_line = true })
	if not link then
		vim.notify("找不到任务: " .. id, vim.log.levels.ERROR)
		return false
	end

	-- 检查状态流转是否允许
	if not M.is_allowed(link.status, target) then
		vim.notify(string.format("不允许的状态流转: %s → %s", link.status, target), vim.log.levels.WARN)
		return false
	end

	-- 执行状态更新
	local result
	if target == types.STATUS.COMPLETED then
		result = store.link.mark_completed(id)
	elseif target == types.STATUS.ARCHIVED then
		result = store.link.mark_archived(id, source or "update")
	else
		-- 从已完成状态恢复
		if types.is_completed_status(link.status) then
			store.link.reopen_link(id)
		end
		result = store.link.update_active_status(id, target)
	end

	local success = result ~= nil

	if success and events then
		events.on_state_changed({
			source = source or "status_update",
			ids = { id },
			timestamp = os.time() * 1000,
		})
	end

	return success
end

--- 循环切换状态（用于UI）
function M.cycle(id, include_completed)
	local link = store.link.get_todo(id, { verify_line = true })
	if not link then
		return false
	end

	local next_status = M.get_next(link.status, include_completed)
	return M.update(id, next_status, "cycle")
end

---------------------------------------------------------------------
-- 快捷查询
---------------------------------------------------------------------
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

	if not id or not store or not store.link then
		return nil
	end

	local link = (link_type == "todo") and store.link.get_todo(id, { verify_line = true })
		or store.link.get_code(id, { verify_line = true })

	return link and {
		id = id,
		type = link_type,
		link = link,
		bufnr = bufnr,
		path = path,
		tag = tag,
	} or nil
end

return M
