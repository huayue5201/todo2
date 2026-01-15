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
-- ⭐ 自动清理：删除数据库中无效的 code/todo 链接
---------------------------------------------------------------------

local function cleanup_headless_links()
	local store_mod = get_store()

	local all_code = store_mod.get_all_code_links()
	local all_todo = store_mod.get_all_todo_links()

	-- 删除无头 TODO（没有 code link）
	for id, todo in pairs(all_todo) do
		if not all_code[id] then
			store_mod.delete_todo_link(id)
		end
	end

	-- 删除无头 CODE（没有 todo link）
	for id, code in pairs(all_code) do
		if not all_todo[id] then
			store_mod.delete_code_link(id)
		end
	end
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
	local all_code_links = store_mod.find_code_links_by_file(path)

	-- 删除文件中已不存在的链接
	for _, link in ipairs(all_code_links) do
		if not found[link.id] then
			store_mod.delete_code_link(link.id)
		end
	end

	-- 更新行号 + 上下文
	for id, lnum in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, lnum)
		local new_context = store_mod.build_context(prev, curr, next)

		local existing = store_mod.get_code_link(id)
		if existing then
			local need_update = existing.line ~= lnum or not store_mod.context_match(existing.context, new_context)

			if need_update then
				store_mod.add_code_link(id, {
					path = path,
					line = lnum,
					content = existing.content or "",
					created_at = existing.created_at or os.time(),
					context = new_context,
				})
			end
		else
			store_mod.add_code_link(id, {
				path = path,
				line = lnum,
				content = "",
				created_at = os.time(),
				context = new_context,
			})
		end
	end

	-- 自动清理孤立项
	cleanup_headless_links()

	-- 刷新渲染
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
	local found = scan_todo_links(lines)

	local store_mod = get_store()
	local all_todo_links = store_mod.find_todo_links_by_file(path)

	-- 删除文件中已不存在的链接
	for _, link in ipairs(all_todo_links) do
		if not found[link.id] then
			store_mod.delete_todo_link(link.id)
		end
	end

	-- 更新行号 + 上下文
	for id, lnum in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, lnum)
		local new_context = store_mod.build_context(prev, curr, next)

		-- ⭐ 关键修复：无头 TODO 不写入数据库
		local code = store_mod.get_code_link(id)
		if not code then
			goto continue
		end

		local existing = store_mod.get_todo_link(id)
		if existing then
			local need_update = existing.line ~= lnum or not store_mod.context_match(existing.context, new_context)

			if need_update then
				store_mod.add_todo_link(id, {
					path = path,
					line = lnum,
					content = existing.content or "",
					created_at = existing.created_at or os.time(),
					context = new_context,
				})
			end
		else
			store_mod.add_todo_link(id, {
				path = path,
				line = lnum,
				content = "",
				created_at = os.time(),
				context = new_context,
			})
		end

		::continue::
	end

	-- 自动清理孤立项
	cleanup_headless_links()

	-- 刷新相关代码文件渲染
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
