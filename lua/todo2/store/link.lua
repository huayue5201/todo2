-- lua/todo2/store/link.lua
--- @module todo2.store.link

local M = {}

---------------------------------------------------------------------
-- 依赖模块
---------------------------------------------------------------------
local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local meta = require("todo2.store.meta")

----------------------------------------------------------------------
-- 内部辅助函数（最小化改动）
----------------------------------------------------------------------
-- 创建链接的通用函数
local function _create_link(id, data, link_type)
	local now = os.time()
	local status = data.status or types.STATUS.NORMAL

	-- 简化的完成时间处理
	local completed_at = (status == types.STATUS.COMPLETED) and (data.completed_at or now) or nil

	local link = {
		id = id,
		type = link_type,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = completed_at,
		status = status,
		previous_status = data.previous_status,
		active = true,
		context = data.context,
	}

	return link
end

-- 获取链接的通用函数
local function _get_link(id, key_prefix, opts)
	opts = opts or {}
	local key = key_prefix .. id
	local link = store.get_key(key)

	if link then
		-- 向后兼容：确保状态字段存在
		if not link.status then
			link.status = types.STATUS.NORMAL
			link.previous_status = nil
			link.completed_at = nil
		end

		if opts.force_relocate then
			link = M._relocate_link_if_needed(link, opts)
		end
	end

	return link
end

-- 删除链接的通用函数
local function _delete_link(id, key_prefix, index_name)
	local key = key_prefix .. id
	local link = store.get_key(key)

	if link then
		index._remove_id_from_file_index(index_name, link.path, id)
		store.delete_key(key)
		meta.decrement_links(1)
	end
end

-- 智能更新previous_status的通用逻辑
local function _smart_update_previous_status(link, new_status)
	local old_status = link.status or types.STATUS.NORMAL

	-- 简化的逻辑：只有两种情况需要更新previous_status
	if new_status == types.STATUS.COMPLETED and old_status ~= types.STATUS.COMPLETED then
		-- 切换到完成状态：保存当前状态
		return old_status
	elseif old_status == types.STATUS.COMPLETED then
		-- 从完成状态切换出去：保持previous_status不变
		return link.previous_status
	else
		-- 其他情况：正常更新
		return old_status
	end
end

----------------------------------------------------------------------
-- 链接操作（保持API不变，简化实现）
----------------------------------------------------------------------
--- 添加TODO链接
function M.add_todo(id, data)
	local link = _create_link(id, data, types.LINK_TYPES.TODO_TO_CODE)
	store.set_key("todo.links.todo." .. id, link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
	meta.increment_links(1)
	return true
end

--- 添加代码链接
function M.add_code(id, data)
	local link = _create_link(id, data, types.LINK_TYPES.CODE_TO_TODO)
	store.set_key("todo.links.code." .. id, link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)
	meta.increment_links(1)
	return true
end

--- 更新链接状态（核心函数 - 简化版）
function M.update_status(id, new_status, link_type)
	-- 自动检测链接类型
	if not link_type then
		if store.get_key("todo.links.todo." .. id) then
			link_type = "todo"
		elseif store.get_key("todo.links.code." .. id) then
			link_type = "code"
		else
			return nil
		end
	end

	local key = "todo.links." .. link_type .. "." .. id
	local link = store.get_key(key)

	if not link then
		return nil
	end

	-- 简化previous_status更新
	link.previous_status = _smart_update_previous_status(link, new_status)
	link.status = new_status
	link.updated_at = os.time()

	-- 简化completed_at处理
	if new_status == types.STATUS.COMPLETED then
		link.completed_at = link.completed_at or os.time()
	elseif link.completed_at then
		link.completed_at = nil
	end

	store.set_key(key, link)
	return link
end

--- 标记为完成
function M.mark_completed(id, link_type)
	return M.update_status(id, types.STATUS.COMPLETED, link_type)
end

--- 标记为紧急
function M.mark_urgent(id, link_type)
	return M.update_status(id, types.STATUS.URGENT, link_type)
end

--- 标记为等待
function M.mark_waiting(id, link_type)
	return M.update_status(id, types.STATUS.WAITING, link_type)
end

--- 标记为正常
function M.mark_normal(id, link_type)
	return M.update_status(id, types.STATUS.NORMAL, link_type)
end

--- 恢复到上一次状态
function M.restore_previous_status(id, link_type)
	if not link_type then
		if store.get_key("todo.links.todo." .. id) then
			link_type = "todo"
		elseif store.get_key("todo.links.code." .. id) then
			link_type = "code"
		else
			return nil
		end
	end

	local key = "todo.links." .. link_type .. "." .. id
	local link = store.get_key(key)

	if not link or not link.previous_status then
		return nil
	end

	return M.update_status(id, link.previous_status, link_type)
end

--- 获取TODO链接
function M.get_todo(id, opts)
	return _get_link(id, "todo.links.todo.", opts)
end

--- 获取代码链接
function M.get_code(id, opts)
	return _get_link(id, "todo.links.code.", opts)
end

--- 删除TODO链接
function M.delete_todo(id)
	_delete_link(id, "todo.links.todo.", "todo.index.file_to_todo")
end

--- 删除代码链接
function M.delete_code(id)
	_delete_link(id, "todo.links.code.", "todo.index.file_to_code")
end

--- 更新链接
function M.update(id, updates, link_type)
	local key_prefix = link_type == types.LINK_TYPES.TODO_TO_CODE and "todo.links.todo" or "todo.links.code"
	local key = key_prefix .. "." .. id
	local link = store.get_key(key)

	if not link then
		return false
	end

	-- 如果更新状态，复用智能更新逻辑
	if updates.status and updates.status ~= link.status then
		updates.previous_status = _smart_update_previous_status(link, updates.status)

		-- 处理完成时间
		if updates.status == types.STATUS.COMPLETED then
			updates.completed_at = updates.completed_at or os.time()
		elseif link.completed_at then
			updates.completed_at = nil
		end
	end

	updates.updated_at = os.time()

	-- 合并更新
	for k, v in pairs(updates) do
		link[k] = v
	end

	store.set_key(key, link)
	return true
end

----------------------------------------------------------------------
-- 批量操作（简化实现）
----------------------------------------------------------------------
--- 根据状态筛选链接
function M.filter_by_status(status, link_type)
	local results = {}

	local function process_links(links)
		for id, link in pairs(links) do
			if (link.status or types.STATUS.NORMAL) == status then
				results[id] = link
			end
		end
	end

	if not link_type or link_type == "todo" then
		process_links(M.get_all_todo())
	end

	if not link_type or link_type == "code" then
		process_links(M.get_all_code())
	end

	return results
end

--- 获取状态统计
function M.get_status_stats(link_type)
	local stats = {
		total = 0,
		normal = 0,
		urgent = 0,
		waiting = 0,
		completed = 0,
	}

	local function count_links(links)
		for _, link in pairs(links) do
			stats.total = stats.total + 1
			local status = link.status or "normal"
			stats[status] = (stats[status] or 0) + 1
		end
	end

	if not link_type or link_type == "todo" then
		count_links(M.get_all_todo())
	end

	if not link_type or link_type == "code" then
		count_links(M.get_all_code())
	end

	return stats
end

--- 获取所有TODO链接
function M.get_all_todo()
	local ids = store.get_namespace_keys("todo.links.todo")
	local result = {}

	for _, id in ipairs(ids) do
		local link = M.get_todo(id) -- 复用get_todo确保向后兼容
		if link and link.active ~= false then
			result[id] = link
		end
	end

	return result
end

--- 获取所有代码链接
function M.get_all_code()
	local ids = store.get_namespace_keys("todo.links.code")
	local result = {}

	for _, id in ipairs(ids) do
		local link = M.get_code(id) -- 复用get_code确保向后兼容
		if link and link.active ~= false then
			result[id] = link
		end
	end

	return result
end

----------------------------------------------------------------------
-- 向后兼容和数据迁移（简化版）
----------------------------------------------------------------------
function M.migrate_status_fields()
	local migrated = 0

	local function migrate_links(key_prefix, link_type)
		local ids = store.get_namespace_keys(key_prefix)
		for _, id in ipairs(ids) do
			local key = key_prefix .. id
			local link = store.get_key(key)
			if link and not link.status then
				link.status = types.STATUS.NORMAL
				link.previous_status = nil
				if link.content and link.content:match("%[x%]") then
					link.status = types.STATUS.COMPLETED
					link.completed_at = link.completed_at or link.created_at
				end
				store.set_key(key, link)
				migrated = migrated + 1
			end
		end
	end

	migrate_links("todo.links.todo.", "todo")
	migrate_links("todo.links.code.", "code")

	return migrated
end

--- 获取数据完整性报告
function M.get_integrity_report()
	local report = {
		total_links = 0,
		links_without_status = 0,
		completed_without_time = 0,
		invalid_completed_at = 0,
	}

	local function check_links(links)
		for _, link in pairs(links) do
			report.total_links = report.total_links + 1

			if not link.status then
				report.links_without_status = report.links_without_status + 1
			end

			if link.status == types.STATUS.COMPLETED then
				if not link.completed_at then
					report.completed_without_time = report.completed_without_time + 1
				elseif link.completed_at < link.created_at then
					report.invalid_completed_at = report.invalid_completed_at + 1
				end
			end
		end
	end

	check_links(M.get_all_todo())
	check_links(M.get_all_code())

	return report
end

--- 修复数据完整性问题
function M.fix_integrity_issues()
	local report = {
		fixed_status = 0,
		fixed_completion_time = 0,
	}

	local function fix_links(key_prefix)
		local ids = store.get_namespace_keys(key_prefix)
		for _, id in ipairs(ids) do
			local key = key_prefix .. id
			local link = store.get_key(key)
			local changed = false

			if link then
				-- 修复缺失的状态
				if not link.status then
					link.status = types.STATUS.NORMAL
					link.previous_status = nil
					link.completed_at = nil
					changed = true
					report.fixed_status = report.fixed_status + 1
				end

				-- 修复完成状态的时间问题
				if link.status == types.STATUS.COMPLETED then
					if not link.completed_at then
						link.completed_at = link.created_at or os.time()
						changed = true
						report.fixed_completion_time = report.fixed_completion_time + 1
					elseif link.completed_at < link.created_at then
						link.completed_at = link.created_at or os.time()
						changed = true
						report.fixed_completion_time = report.fixed_completion_time + 1
					end
				elseif link.completed_at then
					link.completed_at = nil
					changed = true
				end

				if changed then
					store.set_key(key, link)
				end
			end
		end
	end

	fix_links("todo.links.todo.")
	fix_links("todo.links.code.")

	return report
end

----------------------------------------------------------------------
-- 链接重定位（保持不变）
----------------------------------------------------------------------
function M._relocate_link_if_needed(link, opts)
	opts = opts or {}
	local verbose = opts.verbose or false

	if not link or not link.path then
		return link
	end

	local norm = index._normalize_path(link.path)
	if vim.fn.filereadable(norm) == 1 then
		return link
	end

	local project_root = meta.get_project_root()
	local filename = vim.fn.fnamemodify(link.path, ":t")
	if filename == "" then
		return link
	end

	local pattern = project_root .. "/**/" .. filename
	local matches = vim.fn.glob(pattern, false, true)

	if #matches == 0 then
		if verbose then
			vim.notify("todo2: 无法重新定位 " .. link.id, vim.log.levels.DEBUG)
		end
		return link
	end

	local old_path = link.path
	local new_path = matches[1]

	link.path = index._normalize_path(new_path)
	link.updated_at = os.time()

	local key = link.type == types.LINK_TYPES.CODE_TO_TODO and "todo.links.code." .. link.id
		or "todo.links.todo." .. link.id

	store.set_key(key, link)

	if link.type == types.LINK_TYPES.CODE_TO_TODO then
		index._remove_id_from_file_index("todo.index.file_to_code", old_path, link.id)
		index._add_id_to_file_index("todo.index.file_to_code", new_path, link.id)
	else
		index._remove_id_from_file_index("todo.index.file_to_todo", old_path, link.id)
		index._add_id_to_file_index("todo.index.file_to_todo", new_path, link.id)
	end

	return link
end

return M
