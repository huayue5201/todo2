-- lua/todo2/child.lua
--- @module todo2.child

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 状态管理
---------------------------------------------------------------------
local selecting_parent = false
local pending = {
	code_buf = nil,
	code_row = nil,
}

---------------------------------------------------------------------
-- ⭐ 使用 core.parser 准确判断任务行
---------------------------------------------------------------------
local function get_task_at_line(bufnr, row)
	-- 获取文件路径
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return nil
	end

	-- 获取 parser 模块
	local parser = module.get("core.parser")
	if not parser then
		return nil
	end

	-- 解析文件获取任务树（使用缓存）
	local tasks, _ = parser.parse_file(path)
	if not tasks then
		return nil
	end

	-- 查找当前行的任务
	for _, task in ipairs(tasks) do
		if task.line_num == row then
			return task
		end
	end

	return nil
end

---------------------------------------------------------------------
-- ⭐ 自动为任务添加 ID（如果还没有）
---------------------------------------------------------------------
local function ensure_task_has_id(bufnr, row, task)
	-- 如果任务已有 ID，直接返回
	if task.id then
		return task.id
	end

	-- 生成新 ID
	local link_module = module.get("link")
	local new_id = link_module.generate_id()

	-- 读取当前行
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
	if not line then
		return nil
	end

	-- 在行尾添加 {#id}
	local trimmed_line = line:gsub("%s*$", "")
	local new_line = trimmed_line .. " {#" .. new_id .. "}"

	-- 更新行
	vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { new_line })

	-- 更新任务对象的 id
	task.id = new_id

	-- 保存到 store
	local store = module.get("store")
	local path = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 构建上下文
	local prev = row > 1 and lines[row - 1] or ""
	local next = row < #lines and lines[row + 1] or ""

	store.add_todo_link(new_id, {
		path = path,
		line = row,
		content = task.content,
		created_at = os.time(),
		context = { prev = prev, curr = new_line, next = next },
	})

	-- 触发事件
	local events = module.get("core.events")
	events.on_state_changed({
		source = "child_add_id",
		file = path,
		bufnr = bufnr,
		ids = { new_id },
	})

	-- 自动保存
	local autosave = module.get("core.autosave")
	autosave.request_save(bufnr)

	return new_id
end

---------------------------------------------------------------------
-- ⭐ 插入子任务
---------------------------------------------------------------------
local function insert_child(todo_bufnr, parent_task, new_id)
	local parent_row = parent_task.line_num
	local parent_indent = string.rep("  ", parent_task.level) -- 根据 level 计算缩进
	local child_indent = parent_indent .. "  "

	local new_line = string.format("%s- [ ] {#%s} 新任务", child_indent, new_id)

	-- 计算新行的实际位置（在父任务之后）
	local new_line_num = parent_row + 1

	-- 插入行
	vim.api.nvim_buf_set_lines(todo_bufnr, parent_row, parent_row, false, { new_line })

	-- 保存到 store
	local store = module.get("store")
	local todo_path = vim.api.nvim_buf_get_name(todo_bufnr)
	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)

	local prev = new_line_num > 1 and lines[new_line_num - 1] or ""
	local next = new_line_num < #lines and lines[new_line_num + 1] or ""

	store.add_todo_link(new_id, {
		path = todo_path,
		line = new_line_num,
		content = "新任务",
		created_at = os.time(),
		context = { prev = prev, curr = new_line, next = next },
	})

	-- 触发事件
	local events = module.get("core.events")
	events.on_state_changed({
		source = "create_child",
		file = todo_path,
		bufnr = todo_bufnr,
		ids = { new_id },
	})

	-- 自动保存
	local autosave = module.get("core.autosave")
	autosave.request_save(todo_bufnr)

	return new_line_num
end

---------------------------------------------------------------------
-- ⭐ 回填代码 TAG
---------------------------------------------------------------------
local function update_code_line(new_id)
	local cbuf = pending.code_buf
	local crow = pending.code_row
	if not cbuf or not crow then
		vim.notify("无法回填代码 TAG：pending 状态丢失", vim.log.levels.ERROR)
		return
	end

	-- 使用 link.utils 插入代码 TAG
	local link_utils = module.get("link.utils")
	link_utils.insert_code_tag_above(cbuf, crow, new_id)

	-- 保存到 store
	local store = module.get("store")
	local code_path = vim.api.nvim_buf_get_name(cbuf)
	local lines = vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)

	-- 注意：插入在 crow-1 行，所以实际 TAG 在 crow-1 行
	local tag_line_num = crow - 1
	local prev = tag_line_num > 0 and lines[tag_line_num] or ""
	local next = tag_line_num + 1 <= #lines and lines[tag_line_num + 1] or ""
	local tag_line_content = lines[tag_line_num + 1] or ""

	store.add_code_link(new_id, {
		path = code_path,
		line = tag_line_num,
		content = "",
		created_at = os.time(),
		context = { prev = prev, curr = tag_line_content, next = next },
	})

	-- 触发事件
	local events = module.get("core.events")
	events.on_state_changed({
		source = "update_code_child",
		file = code_path,
		bufnr = cbuf,
		ids = { new_id },
	})

	-- 自动保存
	local autosave = module.get("core.autosave")
	autosave.request_save(cbuf)

	-- 清空 pending 状态
	pending.code_buf = nil
	pending.code_row = nil

	vim.notify(string.format("已创建子任务 %s", new_id), vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- ⭐ 改进：在 TODO 浮窗中按 <CR>（使用 parser 判断）
---------------------------------------------------------------------
function M.on_cr_in_todo()
	if not selecting_parent then
		return
	end

	local tbuf = vim.api.nvim_get_current_buf()
	local trow = vim.api.nvim_win_get_cursor(0)[1]

	-- 1. 使用 parser 准确判断当前行是否是任务行
	local parent_task = get_task_at_line(tbuf, trow)
	if not parent_task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return
	end

	-- 2. 确保父任务有 ID（如果没有则自动生成）
	local parent_id = ensure_task_has_id(tbuf, trow, parent_task)
	if not parent_id then
		vim.notify("无法为父任务生成 ID", vim.log.levels.ERROR)
		return
	end

	-- 3. 生成子任务 ID
	local link_module = module.get("link")
	local new_id = link_module.generate_id()

	-- 4. 插入子任务
	local child_row = insert_child(tbuf, parent_task, new_id)

	-- 5. 回填代码 TAG
	update_code_line(new_id)

	selecting_parent = false

	-- 6. 跳到新行行尾并进入插入模式
	vim.api.nvim_win_set_cursor(0, { child_row, 0 })
	vim.cmd("normal! $")
	vim.cmd("startinsert")

	vim.notify(string.format("子任务 %s 创建成功", new_id), vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- ⭐ 创建子任务的入口函数（保持不变）
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

	-- 保存代码位置
	pending.code_buf = cbuf
	pending.code_row = crow

	-- 获取 TODO 文件列表
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local file_manager_module = module.get("ui.file_manager")
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

	-- 选择 TODO 文件
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
		local ui_module = module.get("ui")

		-- 打开 TODO 文件浮窗
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

---------------------------------------------------------------------
-- ⭐ 工具函数：为当前任务添加 ID（可选命令）
---------------------------------------------------------------------
function M.add_id_to_current_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]

	local task = get_task_at_line(bufnr, row)
	if not task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return
	end

	if task.id then
		vim.notify(string.format("任务已有 ID: %s", task.id), vim.log.levels.INFO)
		return
	end

	local new_id = ensure_task_has_id(bufnr, row, task)
	if new_id then
		vim.notify(string.format("已为任务添加 ID: %s", new_id), vim.log.levels.INFO)
	end
end

---------------------------------------------------------------------
-- 注册命令
---------------------------------------------------------------------
if vim.g.todo2_debug then
	vim.api.nvim_create_user_command("Todo2ChildAddId", function()
		M.add_id_to_current_task()
	end, { desc = "为当前任务添加 ID" })
end

return M
