-- lua/todo2/store/verification.lua
-- 行号验证状态管理 - 增量优化版（保持功能不变）
local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local types = require("todo2.store.types")
local fn = vim.fn

---------------------------------------------------------------------
-- 配置（保持不变）
---------------------------------------------------------------------
local CONFIG = {
	AUTO_VERIFY_INTERVAL = 86400,
	VERIFY_ON_FILE_SAVE = true,
	BATCH_SIZE = 50,
	VERIFY_COOLDOWN = 60,
	MAX_LOG_SIZE = 100,
	LOG_SAMPLE_RATE = 10,
	CONTEXT_VALID_THRESHOLD = 70,
	CONTEXT_UPDATE_THRESHOLD = 60,
	FILE_FINGERPRINT_TTL = 3600,
}

---------------------------------------------------------------------
-- ⭐ 优化：使用文件元数据缓存代替内容读取
---------------------------------------------------------------------
local last_verification_time = 0
local last_verify_time = {}
local verify_count = {}
local file_metadata_cache = {} -- {path = {size, mtime, timestamp}}

-- 文件存在性缓存
local file_exists_cache = {}
local FILE_EXISTS_TTL = 60 -- 60秒

local function file_exists_fast(filepath)
	if not filepath then
		return false
	end

	local cached = file_exists_cache[filepath]
	local now = os.time()

	if cached and (now - cached.timestamp) < FILE_EXISTS_TTL then
		return cached.exists
	end

	local exists = fn.filereadable(filepath) == 1
	file_exists_cache[filepath] = { exists = exists, timestamp = now }
	return exists
end

---------------------------------------------------------------------
-- ⭐ 优化：使用文件元数据代替内容指纹
---------------------------------------------------------------------
local function get_file_fingerprint(filepath)
	if not filepath or not file_exists_fast(filepath) then
		return nil
	end

	-- 使用文件系统元数据，避免读取文件内容
	local stat = vim.loop.fs_stat(filepath)
	if not stat then
		return nil
	end

	-- 组合文件大小和修改时间作为指纹
	return string.format("%d_%d", stat.size, stat.mtime.sec)
end

local function is_file_changed(filepath)
	if not filepath or not file_exists_fast(filepath) then
		return false
	end

	local current_fingerprint = get_file_fingerprint(filepath)
	local cached = file_metadata_cache[filepath]

	if not cached or cached.fingerprint ~= current_fingerprint then
		file_metadata_cache[filepath] = {
			fingerprint = current_fingerprint,
			timestamp = os.time(),
		}
		return true
	end

	if os.time() - cached.timestamp > CONFIG.FILE_FINGERPRINT_TTL then
		file_metadata_cache[filepath] = {
			fingerprint = current_fingerprint,
			timestamp = os.time(),
		}
	end

	return false
end

---------------------------------------------------------------------
-- ⭐ 优化：键名缓存，避免重复格式化字符串
---------------------------------------------------------------------
local KEY_PATTERNS = {
	todo = "todo.links.todo.%s",
	code = "todo.links.code.%s",
}

local META_KEY = "todo.meta"
local STATS_KEY = "todo.stats.verification"
local LOG_KEY = "todo.log.verification"

local function get_link_key(link_type, id)
	return KEY_PATTERNS[link_type]:format(id)
end

---------------------------------------------------------------------
-- ⭐ 修复：使用 vim.defer_fn 的简化版（避免手动关闭）
---------------------------------------------------------------------
local meta_dirty = false
local meta_update_timer = nil
local META_UPDATE_DELAY = 1000 -- 1秒

local function schedule_meta_update()
	-- 标记需要更新
	meta_dirty = true

	-- 如果已经有定时器在运行，不需要创建新的
	if meta_update_timer then
		return
	end

	-- 创建新的定时器
	meta_update_timer = vim.defer_fn(function()
		-- 再次检查是否需要更新（可能在等待期间被清除）
		if meta_dirty then
			-- 使用 pcall 保护刷新操作
			local success, err = pcall(function()
				M.refresh_metadata_stats()
			end)

			if not success then
				vim.notify("元数据更新失败: " .. tostring(err), vim.log.levels.ERROR)
			end

			meta_dirty = false
		end

		-- 清除定时器引用
		meta_update_timer = nil
	end, META_UPDATE_DELAY)
end

-- ⭐ 优化：增量更新链接状态
local function update_link_status_incremental(link_id, link_type, old_link, new_link)
	if not old_link or not new_link then
		return
	end

	local meta = store.get_key(META_KEY)
	if not meta then
		return
	end

	local changed = false

	-- 检查活跃状态变化
	local old_active = old_link.active
	local new_active = new_link.active

	if old_active ~= new_active then
		if link_type == "todo" then
			if new_active then
				meta.active_todo_links = (meta.active_todo_links or 0) + 1
				meta.archived_todo_links = math.max(0, (meta.archived_todo_links or 0) - 1)
			else
				meta.active_todo_links = math.max(0, (meta.active_todo_links or 0) - 1)
				meta.archived_todo_links = (meta.archived_todo_links or 0) + 1
			end
		else
			if new_active then
				meta.active_code_links = (meta.active_code_links or 0) + 1
				meta.archived_code_links = math.max(0, (meta.archived_code_links or 0) - 1)
			else
				meta.active_code_links = math.max(0, (meta.active_code_links or 0) - 1)
				meta.archived_code_links = (meta.archived_code_links or 0) + 1
			end
		end
		changed = true
	end

	-- 检查删除状态变化
	local old_deleted = old_link.deleted_at ~= nil
	local new_deleted = new_link.deleted_at ~= nil

	if old_deleted ~= new_deleted then
		if new_deleted then
			meta.total_links = math.max(0, (meta.total_links or 0) - 1)
			if link_type == "todo" then
				meta.todo_links = math.max(0, (meta.todo_links or 0) - 1)
			else
				meta.code_links = math.max(0, (meta.code_links or 0) - 1)
			end
		else
			meta.total_links = (meta.total_links or 0) + 1
			if link_type == "todo" then
				meta.todo_links = (meta.todo_links or 0) + 1
			else
				meta.code_links = (meta.code_links or 0) + 1
			end
		end
		changed = true
	end

	if changed then
		meta.last_sync = os.time()
		store.set_key(META_KEY, meta)
	end
end

---------------------------------------------------------------------
-- 统一的活跃状态判定逻辑（保持不变）
---------------------------------------------------------------------
local function calibrate_link_active_status(link_obj)
	if not link_obj then
		return nil
	end

	if link_obj.deleted_at and link_obj.deleted_at > 0 then
		link_obj.active = false
		return link_obj
	end

	if types.is_archived_status(link_obj.status) then
		link_obj.active = false
	else
		link_obj.active = true
	end

	return link_obj
end

---------------------------------------------------------------------
-- 统一的软删除标记逻辑（保持不变）
---------------------------------------------------------------------
function M.mark_link_deleted(link_id, link_type)
	if not link_id or not link_type then
		return false
	end

	local link_key = get_link_key(link_type, link_id)
	local old_link = store.get_key(link_key)
	if not old_link then
		return false
	end

	-- 保存旧状态用于增量更新
	local old_link_copy = vim.deepcopy(old_link)

	old_link.deleted_at = os.time()
	old_link.active = false
	old_link.status = "deleted"

	store.set_key(link_key, old_link)

	-- ⭐ 增量更新元数据
	update_link_status_incremental(link_id, link_type, old_link_copy, old_link)
	schedule_meta_update()

	return true
end

function M.restore_link_deleted(link_id, link_type)
	if not link_id or not link_type then
		return false
	end

	local link_key = get_link_key(link_type, link_id)
	local old_link = store.get_key(link_key)
	if not old_link then
		return false
	end

	local old_link_copy = vim.deepcopy(old_link)

	old_link.deleted_at = nil
	old_link.active = true
	old_link.status = old_link.status == "deleted" and "normal" or old_link.status

	store.set_key(link_key, old_link)

	-- ⭐ 增量更新元数据
	update_link_status_incremental(link_id, link_type, old_link_copy, old_link)
	schedule_meta_update()

	return true
end

---------------------------------------------------------------------
-- ⭐ 优化：全量刷新元数据（保留，但调用频率降低）
---------------------------------------------------------------------
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

	-- 重新统计所有链接（保留全量能力）
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local todo_stats = { active = 0, archived = 0, total = 0 }
	for id, todo_link in pairs(all_todo) do
		todo_stats.total = todo_stats.total + 1
		todo_link = calibrate_link_active_status(todo_link)
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
		code_link = calibrate_link_active_status(code_link)
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
-- 上下文验证（保持不变）
---------------------------------------------------------------------
function M.verify_context_fingerprint(link_obj)
	if not link_obj or not link_obj.context then
		return {
			valid = false,
			reason = "无上下文信息",
			needs_update = false,
		}
	end

	-- ⭐ 使用优化的文件存在性检查
	if not file_exists_fast(link_obj.path) then
		return {
			valid = false,
			reason = "文件不存在",
			needs_update = false,
		}
	end

	local result =
		locator.locate_by_context_fingerprint(link_obj.path, link_obj.context, CONFIG.CONTEXT_UPDATE_THRESHOLD)

	if result then
		local is_valid = result.similarity >= CONFIG.CONTEXT_VALID_THRESHOLD
		return {
			valid = is_valid,
			similarity = result.similarity,
			line = result.line,
			context = result.context,
			needs_update = not is_valid and result.similarity >= CONFIG.CONTEXT_UPDATE_THRESHOLD,
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

function M.update_expired_context(link_obj, threshold_days)
	threshold_days = threshold_days or 30

	if not link_obj or not link_obj.context then
		return false
	end

	local context_updated_at = link_obj.context_updated_at or link_obj.last_verified_at or 0
	local days_since_update = (os.time() - context_updated_at) / 86400

	if days_since_update < threshold_days then
		return false
	end

	local verify_result = M.verify_context_fingerprint(link_obj)

	if verify_result.valid then
		link_obj.context_updated_at = os.time()
		return true
	elseif verify_result.needs_update and verify_result.context then
		link_obj.context = verify_result.context
		link_obj.context_updated_at = os.time()
		link_obj.context_similarity = verify_result.similarity
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 检查是否可以验证（使用优化后的文件变更检测）
---------------------------------------------------------------------
local function can_verify(id, link_obj)
	if not id then
		return false
	end

	if link_obj and link_obj.path and is_file_changed(link_obj.path) then
		return true
	end

	local last = last_verify_time[id]
	if not last then
		return true
	end

	local now = os.time()
	return (now - last) >= CONFIG.VERIFY_COOLDOWN
end

---------------------------------------------------------------------
-- 日志记录（保持不变）
---------------------------------------------------------------------
local function log_verification(id, link_type, success, reason)
	if not success then
		local log = store.get_key(LOG_KEY) or {}
		table.insert(log, {
			id = id,
			type = link_type,
			success = success,
			reason = reason or "未知原因",
			timestamp = os.time(),
			critical = true,
		})
		if #log > CONFIG.MAX_LOG_SIZE then
			table.remove(log, 1)
		end
		store.set_key(LOG_KEY, log)
		return
	end

	verify_count[id] = (verify_count[id] or 0) + 1
	if verify_count[id] % CONFIG.LOG_SAMPLE_RATE == 1 then
		local log = store.get_key(LOG_KEY) or {}
		table.insert(log, {
			id = id,
			type = link_type,
			success = success,
			timestamp = os.time(),
			sampled = true,
			critical = false,
		})
		if #log > CONFIG.MAX_LOG_SIZE then
			table.remove(log, 1)
		end
		store.set_key(LOG_KEY, log)
	end
end

local function update_verification_stats(report)
	local stats = store.get_key(STATS_KEY) or {}
	stats.last_run = os.time()
	stats.total_runs = (stats.total_runs or 0) + 1
	stats.total_todo_verified = (stats.total_todo_verified or 0) + report.verified_todo
	stats.total_code_verified = (stats.total_code_verified or 0) + report.verified_code
	stats.total_failures = (stats.total_failures or 0) + report.failed_todo + report.failed_code
	store.set_key(STATS_KEY, stats)
end

---------------------------------------------------------------------
-- 异步验证单个链接（保持不变）
---------------------------------------------------------------------
local function verify_single_link_async(link_obj, force_reverify, callback)
	if not link_obj then
		if callback then
			callback(nil)
		end
		return
	end

	link_obj = calibrate_link_active_status(link_obj)

	if not force_reverify and not can_verify(link_obj.id, link_obj) then
		if callback then
			callback(link_obj)
		end
		return
	end

	if link_obj.type == "code_to_todo" then
		local todo_link = link.get_todo(link_obj.id, { verify_line = false })
		if todo_link and types.is_archived_status(todo_link.status) then
			todo_link = calibrate_link_active_status(todo_link)
			link_obj.active = false
			link_obj.last_verified_at = os.time()
			link_obj.line_verified = true
			if callback then
				callback(link_obj)
			end
			return
		end
	end

	if link_obj.line_verified and not force_reverify and not (link_obj.path and is_file_changed(link_obj.path)) then
		if callback then
			callback(link_obj)
		end
		return
	end

	last_verify_time[link_obj.id] = os.time()

	locator.locate_task(link_obj, function(verified_link)
		if not verified_link then
			log_verification(link_obj.id, link_obj.type, false, "定位任务失败")
			if callback then
				callback(link_obj)
			end
			return
		end

		verified_link = calibrate_link_active_status(verified_link)

		local verified_line = verified_link.line or 0
		local original_line = link_obj.line or 0
		local verify_success = verified_line == original_line and verified_link.path == link_obj.path
		local fail_reason = verify_success and nil or "行号已改变"

		if verify_success then
			verified_link.line_verified = true
			verified_link.last_verified_at = os.time()

			if verified_link.context then
				local context_verify = M.verify_context_fingerprint(verified_link)
				if context_verify.valid then
					verified_link.context_valid = true
					verified_link.context_similarity = context_verify.similarity
				elseif context_verify.needs_update and context_verify.context then
					verified_link.context = context_verify.context
					verified_link.context_valid = true
					verified_link.context_similarity = context_verify.similarity
					verified_link.context_updated_at = os.time()
					fail_reason = "上下文已更新"
				else
					verified_link.context_valid = false
					verified_link.context_similarity = context_verify.similarity or 0
					fail_reason = context_verify.reason
					verify_success = false
				end
				verified_link.context_verified_at = os.time()
			end
		else
			verified_link.line_verified = false
			verified_link.verification_failed_at = os.time()
			verified_link.verification_note = fail_reason
		end

		log_verification(verified_link.id, verified_link.type, verify_success, fail_reason)

		if callback then
			callback(verified_link)
		end
	end)
end

---------------------------------------------------------------------
-- 公共 API（大部分保持不变，部分添加增量更新）
---------------------------------------------------------------------

function M.get_unverified_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = { todo = {}, code = {} }

	local all_todo = link.get_all_todo()
	for id, todo_link in pairs(all_todo) do
		todo_link = calibrate_link_active_status(todo_link)
		store.set_key("todo.links.todo." .. id, todo_link)

		local should_include = false
		if not todo_link.active then
			goto continue
		end

		if not todo_link.line_verified then
			should_include = true
		elseif cutoff_time > 0 then
			if not todo_link.last_verified_at or todo_link.last_verified_at < cutoff_time then
				should_include = true
			end
		elseif todo_link.path and is_file_changed(todo_link.path) then
			should_include = true
		end

		if should_include then
			result.todo[id] = todo_link
		end
		::continue::
	end

	local all_code = link.get_all_code()
	for id, code_link in pairs(all_code) do
		code_link = calibrate_link_active_status(code_link)
		store.set_key("todo.links.code." .. id, code_link)

		local should_include = false
		if not code_link.active then
			goto continue
		end

		if not code_link.line_verified then
			should_include = true
		elseif cutoff_time > 0 then
			if not code_link.last_verified_at or code_link.last_verified_at < cutoff_time then
				should_include = true
			end
		elseif code_link.path and is_file_changed(code_link.path) then
			should_include = true
		end

		if should_include then
			result.code[id] = code_link
		end
		::continue::
	end

	return result
end

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
			-- ⭐ 使用延迟更新，避免频繁全量刷新
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
	local index = require("todo2.store.index")
	local result = { total = 0, verified = 0, failed = 0, skipped = 0, processing = true }

	local todo_links = index.find_todo_links_by_file(filepath)
	local code_links = index.find_code_links_by_file(filepath)

	-- 清空文件缓存
	file_metadata_cache[filepath] = nil
	file_exists_cache[filepath] = nil

	local total = #todo_links + #code_links
	local processed = 0

	local function check_complete()
		processed = processed + 1
		if processed >= total then
			result.processing = false
			-- ⭐ 使用延迟更新
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

		verify_single_link_async(todo_link, false, function(verified)
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

			verify_single_link_async(code_link, false, function(verified)
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

function M.cleanup_verify_records()
	local now = os.time()
	local expired_threshold = now - 86400

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

	for path, fp_info in pairs(file_metadata_cache) do
		if fp_info.timestamp < expired_threshold then
			file_metadata_cache[path] = nil
		end
	end

	for path, _ in pairs(file_exists_cache) do
		file_exists_cache[path] = nil
	end

	local log = store.get_key(LOG_KEY)
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

		store.set_key(LOG_KEY, new_log)
	end

	local delete_expired_threshold = now - 30 * 86400
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

function M.get_verify_stats()
	local stats = {
		total_ids = 0,
		recent_verifications = {},
		last_verify_time = {},
		verify_frequency = {},
		file_changes = {},
	}

	for id, _ in pairs(last_verify_time) do
		stats.total_ids = stats.total_ids + 1
	end

	local log = store.get_key(LOG_KEY) or {}
	stats.recent_verifications = vim.list_slice(log, math.max(1, #log - 9), #log)

	for id, count in pairs(verify_count) do
		stats.verify_frequency[id] = count
	end

	for path, fp_info in pairs(file_metadata_cache) do
		stats.file_changes[path] = {
			last_checked = fp_info.timestamp,
			is_changed = is_file_changed(path),
		}
	end

	return stats
end

function M.set_config(custom_config)
	if type(custom_config) ~= "table" then
		return false
	end

	for key, value in pairs(custom_config) do
		if CONFIG[key] ~= nil then
			CONFIG[key] = value
		end
	end

	return true
end

return M
