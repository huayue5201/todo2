-- lua/todo2/ui/statusline.lua
--- @brief 状态栏组件 - 显示当前 buffer 的标记数量

local M = {}

local index = require("todo2.store.index")

-- 缓存，避免频繁计算
local cache = {
	count = 0,
	timestamp = 0,
	filepath = "",
}

local CACHE_TTL = 1000 -- 1秒缓存

--- 获取当前 buffer 的标记数量
--- @param filepath string|nil 文件路径，默认当前 buffer
--- @return number 标记数量
function M.get_marker_count(filepath)
	if not filepath then
		local bufnr = vim.api.nvim_get_current_buf()
		filepath = vim.api.nvim_buf_get_name(bufnr)
	end

	if filepath == "" then
		return 0
	end

	-- 检查缓存
	local now = vim.loop.now()
	if cache.filepath == filepath and (now - cache.timestamp) < CACHE_TTL then
		return cache.count
	end

	-- 使用去重统计
	local seen_ids = {}
	local count = 0

	-- 从 TODO 端索引获取标记
	local todo_links = index.find_todo_links_by_file(filepath) or {}
	for _, task in ipairs(todo_links) do
		if task and task.id and not seen_ids[task.id] then
			seen_ids[task.id] = true
			count = count + 1
		end
	end

	-- 从代码端索引获取标记
	local code_links = index.find_code_links_by_file(filepath) or {}
	for _, task in ipairs(code_links) do
		if task and task.id and not seen_ids[task.id] then
			seen_ids[task.id] = true
			count = count + 1
		end
	end

	-- 更新缓存
	cache.count = count
	cache.timestamp = now
	cache.filepath = filepath

	return count
end

return M
