-- lua/todo2/store/link.lua
--- @module todo2.store.link
--- 核心链接管理系统（原子性操作，确保两端对齐）

local M = {}

---------------------------------------------------------------------
-- 依赖模块
---------------------------------------------------------------------
local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local locator = require("todo2.store.locator")

---------------------------------------------------------------------
-- 配置常量
---------------------------------------------------------------------
local LINK_TYPE_CONFIG = {
	todo = "todo.links.todo.",
	code = "todo.links.code.",
}

-- 活跃状态（只能用于未完成的任务）
local ACTIVE_STATUSES = {
	[types.STATUS.NORMAL] = true,
	[types.STATUS.URGENT] = true,
	[types.STATUS.WAITING] = true,
}

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------
-- 创建新链接
local function create_link(id, data, link_type)
	local now = os.time()

	-- 提取标签
	local tag = "TODO"
	if data.tag then
		tag = data.tag
	elseif data.content then
		local extracted = data.content:match("([A-Z][A-Z0-9]+):ref:")
		tag = extracted or tag
	end

	-- 构建链接对象
	local link = {
		-- 核心标识字段
		id = id,
		type = link_type,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		tag = tag,

		-- 复选框状态（核心）
		completed = false, -- 默认未完成

		-- 活跃状态（仅当 completed = false 时有效）
		status = types.STATUS.NORMAL, -- 默认正常

		-- 归档状态（仅当 completed = true 时有效）
		archived = false,
		archived_at = nil,
		archived_reason = nil,

		-- 时间戳字段
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = nil, -- 第一次完成的时间

		-- 状态历史
		previous_status = nil, -- 上一次的活跃状态

		-- 软删除相关
		active = true,
		deleted_at = nil,
		deletion_reason = nil,
		restored_at = nil,

		-- 验证相关
		line_verified = true,
		last_verified_at = nil,
		verification_failed_at = nil,
		verification_note = nil,

		-- 上下文定位
		context = data.context,
		context_matched = nil,
		context_similarity = nil,
		context_updated_at = nil,

		-- 同步与版本控制
		sync_version = 1,
		last_sync_at = nil,
		sync_status = "local",
		sync_pending = false,
		sync_conflict = false,

		-- 内容验证
		content_hash = locator.calculate_content_hash(data.content or ""),
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

-- 检查链接对完整性
local function check_link_pair_integrity(todo_link, code_link, operation)
	if not todo_link and not code_link then
		return false, "链接ID不存在"
	end

	-- 如果两端都存在但有一端被软删除
	if todo_link and code_link then
		if todo_link.active == false or code_link.active == false then
			return false, "链接已被删除，不能修改状态"
		end
	end

	-- 如果只有一端存在，视为数据损坏
	if (todo_link and not code_link) or (not todo_link and code_link) then
		return false, string.format("数据不一致：链接对只有一端存在 (操作: %s)", operation)
	end

	return true, nil
end

---------------------------------------------------------------------
-- 公共API：链接管理
---------------------------------------------------------------------
--- 添加TODO链接
function M.add_todo(id, data)
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.TODO_TO_CODE)
	if not ok then
		vim.notify("创建TODO链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end

	store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)

	-- 更新元数据统计
	local meta = require("todo2.store.meta")
	meta.increment_links("todo")

	return true
end

--- 添加代码链接
function M.add_code(id, data)
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.CODE_TO_TODO)
	if not ok then
		vim.notify("创建代码链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end

	store.set_key(LINK_TYPE_CONFIG.code .. id, link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)

	-- 更新元数据统计
	local meta = require("todo2.store.meta")
	meta.increment_links("code")

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

---------------------------------------------------------------------
-- 公共API：原子性状态管理
---------------------------------------------------------------------
--- 标记任务为完成（两端同时标记）
--- @param id string 链接ID
--- @return table|nil 更新后的链接
function M.mark_completed(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	-- 检查完整性
	local ok, err = check_link_pair_integrity(todo_link, code_link, "mark_completed")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	-- 更新TODO链接
	if todo_link then
		-- 如果已经完成，直接返回
		if todo_link.completed then
			return todo_link
		end

		-- 保存之前的活跃状态
		todo_link.previous_status = todo_link.status

		-- 设置完成状态
		todo_link.completed = true
		todo_link.status = types.STATUS.COMPLETED
		todo_link.completed_at = os.time()
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if code_link.completed then
			return code_link
		end

		code_link.previous_status = code_link.status
		code_link.completed = true
		code_link.status = types.STATUS.COMPLETED
		code_link.completed_at = os.time()
		code_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 重新打开任务（两端同时重新打开）
--- @param id string 链接ID
--- @return table|nil 更新后的链接
function M.reopen_link(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	-- 检查完整性
	local ok, err = check_link_pair_integrity(todo_link, code_link, "reopen_link")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	-- 更新TODO链接
	if todo_link then
		if not todo_link.completed then
			return todo_link
		end

		-- 如果已归档，先取消归档
		if todo_link.archived then
			todo_link.archived = false
			todo_link.archived_at = nil
			todo_link.archived_reason = nil
		end

		-- 重新打开为未完成状态
		todo_link.completed = false
		todo_link.status = todo_link.previous_status or types.STATUS.NORMAL
		todo_link.completed_at = nil -- 清除完成时间
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if not code_link.completed then
			return code_link
		end

		if code_link.archived then
			code_link.archived = false
			code_link.archived_at = nil
			code_link.archived_reason = nil
		end

		code_link.completed = false
		code_link.status = code_link.previous_status or types.STATUS.NORMAL
		code_link.completed_at = nil -- 清除完成时间
		code_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 更新活跃状态（两端同时更新）
--- @param id string 链接ID
--- @param new_status string 新状态，必须是 normal/urgent/waiting
--- @return table|nil 更新后的链接
function M.update_active_status(id, new_status)
	-- 验证状态
	if not ACTIVE_STATUSES[new_status] then
		vim.notify("活跃状态只能是: normal, urgent 或 waiting", vim.log.levels.ERROR)
		return nil
	end

	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	-- 检查完整性
	local ok, err = check_link_pair_integrity(todo_link, code_link, "update_active_status")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	-- 更新TODO链接
	if todo_link then
		-- 只能更新未完成任务的活跃状态
		if todo_link.completed then
			vim.notify("已完成的任务不能设置活跃状态", vim.log.levels.WARN)
			return nil
		end

		todo_link.status = new_status
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if code_link.completed then
			vim.notify("已完成的任务不能设置活跃状态", vim.log.levels.WARN)
			return nil
		end

		code_link.status = new_status
		code_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 归档任务（两端同时归档）
--- @param id string 链接ID
--- @param reason string|nil 归档原因
--- @return table|nil 归档后的链接
function M.mark_archived(id, reason)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	-- 检查完整性
	local ok, err = check_link_pair_integrity(todo_link, code_link, "mark_archived")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	-- 更新TODO链接
	if todo_link then
		-- 只能归档已完成的任务
		if not todo_link.completed then
			vim.notify("未完成的任务不能归档", vim.log.levels.WARN)
			return nil
		end

		todo_link.archived = true
		todo_link.archived_at = os.time()
		todo_link.archived_reason = reason or "manual"
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if not code_link.completed then
			vim.notify("未完成的任务不能归档", vim.log.levels.WARN)
			return nil
		end

		code_link.archived = true
		code_link.archived_at = os.time()
		code_link.archived_reason = reason or "manual"
		code_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 取消归档（两端同时取消归档）
--- @param id string 链接ID
--- @return table|nil 取消归档后的链接
function M.unarchive_link(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	-- 检查完整性
	local ok, err = check_link_pair_integrity(todo_link, code_link, "unarchive_link")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	-- 更新TODO链接
	if todo_link then
		-- 如果未归档，直接返回
		if not todo_link.archived then
			return todo_link
		end

		todo_link.archived = false
		todo_link.archived_at = nil
		todo_link.archived_reason = nil
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if not code_link.archived then
			return code_link
		end

		code_link.archived = false
		code_link.archived_at = nil
		code_link.archived_reason = nil
		code_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 检查任务是否已完成（两端都完成才返回true）
--- @param id string 链接ID
--- @return boolean
function M.is_completed(id)
	local todo_link = M.get_todo(id, { verify_line = false })
	local code_link = M.get_code(id, { verify_line = false })

	-- 两端都必须存在且都完成
	if todo_link and code_link then
		return todo_link.completed and code_link.completed
	end

	-- 如果只有一端存在，视为数据损坏
	return false
end

--- 检查任务是否已归档（两端都归档才返回true）
--- @param id string 链接ID
--- @return boolean
function M.is_archived(id)
	local todo_link = M.get_todo(id, { verify_line = false })
	local code_link = M.get_code(id, { verify_line = false })

	-- 两端都必须存在且都归档
	if todo_link and code_link then
		return todo_link.archived and code_link.archived
	end

	-- 如果只有一端存在，视为数据损坏
	return false
end

--- 获取活跃状态（两端状态必须一致）
--- @param id string 链接ID
--- @return string|nil, string|nil 状态，错误信息
function M.get_active_status(id)
	local todo_link = M.get_todo(id, { verify_line = false })
	local code_link = M.get_code(id, { verify_line = false })

	-- 检查完整性
	local ok, err = check_link_pair_integrity(todo_link, code_link, "get_active_status")
	if not ok then
		return nil, err
	end

	-- 检查状态一致性
	if todo_link.status ~= code_link.status then
		return nil, string.format("两端状态不一致: TODO=%s, 代码=%s", todo_link.status, code_link.status)
	end

	return todo_link.status, nil
end

--- 硬删除TODO链接
--- @param id string 链接ID
--- @return boolean 是否成功删除
function M.delete_todo(id)
	local link = store.get_key(LINK_TYPE_CONFIG.todo .. id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_todo", link.path, id)
		store.delete_key(LINK_TYPE_CONFIG.todo .. id)

		-- 更新元数据统计
		local meta = require("todo2.store.meta")
		meta.decrement_links("todo")
		return true
	end
	return false
end

--- 硬删除代码链接
--- @param id string 链接ID
--- @return boolean 是否成功删除
function M.delete_code(id)
	local link = store.get_key(LINK_TYPE_CONFIG.code .. id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_code", link.path, id)
		store.delete_key(LINK_TYPE_CONFIG.code .. id)

		-- 更新元数据统计
		local meta = require("todo2.store.meta")
		meta.decrement_links("code")
		return true
	end
	return false
end

--- 硬删除链接对（两端同时删除）
--- @param id string 链接ID
--- @return boolean 是否成功删除
function M.delete_link_pair(id)
	local todo_deleted = M.delete_todo(id)
	local code_deleted = M.delete_code(id)

	return todo_deleted or code_deleted
end

---------------------------------------------------------------------
-- 批量操作
---------------------------------------------------------------------
--- 获取所有TODO链接（默认过滤掉已删除的）
function M.get_all_todo()
	local prefix = LINK_TYPE_CONFIG.todo:sub(1, -2) -- 移除末尾的点
	local ids = store.get_namespace_keys(prefix) or {}
	local result = {}

	for _, id in ipairs(ids) do
		local link = M.get_todo(id, { verify_line = false })
		if link and link.active ~= false then
			result[id] = link
		end
	end

	return result
end

--- 获取所有代码链接（默认过滤掉已删除的）
function M.get_all_code()
	local prefix = LINK_TYPE_CONFIG.code:sub(1, -2) -- 移除末尾的点
	local ids = store.get_namespace_keys(prefix) or {}
	local result = {}

	for _, id in ipairs(ids) do
		local link = M.get_code(id, { verify_line = false })
		if link and link.active ~= false then
			result[id] = link
		end
	end

	return result
end

--- 获取已归档的链接
--- @param days number|nil 多少天内的归档，nil表示所有
--- @return table 归档链接列表
function M.get_archived_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = {}

	-- 获取所有TODO链接
	local all_todo = M.get_all_todo()
	for id, link in pairs(all_todo) do
		if link.archived and link.active ~= false then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
				result[id] = result[id] or {}
				result[id].todo = link
			end
		end
	end

	-- 获取所有代码链接
	local all_code = M.get_all_code()
	for id, link in pairs(all_code) do
		if link.archived and link.active ~= false then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
				result[id] = result[id] or {}
				result[id].code = link
			end
		end
	end

	return result
end

--- 获取已删除的链接（软删除）
--- @return table 已删除的链接
function M.get_all_todo_including_deleted()
	local prefix = LINK_TYPE_CONFIG.todo:sub(1, -2)
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

--- 获取已删除的代码链接（软删除）
--- @return table 已删除的代码链接
function M.get_all_code_including_deleted()
	local prefix = LINK_TYPE_CONFIG.code:sub(1, -2)
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
-- 向后兼容函数（已废弃，保留用于迁移）
---------------------------------------------------------------------
--- 向后兼容：update_status 函数
--- @deprecated 请使用具体函数：mark_completed, reopen_link, update_active_status, mark_archived
function M.update_status(id, new_status)
	local todo_link = M.get_todo(id)
	local code_link = M.get_code(id)

	if not todo_link and not code_link then
		return nil
	end

	-- 如果新状态是完成
	if new_status == types.STATUS.COMPLETED then
		return M.mark_completed(id)
	-- 如果新状态是归档
	elseif new_status == types.STATUS.ARCHIVED then
		return M.mark_archived(id, "compat")
	-- 如果新状态是活跃状态
	elseif ACTIVE_STATUSES[new_status] then
		-- 如果任务已完成，不能直接设置活跃状态
		if (todo_link and todo_link.completed) or (code_link and code_link.completed) then
			vim.notify("已完成的任务不能设置活跃状态，请先重新打开", vim.log.levels.WARN)
			return nil
		else
			return M.update_active_status(id, new_status)
		end
	end

	return nil
end

--- 向后兼容：restore_previous_status 函数
--- @deprecated 请使用 reopen_link
function M.restore_previous_status(id)
	local todo_link = M.get_todo(id)
	local code_link = M.get_code(id)

	if not todo_link and not code_link then
		return nil
	end

	-- 如果任务未完成，直接返回
	if (todo_link and not todo_link.completed) or (code_link and not code_link.completed) then
		return todo_link or code_link
	end

	-- 重新打开任务
	return M.reopen_link(id)
end

return M
