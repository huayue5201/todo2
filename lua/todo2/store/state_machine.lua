-- lua/todo2/store/state_machine.lua
--- @module todo2.store.state_machine
--- 修复状态机

local M = {}

local types = require("todo2.store.types")

--- 更新链接状态（修复完成时间处理）
function M.update_link_status(link, new_status)
	if not link or not link.id then
		return nil
	end

	local old_status = link.status or types.STATUS.NORMAL

	-- 更新状态
	link.status = new_status
	link.updated_at = os.time()
	link.sync_version = (link.sync_version or 0) + 1

	-- 正确处理完成状态
	if new_status == types.STATUS.COMPLETED then
		link.completed_at = link.completed_at or os.time()
		link.previous_status = old_status
	elseif old_status == types.STATUS.COMPLETED and new_status ~= old_status then
		-- ⭐ 修复：只有当从"已完成"状态真正变为其他状态时，才清空完成时间
		link.completed_at = nil
	end

	return link
end

--- 获取状态显示信息
function M.get_status_display_info(status)
	local info = {
		[types.STATUS.NORMAL] = {
			name = "正常",
			icon = "○",
			color = "Normal",
		},
		[types.STATUS.URGENT] = {
			name = "紧急",
			icon = "⚠",
			color = "Error",
		},
		[types.STATUS.WAITING] = {
			name = "等待",
			icon = "⌛",
			color = "WarningMsg",
		},
		[types.STATUS.COMPLETED] = {
			name = "完成",
			icon = "✓",
			color = "Comment",
		},
	}

	return info[status] or info[types.STATUS.NORMAL]
end

--- 验证状态转换是否允许
function M.is_transition_allowed(from_status, to_status)
	-- 总是允许转换（由业务逻辑控制具体限制）
	return true
end

--- 归档链接（新增）
--- @param link table 链接对象
--- @param reason string 归档原因
--- @return table 归档后的链接
function M.archive_link(link, reason)
	if not link or not link.id then
		return nil
	end

	local now = os.time()

	-- 只设置归档字段，不修改状态字段
	link.archived_at = now
	link.archived_reason = reason or "manual"
	link.updated_at = now

	return link
end

--- 检查是否已归档
--- @param link table 链接对象
--- @return boolean 是否已归档
function M.is_archived(link)
	return link and link.archived_at ~= nil
end

--- 获取归档信息
--- @param link table 链接对象
--- @return table|nil 归档信息
function M.get_archive_info(link)
	if not link or not link.archived_at then
		return nil
	end

	return {
		archived_at = link.archived_at,
		archived_reason = link.archived_reason,
		days_since_archive = os.difftime(os.time(), link.archived_at) / 86400,
	}
end

return M
