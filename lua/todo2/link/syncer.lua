--- @module todo2.link.syncer
--- @brief 负责代码文件与 TODO 文件的双链同步（行号更新、上下文修复、孤立清理、渲染刷新）

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
-- 工具函数：扫描文件中的链接（支持 TAG）
---------------------------------------------------------------------

local function scan_code_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		local tag, id = line:match("(%u+):ref:(%w+)")
		if id then
			found[id] = i
		end
	end
	return found
end

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

local function get_context_triplet(lines, lnum)
	local prev = lines[lnum - 1]
	local curr = lines[lnum]
	local next = lines[lnum + 1]
	return prev, curr, next
end

---------------------------------------------------------------------
-- ⭐ 同步：代码文件（代码 → TODO）
---------------------------------------------------------------------
function M.sync_code_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = scan_code_links(lines)

	local store_mod = get_store()
	local existing = store_mod.find_code_links_by_file(path)

	-----------------------------------------------------------------
	-- 1. 删除文件中已不存在的 code_link
	-----------------------------------------------------------------
	for _, link in ipairs(existing) do
		if not found[link.id] then
			store_mod.delete_code_link(link.id)
		end
	end

	-----------------------------------------------------------------
	-- 2. 写入 / 更新 code_link
	-----------------------------------------------------------------
	for id, lnum in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, lnum)
		local ctx = store_mod.build_context(prev, curr, next)

		local old = store_mod.get_code_link(id)
		if old then
			local need_update = old.line ~= lnum or not store_mod.context_match(old.context, ctx)

			if need_update then
				store_mod.add_code_link(id, {
					path = path,
					line = lnum,
					content = old.content or "",
					created_at = old.created_at or os.time(),
					context = ctx,
				})
			end
		else
			store_mod.add_code_link(id, {
				path = path,
				line = lnum,
				content = "",
				created_at = os.time(),
				context = ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- 3. 刷新渲染（只影响代码侧）
	-----------------------------------------------------------------
	vim.schedule(function()
		get_renderer().render_code_status(bufnr)
	end)
end

---------------------------------------------------------------------
-- ⭐ 同步：TODO 文件（TODO → 代码）
---------------------------------------------------------------------
function M.sync_todo_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if #lines == 0 then
		return
	end

	local store_mod = get_store()

	-----------------------------------------------------------------
	-- 1. 扫描当前文件中的 {#id}
	-----------------------------------------------------------------
	local found = scan_todo_links(lines)

	-----------------------------------------------------------------
	-- 2. 清理：删除 store 中指向本文件、但已不存在的 todo_link
	-----------------------------------------------------------------
	local existing_links = store_mod.find_todo_links_by_file(path)
	for _, link in ipairs(existing_links) do
		if not found[link.id] then
			store_mod.delete_todo_link(link.id)
		end
	end

	-----------------------------------------------------------------
	-- 3. 写入 / 更新 todo_link
	-----------------------------------------------------------------
	for id, lnum in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, lnum)
		local ctx = store_mod.build_context(prev, curr, next)

		local old = store_mod.get_todo_link(id)
		if old then
			local need_update = old.line ~= lnum or old.path ~= path or not store_mod.context_match(old.context, ctx)

			if need_update then
				store_mod.add_todo_link(id, {
					path = path,
					line = lnum,
					content = old.content or "",
					created_at = old.created_at or os.time(),
					context = ctx,
				})
			end
		else
			store_mod.add_todo_link(id, {
				path = path,
				line = lnum,
				content = "",
				created_at = os.time(),
				context = ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- ⭐ 4. 刷新相关代码文件的渲染
	-----------------------------------------------------------------
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
