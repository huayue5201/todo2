-- lua/todo2/store/link.lua
--- @module todo2.store.link
--- 核心链接管理系统（数据为核心，归档作为状态）

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

	-- === 修复：禁止直接创建归档状态的链接 ===
	-- 归档应该通过状态机流转实现，而不是直接创建
	if status == types.STATUS.ARCHIVED then
		error(
			string.format(
				"不能直接创建归档状态的链接 (ID: %s)。\n"
					.. "请先创建为正常/完成状态，然后使用 archive_link() 函数进行归档。",
				id
			)
		)
	end

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
		-- 注意：只对完成状态设置 completed_at
		completed_at = (status == types.STATUS.COMPLETED) and (data.completed_at or now) or nil,
		archived_at = nil, -- 新创建的链接不应有归档时间
		archived_reason = nil,
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
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.TODO_TO_CODE)
	if not ok then
		vim.notify("创建TODO链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end

	store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
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
--- 更新链接状态（数据为核心）
function M.update_status(id, new_status, link_type)
	-- 验证状态值
	local valid_statuses = {
		[types.STATUS.NORMAL] = true,
		[types.STATUS.URGENT] = true,
		[types.STATUS.WAITING] = true,
		[types.STATUS.COMPLETED] = true,
		[types.STATUS.ARCHIVED] = true,
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
			local old_status = link.status
			link = state_machine.update_link_status(link, new_status)
			if link then
				store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
				results.todo = link

				-- 记录状态变更
				vim.schedule(function()
					vim.notify(string.format("TODO状态更新: %s -> %s", old_status, new_status), vim.log.levels.INFO)
				end)
			end
		end
	end

	-- 更新代码链接
	if not link_type or link_type == "code" then
		local link = M.get_code(id, { verify_line = true })
		if link then
			local old_status = link.status
			link = state_machine.update_link_status(link, new_status)
			if link then
				store.set_key(LINK_TYPE_CONFIG.code .. id, link)
				results.code = link

				-- 记录状态变更
				vim.schedule(function()
					vim.notify(
						string.format("代码状态更新: %s -> %s", old_status, new_status),
						vim.log.levels.INFO
					)
				end)
			end
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

--- 标记为归档
function M.mark_archived(id, link_type)
	return M.update_status(id, types.STATUS.ARCHIVED, link_type)
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

--- 标记链接为已归档（使用状态机）
--- @param id string 链接ID
--- @param reason string|nil 归档原因
--- @return table|nil 归档后的链接
function M.archive_link(id, reason)
	-- 通过状态机更新状态
	local link = M.update_status(id, types.STATUS.ARCHIVED, nil)
	if link then
		-- 设置归档原因
		if reason then
			link.archived_reason = reason
			-- 更新存储
			if link.type == types.LINK_TYPES.TODO_TO_CODE then
				store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			else
				store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			end
		end
		return link
	end
	return nil
end

--- 恢复已归档的链接（恢复到完成状态）
--- @param id string 链接ID
--- @return table|nil 恢复后的链接
function M.restore_archived_link(id)
	return M.update_status(id, types.STATUS.COMPLETED, nil)
end

--- 获取已归档的链接（通过状态查询）
--- @param days number|nil 多少天内的归档，nil表示所有
--- @return table 归档链接列表
function M.get_archived_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = {}

	-- 获取所有TODO链接
	local all_todo = M.get_all_todo()
	for id, link in pairs(all_todo) do
		if link.status == types.STATUS.ARCHIVED then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
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
	end

	-- 获取所有代码链接
	local all_code = M.get_all_code()
	for id, link in pairs(all_code) do
		if link.status == types.STATUS.ARCHIVED then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
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
		result.todo_archived = todo_link.status == types.STATUS.ARCHIVED
	end

	-- 检查代码链接
	local code_link = M.get_code(task_id)
	if code_link then
		result.code_link = code_link
		result.code_archived = code_link.status == types.STATUS.ARCHIVED
	end

	-- 判断完整性
	result.complete = result.todo_archived and result.code_archived

	return result
end

--- 批量归档已完成的链接
--- @param days number|nil 天数限制，nil表示所有
--- @return table 归档报告
function M.archive_completed_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local report = {
		total = 0,
		success = 0,
		failed = 0,
		failed_ids = {},
	}

	local all_todo = M.get_all_todo()
	for id, link in pairs(all_todo) do
		if link.status == types.STATUS.COMPLETED then
			local should_archive = true
			if cutoff_time > 0 then
				should_archive = link.completed_at and link.completed_at < cutoff_time
			end

			if should_archive then
				report.total = report.total + 1
				local success = M.archive_link(id, "auto_archive")
				if success then
					report.success = report.success + 1
				else
					report.failed = report.failed + 1
					table.insert(report.failed_ids, id)
				end
			end
		end
	end

	return report
end

--- 立即同步链接对（TODO和代码链接）
--- @param id string 链接ID
--- @return boolean 是否成功同步
function M.sync_link_pair_immediately(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	if not todo_link and not code_link then
		return false -- 两个链接都不存在
	end

	-- 确定主链接（使用更新时间最新的）
	local primary, secondary, primary_type
	if todo_link and code_link then
		if todo_link.updated_at >= code_link.updated_at then
			primary, secondary = todo_link, code_link
			primary_type = "todo"
		else
			primary, secondary = code_link, todo_link
			primary_type = "code"
		end

		-- 同步状态
		if secondary.status ~= primary.status then
			secondary.status = primary.status
			secondary.previous_status = primary.previous_status
			secondary.completed_at = primary.completed_at
			secondary.archived_at = primary.archived_at
			secondary.archived_reason = primary.archived_reason
			secondary.updated_at = os.time()
			secondary.sync_version = (secondary.sync_version or 0) + 1

			-- 保存更新
			if secondary.type == types.LINK_TYPES.TODO_TO_CODE then
				store.set_key(LINK_TYPE_CONFIG.todo .. id, secondary)
			else
				store.set_key(LINK_TYPE_CONFIG.code .. id, secondary)
			end

			return true
		end
		return true -- 状态已一致
	elseif todo_link then
		-- 只有TODO链接，尝试通过状态机修复
		local check = consistency.check_link_pair_consistency(id)
		if check.needs_repair then
			consistency.repair_link_pair(id, "todo_first")
			return true
		end
	elseif code_link then
		-- 只有代码链接，尝试通过状态机修复
		local check = consistency.check_link_pair_consistency(id)
		if check.needs_repair then
			consistency.repair_link_pair(id, "code_first")
			return true
		end
	end

	return false
end
return M
