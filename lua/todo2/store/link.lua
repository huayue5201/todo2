-- lua/todo2/store/link.lua
-- 核心链接管理系统（无状态原子操作层）
-- ⭐ 确认：add_todo/add_code 中已正确调用 increment_links

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local locator = require("todo2.store.locator")
local hash = require("todo2.utils.hash")

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
local function create_link(id, data, link_type)
	local now = os.time()
	local tag = data.tag or "TODO"

	-- ⭐ 验证上下文是否来自正确的行
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
		id = id,
		type = link_type,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		tag = tag,
		status = data.status or types.STATUS.NORMAL,
		archived_at = nil,
		archived_reason = nil,
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = nil,
		previous_status = nil,
		pending_restore_status = nil,
		active = true,
		deleted_at = nil,
		deletion_reason = nil,
		restored_at = nil,
		line_verified = true,
		last_verified_at = nil,
		verification_failed_at = nil,
		verification_note = nil,
		context = data.context,
		context_matched = nil,
		context_similarity = nil,
		context_updated_at = data.context and now or nil,
		sync_version = 1,
		last_sync_at = nil,
		sync_status = "local",
		sync_pending = false,
		sync_conflict = false,
		content_hash = hash.hash(data.content or ""),
	}
	return link
end

local function get_link(id, link_type, opts)
	opts = opts or {}
	local key_prefix = link_type == "todo" and LINK_TYPE_CONFIG.todo or LINK_TYPE_CONFIG.code
	local key = key_prefix .. id
	local link = store.get_key(key)

	if not link then
		return nil
	end

	if opts.verify_line or opts.force_verify then
		-- ⭐ 修复：安全调用 locator.locate_task
		local success, verified = pcall(locator.locate_task, link)

		if not success or not verified then
			vim.notify(string.format("验证任务 %s 失败", id), vim.log.levels.DEBUG)
			return link -- 返回原始链接
		end

		-- 添加 nil 检查
		if verified.path and verified.line then
			if verified.path ~= link.path or verified.line ~= link.line then
				if verified.path ~= link.path then
					index._remove_id_from_file_index(
						link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code",
						link.path,
						id
					)
					index._add_id_to_file_index(
						link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code",
						verified.path,
						id
					)
				end
				verified.updated_at = os.time()
				store.set_key(key, verified)
				link = verified
			elseif not verified.line_verified and opts.force_verify then
				local new_path = locator.search_file_by_id(id)
				if new_path then
					verified.path = new_path
					verified.line_verified = false
					verified.updated_at = os.time()
					store.set_key(key, verified)
					link = verified
					vim.notify(
						string.format("找到移动的文件: %s", vim.fn.fnamemodify(new_path, ":.")),
						vim.log.levels.INFO
					)
				end
			else
				link = verified
			end
		else
			-- verified 没有有效的 path/line，返回原始链接
			return link
		end
	end

	return link
end

local function check_link_pair_integrity(todo_link, code_link, operation)
	if not todo_link and not code_link then
		return false, "链接ID不存在"
	end
	if todo_link and code_link then
		if todo_link.active == false or code_link.active == false then
			return false, "链接已被删除，不能修改状态"
		end
	end
	if (todo_link and not code_link) or (not todo_link and code_link) then
		return false, string.format("数据不一致：链接对只有一端存在 (操作: %s)", operation)
	end
	return true, nil
end

---------------------------------------------------------------------
-- 公共 API（无状态原子操作）
---------------------------------------------------------------------
function M.add_todo(id, data)
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.TODO_TO_CODE)
	if not ok then
		vim.notify("创建TODO链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end
	store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)

	-- ⭐ 传递活跃状态
	local meta = require("todo2.store.meta")
	meta.increment_links("todo", link.active ~= false)

	return true
end

function M.add_code(id, data)
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.CODE_TO_TODO)
	if not ok then
		vim.notify("创建代码链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end
	store.set_key(LINK_TYPE_CONFIG.code .. id, link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)

	-- ⭐ 传递活跃状态
	local meta = require("todo2.store.meta")
	meta.increment_links("code", link.active ~= false)

	return true
end

--- 获取TODO链接
--- @param id string 链接ID
--- @param opts table|nil
function M.get_todo(id, opts)
	opts = opts or {}
	return get_link(id, "todo", opts)
end

--- 获取代码链接
--- @param id string 链接ID
--- @param opts table|nil
function M.get_code(id, opts)
	opts = opts or {}
	return get_link(id, "code", opts)
end

--- 更新TODO链接（同时同步代码链接）
function M.update_todo(id, updated_link)
	local key = LINK_TYPE_CONFIG.todo .. id
	local old = store.get_key(key)

	if old then
		if old.path ~= updated_link.path then
			index._remove_id_from_file_index("todo.index.file_to_todo", old.path, id)
			index._add_id_to_file_index("todo.index.file_to_todo", updated_link.path, id)
		end
		updated_link.updated_at = os.time()
		store.set_key(key, updated_link)

		-- ⭐ 同步更新代码链接的内容
		local code_link = M.get_code(id, { verify_line = false })
		if code_link and code_link.content ~= updated_link.content then
			code_link.content = updated_link.content
			code_link.content_hash = updated_link.content_hash
			code_link.updated_at = os.time()
			M.update_code(id, code_link)
		end

		return true
	end
	return false
end

--- 更新代码链接
function M.update_code(id, updated_link)
	local key = LINK_TYPE_CONFIG.code .. id
	local old = store.get_key(key)

	if old then
		if old.path ~= updated_link.path then
			index._remove_id_from_file_index("todo.index.file_to_code", old.path, id)
			index._add_id_to_file_index("todo.index.file_to_code", updated_link.path, id)
		end
		updated_link.updated_at = os.time()
		store.set_key(key, updated_link)
		return true
	end
	return false
end

--- 标记任务为完成（原子操作）
--- @param id string 链接ID
--- @return table|nil 更新后的TODO链接
function M.mark_completed(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "mark_completed")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		-- 记录之前的状态，然后设置为完成
		todo_link.previous_status = todo_link.status
		todo_link.status = types.STATUS.COMPLETED
		todo_link.completed_at = os.time()
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		code_link.previous_status = code_link.status
		code_link.status = types.STATUS.COMPLETED
		code_link.completed_at = os.time()
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 重新打开任务（原子操作）
--- @param id string 链接ID
--- @return table|nil 更新后的TODO链接
function M.reopen_link(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "reopen_link")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		-- 恢复到之前的状态，或默认到NORMAL
		local target_status = todo_link.previous_status or types.STATUS.NORMAL

		-- 清除归档相关字段
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

	if code_link then
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

--- ⭐ 更新活跃状态（原子操作，无业务规则）
--- @param id string 链接ID
--- @param new_status string 新状态（normal/urgent/waiting）
--- @return table|nil 更新后的链接对象
function M.update_active_status(id, new_status)
	-- 只检查目标状态的合法性（存储层基本校验）
	if not types.is_active_status(new_status) then
		vim.notify("update_active_status 只能用于活跃状态: normal, urgent, waiting", vim.log.levels.ERROR)
		return nil
	end

	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "update_active_status")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	-- ⭐ 直接更新为传入的状态，由调用者决定要设置什么
	if todo_link then
		todo_link.status = new_status
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		code_link.status = new_status
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

-- ============================================================
-- 归档相关函数（原子操作）
-- ============================================================

--- 归档任务（原子操作）
--- @param id string 任务ID
--- @param reason string|nil 归档原因
--- @param opts table|nil 选项
---   - code_snapshot: table 代码快照
function M.mark_archived(id, reason, opts)
	opts = opts or {}

	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "mark_archived")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		-- 记录之前的状态，然后设置为归档
		todo_link.previous_status = todo_link.status
		todo_link.status = types.STATUS.ARCHIVED
		todo_link.archived_at = os.time()
		todo_link.archived_reason = reason or "manual"
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		code_link.previous_status = code_link.previous_status or code_link.status
		code_link.status = types.STATUS.ARCHIVED
		code_link.archived_at = os.time()
		code_link.archived_reason = reason or "manual"
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	if opts.code_snapshot then
		M.save_archive_snapshot(id, opts.code_snapshot, todo_link)
	end

	return results.todo or results.code
end

--- 取消归档（原子操作）
--- @param id string 任务ID
--- @param opts table|nil 选项
---   - delete_snapshot: boolean 是否删除快照（默认true）
function M.unarchive_link(id, opts)
	opts = opts or {}

	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "unarchive_link")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	-- 获取快照
	local snapshot = M.get_archive_snapshot(id)
	if not snapshot then
		vim.notify("找不到归档快照，无法恢复", vim.log.levels.ERROR)
		return nil
	end

	-- 验证快照完整性
	local checksum_str = string.format(
		"%s:%s:%s:%s",
		id,
		snapshot.todo.status or "unknown",
		snapshot.todo.completed_at or "0",
		snapshot.archived_at
	)
	local expected_checksum = hash.hash(checksum_str)

	if snapshot.checksum ~= expected_checksum then
		vim.notify("归档快照已损坏，无法恢复", vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		-- 恢复到完成状态
		todo_link.status = types.STATUS.COMPLETED
		todo_link.completed_at = snapshot.todo.completed_at or os.time()
		todo_link.previous_status = snapshot.todo.previous_status
		todo_link.created_at = snapshot.todo.created_at
		todo_link.updated_at = os.time()
		todo_link.archived_at = nil
		todo_link.archived_reason = nil
		todo_link.context = snapshot.todo.context
		todo_link.line_verified = snapshot.todo.line_verified

		-- 如果需要进一步恢复到活跃状态，设置待恢复标记
		if types.is_active_status(snapshot.todo.status) then
			todo_link.pending_restore_status = snapshot.todo.status
		end

		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		code_link.status = types.STATUS.COMPLETED
		code_link.previous_status = nil
		code_link.updated_at = os.time()
		code_link.archived_at = nil
		code_link.archived_reason = nil
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	if opts.delete_snapshot ~= false then
		M.delete_archive_snapshot(id)
	end

	return results.todo or results.code
end

---------------------------------------------------------------------
-- 归档快照管理
---------------------------------------------------------------------

--- 保存归档快照
function M.save_archive_snapshot(id, code_snapshot, todo_snapshot)
	local snapshot_key = "todo.archive.snapshot." .. id

	local todo_link = todo_snapshot or M.get_todo(id, { verify_line = false })

	local snapshot = {
		id = id,
		archived_at = os.time(),
		code = code_snapshot,
		todo = {
			id = id,
			path = todo_link and todo_link.path,
			line_num = todo_link and todo_link.line,
			content = todo_link and todo_link.content,
			tag = todo_link and todo_link.tag,
			status = todo_link and todo_link.status,
			previous_status = todo_link and todo_link.previous_status,
			completed_at = todo_link and todo_link.completed_at,
			created_at = todo_link and todo_link.created_at,
			updated_at = todo_link and todo_link.updated_at,
			archived_at = todo_link and todo_link.archived_at,
			context = todo_link and todo_link.context, -- ⭐ 保存上下文
			line_verified = todo_link and todo_link.line_verified,
			context_updated_at = todo_link and todo_link.context_updated_at,
		},
		metadata = {
			version = 2,
			has_context = todo_link and todo_link.context ~= nil,
		},
		checksum = nil,
	}

	local checksum_str = string.format(
		"%s:%s:%s:%s",
		id,
		snapshot.todo.status or "unknown",
		snapshot.todo.completed_at or "0",
		snapshot.archived_at
	)
	snapshot.checksum = hash.hash(checksum_str)

	store.set_key(snapshot_key, snapshot)
	return snapshot
end

--- 获取归档快照
function M.get_archive_snapshot(id)
	return store.get_key("todo.archive.snapshot." .. id)
end

--- 删除归档快照
function M.delete_archive_snapshot(id)
	store.delete_key("todo.archive.snapshot." .. id)
end

--- 获取所有归档快照
function M.get_all_archive_snapshots()
	local prefix = "todo.archive.snapshot."
	local keys = store.get_namespace_keys(prefix:sub(1, -2)) or {}
	local snapshots = {}

	for _, key in ipairs(keys) do
		local id = key:sub(#prefix + 1)
		local snapshot = store.get_key(key)
		if snapshot then
			table.insert(snapshots, snapshot)
		end
	end

	table.sort(snapshots, function(a, b)
		return (a.archived_at or 0) > (b.archived_at or 0)
	end)

	return snapshots
end

--- 从快照恢复代码标记（增强版：支持上下文指纹）
--- @param id string 任务ID
--- @param insert_pos number|nil 指定插入位置
--- @param opts table|nil 选项
---   - use_context: boolean 是否使用上下文定位
---   - similarity: number 相似度
---   - updated_context: table 更新后的上下文
--- @return boolean, string, table
function M.restore_from_snapshot(id, insert_pos, opts)
	opts = opts or {}
	local snapshot = M.get_archive_snapshot(id)
	if not snapshot then
		return false, "找不到归档快照", nil
	end

	if not snapshot.code then
		return false, "快照中没有代码标记信息", snapshot
	end

	local code_data = snapshot.code

	if vim.fn.filereadable(code_data.path) == 0 then
		return false, string.format("文件不存在: %s", code_data.path), snapshot
	end

	local target_line = insert_pos

	-- ⭐ 如果没有指定插入位置，使用上下文指纹定位
	if not target_line and opts.use_context ~= false and snapshot.todo and snapshot.todo.context then
		local locator = require("todo2.store.locator")
		local context_result = locator.locate_by_context_fingerprint(
			code_data.path,
			snapshot.todo.context,
			70 -- 相似度阈值
		)

		if context_result then
			target_line = context_result.line
			-- 更新快照中的上下文为新位置
			snapshot.todo.context = context_result.context
			store.set_key("todo.archive.snapshot." .. id, snapshot)

			vim.notify(
				string.format(
					"通过上下文指纹定位到行 %d (相似度: %d%%)",
					target_line,
					context_result.similarity
				),
				vim.log.levels.INFO
			)
		end
	end

	-- 如果还是没有找到，使用原有的 find_restore_position
	if not target_line then
		local locator = require("todo2.store.locator")
		target_line = locator.find_restore_position(code_data)
	end

	-- ⭐ 获取或更新上下文
	local context_module = require("todo2.store.context")
	local new_context = opts.updated_context

	if not new_context then
		if vim.api.nvim_buf_is_valid(0) and vim.fn.expand("%:p") == code_data.path then
			-- 如果文件已打开，从缓冲区获取上下文
			new_context = context_module.build_from_buffer(0, target_line):to_storable()
		else
			-- 否则从文件读取
			local lines = vim.fn.readfile(code_data.path)
			local prev = target_line > 1 and lines[target_line - 1] or ""
			local curr = lines[target_line]
			local next = target_line < #lines and lines[target_line + 1] or ""
			new_context = context_module.build(prev, curr, next)
		end
	end

	local success = M.add_code(id, {
		path = code_data.path,
		line = target_line,
		content = code_data.content,
		tag = code_data.tag,
		context = new_context,
	})

	if success then
		return true, string.format("已恢复代码标记到行 %d", target_line), snapshot
	else
		return false, "添加代码链接失败", snapshot
	end
end

--- 批量从快照恢复
function M.batch_restore_from_snapshots(ids, opts)
	opts = opts or {}
	local result = {
		total = #ids,
		success = 0,
		failed = 0,
		skipped = 0,
		details = {},
	}

	for _, id in ipairs(ids) do
		local snapshot = M.get_archive_snapshot(id)
		if not snapshot then
			table.insert(result.details, {
				id = id,
				success = false,
				message = "快照不存在",
				has_code = false,
			})
			result.failed = result.failed + 1
			goto continue
		end

		-- ⭐ 使用上下文定位
		local target_line = nil
		if opts.use_context and snapshot.todo and snapshot.todo.context then
			local locator = require("todo2.store.locator")
			local context_result = locator.locate_by_context_fingerprint(
				snapshot.code.path,
				snapshot.todo.context,
				opts.similarity_threshold or 70
			)
			if context_result then
				target_line = context_result.line
				-- 更新快照中的上下文
				snapshot.todo.context = context_result.context
				store.set_key("todo.archive.snapshot." .. id, snapshot)
			end
		end

		-- 执行恢复
		local ok, msg = M.restore_from_snapshot(id, target_line, {
			use_context = opts.use_context,
		})

		table.insert(result.details, {
			id = id,
			success = ok,
			message = msg,
			has_code = snapshot and snapshot.code ~= nil,
		})

		if ok then
			result.success = result.success + 1
		else
			result.failed = result.failed + 1
		end

		::continue::
	end

	result.summary = string.format("批量恢复完成: 成功 %d, 失败 %d", result.success, result.failed)

	return result
end

---------------------------------------------------------------------
-- 删除操作
---------------------------------------------------------------------
function M.delete_todo(id)
	local link = store.get_key(LINK_TYPE_CONFIG.todo .. id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_todo", link.path, id)
		store.delete_key(LINK_TYPE_CONFIG.todo .. id)

		-- ⭐ 传递活跃状态
		local meta = require("todo2.store.meta")
		meta.decrement_links("todo", link.active ~= false)

		return true
	end
	return false
end

function M.delete_code(id)
	local link = store.get_key(LINK_TYPE_CONFIG.code .. id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_code", link.path, id)
		store.delete_key(LINK_TYPE_CONFIG.code .. id)

		-- ⭐ 传递活跃状态
		local meta = require("todo2.store.meta")
		meta.decrement_links("code", link.active ~= false)

		return true
	end
	return false
end

--- 硬删除链接对
function M.delete_link_pair(id)
	local todo_deleted = M.delete_todo(id)
	local code_deleted = M.delete_code(id)
	return todo_deleted or code_deleted
end

---------------------------------------------------------------------
-- 查询函数
---------------------------------------------------------------------

--- 获取所有TODO链接
function M.get_all_todo()
	local prefix = LINK_TYPE_CONFIG.todo:sub(1, -2)
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

--- 获取所有代码链接
function M.get_all_code()
	local prefix = LINK_TYPE_CONFIG.code:sub(1, -2)
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
function M.get_archived_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = {}
	local all_todo = M.get_all_todo()
	for id, link in pairs(all_todo) do
		if link.status == types.STATUS.ARCHIVED and link.active ~= false then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
				result[id] = result[id] or {}
				result[id].todo = link
			end
		end
	end
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

function M.is_completed(id)
	local todo_link = M.get_todo(id, { verify_line = false })
	local code_link = M.get_code(id, { verify_line = false })
	if todo_link and code_link then
		return types.is_completed_status(todo_link.status) and types.is_completed_status(code_link.status)
	end
	return false
end

function M.is_archived(id)
	local todo_link = M.get_todo(id, { verify_line = false })
	local code_link = M.get_code(id, { verify_line = false })
	if todo_link and code_link then
		return todo_link.status == types.STATUS.ARCHIVED and code_link.status == types.STATUS.ARCHIVED
	end
	return false
end

---------------------------------------------------------------------
-- ⭐ 辅助函数：获取任务组的进度（包括父任务自身）
---------------------------------------------------------------------

--- 递归获取任务组的所有任务
--- @param root_id string 根任务ID
--- @param all_todo table 所有TODO链接
--- @param result table 用于收集结果的表（递归用）
--- @return table 任务列表
local function collect_task_group(root_id, all_todo, result)
	result = result or {}

	-- 添加自身
	if not result[root_id] then
		result[root_id] = all_todo[root_id]
	end

	-- 查找所有子任务
	for id, todo in pairs(all_todo) do
		if id:match("^" .. root_id:gsub("%.", "%%.") .. "%.") then
			if not result[id] then
				result[id] = todo
				-- 递归收集该子任务的子任务
				collect_task_group(id, all_todo, result)
			end
		end
	end

	return result
end

--- 获取任务组的完成进度（包括父任务自身）
--- @param root_id string 根任务ID
--- @return table|nil 进度信息
function M.get_group_progress(root_id)
	local all_todo = M.get_all_todo()
	if not all_todo or vim.tbl_isempty(all_todo) then
		return nil
	end

	-- 收集任务组所有成员
	local group = collect_task_group(root_id, all_todo, {})

	-- 如果只有自己一个任务，返回nil
	if vim.tbl_count(group) <= 1 then
		return nil
	end

	local completed = 0
	local total = 0

	for _, task in pairs(group) do
		total = total + 1
		if task and types.is_completed_status(task.status) then
			completed = completed + 1
		end
	end

	return {
		done = completed,
		total = total,
		percent = math.floor(completed / total * 100),
		group_size = total,
	}
end

--- 获取任务组的所有成员
--- @param root_id string 根任务ID
--- @return table 任务列表
function M.get_task_group(root_id)
	local all_todo = M.get_all_todo()
	if not all_todo then
		return {}
	end

	local group = collect_task_group(root_id, all_todo, {})
	return vim.tbl_values(group)
end

return M
