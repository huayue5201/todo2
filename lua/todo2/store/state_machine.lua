-- lua/todo2/store/state_machine.lua
--- @module todo2.store.state_machine
--- 简化状态机

local M = {}

local types = require("todo2.store.types")

--- 更新链接状态
function M.update_link_status(link, new_status)
	if not link or not link.id then
		return nil
	end

	local old_status = link.status or types.STATUS.NORMAL

	-- 更新状态
	link.status = new_status
	link.updated_at = os.time()
	link.sync_version = (link.sync_version or 0) + 1

	-- 处理完成状态
	if new_status == types.STATUS.COMPLETED then
		link.completed_at = link.completed_at or os.time()
		link.previous_status = old_status
	elseif old_status == types.STATUS.COMPLETED then
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

--- 验证状态转换是否允许（总是允许）
function M.is_transition_allowed(from_status, to_status)
	return true
end

return M
