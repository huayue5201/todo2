-- lua/todo2/cache.lua
local M = {}

-- 统一缓存存储
M._cache = {
	parser = {}, -- 文件解析缓存
	renderer = {}, -- 渲染状态缓存
	metadata = {}, -- 元数据缓存
}

-- 缓存键名常量
M.KEYS = {
	PARSER_FILE = "parser:file:", -- parser:file:/path/to/file
	RENDERER_BUFFER = "renderer:buf:", -- renderer:buf:123
	STATUS_LINK = "status:link:", -- status:link:abc123
}

---------------------------------------------------------------------
-- 公共API
---------------------------------------------------------------------

--- 设置缓存值
--- @param category string 缓存类别
--- @param key string 缓存键
--- @param value any 缓存值
--- @param ttl number 过期时间（秒，可选）
function M.set(category, key, value, ttl)
	if not M._cache[category] then
		M._cache[category] = {}
	end

	local cache_entry = {
		value = value,
		timestamp = os.time(),
		ttl = ttl or nil,
	}

	M._cache[category][key] = cache_entry
	return true
end

--- 获取缓存值
--- @param category string 缓存类别
--- @param key string 缓存键
--- @return any|nil 缓存值
function M.get(category, key)
	if not M._cache[category] then
		return nil
	end

	local entry = M._cache[category][key]
	if not entry then
		return nil
	end

	-- 检查是否过期
	if entry.ttl and os.time() - entry.timestamp > entry.ttl then
		M._cache[category][key] = nil
		return nil
	end

	return entry.value
end

--- 删除缓存值
--- @param category string 缓存类别
--- @param key string 缓存键
function M.delete(category, key)
	if M._cache[category] then
		M._cache[category][key] = nil
	end
end

--- 清除类别下的所有缓存
--- @param category string 缓存类别
function M.clear_category(category)
	M._cache[category] = {}
end

--- 清除所有缓存
function M.clear_all()
	for category, _ in pairs(M._cache) do
		M._cache[category] = {}
	end
end

--- 获取缓存统计信息
function M.get_stats()
	local stats = {
		total_entries = 0,
		by_category = {},
	}

	for category, cache in pairs(M._cache) do
		local count = 0
		for _ in pairs(cache) do
			count = count + 1
		end
		stats.by_category[category] = count
		stats.total_entries = stats.total_entries + count
	end

	return stats
end

---------------------------------------------------------------------
-- 专用API（简化使用）
---------------------------------------------------------------------

--- 缓存文件解析结果
--- @param filepath string 文件路径
--- @param data table 解析数据
function M.cache_parse(filepath, data)
	local key = M.KEYS.PARSER_FILE .. filepath
	return M.set("parser", key, data)
end

--- 获取缓存的解析结果
--- @param filepath string 文件路径
--- @return table|nil
function M.get_cached_parse(filepath)
	local key = M.KEYS.PARSER_FILE .. filepath
	return M.get("parser", key)
end

--- 缓存渲染状态
--- @param bufnr number 缓冲区号
--- @param row number 行号
--- @param state table 渲染状态
function M.cache_render(bufnr, row, state)
	local key = M.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row
	return M.set("renderer", key, state, 60) -- 60秒TTL
end

--- 获取缓存的渲染状态
--- @param bufnr number 缓冲区号
--- @param row number 行号
--- @return table|nil
function M.get_cached_render(bufnr, row)
	local key = M.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row
	return M.get("renderer", key)
end

--- 清除文件相关的所有缓存
--- @param filepath string 文件路径
function M.clear_file_cache(filepath)
	-- 清除解析缓存
	local parser_key = M.KEYS.PARSER_FILE .. filepath
	M.delete("parser", parser_key)

	-- 清除该文件所有buffer的渲染缓存
	local bufnr = vim.fn.bufnr(filepath)
	if bufnr ~= -1 then
		M.clear_buffer_render_cache(bufnr)
	end
end

--- 清除缓冲区的渲染缓存
--- @param bufnr number 缓冲区号
function M.clear_buffer_render_cache(bufnr)
	if not M._cache.renderer then
		return
	end

	local prefix = M.KEYS.RENDERER_BUFFER .. bufnr .. ":"
	for key, _ in pairs(M._cache.renderer) do
		if key:sub(1, #prefix) == prefix then
			M._cache.renderer[key] = nil
		end
	end
end

--- 当状态更新时清除相关缓存
--- @param id string 链接ID
function M.clear_on_status_change(id)
	-- 获取相关链接信息
	local store = require("todo2.store")
	if not store or not store.link then
		return
	end

	local todo_link = store.link.get_todo(id, { verify_line = false })
	local code_link = store.link.get_code(id, { verify_line = false })

	-- 清除相关文件缓存
	if todo_link and todo_link.path then
		M.clear_file_cache(todo_link.path)
	end

	if code_link and code_link.path then
		M.clear_file_cache(code_link.path)
	end

	-- 如果这些buffer是打开的，也清除渲染缓存
	if todo_link and todo_link.path then
		local bufnr = vim.fn.bufnr(todo_link.path)
		if bufnr ~= -1 then
			M.clear_buffer_render_cache(bufnr)
		end
	end

	if code_link and code_link.path then
		local bufnr = vim.fn.bufnr(code_link.path)
		if bufnr ~= -1 then
			M.clear_buffer_render_cache(bufnr)
		end
	end
end

return M
