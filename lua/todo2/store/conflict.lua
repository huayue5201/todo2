-- lua/todo2/store/conflict.lua
--- @module todo2.store.conflict
--- 本地冲突检测和解决（使用 sync_version）

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------
local function detect_conflict_between_links(link1, link2)
	if not link1 or not link2 then
		return { has_conflict = false }
	end

	-- 检查是否是同一个链接的不同版本
	if link1.id ~= link2.id then
		return { has_conflict = false }
	end

	-- 检查同步版本
	local version1 = link1.sync_version or 0
	local version2 = link2.sync_version or 0

	-- 如果版本相同，没有冲突
	if version1 == version2 then
		return { has_conflict = false }
	end

	-- 检查哪些字段有冲突
	local conflicts = {}

	if link1.status ~= link2.status then
		table.insert(conflicts, {
			field = "status",
			value1 = link1.status,
			value2 = link2.status,
		})
	end

	if link1.content ~= link2.content then
		table.insert(conflicts, {
			field = "content",
			value1 = link1.content:sub(1, 50) .. (link1.content:len() > 50 and "..." or ""),
			value2 = link2.content:sub(1, 50) .. (link2.content:len() > 50 and "..." or ""),
		})
	end

	if link1.line ~= link2.line then
		table.insert(conflicts, {
			field = "line",
			value1 = link1.line,
			value2 = link2.line,
		})
	end

	if link1.path ~= link2.path then
		table.insert(conflicts, {
			field = "path",
			value1 = link1.path,
			value2 = link2.path,
		})
	end

	return {
		has_conflict = #conflicts > 0,
		conflicts = conflicts,
		version1 = version1,
		version2 = version2,
		updated1 = link1.updated_at or 0,
		updated2 = link2.updated_at or 0,
	}
end

---------------------------------------------------------------------
-- 公共API
---------------------------------------------------------------------
--- 检测链接冲突
--- @param id string 链接ID
--- @return table 冲突检测结果
function M.detect_conflict(id)
	local todo_key = "todo.links.todo." .. id
	local code_key = "todo.links.code." .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	local result = {
		id = id,
		has_todo = todo_link ~= nil,
		has_code = code_link ~= nil,
		todo_conflict = nil,
		code_conflict = nil,
		pair_conflict = nil,
	}

	if not todo_link and not code_link then
		result.message = "链接不存在"
		return result
	end

	-- 检测TODO链接的内部冲突（如果有历史版本）
	if todo_link then
		local history_key = "todo.history.todo." .. id
		local history = store.get_key(history_key)

		if history and #history > 0 then
			local latest = history[#history]
			result.todo_conflict = detect_conflict_between_links(latest, todo_link)
		end
	end

	-- 检测代码链接的内部冲突
	if code_link then
		local history_key = "todo.history.code." .. id
		local history = store.get_key(history_key)

		if history and #history > 0 then
			local latest = history[#history]
			result.code_conflict = detect_conflict_between_links(latest, code_link)
		end
	end

	-- 检测TODO和代码链接之间的冲突
	if todo_link and code_link then
		result.pair_conflict = detect_conflict_between_links(todo_link, code_link)
	end

	-- 总结冲突状态
	local has_any_conflict = false
	if result.todo_conflict and result.todo_conflict.has_conflict then
		has_any_conflict = true
	end
	if result.code_conflict and result.code_conflict.has_conflict then
		has_any_conflict = true
	end
	if result.pair_conflict and result.pair_conflict.has_conflict then
		has_any_conflict = true
	end

	result.has_any_conflict = has_any_conflict
	result.message = has_any_conflict and "检测到冲突" or "无冲突"

	return result
end

--- 解决冲突
--- @param id string 链接ID
--- @param resolution table 解决策略
--- @return table 解决结果
function M.resolve_conflict(id, resolution)
	local result = {
		id = id,
		resolved = false,
		actions = {},
	}

	-- 获取当前链接
	local todo_key = "todo.links.todo." .. id
	local code_key = "todo.links.code." .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	-- 保存历史版本（冲突解决前）
	M._save_to_history(todo_link, "todo")
	M._save_to_history(code_link, "code")

	-- 应用解决策略
	if resolution.strategy == "newer_wins" then
		-- 使用更新时间最新的版本
		if todo_link and code_link then
			if (todo_link.updated_at or 0) >= (code_link.updated_at or 0) then
				-- TODO链接更新，同步到代码链接
				code_link.status = todo_link.status
				code_link.content = todo_link.content
				code_link.sync_version = (code_link.sync_version or 0) + 1
				code_link.updated_at = os.time()

				store.set_key(code_key, code_link)
				table.insert(result.actions, "同步TODO状态到代码链接")
			else
				-- 代码链接更新，同步到TODO链接
				todo_link.status = code_link.status
				todo_link.content = code_link.content
				todo_link.sync_version = (todo_link.sync_version or 0) + 1
				todo_link.updated_at = os.time()

				store.set_key(todo_key, todo_link)
				table.insert(result.actions, "同步代码状态到TODO链接")
			end
		end
	elseif resolution.strategy == "todo_first" then
		-- 总是以TODO链接为准
		if todo_link and code_link then
			code_link.status = todo_link.status
			code_link.content = todo_link.content
			code_link.sync_version = (code_link.sync_version or 0) + 1
			code_link.updated_at = os.time()

			store.set_key(code_key, code_link)
			table.insert(result.actions, "以TODO链接为准更新代码链接")
		end
	elseif resolution.strategy == "manual" and resolution.values then
		-- 手动指定值
		if resolution.values.todo and todo_link then
			for field, value in pairs(resolution.values.todo) do
				if todo_link[field] ~= nil then
					todo_link[field] = value
				end
			end
			todo_link.sync_version = (todo_link.sync_version or 0) + 1
			todo_link.updated_at = os.time()
			store.set_key(todo_key, todo_link)
			table.insert(result.actions, "手动更新TODO链接")
		end

		if resolution.values.code and code_link then
			for field, value in pairs(resolution.values.code) do
				if code_link[field] ~= nil then
					code_link[field] = value
				end
			end
			code_link.sync_version = (code_link.sync_version or 0) + 1
			code_link.updated_at = os.time()
			store.set_key(code_key, code_link)
			table.insert(result.actions, "手动更新代码链接")
		end
	end

	result.resolved = #result.actions > 0
	result.message = result.resolved and "冲突已解决" or "未执行任何解决操作"

	-- 记录冲突解决日志
	if result.resolved then
		M._log_conflict_resolution(id, resolution.strategy, result.actions)
	end

	return result
end

--- 获取冲突解决历史
--- @param id string|nil 链接ID，nil表示所有
--- @param days number|nil 多少天内的历史，nil表示所有
--- @return table 解决历史
function M.get_resolution_history(id, days)
	local log_key = "todo.log.conflict.resolutions"
	local all_logs = store.get_key(log_key) or {}

	local result = {}
	local cutoff_time = days and (os.time() - days * 86400) or 0

	for _, log in ipairs(all_logs) do
		local should_include = true

		if id and log.id ~= id then
			should_include = false
		end

		if cutoff_time > 0 and log.timestamp < cutoff_time then
			should_include = false
		end

		if should_include then
			table.insert(result, log)
		end
	end

	-- 按时间倒序排序
	table.sort(result, function(a, b)
		return a.timestamp > b.timestamp
	end)

	return result
end

--- 批量检测所有冲突
--- @return table 冲突报告
function M.detect_all_conflicts()
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local report = {
		total_checked = 0,
		conflicts_found = 0,
		todo_conflicts = 0,
		code_conflicts = 0,
		pair_conflicts = 0,
		detailed = {},
	}

	-- 收集所有ID
	local all_ids = {}
	for id, _ in pairs(all_todo) do
		all_ids[id] = true
	end
	for id, _ in pairs(all_code) do
		all_ids[id] = true
	end

	-- 检查每个ID
	for id, _ in pairs(all_ids) do
		report.total_checked = report.total_checked + 1

		local conflict = M.detect_conflict(id)
		if conflict.has_any_conflict then
			report.conflicts_found = report.conflicts_found + 1

			if conflict.todo_conflict and conflict.todo_conflict.has_conflict then
				report.todo_conflicts = report.todo_conflicts + 1
			end

			if conflict.code_conflict and conflict.code_conflict.has_conflict then
				report.code_conflicts = report.code_conflicts + 1
			end

			if conflict.pair_conflict and conflict.pair_conflict.has_conflict then
				report.pair_conflicts = report.pair_conflicts + 1
			end

			table.insert(report.detailed, conflict)
		end
	end

	report.summary = string.format(
		"冲突检测完成: 检查了 %d 个链接，发现 %d 个冲突",
		report.total_checked,
		report.conflicts_found
	)

	return report
end

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------
function M._save_to_history(link, link_type)
	if not link or not link.id then
		return
	end

	local history_key = string.format("todo.history.%s.%s", link_type, link.id)
	local history = store.get_key(history_key) or {}

	-- 只保存必要字段的副本
	local history_entry = {
		status = link.status,
		content = link.content,
		line = link.line,
		path = link.path,
		sync_version = link.sync_version,
		updated_at = link.updated_at,
		saved_at = os.time(),
	}

	table.insert(history, history_entry)

	-- 只保留最近10个版本
	if #history > 10 then
		table.remove(history, 1)
	end

	store.set_key(history_key, history)
end

function M._log_conflict_resolution(id, strategy, actions)
	local log_key = "todo.log.conflict.resolutions"
	local log = store.get_key(log_key) or {}

	table.insert(log, {
		id = id,
		strategy = strategy,
		actions = actions,
		timestamp = os.time(),
	})

	-- 只保留最近100条记录
	if #log > 100 then
		table.remove(log, 1)
	end

	store.set_key(log_key, log)
end

return M
