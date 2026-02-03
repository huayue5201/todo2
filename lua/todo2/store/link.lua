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
local state_machine = require("todo2.store.state_machine")
local consistency = require("todo2.store.consistency")

---------------------------------------------------------------------
-- 内部配置常量
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

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------

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
		sync_version = 1, -- 新增同步版本
		active = true,
		context = data.context,
	}

	return link
end

-- 获取链接对
--- @param id string
--- @return table|nil todo_link, table|nil code_link
local function get_link_pair(id)
	local todo_cfg = LINK_TYPE_CONFIG.todo
	local code_cfg = LINK_TYPE_CONFIG.code

	local todo_key = todo_cfg.key_prefix .. id
	local code_key = code_cfg.key_prefix .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	-- 验证并修复单个链接
	if todo_link then
		todo_link = consistency.validate_and_fix_link(todo_link)
		store.set_key(todo_key, todo_link)
	end

	if code_link then
		code_link = consistency.validate_and_fix_link(code_link)
		store.set_key(code_key, code_link)
	end

	return todo_link, code_link
end

----------------------------------------------------------------------
-- 通用增删查函数
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

		-- 验证并修复链接
		link = consistency.validate_and_fix_link(link)

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

----------------------------------------------------------------------
-- ⭐ 核心状态更新函数
----------------------------------------------------------------------
--- 核心状态更新函数（简化逻辑，避免频繁触发一致性检查）
--- @param id string
--- @param new_status string
--- @param link_type string|nil
function M.update_status(id, new_status, link_type)
	-- 验证新状态
	if not types.ACTIVE_STATUSES[new_status] and new_status ~= types.STATUS.COMPLETED then
		vim.notify(string.format("无效的状态: %s", new_status), vim.log.levels.ERROR)
		return nil
	end

	-- 如果指定了链接类型，只更新该类型
	if link_type then
		local cfg = LINK_TYPE_CONFIG[link_type]
		local key = cfg.key_prefix .. id
		local link = store.get_key(key)

		if not link then
			return nil
		end

		-- 使用状态机更新状态
		local updated = state_machine.update_link_status(link, new_status)
		if not updated then
			return nil
		end

		-- 保存更新
		store.set_key(key, updated)

		-- ⭐ 关键修改：只在状态不一致时才触发一致性检查
		vim.schedule(function()
			local check_result = consistency.check_link_pair_consistency(id)
			-- 只有当状态不一致时才修复
			if check_result.needs_repair then
				consistency.repair_link_pair(id, "latest")
			end
		end)

		return updated
	else
		-- ⭐ 关键修改：简化双向同步更新
		local todo_link, code_link = get_link_pair(id)

		if not todo_link and not code_link then
			return nil
		end

		local now = os.time()
		local results = {}

		-- 更新TODO链接（如果存在）
		if todo_link then
			local updated = state_machine.update_link_status(todo_link, new_status)
			if updated then
				store.set_key(LINK_TYPE_CONFIG.todo.key_prefix .. id, updated)
				results.todo = updated
			end
		end

		-- 更新代码链接（如果存在）
		if code_link then
			local updated = state_machine.update_link_status(code_link, new_status)
			if updated then
				store.set_key(LINK_TYPE_CONFIG.code.key_prefix .. id, updated)
				results.code = updated
			end
		end

		-- ⭐ 关键修改：只在状态不一致时才触发修复
		vim.schedule(function()
			local check_result = consistency.check_link_pair_consistency(id)
			if check_result.needs_repair then
				consistency.repair_link_pair(id, "latest")
			end
		end)

		return results.todo or results.code or nil
	end
end

----------------------------------------------------------------------
-- 快捷状态函数
----------------------------------------------------------------------

function M.mark_completed(id, link_type)
	return M.update_status(id, types.STATUS.COMPLETED, link_type)
end

function M.mark_urgent(id, link_type)
	return M.update_status(id, types.STATUS.URGENT, link_type)
end

function M.mark_waiting(id, link_type)
	return M.update_status(id, types.STATUS.WAITING, link_type)
end

function M.mark_normal(id, link_type)
	return M.update_status(id, types.STATUS.NORMAL, link_type)
end

--- 恢复到上一次状态（智能恢复）
function M.mark_completed(id, link_type)
	-- 直接调用 update_status，不额外触发检查
	return M.update_status(id, types.STATUS.COMPLETED, link_type)
end

function M.restore_previous_status(id, link_type)
	if link_type then
		local cfg = LINK_TYPE_CONFIG[link_type]
		local key = cfg.key_prefix .. id
		local link = store.get_key(key)

		if not link then
			return nil
		end

		-- 只有完成状态才能恢复
		if link.status ~= types.STATUS.COMPLETED then
			return nil
		end

		-- 确定恢复的状态
		local restore_status = link.previous_status or types.STATUS.NORMAL

		-- 更新状态
		return M.update_status(id, restore_status, link_type)
	else
		-- 简化处理：直接恢复到正常状态
		return M.update_status(id, types.STATUS.NORMAL, nil)
	end
end

----------------------------------------------------------------------
-- 链接操作
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

	-- 如果更新状态，使用状态机
	if updates.status and updates.status ~= link.status then
		local updated = state_machine.update_link_status(link, updates.status)
		if not updated then
			return false
		end
		link = updated
	end

	-- 合并其他更新
	for k, v in pairs(updates) do
		if k ~= "status" then
			link[k] = v
		end
	end

	link.updated_at = os.time()
	link.sync_version = (link.sync_version or 0) + 1

	store.set_key(key, link)
	return true
end

----------------------------------------------------------------------
-- 批量操作
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

--- 获取所有TODO链接
--- @return table<string, table>
function M.get_all_todo()
	local cfg = LINK_TYPE_CONFIG.todo
	local prefix = cfg.key_prefix:sub(1, -2) -- 去掉最后的点
	local ids = store.get_namespace_keys(prefix) or {}
	local result = {}

	for _, id in ipairs(ids) do
		local key = cfg.key_prefix .. id
		local link = store.get_key(key)
		if link and link.active ~= false then
			-- 验证并修复链接
			link = consistency.validate_and_fix_link(link)
			result[id] = link
		end
	end

	return result
end

--- 获取所有代码链接
--- @return table<string, table>
function M.get_all_code()
	local cfg = LINK_TYPE_CONFIG.code
	local prefix = cfg.key_prefix:sub(1, -2) -- 去掉最后的点
	local ids = store.get_namespace_keys(prefix) or {}
	local result = {}

	for _, id in ipairs(ids) do
		local key = cfg.key_prefix .. id
		local link = store.get_key(key)
		if link and link.active ~= false then
			-- 验证并修复链接
			link = consistency.validate_and_fix_link(link)
			result[id] = link
		end
	end

	return result
end

-- 为外部提供别名（用于cleaner.lua）
M.get_all_todo_links = M.get_all_todo
M.get_all_code_links = M.get_all_code

----------------------------------------------------------------------
-- 向后兼容和数据迁移
----------------------------------------------------------------------

function M.migrate_status_fields()
	local migrated = 0

	local function migrate_links(link_type)
		local cfg = LINK_TYPE_CONFIG[link_type]
		local ids = store.get_namespace_keys(cfg.key_prefix:sub(1, -2)) or {}

		for _, id in ipairs(ids) do
			local key = cfg.key_prefix .. id
			local link = store.get_key(key)

			if link then
				local changed = false

				-- 添加缺失的字段
				if not link.status then
					link.status = types.STATUS.NORMAL
					changed = true
				end

				if not link.previous_status then
					link.previous_status = nil
					changed = true
				end

				if not link.sync_version then
					link.sync_version = 1
					changed = true
				end

				-- 根据内容推断状态
				if link.content and link.content:match("%[x%]") then
					if link.status ~= types.STATUS.COMPLETED then
						link.status = types.STATUS.COMPLETED
						link.previous_status = types.STATUS.NORMAL
						link.completed_at = link.completed_at or link.created_at or os.time()
						changed = true
					end
				end

				if changed then
					link.updated_at = os.time()
					store.set_key(key, link)
					migrated = migrated + 1
				end
			end
		end
	end

	migrate_links("todo")
	migrate_links("code")

	-- 迁移后进行一次全局一致性检查
	if migrated > 0 then
		vim.schedule(function()
			local report = consistency.check_all_consistency({ verbose = false })
			if report.inconsistent_pairs > 0 then
				vim.notify(
					string.format("迁移后发现%d个不一致项，正在修复...", report.inconsistent_pairs),
					vim.log.levels.INFO
				)
				consistency.repair_all_inconsistencies({ strategy = "latest", verbose = false })
			end
		end)
	end

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
		local ids = store.get_namespace_keys(cfg.key_prefix:sub(1, -2)) or {}
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
-- 链接重定位
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
	link.sync_version = (link.sync_version or 0) + 1

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

----------------------------------------------------------------------
-- 新增：状态同步API
----------------------------------------------------------------------

--- 强制同步链接对状态
--- @param id string
--- @param strategy string|nil
--- @return table
function M.sync_link_pair(id, strategy)
	return consistency.repair_link_pair(id, strategy)
end

--- 获取链接对的详细状态信息
--- @param id string
--- @return table
function M.get_link_pair_status(id)
	local todo_link, code_link = get_link_pair(id)
	local check_result = consistency.check_link_pair_consistency(id, true)

	return {
		id = id,
		todo = todo_link,
		code = code_link,
		consistency = check_result,
		display = {
			todo = todo_link and state_machine.get_status_display_info(todo_link.status) or nil,
			code = code_link and state_machine.get_status_display_info(code_link.status) or nil,
		},
	}
end

--- 启动状态监控
--- @param interval number|nil
function M.start_status_monitor(interval)
	return consistency.start_consistency_monitor(interval)
end

--- 获取状态统计（增强版）
function M.get_status_stats(link_type)
	local stats = {
		total = 0,
		normal = 0,
		urgent = 0,
		waiting = 0,
		completed = 0,
		by_consistency = {
			consistent = 0,
			inconsistent = 0,
			single = 0,
		},
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

	-- 一致性统计
	local all_ids = {}
	local todo_links = M.get_all_todo()
	local code_links = M.get_all_code()

	for id, _ in pairs(todo_links) do
		all_ids[id] = true
	end
	for id, _ in pairs(code_links) do
		all_ids[id] = true
	end

	for id, _ in pairs(all_ids) do
		local check = consistency.check_link_pair_consistency(id)

		if not check.has_todo or not check.has_code then
			stats.by_consistency.single = stats.by_consistency.single + 1
		elseif check.all_consistent then
			stats.by_consistency.consistent = stats.by_consistency.consistent + 1
		else
			stats.by_consistency.inconsistent = stats.by_consistency.inconsistent + 1
		end
	end

	-- 按类型统计
	if not link_type or link_type == "todo" then
		count_links(todo_links)
	end

	if not link_type or link_type == "code" then
		count_links(code_links)
	end

	-- 计算百分比
	stats.consistency_rate = stats.total > 0 and math.floor(stats.by_consistency.consistent / stats.total * 100) or 0
	stats.completion_rate = stats.total > 0 and math.floor(stats.completed / stats.total * 100) or 0

	return stats
end

return M
