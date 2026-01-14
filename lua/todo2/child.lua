-- lua/todo2/child.lua
-- 从代码中创建子任务：复用 TODO 浮窗，<CR> 选择父任务，自动挂载子任务

local M = {}

local ui = require("todo2.ui")
local link = require("todo2.link")
local core = require("todo2.core")
local store = require("todo2.store")
local file_manager = require("todo2.ui.file_manager")

---------------------------------------------------------------------
-- 状态：是否处于“选择父任务模式”
---------------------------------------------------------------------
local selecting_parent = false

-- 记录代码 buffer 和行号
local pending = {
	code_buf = nil,
	code_row = nil,
}

---------------------------------------------------------------------
-- 高亮父任务（extmark）
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("todo2_child_select")

local function highlight_parent(bufnr, row)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
		hl_group = "Visual",
		end_line = row,
		end_col = 0,
	})
end

---------------------------------------------------------------------
-- 插入子任务（缩进 2 空格）
---------------------------------------------------------------------
local function insert_child(todo_bufnr, parent_line, parent_indent, new_id)
	local indent = parent_indent or ""
	local child_indent = indent .. "  " -- ⭐ 两个空格

	local new_line = string.format("%s- [ ] 新子任务 {#%s}", child_indent, new_id)

	vim.api.nvim_buf_set_lines(todo_bufnr, parent_line, parent_line, false, { new_line })
	vim.cmd("silent write")
end

---------------------------------------------------------------------
-- 回填代码 TAG（统一：插入到代码上一行）
---------------------------------------------------------------------
local function update_code_line(new_id)
	local cbuf = pending.code_buf
	local crow = pending.code_row

	-- 统一调用你的 utils 版本
	require("todo2.link.utils").insert_code_tag_above(cbuf, crow, new_id)

	-- 保持原有同步逻辑
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

	local parent_id = line:match("{#(%w+)}")
	if not parent_id then
		vim.notify("当前行不是任务行", vim.log.levels.WARN)
		return
	end

	-- 高亮父任务
	highlight_parent(tbuf, trow)

	-- 生成子任务 ID
	local new_id = require("todo2.link").generate_id()

	-- 获取父任务缩进（2 空格风格）
	local indent = line:match("^(%s*)") or ""

	-- 插入子任务
	insert_child(tbuf, trow, indent, new_id)

	-- 回填代码 TAG
	update_code_line(new_id)

	vim.notify("子任务已挂载", vim.log.levels.INFO)

	-- 退出选择模式
	selecting_parent = false
	vim.api.nvim_buf_clear_namespace(tbuf, ns, 0, -1)
end

---------------------------------------------------------------------
-- 从代码中启动子任务创建
---------------------------------------------------------------------
function M.create_child_from_code()
	local cbuf = vim.api.nvim_get_current_buf()
	local crow = vim.api.nvim_win_get_cursor(0)[1]

	pending.code_buf = cbuf
	pending.code_row = crow

	-- 选择 TODO 文件（默认第一个）
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local files = file_manager.get_todo_files(project)

	if #files == 0 then
		vim.notify("当前项目没有 TODO 文件", vim.log.levels.WARN)
		return
	end

	local todo_path = files[1]

	-- 打开浮窗
	local tbuf, win = ui.open_todo_file(todo_path, "float", nil, { enter_insert = false })

	selecting_parent = true

	vim.notify("请选择父任务，然后按 <CR> 挂载子任务", vim.log.levels.INFO)

	vim.keymap.set("n", "<CR>", function()
		if selecting_parent then
			-- 处于“选择父任务模式” → 拦截 <CR>
			M.on_cr_in_todo()
		else
			-- 非选择模式 → 恢复原有行为
			vim.cmd("normal! <CR>")
		end
	end, {
		buffer = tbuf,
		noremap = true,
		nowait = true,
		desc = "在子任务创建模式下，用 <CR> 选择父任务",
	})
end

return M
