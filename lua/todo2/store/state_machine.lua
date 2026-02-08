-- lua/todo2/store/state_machine.lua
--- @module todo2.store.state_machine
--- 修复状态机（添加归档状态流转和兼容函数）

local M = {}

local types = require("todo2.store.types")

--- 状态流转规则
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
		next = { types.STATUS.ARCHIVED, types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING },
	},
	[types.STATUS.ARCHIVED] = {
		next = { types.STATUS.COMPLETED }, -- 归档只能回到完成状态
	},
}

--- 验证状态流转是否允许
--- @param from_status string 当前状态
--- @param to_status string 目标状态
--- @return boolean 是否允许
function M.is_transition_allowed(from_status, to_status)
	if not from_status or not to_status then
		return false
	end

	if from_status == to_status then
		return true
	end

	local flow = STATUS_FLOW[from_status]
	if not flow then
		return false
	end

	-- 检查目标状态是否在允许的流转列表中
	for _, allowed_status in ipairs(flow.next) do
		if allowed_status == to_status then
			return true
		end
	end

	return false
end

--- 获取从当前状态可以流转到的状态列表
--- @param current_status string 当前状态
--- @return table 可流转到的状态列表
function M.get_available_transitions(current_status)
	local flow = STATUS_FLOW[current_status]
	if not flow then
		return {}
	end
	return flow.next
end

--- 获取用户可切换的下一个状态（不包含归档和完成）
--- @param current_status string 当前状态
--- @param include_completed boolean 是否包含完成状态
--- @return string 下一个状态
function M.get_next_user_status(current_status, include_completed)
	local order
	if include_completed then
		order = {
			types.STATUS.NORMAL,
			types.STATUS.URGENT,
			types.STATUS.WAITING,
			types.STATUS.COMPLETED,
		}
	else
		order = {
			types.STATUS.NORMAL,
			types.STATUS.URGENT,
			types.STATUS.WAITING,
		}
	end

	for i, status in ipairs(order) do
		if current_status == status then
			return order[i % #order + 1]
		end
	end
	return types.STATUS.NORMAL
end

--- 判断状态是否可手动切换（排除归档）
--- @param status string 状态
--- @return boolean
function M.is_user_switchable(status)
	return status ~= types.STATUS.ARCHIVED
end

--- 更新链接状态（修复完成时间处理）
function M.update_link_status(link, new_status)
	if not link or not link.id then
		return nil
	end

	local old_status = link.status or types.STATUS.NORMAL

	-- 检查链接是否活跃（未被软删除）
	if link.active == false then
		-- 返回nil但不抛出错误，让调用者决定如何处理
		return nil
	end

	-- 验证状态流转
	if not M.is_transition_allowed(old_status, new_status) then
		vim.notify(string.format("不允许的状态流转: %s -> %s", old_status, new_status), vim.log.levels.WARN)
		return nil
	end

	-- ⭐ 修复：在状态变更前保存 previous_status
	-- 只有当旧状态不是完成状态时，才保存为 previous_status
	-- 这样我们可以记住"上一次的非完成状态"
	if old_status ~= types.STATUS.COMPLETED and old_status ~= types.STATUS.ARCHIVED then
		link.previous_status = old_status
	end

	-- 更新状态
	link.status = new_status
	link.updated_at = os.time()
	link.sync_version = (link.sync_version or 0) + 1

	-- 正确处理完成状态
	if new_status == types.STATUS.COMPLETED then
		link.completed_at = link.completed_at or os.time()
		-- ⭐ 注意：这里不设置 previous_status，因为上面已经设置了
	elseif old_status == types.STATUS.COMPLETED and new_status ~= types.STATUS.COMPLETED then
		-- ⭐ 修复：从完成状态恢复到之前的状态时，不清空 previous_status
		link.completed_at = nil
		-- 使用保存的 previous_status，如果没有则使用 NORMAL
		if not link.previous_status then
			link.previous_status = types.STATUS.NORMAL
		end
	end

	-- 处理归档状态
	if new_status == types.STATUS.ARCHIVED then
		link.archived_at = os.time()
		link.archived_reason = link.archived_reason or "manual"
		-- 归档时必须是完成状态
		if old_status ~= types.STATUS.COMPLETED then
			link.status = types.STATUS.COMPLETED
			link.completed_at = link.completed_at or os.time()
		end
	elseif old_status == types.STATUS.ARCHIVED and new_status ~= types.STATUS.ARCHIVED then
		link.archived_at = nil
		link.archived_reason = nil
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
		[types.STATUS.ARCHIVED] = {
			name = "归档",
			icon = "📁",
			color = "NonText",
		},
	}

	return info[status] or info[types.STATUS.NORMAL]
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

--- 检查链接是否活跃（未被软删除）
--- @param link table 链接对象
--- @return boolean
function M.is_link_active(link)
	if not link then
		return false
	end

	-- 如果active字段不存在，默认为true（向后兼容）
	if link.active == nil then
		return true
	end

	return link.active
end

--- 获取链接的生命周期信息
--- @param link table 链接对象
--- @return table 生命周期信息
function M.get_lifecycle_info(link)
	if not link then
		return {}
	end

	local now = os.time()
	local info = {
		active = M.is_link_active(link),
		age_days = math.floor((now - (link.created_at or now)) / 86400),
		updated_days = math.floor((now - (link.updated_at or now)) / 86400),
		status_duration_days = 0,
	}

	-- 计算当前状态的持续时间
	if link.status_updated_at then
		info.status_duration_days = math.floor((now - link.status_updated_at) / 86400)
	elseif link.updated_at then
		info.status_duration_days = math.floor((now - link.updated_at) / 86400)
	end

	-- 如果已完成，添加完成信息
	if link.status == types.STATUS.COMPLETED and link.completed_at then
		info.completed_days = math.floor((now - link.completed_at) / 86400)
	end

	-- 如果已归档，添加归档信息
	if link.status == types.STATUS.ARCHIVED and link.archived_at then
		info.archived_days = math.floor((now - link.archived_at) / 86400)
	end

	-- 如果已删除，添加删除信息
	if not info.active and link.deleted_at then
		info.deleted_days = math.floor((now - link.deleted_at) / 86400)
	end

	return info
end

return M
