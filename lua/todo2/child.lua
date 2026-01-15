-- lua/todo2/child.lua
local M = {}

local ui = require("todo2.ui")
local link = require("todo2.link")
local file_manager = require("todo2.ui.file_manager")

local selecting_parent = false

local pending = {
	code_buf = nil,
	code_row = nil,
}

---------------------------------------------------------------------
-- 插入子任务
---------------------------------------------------------------------
local function insert_child(todo_bufnr, parent_line, parent_indent, new_id)
	local indent = parent_indent or ""
	local child_indent = indent .. "  "

	-- 统一格式：- [ ] {#id} 新建任务
	local new_line = string.format("%s- [ ] {#%s} %s", child_indent, new_id, "新任务")

	-- 在父任务下方插入子任务
	vim.api.nvim_buf_set_lines(todo_bufnr, parent_line, parent_line, false, { new_line })

	require("todo2.autosave").request_save(bufnr)

	-- 返回新插入行的行号
	return parent_line + 1
end

---------------------------------------------------------------------
-- 回填代码 TAG
---------------------------------------------------------------------
local function update_code_line(new_id)
	local cbuf = pending.code_buf
	local crow = pending.code_row
	if not cbuf or not crow then
		return
	end
	require("todo2.link.utils").insert_code_tag_above(cbuf, crow, new_id)
	link.sync_code_links()
end

---------------------------------------------------------------------
-- 在 TODO 浮窗中按 <CR>：选择父任务
---------------------------------------------------------------------
function M.on_cr_in_todo()
	if not selecting_parent then
		return
	end

	local tbuf = vim.api.nvim_get_current_buf()
	local trow = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(tbuf, trow - 1, trow, false)[1]
	if not line then
		return
	end

	local parent_id = line:match("{#(%w+)}")
	if not parent_id then
		vim.notify("当前行不是任务行", vim.log.levels.WARN)
		return
	end

	local new_id = link.generate_id()
	local indent = line:match("^(%s*)") or ""

	local child_row = insert_child(tbuf, trow, indent, new_id)
	update_code_line(new_id)

	selecting_parent = false

	-- 跳到新行行尾并进入插入模式
	vim.api.nvim_win_set_cursor(0, { child_row, 0 })
	vim.cmd("normal! $")
	vim.cmd("startinsert")

	-- ⭐ 自动保存 code buffer（关键）
	if pending.code_buf and vim.api.nvim_buf_is_valid(pending.code_buf) then
		vim.api.nvim_buf_call(pending.code_buf, function()
			require("todo2.autosave").request_save(bufnr)
		end)
	end
end

---------------------------------------------------------------------
-- 从代码中启动子任务创建
---------------------------------------------------------------------
function M.create_child_from_code()
	local cbuf = vim.api.nvim_get_current_buf()
	local crow = vim.api.nvim_win_get_cursor(0)[1]

	pending.code_buf = cbuf
	pending.code_row = crow

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local files = file_manager.get_todo_files(project)

	if #files == 0 then
		vim.notify("当前项目没有 TODO 文件", vim.log.levels.WARN)
		return
	end

	local choices = {}
	for _, f in ipairs(files) do
		table.insert(choices, {
			path = f,
			display = vim.fn.fnamemodify(f, ":t"),
		})
	end

	vim.ui.select(choices, {
		prompt = "选择文件",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		if not choice then
			return
		end

		local todo_path = choice.path
		local tbuf, win = ui.open_todo_file(todo_path, "float", nil, { enter_insert = false })

		selecting_parent = true

		vim.notify("请选择父任务，然后按 <CR> 挂载子任务", vim.log.levels.INFO)

		vim.keymap.set("n", "<CR>", function()
			if selecting_parent then
				M.on_cr_in_todo()
			else
				vim.cmd("normal! <CR>")
			end
		end, {
			buffer = tbuf,
			noremap = true,
			nowait = true,
			desc = "在子任务创建模式下，用 <CR> 选择父任务",
		})
	end)
end

return M
