-- lua/todo2/manager.lua
--- @module todo2.manager
--- @brief 提供双链管理工具：QF/LocList 展示、孤立检测、统计、修复（多标签版）

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
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
		-- ⭐ 代码 → TODO（支持 TAG）
		local tag, id = line:match("(%u+):ref:(%w+)")
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

		-- TODO → 代码
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

			-- ⭐ 从代码文件重新读取 TAG
			local code_line = vim.fn.readfile(link.path)[link.line] or ""
			local tag = code_line:match("(%u+):ref:")

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

	for i = #lines, 1, -1 do
		local line = lines[i]

		-- ⭐ 代码 → TODO（支持 TAG）
		local tag, id = line:match("(%u+):ref:(%w+)")
		if id then
			local link = get_store().get_todo_link(id)
			if not link then
				vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
				removed = removed + 1
			end
		end

		-- TODO → 代码
		local id2 = line:match("{#(%w+)}")
		if id2 then
			local link = get_store().get_code_link(id2)
			if not link then
				vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
				removed = removed + 1
			end
		end
	end

	vim.notify(string.format("已清理 %d 个孤立标记", removed), vim.log.levels.INFO)
	vim.cmd("silent write")
end

---------------------------------------------------------------------
-- 双链删除
---------------------------------------------------------------------

function M.delete_code_link_by_id(id)
	if not id or id == "" then
		return false
	end

	local s = get_store()
	local link = s.get_code_link(id)
	if not link or not link.path or not link.line then
		return false
	end

	local path = link.path
	local line = link.line

	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if line < 1 or line > #lines then
		return false
	end

	vim.api.nvim_buf_set_lines(bufnr, line - 1, line, false, {})

	vim.api.nvim_buf_call(bufnr, function()
		vim.cmd("silent write")
	end)

	return true
end

function M.delete_store_links_by_id(id)
	if not id or id == "" then
		return false
	end

	local s = get_store()

	local ok1 = s.delete_todo_link and s.delete_todo_link(id)
	local ok2 = s.delete_code_link and s.delete_code_link(id)

	return (ok1 or ok2) and true or false
end

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

	-- ⭐ TAG 分类统计
	local tag_stats = {}

	for id, link in pairs(all_code) do
		local path = vim.fn.fnamemodify(link.path, ":p")
		if path:sub(1, #project_root) == project_root then
			code_count = code_count + 1

			local line = vim.fn.readfile(link.path)[link.line] or ""
			local tag = line:match("(%u+):ref:") or "TAG"

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
