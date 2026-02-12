--- File: /Users/lijia/todo2/lua/todo2/store/link.lua
-- lua/todo2/store/link.lua
--- @module todo2.store.link
--- 核心链接管理系统（移除 completed 字段，统一使用 status）

local M = {}

---------------------------------------------------------------------
-- 依赖模块
---------------------------------------------------------------------
local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local locator = require("todo2.store.locator")
local format = require("todo2.utils.format") -- ⭐ 引入格式集中管理模块

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

	-- 提取标签（集中到 format 模块）
	local tag = "TODO"
	if data.tag then
		-- 用户显式传入的标签具有最高优先级
		tag = data.tag
	else
		if link_type == types.LINK_TYPES.CODE_TO_TODO then
			-- 代码链接：从注释行提取标签（可能同时提取 ID，但我们只需要 tag）
			local extracted_tag = format.extract_from_code_line(data.content or "")
			tag = extracted_tag or "TODO"
		else
			-- TODO链接：从任务内容提取标签
			tag = format.extract_tag(data.content or "") or "TODO"
		end
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

		-- ⭐ 关键变更：只保留 status 字段，移除 completed
		status = data.status or types.STATUS.NORMAL,

		-- 归档信息（仅当 status = archived 时有效）
		archived_at = nil,
		archived_reason = nil,

		-- 时间戳字段
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = nil, -- 第一次完成的时间

		-- 状态历史
		previous_status = nil,

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
		-- 如果已经是完成状态，直接返回
		if types.is_completed_status(todo_link.status) then
			return todo_link
		end

		-- 保存之前的状态
		todo_link.previous_status = todo_link.status

		-- 设置完成状态
		todo_link.status = types.STATUS.COMPLETED
		todo_link.completed_at = os.time()
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if types.is_completed_status(code_link.status) then
			return code_link
		end

		code_link.previous_status = code_link.status
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
		-- 如果未完成，直接返回
		if types.is_active_status(todo_link.status) then
			return todo_link
		end

		-- 恢复之前的状态或设为正常
		local target_status = todo_link.previous_status or types.STATUS.NORMAL

		-- 如果是归档状态，取消归档
		if todo_link.status == types.STATUS.ARCHIVED then
			todo_link.archived_at = nil
			todo_link.archived_reason = nil
		end

		todo_link.status = target_status
		todo_link.completed_at = nil
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if types.is_active_status(code_link.status) then
			return code_link
		end

		local target_status = code_link.previous_status or types.STATUS.NORMAL

		if code_link.status == types.STATUS.ARCHIVED then
			code_link.archived_at = nil
			code_link.archived_reason = nil
		end

		code_link.status = target_status
		code_link.completed_at = nil
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
	if not types.is_active_status(new_status) then
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
		-- 只能更新活跃任务的状态
		if not types.is_active_status(todo_link.status) then
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
		if not types.is_active_status(code_link.status) then
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
		if not types.is_completed_status(todo_link.status) then
			vim.notify("未完成的任务不能归档", vim.log.levels.WARN)
			return nil
		end

		todo_link.status = types.STATUS.ARCHIVED
		todo_link.archived_at = os.time()
		todo_link.archived_reason = reason or "manual"
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if not types.is_completed_status(code_link.status) then
			vim.notify("未完成的任务不能归档", vim.log.levels.WARN)
			return nil
		end

		code_link.status = types.STATUS.ARCHIVED
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
		if todo_link.status ~= types.STATUS.ARCHIVED then
			return todo_link
		end

		todo_link.status = types.STATUS.COMPLETED
		todo_link.archived_at = nil
		todo_link.archived_reason = nil
		todo_link.updated_at = os.time()

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	-- 更新代码链接
	if code_link then
		if code_link.status ~= types.STATUS.ARCHIVED then
			return code_link
		end

		code_link.status = types.STATUS.COMPLETED
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
		return types.is_completed_status(todo_link.status) and types.is_completed_status(code_link.status)
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
		return todo_link.status == types.STATUS.ARCHIVED and code_link.status == types.STATUS.ARCHIVED
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
		if link.status == types.STATUS.ARCHIVED and link.active ~= false then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
				result[id] = result[id] or {}
				result[id].todo = link
			end
		end
	end

	-- 获取所有代码链接
	local all_code = M.get_all_code()
	for id, link in pairs(all_code) do
		if link.status == types.STATUS.ARCHIVED and link.active ~= false then
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

return M
