-- lua/todo2/manager.lua
--- @module todo2.manager
--- @brief 提供双链管理工具：QF/LocList 展示、孤立检测、统计、修复（多标签版）

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖（统一入口）
---------------------------------------------------------------------

local store

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

---------------------------------------------------------------------
-- 工具函数：扫描当前 buffer 中的链接（支持 TAG）
---------------------------------------------------------------------

--- 扫描当前 buffer 中的代码/TODO 链接
--- @return table[] { filename, lnum, text }
local function scan_buffer_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local results = {}

	for lnum, line in ipairs(lines) do
		-- 代码 → TODO（TAG:ref:id）
		local tag, id = line:match("([A-Z][A-Z0-9_]+):ref:(%w+)")
		if id then
			local link = get_store().get_todo_link(id, { force_relocate = true })
			if link then
				table.insert(results, {
					filename = filename,
					lnum = lnum,
					text = string.format("%s → %s:%d", tag, link.path, link.line),
				})
			else
				table.insert(results, {
					filename = filename,
					lnum = lnum,
					text = string.format("孤立的 %s 标记", tag),
				})
			end
		end

		-- TODO → 代码（{#id}）
		local id2 = line:match("{#(%w+)}")
		if id2 then
			local link = get_store().get_code_link(id2, { force_relocate = true })
			if link then
				table.insert(results, {
					filename = filename,
					lnum = lnum,
					text = string.format("TODO → CODE %s:%d", link.path, link.line),
				})
			else
				table.insert(results, {
					filename = filename,
					lnum = lnum,
					text = "孤立的 TODO 标记",
				})
			end
		end
	end

	return results
end

---------------------------------------------------------------------
-- QF：显示当前项目所有代码标记（多标签版）
---------------------------------------------------------------------

function M.show_project_links_qf()
	local project_root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
	local all_code = get_store().get_all_code_links()

	local qf = {}

	for id, link in pairs(all_code) do
		local path = vim.fn.fnamemodify(link.path, ":p")

		if path:sub(1, #project_root) == project_root then
			local todo = get_store().get_todo_link(id, { force_relocate = true })

			-- 从代码文件重新读取 TAG（防御越界）
			local file_lines = vim.fn.readfile(link.path)
			local code_line = file_lines[link.line] or ""
			local tag = code_line:match("([A-Z][A-Z0-9_]+):ref:")

			local text
			if todo then
				text =
					string.format("[%s %s] → %s:%d", tag or "TAG", id, vim.fn.fnamemodify(todo.path, ":t"), todo.line)
			else
				text = string.format("[%s %s] 孤立的代码标记", tag or "TAG", id)
			end

			table.insert(qf, {
				filename = path,
				lnum = link.line,
				text = text,
			})
		end
	end

	if #qf == 0 then
		vim.notify("当前项目中没有双链标记", vim.log.levels.INFO)
		return
	end

	table.sort(qf, function(a, b)
		if a.filename == b.filename then
			return a.lnum < b.lnum
		end
		return a.filename < b.filename
	end)

	vim.fn.setqflist(qf, "r")
	vim.cmd("copen")

	-- 自动设置 buffer-local keymap
	vim.defer_fn(function()
		local winid = vim.fn.getqflist({ winid = 0 }).winid
		if winid > 0 then
			local buf = vim.api.nvim_win_get_buf(winid)

			vim.keymap.set("n", "<CR>", function()
				local items = vim.fn.getqflist()
				local idx = vim.fn.line(".")
				local item = items[idx]
				if item then
					vim.cmd("cclose")
					vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
					vim.fn.cursor(item.lnum, 1)
					vim.cmd("normal! zz")
				end
			end, { buffer = buf })

			vim.keymap.set("n", "q", function()
				vim.cmd("cclose")
			end, { buffer = buf })
		end
	end, 50)
end

---------------------------------------------------------------------
-- LocList：显示当前 buffer 的所有标记
---------------------------------------------------------------------

function M.show_buffer_links_loclist()
	local items = scan_buffer_links()
	if #items == 0 then
		vim.notify("当前 buffer 没有双链标记", vim.log.levels.INFO)
		return
	end

	vim.fn.setloclist(0, items, "r")
	vim.cmd("lopen")
end

---------------------------------------------------------------------
-- 修复：删除当前 buffer 的孤立标记（多标签版）
---------------------------------------------------------------------

function M.fix_orphan_links_in_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local removed = 0

	-----------------------------------------------------------------
	-- 1. 尝试解析 TODO 任务树，构建 { id -> 子树范围 } 映射
	-----------------------------------------------------------------
	local core_ok, core = pcall(require, "todo2.core")
	local id_ranges = {}
	if core_ok then
		local tasks = core.parse_tasks(lines)

		local function compute_subtree_end(task)
			local max_line = task.line_num or 1
			for _, child in ipairs(task.children or {}) do
				local child_max = compute_subtree_end(child)
				if child_max > max_line then
					max_line = child_max
				end
			end
			return max_line
		end

		for _, task in ipairs(tasks) do
			local line = lines[task.line_num] or ""
			local id = line:match("{#(%w+)}")
			if id then
				local subtree_end = compute_subtree_end(task)
				id_ranges[id] = {
					start = task.line_num,
					["end"] = subtree_end,
				}
			end
		end
	end

	-----------------------------------------------------------------
	-- 2. 从底向上扫描行，删除孤立标记
	-----------------------------------------------------------------
	local handled_todo_ids = {}

	for i = #lines, 1, -1 do
		local line = lines[i]

		-- 代码 → TODO
		local _, id = line:match("([A-Z][A-Z0-9_]+):ref:(%w+)")
		if id then
			local link = get_store().get_todo_link(id)
			if not link then
				vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
				removed = removed + 1
				M.delete_store_links_by_id(id)
			end
		end

		-- TODO → 代码
		local id2 = line:match("{#(%w+)}")
		if id2 then
			local link = get_store().get_code_link(id2)
			if not link then
				local range = id_ranges[id2]
				if range and not handled_todo_ids[id2] then
					local start_idx = math.max(1, math.min(range.start, #lines))
					local end_idx = math.max(start_idx, math.min(range["end"], #lines))

					vim.api.nvim_buf_set_lines(bufnr, start_idx - 1, end_idx, false, {})
					removed = removed + (end_idx - start_idx + 1)

					handled_todo_ids[id2] = true
					M.delete_store_links_by_id(id2)
				else
					vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
					removed = removed + 1
					M.delete_store_links_by_id(id2)
				end
			end
		end
	end

	vim.notify(string.format("已清理 %d 个孤立标记（含子任务）", removed), vim.log.levels.INFO)
	require("todo2.autosave").request_save(bufnr)
end

---------------------------------------------------------------------
-- 双链删除（完全对称 + 安全顺序）
---------------------------------------------------------------------

--- 删除代码文件中的标记行
function M.delete_code_link_by_id(id)
	if not id or id == "" then
		return false
	end

	local s = get_store()
	local link = s.get_code_link(id)
	if not link or not link.path or not link.line then
		return false
	end

	local bufnr = vim.fn.bufadd(link.path)
	vim.fn.bufload(bufnr)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if link.line < 1 or link.line > #lines then
		return false
	end

	vim.api.nvim_buf_set_lines(bufnr, link.line - 1, link.line, false, {})

	vim.api.nvim_buf_call(bufnr, function()
		require("todo2.autosave").request_save(bufnr)
	end)

	return true
end

--- 删除 store 中的记录
function M.delete_store_links_by_id(id)
	if not id or id == "" then
		return false
	end

	local s = get_store()

	local had_todo = s.get_todo_link(id) ~= nil
	local had_code = s.get_code_link(id) ~= nil

	if had_todo then
		s.delete_todo_link(id)
	end
	if had_code then
		s.delete_code_link(id)
	end

	return had_todo or had_code
end

--- TODO 被删除 → 同步删除代码 + store
function M.on_todo_deleted(id)
	if not id or id == "" then
		return
	end

	local deleted_code = M.delete_code_link_by_id(id)
	local deleted_store = M.delete_store_links_by_id(id)

	if deleted_code or deleted_store then
		vim.notify(string.format("已同步删除标记 %s 的代码与存储记录", id), vim.log.levels.INFO)
	end
end

--- 代码被删除 → 同步删除 TODO + store（支持 dd 已先删代码）
function M.on_code_deleted(id, opts)
	opts = opts or {}
	local code_already_deleted = opts.code_already_deleted

	if not id or id == "" then
		return
	end

	local s = get_store()
	local link = s.get_todo_link(id, { force_relocate = true })

	-- 如果 store 中已经没有 TODO 记录 → 只删 store
	if not link then
		M.delete_store_links_by_id(id)
		return
	end

	---------------------------------------------------------------------
	-- ⭐ 关键修复：不再信任 store 的 link.line
	--    而是实时扫描 TODO buffer，找到真正的 {#id} 行号
	---------------------------------------------------------------------
	local todo_path = link.path
	local bufnr = vim.fn.bufnr(todo_path)

	if bufnr == -1 then
		bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(bufnr)
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local real_line = nil

	for i, line in ipairs(lines) do
		if line:match("{#" .. id .. "}") then
			real_line = i
			break
		end
	end

	-- 如果找不到 → 说明 TODO buffer 已经被用户改乱，直接删 store
	if not real_line then
		M.delete_store_links_by_id(id)
		return
	end

	---------------------------------------------------------------------
	-- ⭐ 删除 TODO buffer 中的真实行
	---------------------------------------------------------------------
	pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, real_line - 1, real_line, false, {})
		vim.api.nvim_buf_call(bufnr, function()
			require("todo2.autosave").request_save(bufnr)
		end)
	end)

	---------------------------------------------------------------------
	-- ⭐ 删除 store 记录
	---------------------------------------------------------------------
	M.delete_store_links_by_id(id)

	---------------------------------------------------------------------
	-- 通知
	---------------------------------------------------------------------
	vim.notify(string.format("已同步删除标记 %s 的 TODO 与存储记录", id), vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- dd：代码侧删除（与 TODO 侧完全对称）
---------------------------------------------------------------------
function M.delete_code_link_dd()
	local bufnr = vim.api.nvim_get_current_buf()

	-----------------------------------------------------------------
	-- 1. 计算删除范围（支持可视模式）
	-----------------------------------------------------------------
	local mode = vim.api.nvim_get_mode().mode
	local is_visual = (mode == "v" or mode == "V" or mode == "\22")

	local start_lnum, end_lnum
	if is_visual then
		start_lnum = vim.fn.line("v")
		end_lnum = vim.fn.line(".")
		if start_lnum > end_lnum then
			start_lnum, end_lnum = end_lnum, start_lnum
		end
	else
		start_lnum = vim.fn.line(".")
		end_lnum = start_lnum
	end

	-----------------------------------------------------------------
	-- 2. 收集所有 TAG:ref:id（与 TODO 侧收集 {#id} 对称）
	-----------------------------------------------------------------
	local ids = {}
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)

	for _, line in ipairs(lines) do
		for id in line:gmatch("[A-Z][A-Z0-9_]*:ref:(%w+)") do
			table.insert(ids, id)
		end
	end

	-----------------------------------------------------------------
	-- 3. 同步删除所有 ID（TODO 行 + store）
	--    与 TODO 侧 dd 完全对称：先删另一侧，再删本侧
	-----------------------------------------------------------------
	for _, id in ipairs(ids) do
		pcall(function()
			M.on_code_deleted(id, { code_already_deleted = true })
		end)
	end

	-----------------------------------------------------------------
	-- 4. 执行原生删除（与 TODO 侧一致）
	-----------------------------------------------------------------
	if is_visual then
		vim.cmd("normal! d")
	else
		vim.cmd("normal! dd")
	end

	-----------------------------------------------------------------
	-- 5. 刷新代码侧虚拟文本（立即刷新更丝滑）
	-----------------------------------------------------------------
	local renderer = require("todo2.link.renderer")
	renderer.render_code_status(bufnr)

	-----------------------------------------------------------------
	-- 6. 自动保存（统一走 autosave）
	-----------------------------------------------------------------
	require("todo2.autosave").request_save(bufnr)
end
---------------------------------------------------------------------
-- 统计（多标签版）
---------------------------------------------------------------------

function M.show_stats()
	local project_root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

	local all_code = get_store().get_all_code_links()
	local all_todo = get_store().get_all_todo_links()

	local code_count = 0
	local todo_count = 0
	local orphan_code = 0
	local orphan_todo = 0

	local tag_stats = {}

	for id, link in pairs(all_code) do
		local path = vim.fn.fnamemodify(link.path, ":p")
		if path:sub(1, #project_root) == project_root then
			code_count = code_count + 1

			local file_lines = vim.fn.readfile(link.path)
			local line = file_lines[link.line] or ""
			local tag = line:match("([A-Z][A-Z0-9_]+):ref:") or "TAG"

			tag_stats[tag] = (tag_stats[tag] or 0) + 1

			if not all_todo[id] then
				orphan_code = orphan_code + 1
			end
		end
	end

	for id, link in pairs(all_todo) do
		local path = vim.fn.fnamemodify(link.path, ":p")
		if path:sub(1, #project_root) == project_root then
			todo_count = todo_count + 1
			if not all_code[id] then
				orphan_todo = orphan_todo + 1
			end
		end
	end

	local msg = {}
	table.insert(msg, "📊 双链统计（当前项目）")
	table.insert(msg, "━━━━━━━━━━━━━━━━━━━━")
	table.insert(msg, string.format("• 代码标记总数: %d", code_count))
	table.insert(msg, string.format("• TODO 文件标记总数: %d", todo_count))
	table.insert(msg, string.format("• 孤立代码标记: %d", orphan_code))
	table.insert(msg, string.format("• 孤立 TODO 标记: %d", orphan_todo))
	table.insert(msg, "")
	table.insert(msg, "• 按 TAG 分类:")

	for tag, count in pairs(tag_stats) do
		table.insert(msg, string.format("    %s: %d", tag, count))
	end

	local lines = msg
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, #l)
	end
	width = width + 4

	local height = #lines + 2
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = "双链统计",
	})

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf })
end

---------------------------------------------------------------------
-- 工具：重新加载 store
---------------------------------------------------------------------

function M.reload_store()
	store = nil
	package.loaded["todo2.store"] = nil
	vim.notify("store 模块已重新加载", vim.log.levels.INFO)
end

return M
