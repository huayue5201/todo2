--- @module todo2.link.syncer
--- @brief 负责代码文件与 TODO 文件的双链同步（行号更新、上下文修复、孤立清理、渲染刷新）

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local renderer
local core -- ⭐ 新增：懒加载 core 模块

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

local function get_core()
	if not core then
		core = require("todo2.core")
	end
	return core
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
	-- 2. 写入 / 更新 code_link（不影响 todo_link）
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
	-- 1. 扫描当前文件中的 {#id}（真实存在的 TODO 行）
	-----------------------------------------------------------------
	local found = {} -- id -> line
	for i, line in ipairs(lines) do
		local id = line:match("{#(%w+)}")
		if id then
			found[id] = i
		end
	end

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
	-- 3. 为当前文件中所有 {#id} 写入 / 更新 todo_link
	--    ✅ 不再要求必须先有 code_link
	-----------------------------------------------------------------
	for id, lnum in pairs(found) do
		local prev = lines[lnum - 1]
		local curr = lines[lnum]
		local next = lines[lnum + 1]
		local new_ctx = store_mod.build_context(prev, curr, next)

		local existing = store_mod.get_todo_link(id)
		if existing then
			local need_update = existing.path ~= path
				or existing.line ~= lnum
				or not store_mod.context_match(existing.context, new_ctx)

			if need_update then
				store_mod.add_todo_link(id, {
					path = path,
					line = lnum,
					content = existing.content or "",
					created_at = existing.created_at or os.time(),
					context = new_ctx,
				})
			end
		else
			store_mod.add_todo_link(id, {
				path = path,
				line = lnum,
				content = "",
				created_at = os.time(),
				context = new_ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- 4. 解析任务树 → 写入父子结构（只针对有 {#id} 的任务）
	-----------------------------------------------------------------
	local core_mod = get_core()
	local tasks = core_mod.parse_tasks(lines) or {}

	-- 行号 → 任务对象
	local task_by_line = {}
	for _, t in ipairs(tasks) do
		if t.line_num then
			task_by_line[t.line_num] = t
		end
	end

	-- 行号 → id（只记录有 {#id} 的行）
	local line_to_id = {}
	for id, lnum in pairs(found) do
		line_to_id[lnum] = id
	end

	for id, lnum in pairs(found) do
		local task = task_by_line[lnum]
		if task then
			-- 父 ID（父任务那一行也必须有 {#id} 才会被记录）
			local parent_id = nil
			if task.parent and task.parent.line_num then
				parent_id = line_to_id[task.parent.line_num]
			end

			-- 子 ID 列表（只收集有 {#id} 的子任务）
			local children_ids = {}
			if task.children and #task.children > 0 then
				for _, child in ipairs(task.children) do
					if child.line_num then
						local cid = line_to_id[child.line_num]
						if cid then
							table.insert(children_ids, cid)
						end
					end
				end
			end

			-- 在兄弟中的顺序（从 1 开始）
			local order = nil
			if task.parent and task.parent.children then
				for idx, child in ipairs(task.parent.children) do
					if child == task then
						order = idx
						break
					end
				end
			end

			-- 缩进层级（用前导空白长度表示）
			local raw_line = lines[lnum] or ""
			local indent = raw_line:match("^(%s*)") or ""
			local depth = #indent

			store_mod.set_task_structure(id, {
				parent_id = parent_id,
				children = children_ids,
				order = order,
				depth = depth,
			})
		end
	end

	-----------------------------------------------------------------
	-- 5. 刷新相关代码文件的渲染（只要有 code_link 就刷新）
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
