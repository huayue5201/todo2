-- lua/todo2/store/link/core.lua
-- 链接核心CRUD操作（无状态原子操作层）

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local hash = require("todo2.utils.hash")

---------------------------------------------------------------------
-- 配置常量
---------------------------------------------------------------------
local LINK_TYPE_CONFIG = {
	todo = "todo.links.todo.", -- TODO端链接在存储中的键前缀
	code = "todo.links.code.", -- 代码端链接在存储中的键前缀
}

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------
local function create_link(id, data, link_type)
	local now = os.time()
	local tag = data.tag or "TODO"

	-- 验证上下文行号与指定行号是否一致
	if data.context and data.context.target_line then
		local expected_line = data.line
		if data.context.target_line ~= expected_line then
			print(
				string.format(
					"[WARN] 上下文行号不匹配: 期望=%d, 实际=%d",
					expected_line,
					data.context.target_line
				)
			)
		end
	end

	local link = {
		-- 基础标识字段
		id = id, -- 链接唯一ID（通常是哈希值）
		type = link_type, -- 链接类型：todo_to_code 或 code_to_todo

		-- 位置信息
		path = index._normalize_path(data.path), -- 文件绝对路径（已规范化）
		line = data.line, -- 行号（1-based）

		-- 内容相关
		content = data.content or "", -- 任务内容（去除标记后的纯文本）
		tag = tag, -- 标签（如"TODO", "FIX"等）
		content_hash = hash.hash(data.content or ""), -- 内容的哈希值，用于快速比较

		-- 状态相关
		status = data.status or types.STATUS.NORMAL, -- 当前状态（normal/urgent/waiting/completed/archived）
		previous_status = nil, -- 上一次的状态，用于状态回退

		-- 活跃状态（与status相关但独立）
		active = true, -- 是否活跃（基于status和deleted_at计算）

		-- 时间戳
		created_at = data.created_at or now, -- 创建时间
		updated_at = now, -- 最后更新时间
		completed_at = nil, -- 完成时间

		-- 归档相关
		archived_at = nil, -- 归档时间
		archived_reason = nil, -- 归档原因（manual/auto等）

		-- 软删除相关
		deleted_at = nil, -- 软删除时间
		deletion_reason = nil, -- 删除原因
		restored_at = nil, -- 恢复时间（从软删除恢复）

		-- 验证相关
		line_verified = true, -- 行号是否已验证
		last_verified_at = nil, -- 最后一次验证时间
		verification_failed_at = nil, -- 验证失败时间
		verification_note = nil, -- 验证失败原因

		-- 上下文相关
		context = data.context, -- 上下文信息（用于定位）
		context_matched = nil, -- 上下文是否匹配成功
		context_similarity = nil, -- 上下文相似度（0-100）
		context_updated_at = data.context and now or nil, -- 上下文最后更新时间

		-- 同步相关（用于未来可能的云同步）
		sync_version = 1, -- 数据版本号
		last_sync_at = nil, -- 最后同步时间
		sync_status = "local", -- 同步状态：local/remote/conflict
		sync_pending = false, -- 是否有待同步的更改
		sync_conflict = false, -- 是否存在冲突
	}
	return link
end

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------
function M.add_todo(id, data)
	-- 创建TODO端链接
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.TODO_TO_CODE)
	if not ok then
		vim.notify("创建TODO链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end
	-- 存储链接数据
	store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
	-- 添加到文件索引
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)

	-- 更新元数据计数
	local meta = require("todo2.store.meta")
	meta.increment_links("todo", link.active ~= false)

	return true
end

function M.add_code(id, data)
	-- 创建代码端链接
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.CODE_TO_TODO)
	if not ok then
		vim.notify("创建代码链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end
	-- 存储链接数据
	store.set_key(LINK_TYPE_CONFIG.code .. id, link)
	-- 添加到文件索引
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)

	-- 更新元数据计数
	local meta = require("todo2.store.meta")
	meta.increment_links("code", link.active ~= false)

	return true
end

function M.get_todo(id, opts)
	-- 获取TODO端链接
	return M._get_link(id, "todo", opts)
end

function M.get_code(id, opts)
	-- 获取代码端链接
	return M._get_link(id, "code", opts)
end

-- 内部通用获取函数（供本模块其他函数调用）
function M._get_link(id, link_type, opts)
	opts = opts or {}
	local key_prefix = link_type == "todo" and LINK_TYPE_CONFIG.todo or LINK_TYPE_CONFIG.code
	local key = key_prefix .. id
	local link = store.get_key(key)

	if not link then
		return nil
	end

	-- 如果需要验证行号，调用定位器
	if opts.verify_line or opts.force_verify then
		local locator = require("todo2.store.locator")
		local success, verified = pcall(locator.locate_task, link)

		if not success or not verified then
			vim.notify(string.format("验证任务 %s 失败", id), vim.log.levels.DEBUG)
			return link
		end

		-- 如果位置发生变化，更新存储
		if verified.path and verified.line then
			if verified.path ~= link.path or verified.line ~= link.line then
				M._update_link_position(id, link_type, link, verified)
				link = verified
			else
				link = verified
			end
		end
	end

	return link
end

-- 更新链接位置（内部使用）
function M._update_link_position(id, link_type, old_link, new_link)
	-- 如果文件路径变了，更新索引
	if old_link.path ~= new_link.path then
		local index_ns = link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code"
		index._remove_id_from_file_index(index_ns, old_link.path, id)
		index._add_id_to_file_index(index_ns, new_link.path, id)
	end
	-- 更新时间戳
	new_link.updated_at = os.time()

	local key = (link_type == "todo" and LINK_TYPE_CONFIG.todo or LINK_TYPE_CONFIG.code) .. id
	store.set_key(key, new_link)
end

---------------------------------------------------------------------
-- ⭐ 修改版：update_todo - 添加双向同步
---------------------------------------------------------------------
function M.update_todo(id, updated_link)
	-- 先检查软删除状态
	local old = store.get_key(LINK_TYPE_CONFIG.todo .. id)
	if old and old.deleted_at and old.deleted_at > 0 then
		vim.notify("无法更新已软删除的任务", vim.log.levels.WARN)
		return false
	end

	-- 更新TODO端
	local success = M._update_link(id, "todo", updated_link)

	if success then
		-- ⭐ 自动同步到代码端
		local code_link = M.get_code(id, { verify_line = false })
		if code_link then
			-- 只同步内容相关字段，保持位置信息不变
			local needs_sync = false
			local sync_updates = {}

			-- 检查内容是否有变化
			if code_link.content ~= updated_link.content then
				sync_updates.content = updated_link.content
				sync_updates.content_hash = updated_link.content_hash
				needs_sync = true
			end

			-- 检查标签是否有变化
			if code_link.tag ~= updated_link.tag then
				sync_updates.tag = updated_link.tag
				needs_sync = true
			end

			-- 如果需要同步，更新代码端
			if needs_sync then
				local new_code_link = vim.deepcopy(code_link)
				for k, v in pairs(sync_updates) do
					new_code_link[k] = v
				end
				new_code_link.updated_at = os.time()
				M.update_code(id, new_code_link)

				vim.schedule(function()
					vim.notify(string.format("🔄 已同步内容到代码端: %s", id:sub(1, 6)), vim.log.levels.INFO)
				end)
			end
		end
	end

	return success
end

---------------------------------------------------------------------
-- ⭐ 修改版：update_code - 添加反向同步
---------------------------------------------------------------------
function M.update_code(id, updated_link)
	-- 先检查软删除状态
	local old = store.get_key(LINK_TYPE_CONFIG.code .. id)
	if old and old.deleted_at and old.deleted_at > 0 then
		vim.notify("无法更新已软删除的代码链接", vim.log.levels.WARN)
		return false
	end

	local success = M._update_link(id, "code", updated_link)

	if success then
		-- ⭐ 自动同步到TODO端
		local todo_link = M.get_todo(id, { verify_line = false })
		if todo_link then
			local needs_sync = false
			local sync_updates = {}

			if todo_link.content ~= updated_link.content then
				sync_updates.content = updated_link.content
				sync_updates.content_hash = updated_link.content_hash
				needs_sync = true
			end

			if todo_link.tag ~= updated_link.tag then
				sync_updates.tag = updated_link.tag
				needs_sync = true
			end

			if needs_sync then
				local new_todo_link = vim.deepcopy(todo_link)
				for k, v in pairs(sync_updates) do
					new_todo_link[k] = v
				end
				new_todo_link.updated_at = os.time()
				M.update_todo(id, new_todo_link)

				vim.schedule(function()
					vim.notify(string.format("🔄 已同步内容到TODO端: %s", id:sub(1, 6)), vim.log.levels.INFO)
				end)
			end
		end
	end

	return success
end

---------------------------------------------------------------------
-- ⭐ 修改版：_update_link - 添加软删除检查
---------------------------------------------------------------------
function M._update_link(id, link_type, updated_link)
	local key = (link_type == "todo" and LINK_TYPE_CONFIG.todo or LINK_TYPE_CONFIG.code) .. id
	local old = store.get_key(key)

	if old then
		-- ⭐ 检查软删除状态
		if old.deleted_at and old.deleted_at > 0 then
			vim.notify(string.format("链接 %s 已软删除，不能更新", id:sub(1, 6)), vim.log.levels.WARN)
			return false
		end

		-- 如果文件路径变了，更新索引
		if old.path ~= updated_link.path then
			local index_ns = link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code"
			index._remove_id_from_file_index(index_ns, old.path, id)
			index._add_id_to_file_index(index_ns, updated_link.path, id)
		end
		-- 更新时间戳
		updated_link.updated_at = os.time()
		store.set_key(key, updated_link)
		return true
	end
	return false
end

function M.delete_todo(id)
	-- 删除TODO端链接
	return M._delete_link(id, "todo")
end

function M.delete_code(id)
	-- 删除代码端链接
	return M._delete_link(id, "code")
end

function M._delete_link(id, link_type)
	local key = (link_type == "todo" and LINK_TYPE_CONFIG.todo or LINK_TYPE_CONFIG.code) .. id
	local link = store.get_key(key)
	if link then
		-- 从文件索引中移除
		local index_ns = link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code"
		index._remove_id_from_file_index(index_ns, link.path, id)
		-- 从存储中删除
		store.delete_key(key)

		-- 更新元数据计数
		local meta = require("todo2.store.meta")
		meta.decrement_links(link_type, link.active ~= false)

		return true
	end
	return false
end

function M.delete_link_pair(id)
	-- 同时删除链接对（两端）
	local todo_deleted = M.delete_todo(id)
	local code_deleted = M.delete_code(id)
	return todo_deleted or code_deleted
end

return M
