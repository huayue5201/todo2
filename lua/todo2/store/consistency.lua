-- lua/todo2/store/consistency.lua
--- @module todo2.store.consistency
--- @brief 状态一致性检查和修复工具

local M = {}

local types = require("todo2.store.types")
local store = require("todo2.store.nvim_store")
local state_machine = require("todo2.store.state_machine")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	MAX_STATUS_DIFF_MS = 1000, -- 状态更新时间最大差异（毫秒）
	AUTO_SYNC_ENABLED = true, -- 是否启用自动同步
	LOG_LEVEL = "WARN", -- 日志级别：DEBUG, INFO, WARN, ERROR
}

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------
local function log(level, message, ...)
	local levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
	local config_level = levels[CONFIG.LOG_LEVEL] or levels.WARN

	if levels[level] >= config_level then
		if select("#", ...) > 0 then
			message = string.format(message, ...)
		end
		vim.notify(string.format("[一致性检查] %s: %s", level, message), vim.log.levels[level:upper()])
	end
end

--- 获取链接对（todo和code链接）
--- @param id string
--- @return table|nil todo_link, table|nil code_link
local function get_link_pair(id)
	local todo_key = "todo.links.todo." .. id
	local code_key = "todo.links.code." .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	return todo_link, code_link
end

---------------------------------------------------------------------
-- 一致性检查函数
---------------------------------------------------------------------

--- 检查链接对的一致性（放宽容忍度，防止误判）
--- @param id string
--- @param detailed boolean|nil
--- @return table
function M.check_link_pair_consistency(id, detailed)
	local todo_key = "todo.links.todo." .. id
	local code_key = "todo.links.code." .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	local result = {
		id = id,
		has_todo = todo_link ~= nil,
		has_code = code_link ~= nil,
		status_consistent = true,
		all_consistent = true,
		needs_repair = false,
		inconsistencies = {},
	}

	if not todo_link and not code_link then
		result.all_consistent = true
		result.message = "链接不存在"
		return result
	end

	-- 单边链接的情况
	if not todo_link or not code_link then
		result.all_consistent = false
		result.needs_repair = true
		table.insert(result.inconsistencies, "单边链接")
		result.message = "缺少" .. (todo_link and "代码链接" or "TODO链接")
		return result
	end

	-- ⭐ 关键修改1：放宽状态一致性检查
	if todo_link.status ~= code_link.status then
		result.status_consistent = false
		result.all_consistent = false
		result.needs_repair = true
		table.insert(
			result.inconsistencies,
			string.format("状态不一致: TODO=%s, 代码=%s", todo_link.status, code_link.status)
		)
	end

	-- ⭐ 关键修改2：放宽更新时间检查（从300秒改为30秒）
	local time_diff = math.abs(todo_link.updated_at - code_link.updated_at)
	if time_diff > 30 then -- ⭐ 原为300秒，改为30秒
		result.all_consistent = false
		table.insert(result.inconsistencies, string.format("更新时间差异过大: %d秒", time_diff))
		-- ⭐ 注意：时间差异大不标记为需要修复，防止误判
	end

	-- 生成总结消息
	if result.all_consistent then
		result.message = "状态一致"
	else
		result.message = string.format(
			"发现%d个不一致项，需要修复：%s",
			#result.inconsistencies,
			result.needs_repair and "是" or "否"
		)
	end

	return result
end

--- 批量检查所有链接对的一致性
--- @param opts table|nil 选项
--- @return table 统计报告
function M.check_all_consistency(opts)
	opts = opts or {}
	local verbose = opts.verbose or false

	-- 获取所有TODO链接ID
	local todo_keys = store.get_namespace_keys("todo.links.todo")
	local all_ids = {}

	for _, key in ipairs(todo_keys) do
		local id = key:match("todo%.links%.todo%.(.+)")
		if id then
			all_ids[id] = true
		end
	end

	-- 获取所有代码链接ID
	local code_keys = store.get_namespace_keys("todo.links.code")
	for _, key in ipairs(code_keys) do
		local id = key:match("todo%.links%.code%.(.+)")
		if id then
			all_ids[id] = true
		end
	end

	-- 检查每个ID
	local report = {
		total_checked = 0,
		consistent_pairs = 0,
		inconsistent_pairs = 0,
		single_links = 0,
		missing_pairs = 0,
		issues = {},
		by_status = {},
	}

	for id, _ in pairs(all_ids) do
		report.total_checked = report.total_checked + 1

		local result = M.check_link_pair_consistency(id, verbose)

		if not result.has_todo or not result.has_code then
			report.single_links = report.single_links + 1
			if verbose then
				log("DEBUG", "单边链接: %s", id)
			end
		elseif result.all_consistent then
			report.consistent_pairs = report.consistent_pairs + 1
		else
			report.inconsistent_pairs = report.inconsistent_pairs + 1
			table.insert(report.issues, {
				id = id,
				inconsistencies = result.inconsistencies,
			})

			if verbose then
				log("WARN", "链接%s不一致: %s", id, table.concat(result.inconsistencies, ", "))
			end
		end

		-- 统计状态分布
		local todo_link, code_link = get_link_pair(id)
		if todo_link then
			local status = todo_link.status or "unknown"
			report.by_status[status] = (report.by_status[status] or 0) + 1
		end
		if code_link then
			local status = code_link.status or "unknown"
			report.by_status[status] = (report.by_status[status] or 0) + 1
		end
	end

	-- 计算缺失的对应链接
	report.missing_pairs = report.single_links

	-- 生成总结
	report.summary = string.format(
		"检查了%d个链接对: %d一致, %d不一致, %d单边链接",
		report.total_checked,
		report.consistent_pairs,
		report.inconsistent_pairs,
		report.single_links
	)

	if #report.issues > 0 then
		report.summary = report.summary .. string.format(" (%d个问题需要修复)", #report.issues)
	end

	return report
end

---------------------------------------------------------------------
-- 一致性修复函数
---------------------------------------------------------------------
--- 修复单个链接对的不一致（简化逻辑）
--- @param id string
--- @param strategy string|nil
--- @return table
function M.repair_link_pair(id, strategy)
	strategy = strategy or "latest"

	local result = {
		id = id,
		repaired = false,
		actions = {},
		errors = {},
	}

	local todo_key = "todo.links.todo." .. id
	local code_key = "todo.links.code." .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	if not todo_link and not code_link then
		table.insert(result.errors, "链接不存在")
		return result
	end

	if not todo_link or not code_link then
		result.repaired = true
		table.insert(result.actions, "单边链接，需要手动处理")
		return result
	end

	-- ⭐ 关键修改：只有当状态不一致时才修复
	if todo_link.status ~= code_link.status then
		local primary_link, secondary_link
		local primary_name, secondary_name

		if strategy == "latest" then
			-- 选择更新时间最新的作为主链接
			if todo_link.updated_at >= code_link.updated_at then
				primary_link, secondary_link = todo_link, code_link
				primary_name, secondary_name = "TODO", "代码"
			else
				primary_link, secondary_link = code_link, todo_link
				primary_name, secondary_name = "代码", "TODO"
			end
		elseif strategy == "todo_first" then
			primary_link, secondary_link = todo_link, code_link
			primary_name, secondary_name = "TODO", "代码"
		else
			primary_link, secondary_link = code_link, todo_link
			primary_name, secondary_name = "代码", "TODO"
		end

		-- 同步状态
		secondary_link.status = primary_link.status
		secondary_link.previous_status = primary_link.previous_status
		secondary_link.completed_at = primary_link.completed_at
		secondary_link.updated_at = os.time()
		secondary_link.sync_version = (secondary_link.sync_version or 0) + 1

		-- 保存更新
		if secondary_link.type == types.LINK_TYPES.TODO_TO_CODE then
			store.set_key("todo.links.todo." .. id, secondary_link)
		else
			store.set_key("todo.links.code." .. id, secondary_link)
		end

		result.repaired = true
		table.insert(
			result.actions,
			string.format("同步%s状态: %s -> %s", secondary_name, secondary_link.status, primary_link.status)
		)
	else
		table.insert(result.actions, "状态已一致，无需修复")
	end

	return result
end

--- 批量修复所有不一致的链接对
--- @param opts table|nil 选项
--- @return table 修复报告
function M.repair_all_inconsistencies(opts)
	opts = opts or {}
	local strategy = opts.strategy or "latest"
	local dry_run = opts.dry_run or false
	local verbose = opts.verbose or false

	-- 首先检查所有不一致项
	local check_report = M.check_all_consistency({ verbose = verbose })

	local repair_report = {
		total_inconsistent = #check_report.issues,
		repaired = 0,
		failed = 0,
		skipped = 0,
		details = {},
	}

	if dry_run then
		repair_report.dry_run = true
		repair_report.summary = string.format("试运行: 发现%d个需要修复的不一致项", #check_report.issues)
		return repair_report
	end

	-- 修复每个不一致的链接对
	for _, issue in ipairs(check_report.issues) do
		local id = issue.id

		if verbose then
			log("INFO", "修复链接对: %s", id)
		end

		local result = M.repair_link_pair(id, strategy)

		if result.repaired then
			repair_report.repaired = repair_report.repaired + 1
			if verbose then
				log("INFO", "修复成功: %s - %s", id, table.concat(result.actions, ", "))
			end
		else
			if #result.errors > 0 then
				repair_report.failed = repair_report.failed + 1
				log("ERROR", "修复失败: %s - %s", id, table.concat(result.errors, ", "))
			else
				repair_report.skipped = repair_report.skipped + 1
				if verbose then
					log("DEBUG", "跳过修复: %s - %s", id, table.concat(result.actions, ", "))
				end
			end
		end

		table.insert(repair_report.details, {
			id = id,
			result = result,
		})
	end

	repair_report.summary = string.format(
		"修复完成: %d成功, %d失败, %d跳过",
		repair_report.repaired,
		repair_report.failed,
		repair_report.skipped
	)

	return repair_report
end

---------------------------------------------------------------------
-- 实时监控函数
---------------------------------------------------------------------

--- 监控状态变化，自动修复不一致
--- @param interval number 检查间隔（秒）
function M.start_consistency_monitor(interval)
	interval = interval or 300 -- 默认5分钟

	local timer = vim.loop.new_timer()

	timer:start(interval * 1000, interval * 1000, function()
		vim.schedule(function()
			if CONFIG.AUTO_SYNC_ENABLED then
				local report = M.check_all_consistency({ verbose = false })

				if report.inconsistent_pairs > 0 then
					log("WARN", "发现%d个不一致的链接对，正在自动修复...", report.inconsistent_pairs)

					local repair_report = M.repair_all_inconsistencies({
						strategy = "latest",
						verbose = false,
					})

					if repair_report.repaired > 0 then
						log("INFO", "自动修复完成: %d个链接对已修复", repair_report.repaired)
					end
				end
			end
		end)
	end)

	return timer
end

--- 验证并修复单个链接的状态数据
--- @param link table
--- @return table 修复后的链接
function M.validate_and_fix_link(link)
	if not link then
		return nil
	end

	local fixed = false
	local changes = {}

	-- 确保状态字段存在
	if not link.status then
		link.status = types.STATUS.NORMAL
		link.previous_status = nil
		fixed = true
		table.insert(changes, "添加缺失的状态字段")
	end

	-- 验证状态值
	local valid, err = state_machine.validate_link_status(link)
	if not valid then
		-- 修复无效状态
		link.status = types.STATUS.NORMAL
		link.previous_status = nil
		link.completed_at = nil
		fixed = true
		table.insert(changes, string.format("修复无效状态: %s", err))
	end

	-- 修复完成时间
	if link.status == types.STATUS.COMPLETED and not link.completed_at then
		link.completed_at = link.updated_at or link.created_at or os.time()
		fixed = true
		table.insert(changes, "添加缺失的完成时间")
	elseif link.status ~= types.STATUS.COMPLETED and link.completed_at then
		link.completed_at = nil
		fixed = true
		table.insert(changes, "移除不应存在的完成时间")
	end

	-- 确保同步版本号存在
	if not link.sync_version then
		link.sync_version = 1
		fixed = true
		table.insert(changes, "添加同步版本号")
	end

	if fixed then
		link.updated_at = os.time()
		log("INFO", "修复链接%s: %s", link.id, table.concat(changes, ", "))
	end

	return link
end

return M
