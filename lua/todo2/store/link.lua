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
-- 链接操作
----------------------------------------------------------------------
--- 添加TODO链接
--- @param id string
--- @param data table
--- @return boolean
function M.add_todo(id, data)
	local now = os.time()
	local status = data.status or types.STATUS.NORMAL

	-- 只有完成状态才设置完成时间
	local completed_at = nil
	if status == types.STATUS.COMPLETED then
		completed_at = data.completed_at or now
	end

	-- 确保 previous_status 正确设置
	local previous_status = nil
	if status == types.STATUS.COMPLETED then
		-- 如果是完成状态，尝试从数据中获取 previous_status
		previous_status = data.previous_status
	end

	local link = {
		id = id,
		type = types.LINK_TYPES.TODO_TO_CODE,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = completed_at,
		status = status,
		previous_status = previous_status,
		active = true,
		context = data.context,
	}

	store.set_key("todo.links.todo." .. id, link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
	meta.increment_links(1)

	return true
end

--- 添加代码链接
--- @param id string
--- @param data table
--- @return boolean
function M.add_code(id, data)
	local now = os.time()

	-- 状态默认为 normal
	local status = data.status or types.STATUS.NORMAL

	-- 只有完成状态才设置完成时间
	local completed_at = nil
	if status == types.STATUS.COMPLETED then
		completed_at = data.completed_at or now
	end

	local link = {
		id = id,
		type = types.LINK_TYPES.CODE_TO_TODO,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = completed_at, -- 完成时间
		status = status, -- 状态
		previous_status = nil, -- 上一次状态（初始为空）
		active = true,
		context = data.context,
	}

	store.set_key("todo.links.code." .. id, link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)
	meta.increment_links(1)

	return true
end

--- 更新链接状态（核心函数）
--- @param id string
--- @param new_status string
--- @param link_type string|nil "todo" 或 "code"
--- @return table|nil 更新后的链接
function M.update_status(id, new_status, link_type)
	-- 确定链接类型
	if not link_type then
		-- 自动检测
		if store.get_key("todo.links.todo." .. id) then
			link_type = "todo"
		elseif store.get_key("todo.links.code." .. id) then
			link_type = "code"
		else
			return nil
		end
	end

	local key = string.format("todo.links.%s.%s", link_type, id)
	local link = store.get_key(key)

	if not link then
		return nil
	end

	local old_status = link.status or types.STATUS.NORMAL

	-- 记录状态变化
	link.previous_status = old_status
	link.status = new_status
	link.updated_at = os.time()

	-- 处理完成时间
	if new_status == types.STATUS.COMPLETED then
		-- 如果状态变为完成，设置完成时间
		link.completed_at = link.completed_at or os.time()
	elseif old_status == types.STATUS.COMPLETED then
		-- 如果从完成状态变为其他状态，清除完成时间
		link.completed_at = nil
	end

	store.set_key(key, link)

	return link
end

--- 标记为完成
--- @param id string
--- @param link_type string|nil
--- @return table|nil
function M.mark_completed(id, link_type)
	return M.update_status(id, types.STATUS.COMPLETED, link_type)
end

--- 标记为紧急
--- @param id string
--- @param link_type string|nil
--- @return table|nil
function M.mark_urgent(id, link_type)
	return M.update_status(id, types.STATUS.URGENT, link_type)
end

--- 标记为等待
--- @param id string
--- @param link_type string|nil
--- @return table|nil
function M.mark_waiting(id, link_type)
	return M.update_status(id, types.STATUS.WAITING, link_type)
end

--- 标记为正常
--- @param id string
--- @param link_type string|nil
--- @return table|nil
function M.mark_normal(id, link_type)
	return M.update_status(id, types.STATUS.NORMAL, link_type)
end

--- 恢复到上一次状态（主要用于从完成状态恢复）
--- @param id string
--- @param link_type string|nil
--- @return table|nil
function M.restore_previous_status(id, link_type)
	-- 确定链接类型
	if not link_type then
		-- 自动检测
		if store.get_key("todo.links.todo." .. id) then
			link_type = "todo"
		elseif store.get_key("todo.links.code." .. id) then
			link_type = "code"
		else
			return nil
		end
	end

	local key = string.format("todo.links.%s.%s", link_type, id)
	local link = store.get_key(key)

	if not link or not link.previous_status then
		return nil
	end

	-- 恢复到上一次状态
	return M.update_status(id, link.previous_status, link_type)
end

--- 获取TODO链接
--- @param id string
--- @param opts table|nil
--- @return table|nil
function M.get_todo(id, opts)
	opts = opts or {}
	local link = store.get_key("todo.links.todo." .. id)

	if link then
		-- 确保状态字段存在（向后兼容）
		if not link.status then
			link.status = types.STATUS.NORMAL
			link.previous_status = nil
		end

		if opts.force_relocate then
			link = M._relocate_link_if_needed(link, opts)
		end
	end

	return link
end

--- 获取代码链接
--- @param id string
--- @param opts table|nil
--- @return table|nil
function M.get_code(id, opts)
	opts = opts or {}
	local link = store.get_key("todo.links.code." .. id)

	if link then
		-- 确保状态字段存在（向后兼容）
		if not link.status then
			link.status = types.STATUS.NORMAL
			link.previous_status = nil
		end

		if opts.force_relocate then
			link = M._relocate_link_if_needed(link, opts)
		end
	end

	return link
end

--- 删除TODO链接
--- @param id string
function M.delete_todo(id)
	local link = M.get_todo(id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_todo", link.path, id)
		store.delete_key("todo.links.todo." .. id)
		meta.decrement_links(1)
	end
end

--- 删除代码链接
--- @param id string
function M.delete_code(id)
	local link = M.get_code(id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_code", link.path, id)
		store.delete_key("todo.links.code." .. id)
		meta.decrement_links(1)
	end
end

--- 更新链接
--- @param id string
--- @param updates table
--- @param link_type string
--- @return boolean
function M.update(id, updates, link_type)
	local key_prefix = link_type == types.LINK_TYPES.TODO_TO_CODE and "todo.links.todo" or "todo.links.code"
	local key = key_prefix .. "." .. id
	local link = store.get_key(key)

	if not link then
		return false
	end

	-- 如果更新了状态，处理状态变化逻辑
	if updates.status and updates.status ~= link.status then
		local old_status = link.status or types.STATUS.NORMAL

		-- 记录上一次状态
		updates.previous_status = old_status

		-- 处理完成时间
		if updates.status == types.STATUS.COMPLETED then
			updates.completed_at = updates.completed_at or os.time()
		elseif old_status == types.STATUS.COMPLETED then
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
-- 批量操作
----------------------------------------------------------------------
--- 根据状态筛选链接
--- @param status string
--- @param link_type string|nil "todo" 或 "code"
--- @return table
function M.filter_by_status(status, link_type)
	local results = {}

	-- 检查TODO链接
	if not link_type or link_type == "todo" then
		local todo_links = M.get_all_todo()
		for id, link in pairs(todo_links) do
			if (link.status or types.STATUS.NORMAL) == status then
				results[id] = link
			end
		end
	end

	-- 检查代码链接
	if not link_type or link_type == "code" then
		local code_links = M.get_all_code()
		for id, link in pairs(code_links) do
			if (link.status or types.STATUS.NORMAL) == status then
				results[id] = link
			end
		end
	end

	return results
end

--- 获取状态统计（与init.lua中的实现保持一致）
--- @param link_type string|nil
--- @return table
function M.get_status_stats(link_type)
	local stats = {
		total = 0,
		normal = 0,
		urgent = 0,
		waiting = 0,
		completed = 0,
	}

	-- 统计TODO链接
	if not link_type or link_type == "todo" then
		local todo_links = M.get_all_todo()
		for _, link_obj in pairs(todo_links) do
			stats.total = stats.total + 1
			local status = link_obj.status or "normal"
			stats[status] = (stats[status] or 0) + 1
		end
	end

	-- 统计代码链接
	if not link_type or link_type == "code" then
		local code_links = M.get_all_code()
		for _, link_obj in pairs(code_links) do
			stats.total = stats.total + 1
			local status = link_obj.status or "normal"
			stats[status] = (stats[status] or 0) + 1
		end
	end

	return stats
end

--- 获取所有TODO链接
--- @return table<string, table>
function M.get_all_todo()
	local ids = store.get_namespace_keys("todo.links.todo")
	local result = {}

	for _, id in ipairs(ids) do
		local link = store.get_key("todo.links.todo." .. id)
		if link and link.active ~= false then
			-- 确保状态字段存在（向后兼容）
			if not link.status then
				link.status = types.STATUS.NORMAL
				link.previous_status = nil
			end
			result[id] = link
		end
	end

	return result
end

--- 获取所有代码链接
--- @return table<string, table>
function M.get_all_code()
	local ids = store.get_namespace_keys("todo.links.code")
	local result = {}

	for _, id in ipairs(ids) do
		local link = store.get_key("todo.links.code." .. id)
		if link and link.active ~= false then
			-- 确保状态字段存在（向后兼容）
			if not link.status then
				link.status = types.STATUS.NORMAL
				link.previous_status = nil
			end
			result[id] = link
		end
	end

	return result
end

----------------------------------------------------------------------
-- 向后兼容和数据迁移
----------------------------------------------------------------------
--- 迁移旧数据，添加状态字段
--- @return number 迁移的数量
function M.migrate_status_fields()
	local migrated = 0

	-- 迁移TODO链接
	local todo_ids = store.get_namespace_keys("todo.links.todo")
	for _, id in ipairs(todo_ids) do
		local key = "todo.links.todo." .. id
		local link = store.get_key(key)
		if link and not link.status then
			link.status = types.STATUS.NORMAL
			link.previous_status = nil
			store.set_key(key, link)
			migrated = migrated + 1
		end
	end

	-- 迁移代码链接
	local code_ids = store.get_namespace_keys("todo.links.code")
	for _, id in ipairs(code_ids) do
		local key = "todo.links.code." .. id
		local link = store.get_key(key)
		if link and not link.status then
			link.status = types.STATUS.NORMAL
			link.previous_status = nil
			store.set_key(key, link)
			migrated = migrated + 1
		end
	end

	return migrated
end

--- 获取数据完整性报告（简化版本）
--- @return table
function M.get_integrity_report()
	local report = {
		total_links = 0,
		links_without_status = 0,
		completed_without_time = 0,
	}

	-- 检查TODO链接
	local todo_links = M.get_all_todo()
	for _, link in pairs(todo_links) do
		report.total_links = report.total_links + 1

		if not link.status then
			report.links_without_status = report.links_without_status + 1
		end

		if link.status == types.STATUS.COMPLETED and not link.completed_at then
			report.completed_without_time = report.completed_without_time + 1
		end
	end

	-- 检查代码链接
	local code_links = M.get_all_code()
	for _, link in pairs(code_links) do
		report.total_links = report.total_links + 1

		if not link.status then
			report.links_without_status = report.links_without_status + 1
		end

		if link.status == types.STATUS.COMPLETED and not link.completed_at then
			report.completed_without_time = report.completed_without_time + 1
		end
	end

	return report
end

--- 修复数据完整性问题（简化版本）
--- @return table
function M.fix_integrity_issues()
	local report = {
		fixed_status = 0,
		fixed_completion_time = 0,
	}

	-- 修复TODO链接
	local todo_ids = store.get_namespace_keys("todo.links.todo")
	for _, id in ipairs(todo_ids) do
		local key = "todo.links.todo." .. id
		local link = store.get_key(key)
		local changed = false

		if link then
			-- 修复缺失的状态
			if not link.status then
				link.status = types.STATUS.NORMAL
				link.previous_status = nil
				changed = true
				report.fixed_status = report.fixed_status + 1
			end

			-- 修复完成状态的时间问题
			if link.status == types.STATUS.COMPLETED and not link.completed_at then
				link.completed_at = link.created_at or os.time()
				changed = true
				report.fixed_completion_time = report.fixed_completion_time + 1
			end

			if changed then
				store.set_key(key, link)
			end
		end
	end

	-- 修复代码链接
	local code_ids = store.get_namespace_keys("todo.links.code")
	for _, id in ipairs(code_ids) do
		local key = "todo.links.code." .. id
		local link = store.get_key(key)
		local changed = false

		if link then
			-- 修复缺失的状态
			if not link.status then
				link.status = types.STATUS.NORMAL
				link.previous_status = nil
				changed = true
				report.fixed_status = report.fixed_status + 1
			end

			-- 修复完成状态的时间问题
			if link.status == types.STATUS.COMPLETED and not link.completed_at then
				link.completed_at = link.created_at or os.time()
				changed = true
				report.fixed_completion_time = report.fixed_completion_time + 1
			end

			if changed then
				store.set_key(key, link)
			end
		end
	end

	return report
end

----------------------------------------------------------------------
-- 链接重定位
----------------------------------------------------------------------
--- 重新定位链接（文件移动时使用）
--- @param link table
--- @param opts table
--- @return table
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

	-- 更新链接路径
	local old_path = link.path
	local new_path = matches[1]

	link.path = index._normalize_path(new_path)
	link.updated_at = os.time()

	-- 更新存储
	local key = link.type == types.LINK_TYPES.CODE_TO_TODO and "todo.links.code." .. link.id
		or "todo.links.todo." .. link.id

	store.set_key(key, link)

	-- 更新索引
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
