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

---------------------------------------------------------------------
-- 内部配置常量（新增：消除魔法字符串）
---------------------------------------------------------------------
local LINK_TYPE_CONFIG = {
	todo = {
		key_prefix = "todo.links.todo.",
		index_ns = "todo.index.file_to_todo",
		link_type = types.LINK_TYPES.TODO_TO_CODE,
	},
	code = {
		key_prefix = "todo.links.code.",
		index_ns = "todo.index.file_to_code",
		link_type = types.LINK_TYPES.CODE_TO_TODO,
	},
}

----------------------------------------------------------------------
-- 内部辅助函数
----------------------------------------------------------------------

-- 判断是否为活跃状态
local function is_active_status(status)
	return status == types.STATUS.NORMAL or status == types.STATUS.URGENT or status == types.STATUS.WAITING
end

-- 创建链接的通用函数
local function _create_link(id, data, link_type)
	local now = os.time()
	local status = data.status or types.STATUS.NORMAL

	-- 简化的完成时间处理
	local completed_at = (status == types.STATUS.COMPLETED) and (data.completed_at or now) or nil

	-- 移除冗余的 previous_status 初始化（新链接无历史状态）
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
		previous_status = nil, -- 简化：新链接默认nil
		active = true,
		context = data.context,
	}

	return link
end

----------------------------------------------------------------------
-- 通用增删查函数（新增：抽象重复逻辑）
----------------------------------------------------------------------

-- 通用添加链接
local function _add_link(id, data, link_type)
	local cfg = LINK_TYPE_CONFIG[link_type]
	local link = _create_link(id, data, cfg.link_type)

	store.set_key(cfg.key_prefix .. id, link)
	index._add_id_to_file_index(cfg.index_ns, link.path, id)
	meta.increment_links(link_type) -- 按类型计数

	return true
end

-- 获取链接的通用函数
local function _get_link(id, link_type, opts)
	local cfg = LINK_TYPE_CONFIG[link_type]
	opts = opts or {}
	local key = cfg.key_prefix .. id
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
local function _delete_link(id, link_type)
	local cfg = LINK_TYPE_CONFIG[link_type]
	local key = cfg.key_prefix .. id
	local link = store.get_key(key)

	if link then
		index._remove_id_from_file_index(cfg.index_ns, link.path, id)
		store.delete_key(key)
		meta.decrement_links(link_type) -- 按类型计数
	end
end

-- 智能更新previous_status的通用逻辑
local function _smart_update_previous_status(link, new_status)
	local old_status = link.status or types.STATUS.NORMAL

	-- 情况1: 从活跃状态切换到完成状态
	if new_status == types.STATUS.COMPLETED and is_active_status(old_status) then
		-- 保存当前的活跃状态
		return old_status
	end

	-- 情况2: 从完成状态切换到活跃状态
	if old_status == types.STATUS.COMPLETED and is_active_status(new_status) then
		-- 使用之前保存的活跃状态（如果有）
		return link.previous_status
	end

	-- 情况3: 在活跃状态之间切换
	if is_active_status(old_status) and is_active_status(new_status) then
		-- 保持 previous_status 不变
		return link.previous_status
	end

	-- 默认情况
	return link.previous_status
end

-- 调试状态流转（可选，调试时启用）
local function debug_status_transition(link, old_status, new_status)
	print(string.format("[状态流转调试] ID: %s", link.id))
	print(string.format("  旧状态: %s (活跃: %s)", old_status, is_active_status(old_status)))
	print(string.format("  新状态: %s (活跃: %s)", new_status, is_active_status(new_status)))
	print(string.format("  previous_status: %s", link.previous_status or "nil"))
	print(string.format("  操作: %s -> %s", old_status, new_status))
	print("")
end

----------------------------------------------------------------------
-- ⭐ 关键修复：更新链接状态（核心函数） - 修复版本
----------------------------------------------------------------------
function M.update_status(id, new_status, link_type)
	-- 如果指定了链接类型，只更新该类型
	if link_type then
		local cfg = LINK_TYPE_CONFIG[link_type]
		local key = cfg.key_prefix .. id
		local link = store.get_key(key)

		if not link then
			return nil
		end

		local old_status = link.status or types.STATUS.NORMAL

		-- 更新 previous_status
		link.previous_status = _smart_update_previous_status(link, new_status)
		link.status = new_status
		link.updated_at = os.time()

		-- 处理完成时间
		if new_status == types.STATUS.COMPLETED then
			link.completed_at = link.completed_at or os.time()
		else
			link.completed_at = nil
		end

		store.set_key(key, link)
		return link
	else
		-- ⭐ 关键修复：同时更新 TODO 和代码链接
		local todo_cfg = LINK_TYPE_CONFIG.todo
		local code_cfg = LINK_TYPE_CONFIG.code
		local todo_key = todo_cfg.key_prefix .. id
		local code_key = code_cfg.key_prefix .. id
		local todo_link = store.get_key(todo_key)
		local code_link = store.get_key(code_key)

		local results = {}

		-- 更新 TODO 链接（如果存在）
		if todo_link then
			local old_status = todo_link.status or types.STATUS.NORMAL
			-- 调试输出（需要时启用）
			-- debug_status_transition(todo_link, old_status, new_status)

			todo_link.previous_status = _smart_update_previous_status(todo_link, new_status)
			todo_link.status = new_status
			todo_link.updated_at = os.time()

			if new_status == types.STATUS.COMPLETED then
				todo_link.completed_at = todo_link.completed_at or os.time()
			else
				todo_link.completed_at = nil
			end

			store.set_key(todo_key, todo_link)
			results.todo = todo_link
		end

		-- 更新代码链接（如果存在）
		if code_link then
			local old_status = code_link.status or types.STATUS.NORMAL
			-- 调试输出（需要时启用）
			-- debug_status_transition(code_link, old_status, new_status)

			code_link.previous_status = _smart_update_previous_status(code_link, new_status)
			code_link.status = new_status
			code_link.updated_at = os.time()

			if new_status == types.STATUS.COMPLETED then
				code_link.completed_at = code_link.completed_at or os.time()
			else
				code_link.completed_at = nil
			end

			store.set_key(code_key, code_link)
			results.code = code_link
		end

		-- 返回至少一个更新后的链接
		return results.todo or results.code or nil
	end
end

----------------------------------------------------------------------
-- 快捷状态函数 - 修复版本
----------------------------------------------------------------------

--- 标记为完成（同时更新两种链接）
function M.mark_completed(id, link_type)
	if link_type then
		return M.update_status(id, types.STATUS.COMPLETED, link_type)
	else
		-- 不指定链接类型，同时更新两种
		return M.update_status(id, types.STATUS.COMPLETED)
	end
end

--- 标记为紧急（同时更新两种链接）
function M.mark_urgent(id, link_type)
	if link_type then
		return M.update_status(id, types.STATUS.URGENT, link_type)
	else
		return M.update_status(id, types.STATUS.URGENT)
	end
end

--- 标记为等待（同时更新两种链接）
function M.mark_waiting(id, link_type)
	if link_type then
		return M.update_status(id, types.STATUS.WAITING, link_type)
	else
		return M.update_status(id, types.STATUS.WAITING)
	end
end

--- 标记为正常（同时更新两种链接）
function M.mark_normal(id, link_type)
	if link_type then
		return M.update_status(id, types.STATUS.NORMAL, link_type)
	else
		return M.update_status(id, types.STATUS.NORMAL)
	end
end

--- 恢复到上一次状态（同时更新两种链接）
function M.restore_previous_status(id, link_type)
	if link_type then
		-- 只更新指定类型的链接
		local cfg = LINK_TYPE_CONFIG[link_type]
		local key = cfg.key_prefix .. id
		local link = store.get_key(key)

		if not link then
			return nil
		end

		-- 只有在完成状态时才能恢复到之前的活跃状态
		if link.status ~= types.STATUS.COMPLETED then
			return nil
		end

		-- 确定要恢复的状态
		local restore_status = link.previous_status or types.STATUS.NORMAL

		-- 直接更新状态
		link.status = restore_status
		link.updated_at = os.time()
		link.completed_at = nil
		-- previous_status 保持不变，以便再次标记完成时可以恢复

		store.set_key(key, link)
		return link
	else
		-- ⭐ 关键修复：同时尝试恢复两种链接
		local todo_cfg = LINK_TYPE_CONFIG.todo
		local code_cfg = LINK_TYPE_CONFIG.code
		local todo_key = todo_cfg.key_prefix .. id
		local code_key = code_cfg.key_prefix .. id
		local todo_link = store.get_key(todo_key)
		local code_link = store.get_key(code_key)

		local results = {}

		-- 恢复 TODO 链接（如果存在且处于完成状态）
		if todo_link and todo_link.status == types.STATUS.COMPLETED then
			local restore_status = todo_link.previous_status or types.STATUS.NORMAL
			todo_link.status = restore_status
			todo_link.updated_at = os.time()
			todo_link.completed_at = nil
			store.set_key(todo_key, todo_link)
			results.todo = todo_link
		end

		-- 恢复代码链接（如果存在且处于完成状态）
		if code_link and code_link.status == types.STATUS.COMPLETED then
			local restore_status = code_link.previous_status or types.STATUS.NORMAL
			code_link.status = restore_status
			code_link.updated_at = os.time()
			code_link.completed_at = nil
			store.set_key(code_key, code_link)
			results.code = code_link
		end

		-- 返回至少一个恢复后的链接
		return results.todo or results.code or nil
	end
end

----------------------------------------------------------------------
-- 链接操作（复用通用函数）
----------------------------------------------------------------------

--- 添加TODO链接
function M.add_todo(id, data)
	return _add_link(id, data, "todo")
end

--- 添加代码链接
function M.add_code(id, data)
	return _add_link(id, data, "code")
end

--- 获取TODO链接
function M.get_todo(id, opts)
	return _get_link(id, "todo", opts)
end

--- 获取代码链接
function M.get_code(id, opts)
	return _get_link(id, "code", opts)
end

--- 删除TODO链接
function M.delete_todo(id)
	_delete_link(id, "todo")
end

--- 删除代码链接
function M.delete_code(id)
	_delete_link(id, "code")
end

--- 更新链接
function M.update(id, updates, link_type)
	local cfg = link_type == types.LINK_TYPES.TODO_TO_CODE and LINK_TYPE_CONFIG.todo or LINK_TYPE_CONFIG.code
	local key = cfg.key_prefix .. id
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
-- 批量操作（保持不变）
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
			local status = link.status or types.STATUS.NORMAL
			if status == types.STATUS.NORMAL then
				stats.normal = stats.normal + 1
			elseif status == types.STATUS.URGENT then
				stats.urgent = stats.urgent + 1
			elseif status == types.STATUS.WAITING then
				stats.waiting = stats.waiting + 1
			elseif status == types.STATUS.COMPLETED then
				stats.completed = stats.completed + 1
			end
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
	local ids = store.get_namespace_keys(LINK_TYPE_CONFIG.todo.key_prefix:sub(1, -2)) -- 去掉末尾的.
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
	local ids = store.get_namespace_keys(LINK_TYPE_CONFIG.code.key_prefix:sub(1, -2)) -- 去掉末尾的.
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
-- 向后兼容和数据迁移（保持不变）
----------------------------------------------------------------------

function M.migrate_status_fields()
	local migrated = 0

	local function migrate_links(link_type)
		local cfg = LINK_TYPE_CONFIG[link_type]
		local ids = store.get_namespace_keys(cfg.key_prefix:sub(1, -2))
		for _, id in ipairs(ids) do
			local key = cfg.key_prefix .. id
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

	migrate_links("todo")
	migrate_links("code")

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

	local function fix_links(link_type)
		local cfg = LINK_TYPE_CONFIG[link_type]
		local ids = store.get_namespace_keys(cfg.key_prefix:sub(1, -2))
		for _, id in ipairs(ids) do
			local key = cfg.key_prefix .. id
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

	fix_links("todo")
	fix_links("code")

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

	local cfg = link.type == types.LINK_TYPES.CODE_TO_TODO and LINK_TYPE_CONFIG.code or LINK_TYPE_CONFIG.todo
	local key = cfg.key_prefix .. link.id

	store.set_key(key, link)

	if link.type == types.LINK_TYPES.CODE_TO_TODO then
		index._remove_id_from_file_index(LINK_TYPE_CONFIG.code.index_ns, old_path, link.id)
		index._add_id_to_file_index(LINK_TYPE_CONFIG.code.index_ns, new_path, link.id)
	else
		index._remove_id_from_file_index(LINK_TYPE_CONFIG.todo.index_ns, old_path, link.id)
		index._add_id_to_file_index(LINK_TYPE_CONFIG.todo.index_ns, new_path, link.id)
	end

	return link
end

return M
