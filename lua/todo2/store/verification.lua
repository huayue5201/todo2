-- lua/todo2/store/verification.lua
-- 行号验证状态管理 - 最终完整版（修复：上下文验证+活跃状态+软删除统一）
local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local types = require("todo2.store.types")
local fn = vim.fn

---------------------------------------------------------------------
-- 配置（修复：阈值配置化）
---------------------------------------------------------------------
local CONFIG = {
	AUTO_VERIFY_INTERVAL = 86400, -- 24小时一次
	VERIFY_ON_FILE_SAVE = true,
	BATCH_SIZE = 50,
	VERIFY_COOLDOWN = 60, -- 60秒内不重复验证同一ID（可配置）
	MAX_LOG_SIZE = 100, -- 最大日志条数
	LOG_SAMPLE_RATE = 10, -- 日志采样率（只记录1/10的成功验证，可配置）
	-- 上下文验证阈值配置化
	CONTEXT_VALID_THRESHOLD = 70, -- 上下文有效阈值（原硬编码70%）
	CONTEXT_UPDATE_THRESHOLD = 60, -- 上下文需要更新的阈值（原硬编码60%）
	-- 文件指纹缓存过期时间（秒）
	FILE_FINGERPRINT_TTL = 3600, -- 1小时
}

---------------------------------------------------------------------
-- 内部状态（修复：增加文件指纹缓存）
---------------------------------------------------------------------
local last_verification_time = 0
local last_verify_time = {} -- 记录每个ID的最后验证时间
local verify_count = {} -- 记录每个ID的验证次数
local file_fingerprints = {} -- 记录文件内容指纹 {path = {fingerprint, timestamp}}

---------------------------------------------------------------------
-- 新增：统一的活跃状态判定逻辑（核心修复）
---------------------------------------------------------------------
--- 校准链接的活跃状态（解决归档链接active字段未更新问题）
--- @param link_obj table 链接对象
--- @return table 校准后的链接对象
local function calibrate_link_active_status(link_obj)
	if not link_obj then
		return nil
	end

	-- 1. 软删除优先级最高：有deleted_at则active=false
	if link_obj.deleted_at and link_obj.deleted_at > 0 then
		link_obj.active = false
		return link_obj
	end

	-- 2. 归档状态判定：归档状态则active=false
	if types.is_archived_status(link_obj.status) then
		link_obj.active = false
	else
		link_obj.active = true -- 非归档/未删除则active=true
	end

	return link_obj
end

---------------------------------------------------------------------
-- 新增：统一的软删除标记逻辑（核心修复）
---------------------------------------------------------------------
--- 标记链接为软删除（同步更新active和deleted_at字段）
--- @param link_id string 链接ID
--- @param link_type string "todo" | "code"
--- @return boolean 是否标记成功
function M.mark_link_deleted(link_id, link_type)
	if not link_id or not link_type then
		return false
	end

	local link_key = string.format("todo.links.%s.%s", link_type, link_id)
	local link_obj = store.get_key(link_key)
	if not link_obj then
		return false
	end

	-- 统一软删除标记：设置deleted_at + 同步active=false
	link_obj.deleted_at = os.time()
	link_obj.active = false
	link_obj.status = "deleted" -- 补充删除状态标记

	store.set_key(link_key, link_obj)
	-- 触发元数据重新统计
	M.refresh_metadata_stats()

	return true
end

--- 恢复软删除链接（同步更新字段）
--- @param link_id string 链接ID
--- @param link_type string "todo" | "code"
--- @return boolean 是否恢复成功
function M.restore_link_deleted(link_id, link_type)
	if not link_id or not link_type then
		return false
	end

	local link_key = string.format("todo.links.%s.%s", link_type, link_id)
	local link_obj = store.get_key(link_key)
	if not link_obj then
		return false
	end

	-- 恢复：清空deleted_at + 恢复active和status
	link_obj.deleted_at = nil
	link_obj.active = true
	link_obj.status = link_obj.status == "deleted" and "normal" or link_obj.status

	store.set_key(link_key, link_obj)
	-- 触发元数据重新统计
	M.refresh_metadata_stats()

	return true
end

---------------------------------------------------------------------
-- 新增：刷新元数据统计（解决计数不准问题）
---------------------------------------------------------------------
function M.refresh_metadata_stats()
	local meta_key = "todo.meta"
	local meta = store.get_key(meta_key)
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

	-- 重新统计所有链接
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	-- 统计TODO链接
	local todo_stats = { active = 0, archived = 0, total = 0 }
	for id, todo_link in pairs(all_todo) do
		todo_stats.total = todo_stats.total + 1
		-- 先校准活跃状态
		todo_link = calibrate_link_active_status(todo_link)
		-- 更新存储的链接数据
		store.set_key("todo.links.todo." .. id, todo_link)

		if todo_link.active then
			todo_stats.active = todo_stats.active + 1
		elseif types.is_archived_status(todo_link.status) then
			todo_stats.archived = todo_stats.archived + 1
		end
	end

	-- 统计Code链接
	local code_stats = { active = 0, archived = 0, total = 0 }
	for id, code_link in pairs(all_code) do
		code_stats.total = code_stats.total + 1
		-- 先校准活跃状态
		code_link = calibrate_link_active_status(code_link)
		-- 更新存储的链接数据
		store.set_key("todo.links.code." .. id, code_link)

		if code_link.active then
			code_stats.active = code_stats.active + 1
		elseif types.is_archived_status(code_link.status) then
			code_stats.archived = code_stats.archived + 1
		end
	end

	-- 更新元数据
	meta.active_todo_links = todo_stats.active
	meta.archived_todo_links = todo_stats.archived
	meta.todo_links = todo_stats.total

	meta.active_code_links = code_stats.active
	meta.archived_code_links = code_stats.archived
	meta.code_links = code_stats.total

	meta.total_links = todo_stats.total + code_stats.total
	meta.last_sync = os.time()

	store.set_key(meta_key, meta)
	return meta
end

---------------------------------------------------------------------
-- 新增：计算文件内容指纹（用于检测文件变更）
---------------------------------------------------------------------
local function get_file_fingerprint(filepath)
	if not filepath or fn.filereadable(filepath) ~= 1 then
		return nil
	end

	-- 读取文件内容并计算简单哈希（Lua 轻量实现）
	local file = io.open(filepath, "rb")
	if not file then
		return nil
	end

	local content = file:read("*a")
	file:close()

	-- 简单的内容哈希（生产环境可替换为更安全的哈希算法）
	local fingerprint = ""
	local sum = 0
	for i = 1, #content do
		sum = sum + content:byte(i)
	end
	fingerprint = tostring(sum) .. "_" .. tostring(#content)

	return fingerprint
end

---------------------------------------------------------------------
-- 新增：检查文件是否变更
---------------------------------------------------------------------
local function is_file_changed(filepath)
	if not filepath or fn.filereadable(filepath) ~= 1 then
		return false
	end

	local current_fingerprint = get_file_fingerprint(filepath)
	local cached = file_fingerprints[filepath]

	-- 文件指纹不存在或不匹配 = 文件已变更
	if not cached or cached.fingerprint ~= current_fingerprint then
		-- 更新缓存
		file_fingerprints[filepath] = {
			fingerprint = current_fingerprint,
			timestamp = os.time(),
		}
		return true
	end

	-- 检查指纹缓存是否过期
	if os.time() - cached.timestamp > CONFIG.FILE_FINGERPRINT_TTL then
		file_fingerprints[filepath] = {
			fingerprint = current_fingerprint,
			timestamp = os.time(),
		}
	end

	return false
end

---------------------------------------------------------------------
-- 新增：验证上下文指纹（修复：使用配置化阈值）
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
	if fn.filereadable(link_obj.path) ~= 1 then
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
		CONFIG.CONTEXT_UPDATE_THRESHOLD -- 使用配置化的低阈值
	)

	if result then
		-- 修复：使用配置化的阈值判断
		local is_valid = result.similarity >= CONFIG.CONTEXT_VALID_THRESHOLD
		return {
			valid = is_valid,
			similarity = result.similarity,
			line = result.line,
			context = result.context,
			-- 使用配置化的阈值范围判断是否需要更新
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

--- 更新过期上下文（修复：使用配置化阈值）
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
-- 修复：检查是否可以验证（增加文件变更检测）
---------------------------------------------------------------------
local function can_verify(id, link_obj)
	if not id then
		return false
	end

	-- 如果文件已变更，强制重新验证（忽略节流）
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
-- 修复：日志记录（优化采样策略，确保失败日志不丢失）
---------------------------------------------------------------------
local function log_verification(id, link_type, success, reason)
	-- 修复：失败验证始终记录，且增加失败原因
	if not success then
		local log_key = "todo.log.verification"
		local log = store.get_key(log_key) or {}
		table.insert(log, {
			id = id,
			type = link_type,
			success = success,
			reason = reason or "未知原因", -- 新增：记录失败原因
			timestamp = os.time(),
			critical = true, -- 标记为关键日志
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
			critical = false,
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
-- 增强：异步验证单个链接（修复：文件变更强制验证 + 活跃状态校准）
---------------------------------------------------------------------
local function verify_single_link_async(link_obj, force_reverify, callback)
	if not link_obj then
		if callback then
			callback(nil)
		end
		return
	end

	-- 新增：先校准活跃状态
	link_obj = calibrate_link_active_status(link_obj)

	-- 修复：检查验证节流（传入link_obj用于文件变更检测）
	if not force_reverify and not can_verify(link_obj.id, link_obj) then
		if callback then
			callback(link_obj)
		end
		return
	end

	-- 如果是代码链接，检查对应 TODO 是否为归档状态
	if link_obj.type == "code_to_todo" then
		local todo_link = link.get_todo(link_obj.id, { verify_line = false })
		if todo_link and types.is_archived_status(todo_link.status) then
			-- 归档任务：校准active状态后返回
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

	-- 修复：即使已验证，但文件变更也需要重新验证
	if link_obj.line_verified and not force_reverify and not (link_obj.path and is_file_changed(link_obj.path)) then
		if callback then
			callback(link_obj)
		end
		return
	end

	-- 记录验证开始时间
	last_verify_time[link_obj.id] = os.time()

	-- 异步调用 locator.locate_task
	locator.locate_task(link_obj, function(verified_link)
		if not verified_link then
			-- 修复：记录失败日志
			log_verification(link_obj.id, link_obj.type, false, "定位任务失败")
			if callback then
				callback(link_obj) -- 返回原始链接
			end
			return
		end

		-- 新增：校准返回链接的活跃状态
		verified_link = calibrate_link_active_status(verified_link)

		local verified_line = verified_link.line or 0
		local original_line = link_obj.line or 0
		local verify_success = verified_line == original_line and verified_link.path == link_obj.path
		local fail_reason = verify_success and nil or "行号已改变"

		if verify_success then
			verified_link.line_verified = true
			verified_link.last_verified_at = os.time()

			-- 验证并更新上下文
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
					fail_reason = "上下文已更新" -- 记录上下文更新原因
				else
					verified_link.context_valid = false
					verified_link.context_similarity = context_verify.similarity or 0
					fail_reason = context_verify.reason -- 记录上下文验证失败原因
					verify_success = false -- 上下文验证失败，整体标记为失败
				end
				verified_link.context_verified_at = os.time()
			end
		else
			verified_link.line_verified = false
			verified_link.verification_failed_at = os.time()
			verified_link.verification_note = fail_reason
		end

		-- 修复：记录验证日志（包含失败原因）
		log_verification(verified_link.id, verified_link.type, verify_success, fail_reason)

		if callback then
			callback(verified_link)
		end
	end)
end

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------

--- 获取未验证的链接（修复：过滤已归档/删除的链接）
--- @param days number|nil
--- @return table
function M.get_unverified_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = { todo = {}, code = {} }

	local all_todo = link.get_all_todo()
	for id, todo_link in pairs(all_todo) do
		-- 新增：先校准活跃状态
		todo_link = calibrate_link_active_status(todo_link)
		store.set_key("todo.links.todo." .. id, todo_link)

		local should_include = false
		-- 跳过已删除/归档的链接（无需验证）
		if not todo_link.active then
			goto continue
		end

		if not todo_link.line_verified then
			should_include = true
		elseif cutoff_time > 0 then
			if not todo_link.last_verified_at or todo_link.last_verified_at < cutoff_time then
				should_include = true
			end
		-- 修复：文件变更时强制加入未验证列表
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
		-- 新增：先校准活跃状态
		code_link = calibrate_link_active_status(code_link)
		store.set_key("todo.links.code." .. id, code_link)

		local should_include = false
		-- 跳过已删除/归档的链接（无需验证）
		if not code_link.active then
			goto continue
		end

		if not code_link.line_verified then
			should_include = true
		elseif cutoff_time > 0 then
			if not code_link.last_verified_at or code_link.last_verified_at < cutoff_time then
				should_include = true
			end
		-- 修复：文件变更时强制加入未验证列表
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

--- 修改：设置自动验证定时器（增加节流控制）
--- @param interval number|nil
function M.setup_auto_verification(interval)
	local verify_interval = interval or CONFIG.AUTO_VERIFY_INTERVAL
	local config = require("todo2.config")

	local group = vim.api.nvim_create_augroup("Todo2AutoVerification", { clear = true })

	local timer = vim.loop.new_timer()
	timer:start(verify_interval * 1000, verify_interval * 1000, function()
		vim.schedule(function()
			-- 检查上次验证时间，避免重复
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
					-- 文件保存时只验证该文件，不触发全量验证
					M.verify_file_links(args.file)
				end)
			end,
		})
	end

	M._timer = timer
end

--- 修改：验证所有链接（异步版，带节流 + 验证后刷新元数据）
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
			-- 新增：验证完成后刷新元数据统计
			M.refresh_metadata_stats()

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
				-- 日志已在 verify_single_link_async 中记录，此处无需重复
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
				-- 日志已在 verify_single_link_async 中记录，此处无需重复
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

--- 修改：验证文件中的所有链接（异步版，带节流 + 验证后刷新元数据）
function M.verify_file_links(filepath, callback)
	local index = require("todo2.store.index")
	local result = { total = 0, verified = 0, failed = 0, skipped = 0, processing = true }

	local todo_links = index.find_todo_links_by_file(filepath)
	local code_links = index.find_code_links_by_file(filepath)

	-- 修复：文件变更时清空该文件的指纹缓存，强制重新计算
	if file_fingerprints[filepath] then
		file_fingerprints[filepath] = nil
	end

	local total = #todo_links + #code_links
	local processed = 0

	local function check_complete()
		processed = processed + 1
		if processed >= total then
			result.processing = false
			-- 新增：验证完成后刷新元数据统计
			M.refresh_metadata_stats()
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
				-- 日志已在 verify_single_link_async 中记录
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
					-- 日志已在 verify_single_link_async 中记录
				end
				check_complete()
			end)
		end
	end

	return result
end

---------------------------------------------------------------------
-- 新增：清理过期的验证记录（修复：增加文件指纹缓存 + 软删除记录清理）
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

	-- 修复：清理过期的文件指纹缓存
	for path, fp_info in pairs(file_fingerprints) do
		if fp_info.timestamp < expired_threshold then
			file_fingerprints[path] = nil
		end
	end

	-- 可选：压缩日志
	local log_key = "todo.log.verification"
	local log = store.get_key(log_key)
	if log and #log > CONFIG.MAX_LOG_SIZE then
		-- 修复：保留关键失败日志优先
		local critical_logs = {}
		local normal_logs = {}
		for _, entry in ipairs(log) do
			if entry.critical then
				table.insert(critical_logs, entry)
			else
				table.insert(normal_logs, entry)
			end
		end

		-- 先保留关键日志，再补充普通日志到最大限制
		local new_log = {}
		-- 关键日志全部保留（如果超过最大值则只保留最新的）
		local keep_critical = #critical_logs > CONFIG.MAX_LOG_SIZE
				and vim.list_slice(critical_logs, #critical_logs - CONFIG.MAX_LOG_SIZE + 1, #critical_logs)
			or critical_logs

		-- 补充普通日志
		local remaining = CONFIG.MAX_LOG_SIZE - #keep_critical
		local keep_normal = remaining > 0
				and vim.list_slice(normal_logs, math.max(1, #normal_logs - remaining + 1), #normal_logs)
			or {}

		vim.list_extend(new_log, keep_critical)
		vim.list_extend(new_log, keep_normal)

		store.set_key(log_key, new_log)
	end

	-- 新增：清理超过30天的软删除链接（可选）
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

	-- 清理后刷新元数据
	M.refresh_metadata_stats()

	return true
end

---------------------------------------------------------------------
-- 新增：获取验证统计
---------------------------------------------------------------------
function M.get_verify_stats()
	local stats = {
		total_ids = 0,
		recent_verifications = {},
		last_verify_time = {},
		verify_frequency = {},
		file_changes = {}, -- 新增：文件变更统计
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

	-- 新增：文件变更统计
	for path, fp_info in pairs(file_fingerprints) do
		stats.file_changes[path] = {
			last_checked = fp_info.timestamp,
			is_changed = is_file_changed(path),
		}
	end

	return stats
end

---------------------------------------------------------------------
-- 新增：外部配置覆盖接口（方便用户自定义阈值）
---------------------------------------------------------------------
function M.set_config(custom_config)
	if type(custom_config) ~= "table" then
		return false
	end

	-- 覆盖配置项（只覆盖存在的键）
	for key, value in pairs(custom_config) do
		if CONFIG[key] ~= nil then
			CONFIG[key] = value
		end
	end

	return true
end

return M
