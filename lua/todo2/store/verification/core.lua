-- lua/todo2/store/verification/core.lua
-- 核心验证逻辑：上下文验证、状态校准、单个链接验证

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local types = require("todo2.store.types")
local cache = require("todo2.store.verification.cache")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
M.CONFIG = {
	CONTEXT_VALID_THRESHOLD = 70,
	CONTEXT_UPDATE_THRESHOLD = 60,
	MAX_LOG_SIZE = 100,
	LOG_SAMPLE_RATE = 10,
}

local LOG_KEY = "todo.log.verification"
local STATS_KEY = "todo.stats.verification"

---------------------------------------------------------------------
-- 链接状态校准
---------------------------------------------------------------------
function M.calibrate_link_active_status(link_obj)
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
-- 上下文验证
---------------------------------------------------------------------
function M.verify_context_fingerprint(link_obj)
	if not link_obj or not link_obj.context then
		return {
			valid = false,
			reason = "无上下文信息",
			needs_update = false,
		}
	end

	if not cache.file_exists_fast(link_obj.path) then
		return {
			valid = false,
			reason = "文件不存在",
			needs_update = false,
		}
	end

	local result =
		locator.locate_by_context_fingerprint(link_obj.path, link_obj.context, M.CONFIG.CONTEXT_UPDATE_THRESHOLD)

	if result then
		local is_valid = result.similarity >= M.CONFIG.CONTEXT_VALID_THRESHOLD
		return {
			valid = is_valid,
			similarity = result.similarity,
			line = result.line,
			context = result.context,
			needs_update = not is_valid and result.similarity >= M.CONFIG.CONTEXT_UPDATE_THRESHOLD,
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
-- 日志记录
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
		if #log > M.CONFIG.MAX_LOG_SIZE then
			table.remove(log, 1)
		end
		store.set_key(LOG_KEY, log)
		return
	end

	local count = cache.get_verify_count(id)
	if count % M.CONFIG.LOG_SAMPLE_RATE == 1 then
		local log = store.get_key(LOG_KEY) or {}
		table.insert(log, {
			id = id,
			type = link_type,
			success = success,
			timestamp = os.time(),
			sampled = true,
			critical = false,
		})
		if #log > M.CONFIG.MAX_LOG_SIZE then
			table.remove(log, 1)
		end
		store.set_key(LOG_KEY, log)
	end
end

function M.update_verification_stats(report)
	local stats = store.get_key(STATS_KEY) or {}
	stats.last_run = os.time()
	stats.total_runs = (stats.total_runs or 0) + 1
	stats.total_todo_verified = (stats.total_todo_verified or 0) + report.verified_todo
	stats.total_code_verified = (stats.total_code_verified or 0) + report.verified_code
	stats.total_failures = (stats.total_failures or 0) + report.failed_todo + report.failed_code
	store.set_key(STATS_KEY, stats)
end

---------------------------------------------------------------------
-- 单个链接异步验证
---------------------------------------------------------------------
function M.verify_single_link_async(link_obj, force_reverify, callback)
	if not link_obj then
		if callback then
			callback(nil)
		end
		return
	end

	link_obj = M.calibrate_link_active_status(link_obj)

	if not force_reverify and not cache.can_verify(link_obj.id, link_obj) then
		if callback then
			callback(link_obj)
		end
		return
	end

	if link_obj.type == "code_to_todo" then
		local todo_link = link.get_todo(link_obj.id, { verify_line = false })
		if todo_link and types.is_archived_status(todo_link.status) then
			todo_link = M.calibrate_link_active_status(todo_link)
			link_obj.active = false
			link_obj.last_verified_at = os.time()
			link_obj.line_verified = true
			if callback then
				callback(link_obj)
			end
			return
		end
	end

	if
		link_obj.line_verified
		and not force_reverify
		and not (link_obj.path and cache.is_file_changed(link_obj.path))
	then
		if callback then
			callback(link_obj)
		end
		return
	end

	cache.update_verify_time(link_obj.id)

	locator.locate_task(link_obj, function(verified_link)
		if not verified_link then
			log_verification(link_obj.id, link_obj.type, false, "定位任务失败")
			if callback then
				callback(link_obj)
			end
			return
		end

		verified_link = M.calibrate_link_active_status(verified_link)

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
-- 删除恢复操作
---------------------------------------------------------------------
local KEY_PATTERNS = {
	todo = "todo.links.todo.%s",
	code = "todo.links.code.%s",
}

local function get_link_key(link_type, id)
	return KEY_PATTERNS[link_type]:format(id)
end

function M.mark_link_deleted(link_id, link_type)
	if not link_id or not link_type then
		return false
	end

	local link_key = get_link_key(link_type, link_id)
	local old_link = store.get_key(link_key)
	if not old_link then
		return false
	end

	local old_link_copy = vim.deepcopy(old_link)

	old_link.deleted_at = os.time()
	old_link.active = false
	old_link.status = "deleted"

	store.set_key(link_key, old_link)
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

	old_link.deleted_at = nil
	old_link.active = true
	old_link.status = old_link.status == "deleted" and "normal" or old_link.status

	store.set_key(link_key, old_link)
	return true
end

function M.set_config(custom_config)
	if type(custom_config) ~= "table" then
		return false
	end

	for key, value in pairs(custom_config) do
		if M.CONFIG[key] ~= nil then
			M.CONFIG[key] = value
		end
	end

	return true
end

return M
