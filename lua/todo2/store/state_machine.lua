-- lua/todo2/store/state_machine.lua
--- @module todo2.store.state_machine
--- @brief 统一的状态机管理，确保状态流转的原子性和一致性

local M = {}

local types = require("todo2.store.types")
local store = require("todo2.store.nvim_store")

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------

--- 检查状态转换是否允许（放宽规则）
--- @param from_status string
--- @param to_status string
--- @return boolean
function M.is_transition_allowed(from_status, to_status)
	-- ⭐ 关键修改：允许任意状态之间转换
	if from_status == to_status then
		return true
	end

	-- 所有状态都可以互相转换
	return true
end

--- 计算新的previous_status值
--- @param old_status string
--- @param new_status string
--- @param current_previous_status string|nil
--- @return string|nil
local function calculate_previous_status(old_status, new_status, current_previous_status)
	-- 情况1: 从活跃状态切换到完成状态
	if new_status == types.STATUS.COMPLETED and types.ACTIVE_STATUSES[old_status] then
		return old_status -- 保存当前的活跃状态
	end

	-- 情况2: 从完成状态切换到活跃状态
	if old_status == types.STATUS.COMPLETED and types.ACTIVE_STATUSES[new_status] then
		-- 返回之前保存的活跃状态（如果有），否则保持不变
		return current_previous_status
	end

	-- 情况3: 在活跃状态之间切换
	if types.ACTIVE_STATUSES[old_status] and types.ACTIVE_STATUSES[new_status] then
		return current_previous_status -- 保持 previous_status 不变
	end

	-- 其他情况：保持不变
	return current_previous_status
end

--- 处理完成时间
--- @param old_status string
--- @param new_status string
--- @param current_completed_at number|nil
--- @return number|nil
local function handle_completed_at(old_status, new_status, current_completed_at)
	if new_status == types.STATUS.COMPLETED then
		return current_completed_at or os.time()
	else
		return nil
	end
end

---------------------------------------------------------------------
-- 核心状态更新函数
---------------------------------------------------------------------
--- 原子化状态更新（确保状态流转的一致性）
--- @param link table 链接对象
--- @param new_status string 新状态
--- @return table|nil 更新后的链接
function M.update_link_status(link, new_status)
	if not link or not link.id then
		return nil
	end

	local old_status = link.status or types.STATUS.NORMAL

	-- ⭐ 关键修改：放宽状态流转规则，允许任意状态转换
	-- 任何状态都可以直接转换到任何其他状态
	local allowed = true

	if not allowed then
		vim.notify(string.format("不允许的状态转换: %s -> %s", old_status, new_status), vim.log.levels.WARN)
		return nil
	end

	-- 处理 previous_status
	local new_previous_status = link.previous_status

	-- 只有当从完成状态恢复时，才需要 previous_status
	if new_status == types.STATUS.COMPLETED then
		-- 保存当前的活跃状态到 previous_status
		if old_status ~= types.STATUS.COMPLETED then
			new_previous_status = old_status
		end
	elseif old_status == types.STATUS.COMPLETED then
		-- 从完成状态切换到其他状态时，保留之前的 previous_status
		-- 这样可以通过 restore_previous_status 恢复到正确的状态
		new_previous_status = link.previous_status
	end

	-- 处理 completed_at
	local new_completed_at = link.completed_at
	if new_status == types.STATUS.COMPLETED then
		new_completed_at = os.time()
	else
		new_completed_at = nil
	end

	-- 更新链接
	link.status = new_status
	link.previous_status = new_previous_status
	link.completed_at = new_completed_at
	link.updated_at = os.time()
	link.sync_version = (link.sync_version or 0) + 1

	return link
end

--- 批量更新链接状态（用于双向同步）
--- @param links table[] 链接对象数组
--- @param new_status string 新状态
--- @param source_link table|nil 源链接（用于确定主状态）
--- @return boolean 是否全部成功
function M.batch_update_status(links, new_status, source_link)
	if #links == 0 then
		return false
	end

	-- 如果提供了源链接，使用它的状态作为参考
	local reference_status = source_link and source_link.status or types.STATUS.NORMAL
	local all_success = true

	for _, link in ipairs(links) do
		-- 如果目标链接状态已经和参考状态一致，跳过
		if link.status == new_status then
			goto continue
		end

		local updated = M.update_link_status(link, new_status)
		if not updated then
			all_success = false
		end

		::continue::
	end

	return all_success
end

--- 获取状态显示信息
--- @param status string
--- @return table 包含显示名称、图标、颜色等信息
function M.get_status_display_info(status)
	local info = {
		name = status,
		icon = "○",
		color = "Normal",
		priority = 1,
	}

	if status == types.STATUS.NORMAL then
		info.name = "正常"
		info.icon = "○"
		info.color = "Normal"
		info.priority = 1
	elseif status == types.STATUS.URGENT then
		info.name = "紧急"
		info.icon = "⚠"
		info.color = "Error"
		info.priority = 3
	elseif status == types.STATUS.WAITING then
		info.name = "等待"
		info.icon = "⌛"
		info.color = "WarningMsg"
		info.priority = 2
	elseif status == types.STATUS.COMPLETED then
		info.name = "完成"
		info.icon = "✓"
		info.color = "Comment"
		info.priority = 0
	end

	return info
end

--- 获取下一个推荐状态（循环切换）
--- @param current_status string
--- @return string
function M.get_next_recommended_status(current_status)
	local order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING }

	for i, status in ipairs(order) do
		if current_status == status then
			return order[(i % #order) + 1]
		end
	end

	return types.STATUS.NORMAL
end

--- 验证链接状态是否有效
--- @param link table
--- @return boolean, string|nil 是否有效，错误信息
function M.validate_link_status(link)
	if not link.status then
		return false, "状态字段缺失"
	end

	-- 检查状态值是否有效
	local valid_statuses = {
		[types.STATUS.NORMAL] = true,
		[types.STATUS.URGENT] = true,
		[types.STATUS.WAITING] = true,
		[types.STATUS.COMPLETED] = true,
	}

	if not valid_statuses[link.status] then
		return false, string.format("无效的状态值: %s", link.status)
	end

	-- 检查完成时间
	if link.status == types.STATUS.COMPLETED then
		if not link.completed_at then
			return false, "完成状态缺少完成时间"
		end
		if link.completed_at < link.created_at then
			return false, "完成时间早于创建时间"
		end
	else
		if link.completed_at then
			return false, "非完成状态不应该有完成时间"
		end
	end

	return true, nil
end

return M
