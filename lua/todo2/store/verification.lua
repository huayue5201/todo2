-- lua/todo2/store/verification.lua
-- 行号验证状态管理 - ⭐ 添加上下文验证
-- 修复：增加验证节流、日志采样、元数据诊断

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	AUTO_VERIFY_INTERVAL = 86400, -- 24小时一次
	VERIFY_ON_FILE_SAVE = true,
	BATCH_SIZE = 50,
	VERIFY_COOLDOWN = 60, -- ⭐ 60秒内不重复验证同一ID
	MAX_LOG_SIZE = 100, -- ⭐ 最大日志条数
	LOG_SAMPLE_RATE = 10, -- ⭐ 日志采样率（只记录1/10的成功验证）
}

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local last_verification_time = 0
local last_verify_time = {} -- ⭐ 记录每个ID的最后验证时间
local verify_count = {} -- ⭐ 记录每个ID的验证次数

---------------------------------------------------------------------
-- ⭐ 新增：验证上下文指纹
---------------------------------------------------------------------
--- 验证上下文指纹
--- @param link_obj table 链接对象
--- @return table { valid, similarity, reason, needs_update, context }
function M.verify_context_fingerprint(link_obj)
	if not link_obj or not link_obj.context then
		return {
			valid = false,
			reason = "无上下文信息",
			needs_update = false,
		}
	end

	-- 检查文件是否存在
	if vim.fn.filereadable(link_obj.path) ~= 1 then
		return {
			valid = false,
			reason = "文件不存在",
			needs_update = false,
		}
	end

	-- 在当前文件中查找最佳匹配
	local result = locator.locate_by_context_fingerprint(
		link_obj.path,
		link_obj.context,
		60 -- 较低的阈值用于验证
	)

	if result then
		local is_valid = result.similarity >= 70
		return {
			valid = is_valid,
			similarity = result.similarity,
			line = result.line,
			context = result.context,
			needs_update = not is_valid and result.similarity >= 60, -- 60-70% 之间需要更新
			reason = is_valid and "上下文匹配" or "上下文相似度不足",
		}
	else
		return {
			valid = false,
			reason = "找不到匹配的上下文",
			similarity = 0,
			needs_update = false,
		}
	end
end

--- ⭐ 更新过期上下文
--- @param link_obj table 链接对象
--- @param threshold_days number 过期阈值（天）
--- @return boolean 是否更新
function M.update_expired_context(link_obj, threshold_days)
	threshold_days = threshold_days or 30

	if not link_obj or not link_obj.context then
		return false
	end

	-- 检查上下文是否过期
	local context_updated_at = link_obj.context_updated_at or link_obj.last_verified_at or 0
	local days_since_update = (os.time() - context_updated_at) / 86400

	if days_since_update < threshold_days then
		return false -- 未过期
	end

	-- 验证当前上下文
	local verify_result = M.verify_context_fingerprint(link_obj)

	if verify_result.valid then
		-- 上下文仍然有效，更新时间戳
		link_obj.context_updated_at = os.time()
		return true
	elseif verify_result.needs_update and verify_result.context then
		-- 更新为找到的新上下文
		link_obj.context = verify_result.context
		link_obj.context_updated_at = os.time()
		link_obj.context_similarity = verify_result.similarity
		return true
	end

	return false
end

---------------------------------------------------------------------
-- ⭐ 新增：检查是否可以验证（节流控制）
---------------------------------------------------------------------
local function can_verify(id)
	if not id then
		return false
	end

	local last = last_verify_time[id]
	if not last then
		return true
	end

	local now = os.time()
	return (now - last) >= CONFIG.VERIFY_COOLDOWN
end

---------------------------------------------------------------------
-- ⭐ 修改：日志记录（带采样）
---------------------------------------------------------------------
local function log_verification(id, link_type, success)
	-- 只记录失败验证，成功验证按采样率记录
	if not success then
		-- 失败验证始终记录
		local log_key = "todo.log.verification"
		local log = store.get_key(log_key) or {}
		table.insert(log, {
			id = id,
			type = link_type,
			success = success,
			timestamp = os.time(),
		})
		if #log > CONFIG.MAX_LOG_SIZE then
			table.remove(log, 1)
		end
		store.set_key(log_key, log)
		return
	end

	-- 成功验证按采样率记录
	verify_count[id] = (verify_count[id] or 0) + 1
	if verify_count[id] % CONFIG.LOG_SAMPLE_RATE == 1 then
		local log_key = "todo.log.verification"
		local log = store.get_key(log_key) or {}
		table.insert(log, {
			id = id,
			type = link_type,
			success = success,
			timestamp = os.time(),
			sampled = true,
		})
		if #log > CONFIG.MAX_LOG_SIZE then
			table.remove(log, 1)
		end
		store.set_key(log_key, log)
	end
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
-- ⭐ 增强：异步验证单个链接（添加上下文验证和节流）
---------------------------------------------------------------------
local function verify_single_link_async(link_obj, force_reverify, callback)
	if not link_obj then
		if callback then
			callback(nil)
		end
		return
	end

	-- ⭐ 检查验证节流
	if not force_reverify and not can_verify(link_obj.id) then
		if callback then
			callback(link_obj)
		end
		return
	end

	-- 如果是代码链接，检查对应 TODO 是否为归档状态
	if link_obj.type == "code_to_todo" then
		local todo_link = link.get_todo(link_obj.id, { verify_line = false })
		if todo_link and types.is_archived_status(todo_link.status) then
			-- 归档任务的代码标记不需要验证，直接返回原对象
			link_obj.last_verified_at = os.time()
			link_obj.line_verified = true
			if callback then
				callback(link_obj)
			end
			return
		end
	end

	if link_obj.line_verified and not force_reverify then
		if callback then
			callback(link_obj)
		end
		return
	end

	-- 记录验证开始时间
	last_verify_time[link_obj.id] = os.time()

	-- ⭐ 异步调用 locator.locate_task
	locator.locate_task(link_obj, function(verified_link)
		if not verified_link then
			if callback then
				callback(link_obj) -- 返回原始链接
			end
			return
		end

		local verified_line = verified_link.line or 0
		local original_line = link_obj.line or 0

		if verified_line == original_line and verified_link.path == link_obj.path then
			verified_link.line_verified = true
			verified_link.last_verified_at = os.time()

			-- ⭐ 验证并更新上下文
			if verified_link.context then
				local context_verify = M.verify_context_fingerprint(verified_link)
				if context_verify.valid then
					verified_link.context_valid = true
					verified_link.context_similarity = context_verify.similarity
				elseif context_verify.needs_update and context_verify.context then
					-- 更新上下文
					verified_link.context = context_verify.context
					verified_link.context_valid = true
					verified_link.context_similarity = context_verify.similarity
					verified_link.context_updated_at = os.time()
				else
					verified_link.context_valid = false
					verified_link.context_similarity = context_verify.similarity or 0
				end
				verified_link.context_verified_at = os.time()
			end
		else
			verified_link.line_verified = false
			verified_link.verification_failed_at = os.time()
			verified_link.verification_note = "行号已改变"
		end

		if callback then
			callback(verified_link)
		end
	end)
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

--- ⭐ 修改：设置自动验证定时器（增加节流控制）
--- @param interval number|nil
function M.setup_auto_verification(interval)
	local verify_interval = interval or CONFIG.AUTO_VERIFY_INTERVAL
	local config = require("todo2.config")

	local group = vim.api.nvim_create_augroup("Todo2AutoVerification", { clear = true })

	local timer = vim.loop.new_timer()
	timer:start(verify_interval * 1000, verify_interval * 1000, function()
		vim.schedule(function()
			-- ⭐ 检查上次验证时间，避免重复
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
					-- ⭐ 文件保存时只验证该文件，不触发全量验证
					M.verify_file_links(args.file)
				end)
			end,
		})
	end

	M._timer = timer
end

--- ⭐ 修改：验证所有链接（异步版，带节流）
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

	-- TODO 链接验证
	local todo_ids = {}
	for id, _ in pairs(all_todo) do
		table.insert(todo_ids, id)
	end

	local processed = 0
	local total = #todo_ids
		+ (function()
			local count = 0
			for _ in pairs(all_code) do
				count = count + 1
			end
			return count
		end)()

	if show_progress then
		vim.notify(string.format("开始验证 %d 个链接...", total), vim.log.levels.INFO)
	end

	local function check_complete()
		processed = processed + 1
		if processed >= total then
			report.processing = false
			last_verification_time = os.time()
			update_verification_stats(report)

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

	-- 处理 TODO 链接
	for i, id in ipairs(todo_ids) do
		report.total_todo = report.total_todo + 1
		local todo_link = all_todo[id]

		verify_single_link_async(todo_link, force, function(verified)
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

			check_complete()
		end)
	end

	-- 处理代码链接
	local code_ids = {}
	for id, _ in pairs(all_code) do
		table.insert(code_ids, id)
	end

	for i, id in ipairs(code_ids) do
		report.total_code = report.total_code + 1
		local code_link = all_code[id]

		verify_single_link_async(code_link, force, function(verified)
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

			check_complete()
		end)
	end

	return report -- 立即返回进行中的报告
end

--- ⭐ 修改：验证文件中的所有链接（异步版，带节流）
function M.verify_file_links(filepath, callback)
	local index = require("todo2.store.index")
	local result = { total = 0, verified = 0, failed = 0, skipped = 0, processing = true }

	local todo_links = index.find_todo_links_by_file(filepath)
	local code_links = index.find_code_links_by_file(filepath)

	local total = #todo_links + #code_links
	local processed = 0

	local function check_complete()
		processed = processed + 1
		if processed >= total then
			result.processing = false
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

	-- 处理 TODO 链接
	for _, todo_link in ipairs(todo_links) do
		result.total = result.total + 1

		verify_single_link_async(todo_link, false, function(verified)
			if verified then
				store.set_key("todo.links.todo." .. todo_link.id, verified)
				if verified.line_verified then
					result.verified = result.verified + 1
				else
					result.failed = result.failed + 1
				end
				log_verification(todo_link.id, "todo", verified.line_verified)
			end
			check_complete()
		end)
	end

	-- 处理代码链接
	for _, code_link in ipairs(code_links) do
		-- 检查是否为归档任务
		local todo_link = link.get_todo(code_link.id, { verify_line = false })
		if todo_link and types.is_archived_status(todo_link.status) then
			result.skipped = result.skipped + 1
			result.total = result.total + 1
			check_complete() -- 跳过验证
		else
			result.total = result.total + 1

			verify_single_link_async(code_link, false, function(verified)
				if verified then
					store.set_key("todo.links.code." .. code_link.id, verified)
					if verified.line_verified then
						result.verified = result.verified + 1
					else
						result.failed = result.failed + 1
					end
					log_verification(code_link.id, "code", verified.line_verified)
				end
				check_complete()
			end)
		end
	end

	return result
end

---------------------------------------------------------------------
-- ⭐ 新增：清理过期的验证记录
---------------------------------------------------------------------
function M.cleanup_verify_records()
	local now = os.time()
	local expired_threshold = now - 86400 -- 24小时前的记录

	for id, time in pairs(last_verify_time) do
		if time < expired_threshold then
			last_verify_time[id] = nil
		end
	end

	for id, count in pairs(verify_count) do
		if (last_verify_time[id] or 0) < expired_threshold then
			verify_count[id] = nil
		end
	end

	-- 可选：压缩日志
	local log_key = "todo.log.verification"
	local log = store.get_key(log_key)
	if log and #log > CONFIG.MAX_LOG_SIZE then
		-- 只保留最近的 MAX_LOG_SIZE 条记录
		local new_log = {}
		for i = math.max(1, #log - CONFIG.MAX_LOG_SIZE + 1), #log do
			table.insert(new_log, log[i])
		end
		store.set_key(log_key, new_log)
	end

	return true
end

---------------------------------------------------------------------
-- ⭐ 新增：获取验证统计
---------------------------------------------------------------------
function M.get_verify_stats()
	local stats = {
		total_ids = 0,
		recent_verifications = {},
		last_verify_time = {},
		verify_frequency = {},
	}

	-- 统计ID数量
	for id, _ in pairs(last_verify_time) do
		stats.total_ids = stats.total_ids + 1
	end

	-- 最近10次验证
	local log_key = "todo.log.verification"
	local log = store.get_key(log_key) or {}
	stats.recent_verifications = vim.list_slice(log, math.max(1, #log - 9), #log)

	-- 验证频率
	for id, count in pairs(verify_count) do
		stats.verify_frequency[id] = count
	end

	return stats
end

return M
