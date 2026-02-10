-- lua/todo2/store/link.lua
--- @module todo2.store.link
--- 核心链接管理系统（简化状态管理）

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
-- 公共API：状态管理
---------------------------------------------------------------------
--- 标记任务为完成（复选框从[ ]变为[x]）
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都更新）
--- @return table|nil 更新后的链接
function M.mark_completed(id, link_type)
	local results = {}

	-- 更新TODO链接
	if not link_type or link_type == "todo" then
		local link = M.get_todo(id, { verify_line = true })
		if link then
			-- 检查链接是否活跃（未被软删除）
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			-- 如果已经完成，直接返回
			if link.completed then
				return link
			end

			-- 保存之前的活跃状态
			link.previous_status = link.status

			-- 设置完成状态
			link.completed = true
			link.status = types.STATUS.COMPLETED -- 修复：设置状态为完成
			link.completed_at = os.time()
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			results.todo = link
		end
	end

	-- 更新代码链接
	if not link_type or link_type == "code" then
		local link = M.get_code(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			if link.completed then
				return link
			end

			link.previous_status = link.status
			link.completed = true
			link.status = types.STATUS.COMPLETED -- 修复：设置状态为完成
			link.completed_at = os.time()
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			results.code = link
		end
	end

	return results.todo or results.code
end

--- 重新打开任务（复选框从[x]变为[ ]）
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都更新）
--- @return table|nil 更新后的链接
function M.reopen_link(id, link_type)
	local results = {}

	-- 更新TODO链接
	if not link_type or link_type == "todo" then
		local link = M.get_todo(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			-- 如果未完成，直接返回
			if not link.completed then
				return link
			end

			-- 如果已归档，先取消归档
			if link.archived then
				link.archived = false
				link.archived_at = nil
				link.archived_reason = nil
			end

			-- 重新打开为未完成状态
			link.completed = false
			link.status = link.previous_status or types.STATUS.NORMAL
			link.completed_at = nil -- 清除完成时间
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			results.todo = link
		end
	end

	-- 更新代码链接
	if not link_type or link_type == "code" then
		local link = M.get_code(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			if not link.completed then
				return link
			end

			if link.archived then
				link.archived = false
				link.archived_at = nil
				link.archived_reason = nil
			end

			link.completed = false
			link.status = link.previous_status or types.STATUS.NORMAL
			link.completed_at = nil -- 清除完成时间
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			results.code = link
		end
	end

	return results.todo or results.code
end

--- 更新活跃状态（仅用于未完成的任务）
--- @param id string 链接ID
--- @param new_status string 新状态，必须是 normal/urgent/waiting
--- @param link_type string|nil "todo", "code" 或 nil（两者都更新）
--- @return table|nil 更新后的链接
function M.update_active_status(id, new_status, link_type)
	-- 验证状态
	if not ACTIVE_STATUSES[new_status] then
		vim.notify("活跃状态只能是: normal, urgent 或 waiting", vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	-- 更新TODO链接
	if not link_type or link_type == "todo" then
		local link = M.get_todo(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			-- 只能更新未完成任务的活跃状态
			if link.completed then
				vim.notify("已完成的任务不能设置活跃状态", vim.log.levels.WARN)
				return nil
			end

			link.status = new_status
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			results.todo = link
		end
	end

	-- 更新代码链接
	if not link_type or link_type == "code" then
		local link = M.get_code(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			if link.completed then
				vim.notify("已完成的任务不能设置活跃状态", vim.log.levels.WARN)
				return nil
			end

			link.status = new_status
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			results.code = link
		end
	end

	return results.todo or results.code
end

--- 归档任务（只能归档已完成的任务）
--- @param id string 链接ID
--- @param reason string|nil 归档原因
--- @param link_type string|nil "todo", "code" 或 nil（两者都归档）
--- @return table|nil 归档后的链接
function M.mark_archived(id, reason, link_type)
	local results = {}

	-- 更新TODO链接
	if not link_type or link_type == "todo" then
		local link = M.get_todo(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			-- 只能归档已完成的任务
			if not link.completed then
				vim.notify("未完成的任务不能归档", vim.log.levels.WARN)
				return nil
			end

			link.archived = true
			link.archived_at = os.time()
			link.archived_reason = reason or "manual"
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			results.todo = link
		end
	end

	-- 更新代码链接
	if not link_type or link_type == "code" then
		local link = M.get_code(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			if not link.completed then
				vim.notify("未完成的任务不能归档", vim.log.levels.WARN)
				return nil
			end

			link.archived = true
			link.archived_at = os.time()
			link.archived_reason = reason or "manual"
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			results.code = link
		end
	end

	return results.todo or results.code
end

--- 取消归档（任务仍然保持完成状态）
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都取消归档）
--- @return table|nil 取消归档后的链接
function M.unarchive_link(id, link_type)
	local results = {}

	-- 更新TODO链接
	if not link_type or link_type == "todo" then
		local link = M.get_todo(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			-- 如果未归档，直接返回
			if not link.archived then
				return link
			end

			link.archived = false
			link.archived_at = nil
			link.archived_reason = nil
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			results.todo = link
		end
	end

	-- 更新代码链接
	if not link_type or link_type == "code" then
		local link = M.get_code(id, { verify_line = true })
		if link then
			if link.active == false then
				vim.notify("无法更新已删除的链接状态: " .. id, vim.log.levels.WARN)
				return nil
			end

			if not link.archived then
				return link
			end

			link.archived = false
			link.archived_at = nil
			link.archived_reason = nil
			link.updated_at = os.time()

			store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			results.code = link
		end
	end

	return results.todo or results.code
end

--- 检查任务是否已完成
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都检查）
--- @return boolean
function M.is_completed(id, link_type)
	local todo_link, code_link

	if not link_type or link_type == "todo" then
		todo_link = M.get_todo(id, { verify_line = false })
	end

	if not link_type or link_type == "code" then
		code_link = M.get_code(id, { verify_line = false })
	end

	-- 如果指定了类型，只检查该类型
	if link_type == "todo" then
		return todo_link and todo_link.completed or false
	elseif link_type == "code" then
		return code_link and code_link.completed or false
	else
		-- 两者都检查，只要有一个完成就返回true
		return (todo_link and todo_link.completed) or (code_link and code_link.completed) or false
	end
end

--- 检查任务是否已归档
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都检查）
--- @return boolean
function M.is_archived(id, link_type)
	local todo_link, code_link

	if not link_type or link_type == "todo" then
		todo_link = M.get_todo(id, { verify_line = false })
	end

	if not link_type or link_type == "code" then
		code_link = M.get_code(id, { verify_line = false })
	end

	if link_type == "todo" then
		return todo_link and todo_link.archived or false
	elseif link_type == "code" then
		return code_link and code_link.archived or false
	else
		return (todo_link and todo_link.archived) or (code_link and code_link.archived) or false
	end
end

--- 获取活跃状态（仅适用于未完成的任务）
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都获取）
--- @return string|nil
function M.get_active_status(id, link_type)
	local todo_link, code_link

	if not link_type or link_type == "todo" then
		todo_link = M.get_todo(id, { verify_line = false })
	end

	if not link_type or link_type == "code" then
		code_link = M.get_code(id, { verify_line = false })
	end

	if link_type == "todo" then
		return todo_link and todo_link.status
	elseif link_type == "code" then
		return code_link and code_link.status
	else
		-- 返回其中一个，优先返回TODO链接的状态
		return (todo_link and todo_link.status) or (code_link and code_link.status)
	end
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

---------------------------------------------------------------------
-- 向后兼容函数
---------------------------------------------------------------------
--- 向后兼容：update_status 函数
--- @deprecated 请使用具体函数：mark_completed, reopen_link, update_active_status, mark_archived
function M.update_status(id, new_status, link_type)
	local link = M.get_todo(id)
	if not link then
		link = M.get_code(id)
	end

	if not link then
		return nil
	end

	-- 如果新状态是完成
	if new_status == types.STATUS.COMPLETED then
		return M.mark_completed(id, link_type)
	-- 如果新状态是归档
	elseif new_status == types.STATUS.ARCHIVED then
		return M.mark_archived(id, "compat", link_type)
	-- 如果新状态是活跃状态
	elseif ACTIVE_STATUSES[new_status] then
		-- 如果任务已完成，不能直接设置活跃状态
		if link.completed then
			vim.notify("已完成的任务不能设置活跃状态，请先重新打开", vim.log.levels.WARN)
			return nil
		else
			return M.update_active_status(id, new_status, link_type)
		end
	end

	return nil
end

--- 向后兼容：restore_previous_status 函数
--- @deprecated 请使用 reopen_link
function M.restore_previous_status(id, link_type)
	local link = M.get_todo(id)
	if not link then
		link = M.get_code(id)
	end

	if not link then
		return nil
	end

	-- 如果任务未完成，直接返回
	if not link.completed then
		return link
	end

	-- 重新打开任务
	return M.reopen_link(id, link_type)
end

return M
