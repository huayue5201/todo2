-- lua/todo2/store/link_lifecycle.lua
--- 链接生命周期管理（纯数据层）
--- 职责：
---   - 状态类别判定（基于存储字段）
---   - 链接对一致性检查
---   - 为清理、验证模块提供状态信息

local M = {}

local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 状态类别定义
---------------------------------------------------------------------

M.STATE_CLASS = {
	ACTIVE = "active",
	COMPLETED = "completed",
	ARCHIVED = "archived",
	DELETED = "deleted",
}

--- 获取链接的状态类别
--- @param link table|nil 链接对象
--- @return string|nil 状态类别
function M.get_state_class(link)
	if not link then
		return nil
	end

	if link.deleted_at and link.deleted_at > 0 then
		return M.STATE_CLASS.DELETED
	end

	if types.is_archived_status(link.status) then
		return M.STATE_CLASS.ARCHIVED
	end

	if types.is_completed_status(link.status) then
		return M.STATE_CLASS.COMPLETED
	end

	return M.STATE_CLASS.ACTIVE
end

--- 判断链接是否活跃
--- @param link table|nil 链接对象
--- @return boolean
function M.is_active(link)
	if not link then
		return false
	end

	if link.deleted_at and link.deleted_at > 0 then
		return false
	end

	if types.is_archived_status(link.status) then
		return false
	end

	if types.is_completed_status(link.status) then
		return false
	end

	return true
end

---------------------------------------------------------------------
-- 链接对一致性检查
---------------------------------------------------------------------

--- 检查链接对状态是否一致
--- @param todo_link table|nil TODO端链接
--- @param code_link table|nil 代码端链接
--- @return boolean 是否一致
--- @return table 差异信息
function M.check_pair_consistency(todo_link, code_link)
	if not todo_link and not code_link then
		return true, { message = "两端都不存在" }
	end

	if not todo_link or not code_link then
		return false,
			{
				has_todo = todo_link ~= nil,
				has_code = code_link ~= nil,
				message = "链接对不完整",
			}
	end

	-- 此时 todo_link 和 code_link 都不为 nil
	local todo_class = M.get_state_class(todo_link)
	local code_class = M.get_state_class(code_link)

	if todo_class ~= code_class then
		return false,
			{
				todo_class = todo_class,
				code_class = code_class,
				message = string.format("状态类别不一致: TODO=%s, 代码=%s", todo_class, code_class),
			}
	end

	if todo_class == M.STATE_CLASS.ACTIVE then
		if todo_link.status ~= code_link.status then
			return false,
				{
					message = string.format(
						"活跃状态不一致: TODO=%s, 代码=%s",
						todo_link.status,
						code_link.status
					),
				}
		end
	end

	if todo_class == M.STATE_CLASS.DELETED then
		if math.abs((todo_link.deleted_at or 0) - (code_link.deleted_at or 0)) > 5 then
			return false, {
				message = "删除时间不一致",
			}
		end
	end

	return true, { message = "状态一致" }
end

--- 同步链接对状态
--- @param todo_link table TODO端链接
--- @param code_link table 代码端链接
--- @return table, table 同步后的两端链接
function M.sync_pair_state(todo_link, code_link)
	-- 参数验证
	if not todo_link or not code_link then
		vim.notify("sync_pair_state: 参数不能为nil", vim.log.levels.ERROR)
		return todo_link or {}, code_link or {}
	end

	local todo_class = M.get_state_class(todo_link)
	local code_class = M.get_state_class(code_link)

	if todo_class == code_class then
		return todo_link, code_link
	end

	local priority = {
		[M.STATE_CLASS.DELETED] = 100,
		[M.STATE_CLASS.ARCHIVED] = 90,
		[M.STATE_CLASS.COMPLETED] = 80,
		[M.STATE_CLASS.ACTIVE] = 70,
	}

	local primary, secondary
	if priority[todo_class] >= priority[code_class] then
		primary, secondary = todo_link, code_link
	else
		primary, secondary = code_link, todo_link
	end

	-- primary 和 secondary 现在肯定不为 nil
	local new_secondary = vim.deepcopy(secondary)

	-- 同步状态
	if primary.deleted_at then
		new_secondary.deleted_at = primary.deleted_at
		new_secondary.deletion_reason = primary.deletion_reason
	end

	if primary.archived_at then
		new_secondary.archived_at = primary.archived_at
		new_secondary.archived_reason = primary.archived_reason
	end

	if primary.completed_at then
		new_secondary.completed_at = primary.completed_at
	end

	new_secondary.status = primary.status
	new_secondary.updated_at = os.time()
	new_secondary.active = M.is_active(new_secondary)

	-- 根据 primary/secondary 的原始关系返回
	if secondary == code_link then
		return primary, new_secondary
	else
		return new_secondary, primary
	end
end

return M
