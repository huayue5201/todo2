-- lua/todo2/store/link.lua
--- @module todo2.store.link
--- 核心链接管理系统（修复归档函数）

local M = {}

---------------------------------------------------------------------
-- 依赖模块
---------------------------------------------------------------------
local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local locator = require("todo2.store.locator")
local state_machine = require("todo2.store.state_machine")
local consistency = require("todo2.store.consistency")

---------------------------------------------------------------------
-- 配置常量
---------------------------------------------------------------------
local LINK_TYPE_CONFIG = {
	todo = "todo.links.todo.",
	code = "todo.links.code.",
}

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------
-- 创建新链接
local function create_link(id, data, link_type)
	local now = os.time()
	local status = data.status or types.STATUS.NORMAL

	-- 提取标签
	local tag = "TODO"
	if data.tag then
		tag = data.tag
	elseif data.content then
		local extracted = data.content:match("([A-Z][A-Z0-9]+):ref:")
		tag = extracted or tag
	end

	-- 创建链接对象
	local link = {
		id = id,
		type = link_type,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		tag = tag,
		status = status,
		previous_status = nil,
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = (status == types.STATUS.COMPLETED) and (data.completed_at or now) or nil,
		archived_at = data.archived_at or nil,
		archived_reason = data.archived_reason or nil,
		sync_version = 1,
		active = true,
		context = data.context,
		content_hash = locator.calculate_content_hash(data.content or ""),
		line_verified = true,
	}

	return link
end

-- 通用链接获取函数
local function get_link(id, link_type, verify_line)
	local key_prefix = link_type == "todo" and LINK_TYPE_CONFIG.todo or LINK_TYPE_CONFIG.code
	local key = key_prefix .. id
	local link = store.get_key(key)

	if not link then
		return nil
	end

	-- 如果要求验证行号，调用定位器
	if verify_line then
		link = locator.locate_task(link)
		-- 保存修复后的链接
		store.set_key(key, link)
	end

	return link
end

---------------------------------------------------------------------
-- 公共API：链接管理
---------------------------------------------------------------------
--- 添加TODO链接
function M.add_todo(id, data)
	local link = create_link(id, data, types.LINK_TYPES.TODO_TO_CODE)
	store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
	return true
end

--- 添加代码链接
function M.add_code(id, data)
	local link = create_link(id, data, types.LINK_TYPES.CODE_TO_TODO)
	store.set_key(LINK_TYPE_CONFIG.code .. id, link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)
	return true
end

--- 获取TODO链接
--- @param id string 链接ID
--- @param opts table|nil 选项
function M.get_todo(id, opts)
	opts = opts or {}
	return get_link(id, "todo", opts.verify_line ~= false)
end

--- 获取代码链接
--- @param id string 链接ID
--- @param opts table|nil 选项
function M.get_code(id, opts)
	opts = opts or {}
	return get_link(id, "code", opts.verify_line ~= false)
end

--- 删除TODO链接
function M.delete_todo(id)
	local link = store.get_key(LINK_TYPE_CONFIG.todo .. id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_todo", link.path, id)
		store.delete_key(LINK_TYPE_CONFIG.todo .. id)
	end
end

--- 删除代码链接
function M.delete_code(id)
	local link = store.get_key(LINK_TYPE_CONFIG.code .. id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_code", link.path, id)
		store.delete_key(LINK_TYPE_CONFIG.code .. id)
	end
end

---------------------------------------------------------------------
-- 公共API：状态管理
---------------------------------------------------------------------
--- 更新链接状态
function M.update_status(id, new_status, link_type)
	-- 验证状态值
	local valid_statuses = {
		[types.STATUS.NORMAL] = true,
		[types.STATUS.URGENT] = true,
		[types.STATUS.WAITING] = true,
		[types.STATUS.COMPLETED] = true,
	}

	if not valid_statuses[new_status] then
		vim.notify("无效的状态: " .. new_status, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	-- 更新TODO链接
	if not link_type or link_type == "todo" then
		local link = M.get_todo(id, { verify_line = true })
		if link then
			link = state_machine.update_link_status(link, new_status)
			store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			results.todo = link
		end
	end

	-- 更新代码链接
	if not link_type or link_type == "code" then
		local link = M.get_code(id, { verify_line = true })
		if link then
			link = state_machine.update_link_status(link, new_status)
			store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			results.code = link
		end
	end

	-- 触发一致性检查
	vim.schedule(function()
		local check = consistency.check_link_pair_consistency(id)
		if check.needs_repair then
			consistency.repair_link_pair(id, "latest")
		end
	end)

	return results.todo or results.code
end

--- 标记为完成
function M.mark_completed(id, link_type)
	return M.update_status(id, types.STATUS.COMPLETED, link_type)
end

--- 标记为紧急
function M.mark_urgent(id, link_type)
	return M.update_status(id, types.STATUS.URGENT, link_type)
end

--- 标记为正常
function M.mark_normal(id, link_type)
	return M.update_status(id, types.STATUS.NORMAL, link_type)
end

--- 标记为等待
function M.mark_waiting(id, link_type)
	return M.update_status(id, types.STATUS.WAITING, link_type)
end

--- 恢复到上一次状态
function M.restore_previous_status(id, link_type)
	if link_type == "todo" or not link_type then
		local link = M.get_todo(id, { verify_line = true })
		if link and link.previous_status then
			return M.update_status(id, link.previous_status, link_type)
		end
	end

	if link_type == "code" or not link_type then
		local link = M.get_code(id, { verify_line = true })
		if link and link.previous_status then
			return M.update_status(id, link.previous_status, link_type)
		end
	end

	-- 如果没有之前的状态，标记为正常
	return M.update_status(id, types.STATUS.NORMAL, link_type)
end

---------------------------------------------------------------------
-- 公共API：批量操作
---------------------------------------------------------------------
--- 获取所有TODO链接
function M.get_all_todo()
	local prefix = LINK_TYPE_CONFIG.todo:sub(1, -2) -- 移除末尾的点
	local ids = store.get_namespace_keys(prefix) or {}
	local result = {}

	for _, id in ipairs(ids) do
		local link = M.get_todo(id, { verify_line = false })
		if link then
			result[id] = link
		end
	end

	return result
end

--- 获取所有代码链接
function M.get_all_code()
	local prefix = LINK_TYPE_CONFIG.code:sub(1, -2) -- 移除末尾的点
	local ids = store.get_namespace_keys(prefix) or {}
	local result = {}

	for _, id in ipairs(ids) do
		local link = M.get_code(id, { verify_line = false })
		if link then
			result[id] = link
		end
	end

	return result
end

---------------------------------------------------------------------
-- 公共API：定位修复
---------------------------------------------------------------------
--- 修复单个链接的位置
function M.fix_link_location(id, link_type)
	if link_type == "todo" or not link_type then
		local link = store.get_key(LINK_TYPE_CONFIG.todo .. id)
		if link then
			link = locator.locate_task(link)
			store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			return link
		end
	end

	if link_type == "code" or not link_type then
		local link = store.get_key(LINK_TYPE_CONFIG.code .. id)
		if link then
			link = locator.locate_task(link)
			store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			return link
		end
	end

	return nil
end

--- 修复文件中所有链接的位置
function M.fix_file_locations(filepath, link_type)
	return locator.locate_file_tasks(filepath, link_type)
end

--- 标记链接为已归档（修复版：双链同时归档，强制为完成状态）
--- @param id string 链接ID
--- @param reason string|nil 归档原因
--- @return table|nil 归档后的链接
function M.archive_link(id, reason)
	local now = os.time()
	local results = {}

	-- 1. 归档TODO链接
	local todo_link = M.get_todo(id)
	if todo_link then
		-- ⭐ 修复：归档时必须为完成状态
		todo_link.status = types.STATUS.COMPLETED
		todo_link.completed_at = todo_link.completed_at or now

		-- 设置归档字段
		todo_link.archived_at = now
		todo_link.archived_reason = reason or "project_completed"
		todo_link.updated_at = now
		todo_link.active = true

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 2. 归档代码链接
	local code_link = M.get_code(id)
	if code_link then
		-- ⭐ 修复：代码链接也必须是完成状态
		code_link.status = types.STATUS.COMPLETED
		code_link.completed_at = code_link.completed_at or now

		-- 设置归档字段
		code_link.archived_at = now
		code_link.archived_reason = reason or "project_completed"
		code_link.updated_at = now
		code_link.active = false

		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 恢复已归档的链接
--- @param id string 链接ID
--- @return table|nil 恢复后的链接
function M.restore_archived_link(id)
	local todo_link = M.get_todo(id)
	local code_link = M.get_code(id)

	-- 恢复TODO链接
	if todo_link and todo_link.archived_at then
		todo_link.archived_at = nil
		todo_link.archived_reason = nil
		todo_link.updated_at = os.time()
		todo_link.active = true
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
	end

	-- 恢复代码链接
	if code_link and code_link.archived_at then
		code_link.archived_at = nil
		code_link.archived_reason = nil
		code_link.updated_at = os.time()
		code_link.active = true
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
	end

	return todo_link or code_link
end

--- 获取已归档的链接（双链信息）
--- @param days number|nil 多少天内的归档，nil表示所有
--- @return table 归档链接列表
function M.get_archived_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = {}

	-- 获取所有TODO链接
	local all_todo = M.get_all_todo()
	for id, link in pairs(all_todo) do
		if link.archived_at and link.archived_at >= cutoff_time then
			result[id] = result[id] or {}
			result[id].todo = {
				type = "todo",
				link = link,
				archived_at = link.archived_at,
				archived_reason = link.archived_reason,
				status = link.status,
				completed_at = link.completed_at,
			}
		end
	end

	-- 获取所有代码链接
	local all_code = M.get_all_code()
	for id, link in pairs(all_code) do
		if link.archived_at and link.archived_at >= cutoff_time then
			result[id] = result[id] or {}
			result[id].code = {
				type = "code",
				link = link,
				archived_at = link.archived_at,
				archived_reason = link.archived_reason,
				status = link.status,
				completed_at = link.completed_at,
				active = link.active,
			}
		end
	end

	return result
end

--- 安全归档函数
--- @param id string 链接ID
--- @param reason string|nil 归档原因
--- @return boolean 是否成功
function M.safe_archive(id, reason)
	local link = M.archive_link(id, reason)
	return link ~= nil
end

--- 验证归档完整性
--- @param task_id string 任务ID
--- @return table 验证结果
function M.verify_archive_integrity(task_id)
	local result = {
		task_id = task_id,
		todo_link = nil,
		code_link = nil,
		todo_archived = false,
		code_archived = false,
		complete = false,
	}

	-- 检查TODO链接
	local todo_link = M.get_todo(task_id)
	if todo_link then
		result.todo_link = todo_link
		result.todo_archived = todo_link.archived_at ~= nil
	end

	-- 检查代码链接
	local code_link = M.get_code(task_id)
	if code_link then
		result.code_link = code_link
		result.code_archived = code_link.archived_at ~= nil
	end

	-- 判断完整性
	result.complete = result.todo_archived and result.code_archived

	return result
end

return M
