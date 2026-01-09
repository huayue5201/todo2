-- lua/todo2/manager.lua
--- @module todo2.manager
--- @brief 提供双链管理工具：QF/LocList 展示、孤立检测、统计、修复
---
--- 设计目标：
--- 1. 与 store.lua 完全对齐（路径规范化、force_relocate）
--- 2. 提供专业级工具：孤立检测、统计、QF 展示
--- 3. 所有操作幂等、安全、可恢复
--- 4. 所有函数带 LuaDoc 注释

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
-- 工具函数：扫描当前 buffer 中的链接
---------------------------------------------------------------------

--- 扫描当前 buffer 中的代码/TODO 链接
--- @return table[] { filename, lnum, text }
local function scan_buffer_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local results = {}

	for lnum, line in ipairs(lines) do
		-- 代码 → TODO
		local id = line:match("TODO:ref:(%w+)")
		if id then
			local link = get_store().get_todo_link(id, { force_relocate = true })
			if link then
				table.insert(results, {
					filename = filename,
					lnum = lnum,
					text = string.format("CODE → TODO %s:%d", link.path, link.line),
				})
			else
				table.insert(results, {
					filename = filename,
					lnum = lnum,
					text = "孤立的代码标记",
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
-- QF：显示当前项目所有代码标记
---------------------------------------------------------------------

--- 显示当前项目所有代码标记（QuickFix）
--- @return nil
function M.show_project_links_qf()
	local project_root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
	local all_code = get_store().get_all_code_links()

	local qf = {}

	for id, link in pairs(all_code) do
		local path = vim.fn.fnamemodify(link.path, ":p")

		-- 必须在当前项目内
		if path:sub(1, #project_root) == project_root then
			local todo = get_store().get_todo_link(id, { force_relocate = true })

			local text
			if todo then
				text = string.format("[%s] → %s:%d", id, vim.fn.fnamemodify(todo.path, ":t"), todo.line)
			else
				text = string.format("[%s] 孤立的代码标记", id)
			end

			table.insert(qf, {
				filename = path,
				lnum = link.line,
				text = text,
			})
		end
	end

	if #qf == 0 then
		vim.notify("当前项目中没有代码双链标记", vim.log.levels.INFO)
		return
	end

	-- 排序：按文件 → 行号
	table.sort(qf, function(a, b)
		if a.filename == b.filename then
			return a.lnum < b.lnum
		end
		return a.filename < b.filename
	end)

	vim.fn.setqflist(qf, "r")
	vim.cmd("copen")

	-- QF 键位
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

--- 显示当前 buffer 的所有双链标记（LocList）
--- @return nil
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
-- 修复：删除当前 buffer 的孤立标记
---------------------------------------------------------------------

--- 删除当前 buffer 中的孤立标记
--- @return nil
function M.fix_orphan_links_in_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local removed = 0

	for i = #lines, 1, -1 do
		local line = lines[i]

		-- 代码 → TODO
		local id = line:match("TODO:ref:(%w+)")
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
end

---------------------------------------------------------------------
-- 统计：当前项目的双链统计
---------------------------------------------------------------------

--- 显示当前项目的双链统计（浮窗）
--- @return nil
function M.show_stats()
	local project_root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

	local all_code = get_store().get_all_code_links()
	local all_todo = get_store().get_all_todo_links()

	local code_count = 0
	local todo_count = 0
	local orphan_code = 0
	local orphan_todo = 0

	for id, link in pairs(all_code) do
		local path = vim.fn.fnamemodify(link.path, ":p")
		if path:sub(1, #project_root) == project_root then
			code_count = code_count + 1
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

	local msg = string.format(
		"📊 双链统计（当前项目）\n"
			.. "━━━━━━━━━━━━━━━━━━━━\n"
			.. "• 代码标记: %d\n"
			.. "• TODO 标记: %d\n"
			.. "• 孤立代码标记: %d\n"
			.. "• 孤立 TODO 标记: %d\n",
		code_count,
		todo_count,
		orphan_code,
		orphan_todo
	)

	-- 浮窗展示
	local lines = vim.split(msg, "\n")
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
