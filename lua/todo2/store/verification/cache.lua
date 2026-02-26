-- lua/todo2/store/verification/cache.lua
-- 缓存管理：文件元数据、验证时间等

local M = {}

local fn = vim.fn

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	FILE_EXISTS_TTL = 60,
	FILE_FINGERPRINT_TTL = 3600,
	VERIFY_COOLDOWN = 60,
}

---------------------------------------------------------------------
-- 文件元数据缓存
---------------------------------------------------------------------
local file_metadata_cache = {} -- {path = {fingerprint, timestamp}}
local file_exists_cache = {} -- {path = {exists, timestamp}}

function M.file_exists_fast(filepath)
	if not filepath then
		return false
	end

	local cached = file_exists_cache[filepath]
	local now = os.time()

	if cached and (now - cached.timestamp) < CONFIG.FILE_EXISTS_TTL then
		return cached.exists
	end

	local exists = fn.filereadable(filepath) == 1
	file_exists_cache[filepath] = { exists = exists, timestamp = now }
	return exists
end

function M.get_file_fingerprint(filepath)
	if not filepath or not M.file_exists_fast(filepath) then
		return nil
	end

	local stat = vim.loop.fs_stat(filepath)
	if not stat then
		return nil
	end

	return string.format("%d_%d", stat.size, stat.mtime.sec)
end

function M.is_file_changed(filepath)
	if not filepath or not M.file_exists_fast(filepath) then
		return false
	end

	local current_fingerprint = M.get_file_fingerprint(filepath)
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
-- 验证时间缓存
---------------------------------------------------------------------
local last_verify_time = {}
local verify_count = {}

function M.can_verify(id, link_obj)
	if not id then
		return false
	end

	if link_obj and link_obj.path and M.is_file_changed(link_obj.path) then
		return true
	end

	local last = last_verify_time[id]
	if not last then
		return true
	end

	local now = os.time()
	return (now - last) >= CONFIG.VERIFY_COOLDOWN
end

function M.update_verify_time(id)
	last_verify_time[id] = os.time()
	verify_count[id] = (verify_count[id] or 0) + 1
end

function M.get_verify_count(id)
	return verify_count[id] or 0
end

---------------------------------------------------------------------
-- 缓存清理
---------------------------------------------------------------------
function M.cleanup(expired_threshold)
	-- 清理验证时间缓存
	for id, time in pairs(last_verify_time) do
		if time < expired_threshold then
			last_verify_time[id] = nil
			verify_count[id] = nil
		end
	end

	-- 清理文件元数据缓存
	for path, info in pairs(file_metadata_cache) do
		if info.timestamp < expired_threshold then
			file_metadata_cache[path] = nil
		end
	end

	-- 清理文件存在性缓存
	for path, _ in pairs(file_exists_cache) do
		file_exists_cache[path] = nil
	end
end

function M.clear_file_cache(filepath)
	file_metadata_cache[filepath] = nil
	file_exists_cache[filepath] = nil
end

return M
