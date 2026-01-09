-- lua/todo2/link/syncer.lua
--- @module todo2.link.syncer
--- @brief 负责代码文件与 TODO 文件的双链同步（行号更新、孤立清理、渲染刷新）
---
--- 设计目标：
--- 1. 同步必须是幂等的（多次执行不会破坏数据）
--- 2. 与 store.lua 完全对齐（路径规范化、force_relocate）
--- 3. 不主动覆盖 store 中的行号，除非文件中确实发生变化
--- 4. 不产生“行号漂移”或“重复写入”
--- 5. 同步后自动刷新渲染（代码状态渲染）

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local renderer

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

local function get_renderer()
	if not renderer then
		renderer = require("todo2.link.renderer")
	end
	return renderer
end

---------------------------------------------------------------------
-- 工具函数：扫描文件中的链接
---------------------------------------------------------------------

--- 扫描代码文件中的 TODO:ref:id
--- @param lines string[]
--- @return table<string, integer> 映射 id → 行号
local function scan_code_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		local id = line:match("TODO:ref:(%w+)")
		if id then
			found[id] = i
		end
	end
	return found
end

--- 扫描 TODO 文件中的 {#id}
--- @param lines string[]
--- @return table<string, integer> 映射 id → 行号
local function scan_todo_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		local id = line:match("{#(%w+)}")
		if id then
			found[id] = i
		end
	end
	return found
end

---------------------------------------------------------------------
-- 同步：代码文件（代码 → TODO）
---------------------------------------------------------------------

--- 同步当前代码文件中的链接
--- @return nil
function M.sync_code_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = scan_code_links(lines)

	local store_mod = get_store()
	local all_code_links = store_mod.find_code_links_by_file(path)

	-- 1. 删除文件中已不存在的链接
	for _, link in ipairs(all_code_links) do
		if not found[link.id] then
			store_mod.delete_code_link(link.id)
		end
	end

	-- 2. 更新行号（仅当文件中行号变化时）
	for id, lnum in pairs(found) do
		local link = store_mod.get_code_link(id)
		if link then
			if link.line ~= lnum then
				store_mod.add_code_link(id, {
					path = path,
					line = lnum,
					content = link.content or "",
					created_at = link.created_at or os.time(),
				})
			end
		end
	end

	-- 3. 刷新代码状态渲染
	vim.schedule(function()
		get_renderer().render_code_status(bufnr)
	end)
end

---------------------------------------------------------------------
-- 同步：TODO 文件（TODO → 代码）
---------------------------------------------------------------------

--- 同步当前 TODO 文件中的链接
--- @return nil
function M.sync_todo_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = scan_todo_links(lines)

	local store_mod = get_store()
	local all_todo_links = store_mod.find_todo_links_by_file(path)

	-- 1. 删除文件中已不存在的链接
	for _, link in ipairs(all_todo_links) do
		if not found[link.id] then
			store_mod.delete_todo_link(link.id)
		end
	end

	-- 2. 更新行号（仅当文件中行号变化时）
	for id, lnum in pairs(found) do
		local link = store_mod.get_todo_link(id)
		if link then
			if link.line ~= lnum then
				store_mod.add_todo_link(id, {
					path = path,
					line = lnum,
					content = link.content or "",
					created_at = link.created_at or os.time(),
				})
			end
		end
	end

	-- 3. 刷新相关代码文件的渲染
	for id, _ in pairs(found) do
		local code = store_mod.get_code_link(id)
		if code then
			local cbuf = vim.fn.bufnr(code.path)
			if cbuf ~= -1 then
				vim.schedule(function()
					get_renderer().render_code_status(cbuf)
				end)
			end
		end
	end
end

return M
