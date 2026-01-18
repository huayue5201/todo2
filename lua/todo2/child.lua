-- lua/todo2/child.lua
--- @module todo2.child

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 懒加载依赖（使用模块管理器）
---------------------------------------------------------------------
local ui
local function get_ui()
	if not ui then
		ui = module.get("ui")
	end
	return ui
end

local link
local function get_link()
	if not link then
		link = module.get("link")
	end
	return link
end

local file_manager
local function get_file_manager()
	if not file_manager then
		file_manager = module.get("ui.file_manager")
	end
	return file_manager
end

---------------------------------------------------------------------
-- 状态管理
---------------------------------------------------------------------
local selecting_parent = false

local pending = {
	code_buf = nil,
	code_row = nil,
}

---------------------------------------------------------------------
-- 插入子任务（buffer API + autosave，不直接触发事件）
---------------------------------------------------------------------
local function insert_child(todo_bufnr, parent_line, parent_indent, new_id)
	local indent = parent_indent or ""
	local child_indent = indent .. "  "

	local new_line = string.format("%s- [ ] {#%s} 新任务", child_indent, new_id)

	-- 插入行
	vim.api.nvim_buf_set_lines(todo_bufnr, parent_line, parent_line, false, { new_line })

	-- autosave（写盘 → BufWritePost → sync → 事件系统）
	local autosave = module.get("core.autosave")
	autosave.request_save(todo_bufnr)

	return parent_line + 1
end

---------------------------------------------------------------------
-- 回填代码 TAG（buffer API + autosave，不直接触发事件）
---------------------------------------------------------------------
local function update_code_line(new_id)
	local cbuf = pending.code_buf
	local crow = pending.code_row
	if not cbuf or not crow then
		return
	end

	-- 使用模块管理器获取 link.utils
	local link_utils = module.get("link.utils")
	link_utils.insert_code_tag_above(cbuf, crow, new_id)

	-- autosave（写盘 → BufWritePost → sync → 事件系统）
	local autosave = module.get("core.autosave")
	autosave.request_save(cbuf)
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

	local link_module = get_link()
	local new_id = link_module.generate_id()
	local indent = line:match("^(%s*)") or ""

	-- 插入子任务
	local child_row = insert_child(tbuf, trow, indent, new_id)

	-- 回填代码 TAG
	update_code_line(new_id)

	selecting_parent = false

	-- 跳到新行行尾并进入插入模式
	vim.api.nvim_win_set_cursor(0, { child_row, 0 })
	vim.cmd("normal! $")
	vim.cmd("startinsert")
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
	local file_manager_module = get_file_manager()
	local files = file_manager_module.get_todo_files(project)

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
		local ui_module = get_ui()
		local tbuf, win = ui_module.open_todo_file(todo_path, "float", nil, { enter_insert = false })

		selecting_parent = true

		vim.notify("请选择父任务，然后按 <CR> 挂载子任务", vim.log.levels.INFO)

		-- 覆盖浮窗内的 <CR>
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
