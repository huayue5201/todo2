-- lua/todo2/link/child.lua
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
-- 获取操作模块
---------------------------------------------------------------------
local function get_operations()
	return module.get("ui.operations")
end

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

	-- ⭐ 使用新的接口获取任务树
	local tasks, _, _ = parser.parse_file(path)
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
-- ⭐ 回填代码 TAG
---------------------------------------------------------------------
local function update_code_line(new_id)
	local cbuf = pending.code_buf
	local crow = pending.code_row
	if not cbuf or not crow then
		vim.notify("无法回填代码 TAG：pending 状态丢失", vim.log.levels.ERROR)
		return
	end

	-- 保存当前窗口
	local original_win = vim.api.nvim_get_current_win()

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

	-- 恢复窗口（解决光标定位问题）
	if vim.api.nvim_win_is_valid(original_win) then
		vim.api.nvim_set_current_win(original_win)
	end

	vim.notify(string.format("已创建子任务 %s", new_id), vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- ⭐ 改进：在 TODO 浮窗中按 <CR>（使用 parser 判断）
---------------------------------------------------------------------
function M.on_cr_in_todo()
	if not selecting_parent then
		return
	end

	-- 保存当前浮窗信息
	local float_win = vim.api.nvim_get_current_win()
	local tbuf = vim.api.nvim_get_current_buf()
	local trow = vim.api.nvim_win_get_cursor(0)[1]

	-- 1. 使用 parser 准确判断当前行是否是任务行
	local parent_task = get_task_at_line(tbuf, trow)
	if not parent_task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return
	end

	-- 2. 确保父任务有 ID（如果没有则自动生成）
	local operations = get_operations()
	if not operations then
		vim.notify("无法获取操作模块", vim.log.levels.ERROR)
		return
	end

	local parent_id = operations.ensure_task_id(tbuf, trow, parent_task)
	if not parent_id then
		vim.notify("无法为父任务生成 ID", vim.log.levels.ERROR)
		return
	end

	-- 3. 生成子任务 ID
	local link_module = module.get("link")
	local new_id = link_module.generate_id()

	-- 4. 插入子任务（使用操作模块的公共方法）
	local child_row = operations.create_child_task(tbuf, parent_task, new_id)

	-- 5. 回填代码 TAG
	update_code_line(new_id)

	selecting_parent = false

	-- 6. 确保回到正确的窗口和缓冲区
	if vim.api.nvim_win_is_valid(float_win) then
		vim.api.nvim_set_current_win(float_win)

		-- 如果浮窗的缓冲区不是 tbuf（可能被切换了），切换回来
		if vim.api.nvim_win_get_buf(float_win) ~= tbuf then
			vim.api.nvim_win_set_buf(float_win, tbuf)
		end

		-- 定位光标到新行行尾
		operations.place_cursor_at_line_end(float_win, child_row)

		-- 进入插入模式
		operations.start_insert_at_line_end()
	end

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

	local operations = get_operations()
	if not operations then
		vim.notify("无法获取操作模块", vim.log.levels.ERROR)
		return
	end

	local new_id = operations.ensure_task_id(bufnr, row)
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
