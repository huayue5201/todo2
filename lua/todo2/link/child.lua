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
-- ⭐ 修复：插入子任务并立即存储到store（与普通双链任务一致）
---------------------------------------------------------------------
local function insert_child(todo_bufnr, parent_line, parent_indent, new_id)
	local indent = parent_indent or ""
	local child_indent = indent .. "  "

	local new_line = string.format("%s- [ ] {#%s} 新任务", child_indent, new_id)

	-- 计算新行的实际位置
	local new_line_num = parent_line + 1

	-- 插入行
	vim.api.nvim_buf_set_lines(todo_bufnr, parent_line, parent_line, false, { new_line })

	-----------------------------------------------------------------
	-- ⭐ 关键修复：立即存储到store（与普通双链任务一致）
	-----------------------------------------------------------------
	local store = module.get("store")
	local todo_path = vim.api.nvim_buf_get_name(todo_bufnr)

	-- 构建上下文（与普通双链任务类似）
	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)
	local prev = new_line_num > 1 and lines[new_line_num - 1] or ""
	local next = new_line_num < #lines and lines[new_line_num + 1] or ""

	-- ⭐ 立即存储 TODO link（与普通双链任务中的 add_task_to_todo_file 一致）
	store.add_todo_link(new_id, {
		path = todo_path,
		line = new_line_num,
		content = "新任务",
		created_at = os.time(),
		context = { prev = prev, curr = new_line, next = next },
	})

	-----------------------------------------------------------------
	-- ⭐ 触发事件，立即刷新
	-----------------------------------------------------------------
	local events = module.get("core.events")
	events.on_state_changed({
		source = "create_child",
		file = todo_path,
		bufnr = todo_bufnr,
		ids = { new_id },
	})

	-----------------------------------------------------------------
	-- autosave（与普通双链任务一致）
	-----------------------------------------------------------------
	local autosave = module.get("core.autosave")
	autosave.request_save(todo_bufnr)

	return new_line_num
end

---------------------------------------------------------------------
-- ⭐ 修复：回填代码 TAG 并立即存储到store（与普通双链任务一致）
---------------------------------------------------------------------
local function update_code_line(new_id)
	local cbuf = pending.code_buf
	local crow = pending.code_row
	if not cbuf or not crow then
		vim.notify("无法回填代码 TAG：pending 状态丢失", vim.log.levels.ERROR)
		return
	end

	-- 使用模块管理器获取 link.utils（与普通双链任务一致）
	local link_utils = module.get("link.utils")
	link_utils.insert_code_tag_above(cbuf, crow, new_id)

	-----------------------------------------------------------------
	-- ⭐ 关键修复：立即存储code_link到store（与普通双链任务一致）
	-----------------------------------------------------------------
	local store = module.get("store")
	local code_path = vim.api.nvim_buf_get_name(cbuf)

	-- 构建上下文（与普通双链任务中的 add_code_link 一致）
	local lines = vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)

	-- 注意：插入在 crow-1 行，所以实际 TAG 在 crow-1 行，但 store 需要存储真实位置
	local tag_line_num = crow - 1 -- insert_code_tag_above 插入在 crow-1 行
	local prev = tag_line_num > 0 and lines[tag_line_num] or "" -- 插入前的那一行
	local next = tag_line_num + 1 <= #lines and lines[tag_line_num + 1] or "" -- 插入后的下一行

	local tag_line_content = lines[tag_line_num + 1] or "" -- 新插入的 TAG 行

	-- ⭐ 立即存储 CODE link（与普通双链任务中的 add_code_link 完全一致）
	store.add_code_link(new_id, {
		path = code_path,
		line = tag_line_num, -- 实际行号（0-based 转为 1-based 的 line 字段）
		content = "",
		created_at = os.time(),
		context = { prev = prev, curr = tag_line_content, next = next },
	})

	-----------------------------------------------------------------
	-- ⭐ 触发事件，立即刷新（与普通双链任务一致）
	-----------------------------------------------------------------
	local events = module.get("core.events")
	events.on_state_changed({
		source = "update_code_child",
		file = code_path,
		bufnr = cbuf,
		ids = { new_id },
	})

	-- autosave（与普通双链任务一致）
	local autosave = module.get("core.autosave")
	autosave.request_save(cbuf)

	-- 清空 pending 状态
	pending.code_buf = nil
	pending.code_row = nil

	vim.notify(string.format("已创建子任务 %s", new_id), vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- ⭐ 修复：在 TODO 浮窗中按 <CR>（完整流程）
---------------------------------------------------------------------
function M.on_cr_in_todo()
	if not selecting_parent then
		return
	end

	local tbuf = vim.api.nvim_get_current_buf()
	local trow = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(tbuf, trow - 1, trow, false)[1]
	if not line then
		vim.notify("无法读取当前行", vim.log.levels.ERROR)
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

	-- 1. 插入子任务并存储
	local child_row = insert_child(tbuf, trow, indent, new_id)

	-- 2. 回填代码 TAG 并存储
	update_code_line(new_id)

	selecting_parent = false

	-- 跳到新行行尾并进入插入模式
	vim.api.nvim_win_set_cursor(0, { child_row, 0 })
	vim.cmd("normal! $")
	vim.cmd("startinsert")

	vim.notify(string.format("子任务 %s 创建成功", new_id), vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- ⭐ 修复：创建子任务的入口函数（简化流程）
---------------------------------------------------------------------
function M.create_child_from_code()
	local cbuf = vim.api.nvim_get_current_buf()
	local crow = vim.api.nvim_win_get_cursor(0)[1]

	-- 检查当前行是否已有 TAG
	local line = vim.api.nvim_buf_get_lines(cbuf, crow - 1, crow, false)[1]
	if line and line:match("%u+:ref:%w+") then
		vim.notify("当前行已有 TAG 标记，请选择其他位置", vim.log.levels.WARN)
		return
	end

	-- 保存代码位置（与普通双链任务类似）
	pending.code_buf = cbuf
	pending.code_row = crow

	-- 获取 TODO 文件列表（与普通双链任务一致）
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local file_manager_module = get_file_manager()
	local files = file_manager_module.get_todo_files(project)

	if #files == 0 then
		vim.notify("当前项目没有 TODO 文件", vim.log.levels.WARN)
		pending.code_buf = nil
		pending.code_row = nil
		return
	end

	local choices = {}
	for _, f in ipairs(files) do
		table.insert(choices, {
			path = f,
			display = vim.fn.fnamemodify(f, ":t"),
		})
	end

	-- 选择 TODO 文件（与普通双链任务一致）
	vim.ui.select(choices, {
		prompt = "选择 TODO 文件",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		if not choice then
			pending.code_buf = nil
			pending.code_row = nil
			return
		end

		local todo_path = choice.path
		local ui_module = get_ui()

		-- 打开 TODO 文件浮窗（与普通双链任务中的预览一致）
		local tbuf, win = ui_module.open_todo_file(todo_path, "float", nil, {
			enter_insert = false,
			focus = true,
		})

		if not tbuf or not win then
			vim.notify("无法打开 TODO 文件", vim.log.levels.ERROR)
			pending.code_buf = nil
			pending.code_row = nil
			return
		end

		selecting_parent = true
		vim.notify("请选择父任务，然后按 <CR> 创建子任务", vim.log.levels.INFO)

		-- 临时覆盖浮窗内的 <CR> 键
		local map_opts = {
			buffer = tbuf,
			noremap = true,
			silent = true,
			desc = "选择父任务并创建子任务",
		}

		vim.keymap.set("n", "<CR>", function()
			if selecting_parent then
				M.on_cr_in_todo()
				-- 清理临时映射
				vim.keymap.del("n", "<CR>", { buffer = tbuf })
				vim.keymap.del("n", "<ESC>", { buffer = tbuf })
			else
				vim.cmd("normal! <CR>")
			end
		end, map_opts)

		-- 添加取消操作的 ESC 键
		vim.keymap.set("n", "<ESC>", function()
			selecting_parent = false
			pending.code_buf = nil
			pending.code_row = nil
			vim.notify("已取消创建子任务", vim.log.levels.INFO)
			vim.keymap.del("n", "<CR>", { buffer = tbuf })
			vim.keymap.del("n", "<ESC>", { buffer = tbuf })
		end, {
			buffer = tbuf,
			noremap = true,
			silent = true,
			desc = "取消创建子任务",
		})
	end)
end

return M
