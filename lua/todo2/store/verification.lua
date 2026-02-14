-- lua/todo2/store/verification.lua
-- 行号验证状态管理

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	AUTO_VERIFY_INTERVAL = 86400,
	VERIFY_ON_FILE_SAVE = true,
	BATCH_SIZE = 50,
}

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local last_verification_time = 0

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------
local function verify_single_link(link_obj, force_reverify)
	if not link_obj then
		return nil
	end

	-- 如果是代码链接，检查对应 TODO 是否为归档状态
	if link_obj.type == "code_to_todo" then
		local todo_link = link.get_todo(link_obj.id, { verify_line = false })
		if todo_link and types.is_archived_status(todo_link.status) then
			-- 归档任务的代码标记不需要验证，直接返回原对象
			link_obj.last_verified_at = os.time()
			link_obj.line_verified = true
			return link_obj
		end
	end

	if link_obj.line_verified and not force_reverify then
		return link_obj
	end

	local verified_link = locator.locate_task(link_obj)

	local verified_line = verified_link.line or 0
	local original_line = link_obj.line or 0

	if verified_line == original_line and verified_link.path == link_obj.path then
		verified_link.line_verified = true
		verified_link.last_verified_at = os.time()
	else
		verified_link.line_verified = false
		verified_link.verification_failed_at = os.time()
		verified_link.verification_note = "行号已改变"
	end

	return verified_link
end

local function log_verification(id, link_type, success)
	local log_key = "todo.log.verification"
	local log = store.get_key(log_key) or {}
	table.insert(log, {
		id = id,
		type = link_type,
		success = success,
		timestamp = os.time(),
	})
	if #log > 200 then
		table.remove(log, 1)
	end
	store.set_key(log_key, log)
end

local function update_verification_stats(report)
	local stats_key = "todo.stats.verification"
	local stats = store.get_key(stats_key) or {}
	stats.last_run = os.time()
	stats.total_runs = (stats.total_runs or 0) + 1
	stats.total_todo_verified = (stats.total_todo_verified or 0) + report.verified_todo
	stats.total_code_verified = (stats.total_code_verified or 0) + report.verified_code
	stats.total_failures = (stats.total_failures or 0) + report.failed_todo + report.failed_code
	store.set_key(stats_key, stats)
end

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------
--- 获取未验证的链接
--- @param days number|nil
--- @return table
function M.get_unverified_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = { todo = {}, code = {} }

	local all_todo = link.get_all_todo()
	for id, todo_link in pairs(all_todo) do
		local should_include = false
		if not todo_link.line_verified then
			should_include = true
		elseif cutoff_time > 0 then
			if not todo_link.last_verified_at or todo_link.last_verified_at < cutoff_time then
				should_include = true
			end
		end
		if should_include then
			result.todo[id] = todo_link
		end
	end

	local all_code = link.get_all_code()
	for id, code_link in pairs(all_code) do
		local should_include = false
		if not code_link.line_verified then
			should_include = true
		elseif cutoff_time > 0 then
			if not code_link.last_verified_at or code_link.last_verified_at < cutoff_time then
				should_include = true
			end
		end
		if should_include then
			result.code[id] = code_link
		end
	end

	return result
end

--- 设置自动验证定时器
--- @param interval number|nil
function M.setup_auto_verification(interval)
	local verify_interval = interval or CONFIG.AUTO_VERIFY_INTERVAL
	local config = require("todo2.store.config")

	local group = vim.api.nvim_create_augroup("Todo2AutoVerification", { clear = true })

	local timer = vim.loop.new_timer()
	timer:start(verify_interval * 1000, verify_interval * 1000, function()
		vim.schedule(function()
			local unverified = M.get_unverified_links(7)
			local total = 0
			for _ in pairs(unverified.todo) do
				total = total + 1
			end
			for _ in pairs(unverified.code) do
				total = total + 1
			end
			if total > 0 then
				vim.notify(
					string.format("发现 %d 个未验证链接，正在自动验证...", total),
					vim.log.levels.INFO
				)
				M.verify_all({ show_progress = false })
			end
		end)
	end)

	if config.get("verification.verify_on_file_save") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = "*",
			callback = function(args)
				vim.schedule(function()
					M.verify_file_links(args.file)
				end)
			end,
		})
	end

	M._timer = timer
end

--- 验证所有链接
function M.verify_all(opts)
	opts = opts or {}
	local force = opts.force or false
	local batch_size = opts.batch_size or CONFIG.BATCH_SIZE
	local show_progress = opts.show_progress ~= false

	local report = {
		total_todo = 0,
		total_code = 0,
		verified_todo = 0,
		verified_code = 0,
		failed_todo = 0,
		failed_code = 0,
		unverified_todo = 0,
		unverified_code = 0,
	}

	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	-- TODO 链接验证
	local todo_ids = {}
	for id, _ in pairs(all_todo) do
		table.insert(todo_ids, id)
	end

	if show_progress then
		vim.notify(string.format("开始验证 %d 个TODO链接...", #todo_ids), vim.log.levels.INFO)
	end

	for i, id in ipairs(todo_ids) do
		report.total_todo = report.total_todo + 1
		local todo_link = all_todo[id]
		local verified = verify_single_link(todo_link, force)
		if verified then
			store.set_key("todo.links.todo." .. id, verified)
			if verified.line_verified then
				report.verified_todo = report.verified_todo + 1
			else
				report.failed_todo = report.failed_todo + 1
			end
			log_verification(id, "todo", verified.line_verified)
		else
			report.unverified_todo = report.unverified_todo + 1
		end
		if i % batch_size == 0 and show_progress then
			vim.schedule(function()
				vim.notify(string.format("已验证 %d/%d 个TODO链接", i, #todo_ids), vim.log.levels.INFO)
			end)
		end
	end

	-- 代码链接验证
	local code_ids = {}
	for id, _ in pairs(all_code) do
		table.insert(code_ids, id)
	end

	if show_progress then
		vim.notify(string.format("开始验证 %d 个代码链接...", #code_ids), vim.log.levels.INFO)
	end

	for i, id in ipairs(code_ids) do
		report.total_code = report.total_code + 1
		local code_link = all_code[id]
		local verified = verify_single_link(code_link, force)
		if verified then
			store.set_key("todo.links.code." .. id, verified)
			if verified.line_verified then
				report.verified_code = report.verified_code + 1
			else
				report.failed_code = report.failed_code + 1
			end
			log_verification(id, "code", verified.line_verified)
		else
			report.unverified_code = report.unverified_code + 1
		end
		if i % batch_size == 0 and show_progress then
			vim.schedule(function()
				vim.notify(string.format("已验证 %d/%d 个代码链接", i, #code_ids), vim.log.levels.INFO)
			end)
		end
	end

	last_verification_time = os.time()
	update_verification_stats(report)

	report.summary = string.format(
		"验证完成: %d/%d TODO链接已验证, %d/%d 代码链接已验证",
		report.verified_todo,
		report.total_todo,
		report.verified_code,
		report.total_code
	)
	return report
end

--- 验证文件中的所有链接
function M.verify_file_links(filepath)
	local index = require("todo2.store.index")
	local result = { total = 0, verified = 0, failed = 0, skipped = 0 }

	local todo_links = index.find_todo_links_by_file(filepath)
	for _, todo_link in ipairs(todo_links) do
		result.total = result.total + 1
		local verified = verify_single_link(todo_link, false)
		if verified then
			store.set_key("todo.links.todo." .. todo_link.id, verified)
			if verified.line_verified then
				result.verified = result.verified + 1
			else
				result.failed = result.failed + 1
			end
			log_verification(todo_link.id, "todo", verified.line_verified)
		end
	end

	local code_links = index.find_code_links_by_file(filepath)
	for _, code_link in ipairs(code_links) do
		-- 检查是否为归档任务
		local todo_link = link.get_todo(code_link.id, { verify_line = false })
		if todo_link and types.is_archived_status(todo_link.status) then
			result.skipped = result.skipped + 1
			result.total = result.total + 1
			-- 跳过验证
		else
			result.total = result.total + 1
			local verified = verify_single_link(code_link, false)
			if verified then
				store.set_key("todo.links.code." .. code_link.id, verified)
				if verified.line_verified then
					result.verified = result.verified + 1
				else
					result.failed = result.failed + 1
				end
				log_verification(code_link.id, "code", verified.line_verified)
			end
		end
	end

	return result
end

return M
