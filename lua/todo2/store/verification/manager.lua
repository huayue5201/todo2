-- lua/todo2/store/verification/manager.lua
-- 批量管理：批量验证、自动验证、清理

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local types = require("todo2.store.types")
local index = require("todo2.store.index")
local cache = require("todo2.store.verification.cache")
local core = require("todo2.store.verification.core")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	AUTO_VERIFY_INTERVAL = 86400,
	BATCH_SIZE = 50,
	MAX_LOG_SIZE = 100,
}

local META_KEY = "todo.meta"
local last_verification_time = 0

---------------------------------------------------------------------
-- 元数据延迟更新
---------------------------------------------------------------------
local meta_dirty = false
local meta_update_timer = nil
local META_UPDATE_DELAY = 1000

local function schedule_meta_update()
	meta_dirty = true

	if meta_update_timer then
		return
	end

	meta_update_timer = vim.defer_fn(function()
		if meta_dirty then
			local success, err = pcall(function()
				M.refresh_metadata_stats()
			end)

			if not success then
				vim.notify("元数据更新失败: " .. tostring(err), vim.log.levels.ERROR)
			end

			meta_dirty = false
		end
		meta_update_timer = nil
	end, META_UPDATE_DELAY)
end

function M.refresh_metadata_stats()
	local meta = store.get_key(META_KEY)
		or {
			active_code_links = 0,
			active_todo_links = 0,
			archived_code_links = 0,
			archived_todo_links = 0,
			code_links = 0,
			todo_links = 0,
			total_links = 0,
			last_sync = os.time(),
		}

	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local todo_stats = { active = 0, archived = 0, total = 0 }
	for id, todo_link in pairs(all_todo) do
		todo_stats.total = todo_stats.total + 1
		todo_link = core.calibrate_link_active_status(todo_link)
		store.set_key("todo.links.todo." .. id, todo_link)

		if todo_link.active then
			todo_stats.active = todo_stats.active + 1
		elseif types.is_archived_status(todo_link.status) then
			todo_stats.archived = todo_stats.archived + 1
		end
	end

	local code_stats = { active = 0, archived = 0, total = 0 }
	for id, code_link in pairs(all_code) do
		code_stats.total = code_stats.total + 1
		code_link = core.calibrate_link_active_status(code_link)
		store.set_key("todo.links.code." .. id, code_link)

		if code_link.active then
			code_stats.active = code_stats.active + 1
		elseif types.is_archived_status(code_link.status) then
			code_stats.archived = code_stats.archived + 1
		end
	end

	meta.active_todo_links = todo_stats.active
	meta.archived_todo_links = todo_stats.archived
	meta.todo_links = todo_stats.total

	meta.active_code_links = code_stats.active
	meta.archived_code_links = code_stats.archived
	meta.code_links = code_stats.total

	meta.total_links = todo_stats.total + code_stats.total
	meta.last_sync = os.time()

	store.set_key(META_KEY, meta)
	meta_dirty = false
	return meta
end

---------------------------------------------------------------------
-- 查询功能
---------------------------------------------------------------------
function M.get_unverified_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = { todo = {}, code = {} }

	local all_todo = link.get_all_todo()
	for id, todo_link in pairs(all_todo) do
		todo_link = core.calibrate_link_active_status(todo_link)
		store.set_key("todo.links.todo." .. id, todo_link)

		if todo_link.active then
			local should_include = false
			if not todo_link.line_verified then
				should_include = true
			elseif cutoff_time > 0 then
				if not todo_link.last_verified_at or todo_link.last_verified_at < cutoff_time then
					should_include = true
				end
			elseif todo_link.path and cache.is_file_changed(todo_link.path) then
				should_include = true
			end

			if should_include then
				result.todo[id] = todo_link
			end
		end
	end

	local all_code = link.get_all_code()
	for id, code_link in pairs(all_code) do
		code_link = core.calibrate_link_active_status(code_link)
		store.set_key("todo.links.code." .. id, code_link)

		if code_link.active then
			local should_include = false
			if not code_link.line_verified then
				should_include = true
			elseif cutoff_time > 0 then
				if not code_link.last_verified_at or code_link.last_verified_at < cutoff_time then
					should_include = true
				end
			elseif code_link.path and cache.is_file_changed(code_link.path) then
				should_include = true
			end

			if should_include then
				result.code[id] = code_link
			end
		end
	end

	return result
end

---------------------------------------------------------------------
-- 批量验证
---------------------------------------------------------------------
function M.verify_all(opts, callback)
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
		processing = true,
	}

	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local todo_ids = {}
	for id, _ in pairs(all_todo) do
		table.insert(todo_ids, id)
	end

	local code_ids = {}
	for id, _ in pairs(all_code) do
		table.insert(code_ids, id)
	end

	local total = #todo_ids + #code_ids
	local processed = 0

	if show_progress then
		vim.notify(string.format("开始验证 %d 个链接...", total), vim.log.levels.INFO)
	end

	local function check_complete()
		processed = processed + 1
		if processed >= total then
			report.processing = false
			last_verification_time = os.time()
			core.update_verification_stats(report)
			schedule_meta_update()

			report.summary = string.format(
				"验证完成: %d/%d TODO链接已验证, %d/%d 代码链接已验证",
				report.verified_todo,
				report.total_todo,
				report.verified_code,
				report.total_code
			)

			if callback then
				callback(report)
			end
		end
	end

	-- 验证TODO链接
	for i, id in ipairs(todo_ids) do
		report.total_todo = report.total_todo + 1
		local todo_link = all_todo[id]

		core.verify_single_link_async(todo_link, force, function(verified)
			if verified then
				store.set_key("todo.links.todo." .. id, verified)
				if verified.line_verified then
					report.verified_todo = report.verified_todo + 1
				else
					report.failed_todo = report.failed_todo + 1
				end
			else
				report.unverified_todo = report.unverified_todo + 1
			end

			if i % batch_size == 0 and show_progress then
				vim.schedule(function()
					vim.notify(string.format("已验证 %d/%d 个TODO链接", i, #todo_ids), vim.log.levels.INFO)
				end)
			end

			check_complete()
		end)
	end

	-- 验证代码链接
	for i, id in ipairs(code_ids) do
		report.total_code = report.total_code + 1
		local code_link = all_code[id]

		core.verify_single_link_async(code_link, force, function(verified)
			if verified then
				store.set_key("todo.links.code." .. id, verified)
				if verified.line_verified then
					report.verified_code = report.verified_code + 1
				else
					report.failed_code = report.failed_code + 1
				end
			else
				report.unverified_code = report.unverified_code + 1
			end

			if i % batch_size == 0 and show_progress then
				vim.schedule(function()
					vim.notify(string.format("已验证 %d/%d 个代码链接", i, #code_ids), vim.log.levels.INFO)
				end)
			end

			check_complete()
		end)
	end

	return report
end

function M.verify_file_links(filepath, callback)
	local result = { total = 0, verified = 0, failed = 0, skipped = 0, processing = true }

	local todo_links = index.find_todo_links_by_file(filepath)
	local code_links = index.find_code_links_by_file(filepath)

	-- 清空文件缓存
	cache.clear_file_cache(filepath)

	local total = #todo_links + #code_links
	local processed = 0

	local function check_complete()
		processed = processed + 1
		if processed >= total then
			result.processing = false
			schedule_meta_update()
			if callback then
				callback(result)
			end
		end
	end

	if total == 0 then
		result.processing = false
		if callback then
			callback(result)
		end
		return result
	end

	for _, todo_link in ipairs(todo_links) do
		result.total = result.total + 1

		core.verify_single_link_async(todo_link, false, function(verified)
			if verified then
				store.set_key("todo.links.todo." .. todo_link.id, verified)
				if verified.line_verified then
					result.verified = result.verified + 1
				else
					result.failed = result.failed + 1
				end
			end
			check_complete()
		end)
	end

	for _, code_link in ipairs(code_links) do
		local todo_link = link.get_todo(code_link.id, { verify_line = false })
		if todo_link and types.is_archived_status(todo_link.status) then
			result.skipped = result.skipped + 1
			result.total = result.total + 1
			check_complete()
		else
			result.total = result.total + 1

			core.verify_single_link_async(code_link, false, function(verified)
				if verified then
					store.set_key("todo.links.code." .. code_link.id, verified)
					if verified.line_verified then
						result.verified = result.verified + 1
					else
						result.failed = result.failed + 1
					end
				end
				check_complete()
			end)
		end
	end

	return result
end

---------------------------------------------------------------------
-- 自动验证
---------------------------------------------------------------------
function M.setup_auto_verification(interval)
	local verify_interval = interval or CONFIG.AUTO_VERIFY_INTERVAL
	local config = require("todo2.config")

	local group = vim.api.nvim_create_augroup("Todo2AutoVerification", { clear = true })

	local timer = vim.loop.new_timer()
	timer:start(verify_interval * 1000, verify_interval * 1000, function()
		vim.schedule(function()
			local now = os.time()
			if now - last_verification_time < verify_interval / 2 then
				return
			end

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

---------------------------------------------------------------------
-- 清理功能
---------------------------------------------------------------------
function M.cleanup_verify_records()
	local now = os.time()
	local expired_threshold = now - 86400
	local delete_expired_threshold = now - 30 * 86400

	-- 清理缓存
	cache.cleanup(expired_threshold)

	-- 清理日志
	local log = store.get_key("todo.log.verification")
	if log and #log > CONFIG.MAX_LOG_SIZE then
		local critical_logs = {}
		local normal_logs = {}
		for _, entry in ipairs(log) do
			if entry.critical then
				table.insert(critical_logs, entry)
			else
				table.insert(normal_logs, entry)
			end
		end

		local new_log = {}
		local keep_critical = #critical_logs > CONFIG.MAX_LOG_SIZE
				and vim.list_slice(critical_logs, #critical_logs - CONFIG.MAX_LOG_SIZE + 1, #critical_logs)
			or critical_logs

		local remaining = CONFIG.MAX_LOG_SIZE - #keep_critical
		local keep_normal = remaining > 0
				and vim.list_slice(normal_logs, math.max(1, #normal_logs - remaining + 1), #normal_logs)
			or {}

		vim.list_extend(new_log, keep_critical)
		vim.list_extend(new_log, keep_normal)

		store.set_key("todo.log.verification", new_log)
	end

	-- 清理过期删除记录
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	for id, todo_link in pairs(all_todo) do
		if todo_link.deleted_at and todo_link.deleted_at < delete_expired_threshold then
			store.delete_key("todo.links.todo." .. id)
		end
	end

	for id, code_link in pairs(all_code) do
		if code_link.deleted_at and code_link.deleted_at < delete_expired_threshold then
			store.delete_key("todo.links.code." .. id)
		end
	end

	schedule_meta_update()
	return true
end

return M
