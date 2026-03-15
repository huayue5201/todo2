-- lua/todo2/ui/statusline.lua
--- @module todo2.ui.status
--- @brief 状态栏组件 - 显示当前 buffer 的标记数量

local M = {}

local index = require("todo2.store.index")
local config = require("todo2.config")

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

	-- ⭐ 修复：使用去重统计
	local seen_ids = {} -- 用于去重的表
	local count = 0

	-- 从TODO端索引获取标记
	local todo_links = index.find_todo_links_by_file(filepath) or {}
	for _, link in ipairs(todo_links) do
		if not seen_ids[link.id] then
			seen_ids[link.id] = true
			count = count + 1
		end
	end

	-- 从代码端索引获取标记
	local code_links = index.find_code_links_by_file(filepath) or {}
	for _, link in ipairs(code_links) do
		if not seen_ids[link.id] then
			seen_ids[link.id] = true
			count = count + 1
		end
	end

	-- 更新缓存
	cache.count = count
	cache.timestamp = now
	cache.filepath = filepath

	return count
end

--- 获取格式化的状态栏文本
--- @param filepath string|nil 文件路径，默认当前 buffer
--- @return string 格式化的文本
function M.get_status_text(filepath)
	local count = M.get_marker_count(filepath)

	if count == 0 then
		return ""
	end

	local icons = config.get("status_icons") or { marker = "📍" }
	local icon = icons.marker or "📍"

	return string.format("%s %d", icon, count)
end

--- 注册到 lualine
function M.register_lualine()
	return {
		"todo2.ui.status",
		cond = function()
			local bufnr = vim.api.nvim_get_current_buf()
			local filepath = vim.api.nvim_buf_get_name(bufnr)
			return M.get_marker_count(filepath) > 0
		end,
	}
end

return M
