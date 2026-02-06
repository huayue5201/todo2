--- File: /Users/lijia/todo2/lua/todo2/link/chain.lua ---
-- /Users/lijia/todo2/lua/todo2/chain.lua
-- 链式标记模块 - 最小版本，只自动生成链式标记内容
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
-- 清理状态
---------------------------------------------------------------------
local function cleanup_state()
	selecting_parent = false
	pending.code_buf = nil
	pending.code_row = nil
end

---------------------------------------------------------------------
-- 链式标记工具函数
---------------------------------------------------------------------

--- 判断是否是链式标记
local function is_chain_mark(content)
	return content and content:match("^链%d+:%s*观察点")
end

--- 从链式标记内容中提取序号
local function get_chain_order(content)
	local order = content:match("^链(%d+)")
	return order and tonumber(order) or 0
end

--- 格式化链式标记内容
local function format_chain_content(order)
	return string.format("链%d: 观察点", order)
end

--- 获取已解析的任务（复用现有逻辑）
local function get_parsed_task_at_line(bufnr, row)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return nil
	end

	local parser = module.get("core.parser")
	if not parser then
		return nil
	end

	local tasks, _ = parser.parse_file(path)
	if not tasks then
		return nil
	end

	for _, task in ipairs(tasks) do
		if task.line_num == row then
			return task
		end
	end

	return nil
end

--- 重新排序同一父任务下的链式标记
local function reorder_chain_marks(parent_id)
	local store = module.get("store")
	if not store then
		return
	end

	local parent = store.get_todo_link(parent_id)
	if not parent then
		return
	end

	-- 获取父任务的所有子任务
	local all_tasks = store.find_todo_links_by_file(parent.path)
	local parent_task = nil

	-- 先找到父任务
	for _, task in ipairs(all_tasks) do
		if task.id == parent_id then
			parent_task = task
			break
		end
	end

	if not parent_task or not parent_task.children then
		return
	end

	-- 找出父任务下的所有链式标记子任务
	local chain_marks = {}
	for _, child_id in ipairs(parent_task.children) do
		local child = store.get_todo_link(child_id)
		if child and is_chain_mark(child.content) then
			table.insert(chain_marks, child)
		end
	end

	-- 按当前内容中的顺序排序
	table.sort(chain_marks, function(a, b)
		local order_a = get_chain_order(a.content) or 9999
		local order_b = get_chain_order(b.content) or 9999
		if order_a == order_b then
			return (a.line or 0) < (b.line or 0)
		end
		return order_a < order_b
	end)

	-- 重新编号（1开始连续）
	for i, mark in ipairs(chain_marks) do
		local current_order = get_chain_order(mark.content)
		if current_order ~= i then
			local new_content = format_chain_content(i)

			-- 更新存储
			local updated = store.get_todo_link(mark.id)
			if updated then
				updated.content = new_content
				store.set_key("todo.links.todo." .. mark.id, updated)
			end
		end
	end
end

--- 计算链式标记的插入位置（序号）
local function calculate_chain_order(parent_id)
	local store = module.get("store")
	if not store then
		return 1
	end

	local parent = store.get_todo_link(parent_id)
	if not parent then
		return 1
	end

	local max_order = 0

	-- 检查父任务的所有子任务
	if parent.children then
		for _, child_id in ipairs(parent.children) do
			local child = store.get_todo_link(child_id)
			if child and is_chain_mark(child.content) then
				local order = get_chain_order(child.content) or 0
				if order > max_order then
					max_order = order
				end
			end
		end
	end

	return max_order + 1
end

---------------------------------------------------------------------
-- ⭐ 核心：创建链式标记（修复为真正的子任务）
---------------------------------------------------------------------
function M.create_chain_from_code()
	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]

	-- 检查是否已有标记
	if line and line:match("%u+:ref:%w+") then
		vim.notify("当前行已有标记，请选择其他位置", vim.log.levels.WARN)
		return
	end

	-- 保存代码位置
	pending.code_buf = bufnr
	pending.code_row = row

	-- 获取TODO文件列表
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local file_manager = module.get("ui.file_manager")
	local files = file_manager.get_todo_files(project)

	if #files == 0 then
		vim.notify("当前项目没有TODO文件", vim.log.levels.WARN)
		cleanup_state()
		return
	end

	-- 选择TODO文件
	local choices = {}
	for _, f in ipairs(files) do
		table.insert(choices, {
			project = project,
			path = f,
			display = vim.fn.fnamemodify(f, ":t"),
		})
	end

	vim.ui.select(choices, {
		prompt = "🗂️ 选择 TODO 文件：",
		format_item = function(item)
			return string.format("%-20s • %s", item.project or project, vim.fn.fnamemodify(item.path, ":t"))
		end,
	}, function(choice)
		if not choice then
			cleanup_state()
			return
		end

		local ui = module.get("ui")
		local todo_buf, todo_win = ui.open_todo_file(choice.path, "float", nil, {
			enter_insert = false,
			focus = true,
		})

		if not todo_buf or not todo_win then
			vim.notify("无法打开TODO文件", vim.log.levels.ERROR)
			cleanup_state()
			return
		end

		selecting_parent = true
		vim.notify("请选择父任务，然后按<CR>创建链式标记", vim.log.levels.INFO)

		-- 设置临时键位
		local function clear_temp_maps()
			vim.keymap.del("n", "<CR>", { buffer = todo_buf })
			vim.keymap.del("n", "<ESC>", { buffer = todo_buf })
		end

		vim.keymap.set("n", "<CR>", function()
			if selecting_parent then
				M.on_cr_in_todo()
				clear_temp_maps()
			else
				vim.cmd("normal! <CR>")
			end
		end, { buffer = todo_buf, noremap = true, silent = true, desc = "选择父任务并创建链式标记" })

		vim.keymap.set("n", "<ESC>", function()
			selecting_parent = false
			cleanup_state()
			vim.notify("已取消创建链式标记", vim.log.levels.INFO)
			clear_temp_maps()
		end, { buffer = todo_buf, noremap = true, silent = true, desc = "取消创建链式标记" })
	end)
end

---------------------------------------------------------------------
-- ⭐ 在 TODO 浮窗中按 <CR>（修复为创建真正的子任务）
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
	local parent_task = get_parsed_task_at_line(tbuf, trow)
	if not parent_task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return
	end

	-- 2. 确保父任务有 ID
	local utils = module.get("core.utils")
	if not utils then
		vim.notify("无法获取操作模块", vim.log.levels.ERROR)
		return
	end

	local parent_id = utils.ensure_task_id(tbuf, trow, parent_task)
	if not parent_id then
		vim.notify("无法为父任务生成 ID", vim.log.levels.ERROR)
		return
	end

	-- 3. 生成链式标记 ID
	local link_module = module.get("link")
	local new_id = link_module.generate_id()

	-- 4. 获取存储模块
	local store = module.get("store")
	if not store then
		vim.notify("无法获取存储模块", vim.log.levels.ERROR)
		return
	end

	-- 5. 计算当前父任务下链式标记的序号
	local order = calculate_chain_order(parent_id)
	local content = format_chain_content(order)

	-- 6. ⭐ 关键修复：使用 create_child_task 创建链式标记（作为真正的子任务）
	local link_service = module.get("link.service")
	if not link_service then
		vim.notify("无法获取链接服务模块", vim.log.levels.ERROR)
		return
	end

	-- 使用 create_child_task 创建链式标记，使其成为真正的子任务
	local child_row = link_service.create_child_task(tbuf, parent_task, new_id, content, "TODO")

	if not child_row then
		vim.notify("无法创建链式标记", vim.log.levels.ERROR)
		return
	end

	-- 7. 在代码中插入标记行（使用TODO标签）
	if pending.code_buf and pending.code_row then
		local link_utils = module.get("link.utils")
		if link_utils then
			-- 在代码行上方插入TODO标记
			link_utils.insert_code_tag_above(pending.code_buf, pending.code_row, new_id, "TODO")
		end

		-- 使用统一服务创建代码链接
		local cleaned_content = content
		local tag_manager = module.get("todo2.utils.tag_manager")
		if tag_manager then
			cleaned_content = tag_manager.clean_content(content, "TODO")
		end

		link_service.create_code_link(pending.code_buf, pending.code_row, new_id, cleaned_content, "TODO")
	end

	-- 8. 自动重排链式标记（确保序号连续）
	reorder_chain_marks(parent_id)

	-- 9. 清理状态
	cleanup_state()

	-- 10. 确保回到正确的窗口
	if vim.api.nvim_win_is_valid(float_win) then
		vim.api.nvim_set_current_win(float_win)

		if vim.api.nvim_win_get_buf(float_win) ~= tbuf then
			vim.api.nvim_win_set_buf(float_win, tbuf)
		end

		-- 定位光标到新行行尾并进入插入模式
		local col = vim.fn.col("$") - 1
		vim.api.nvim_win_set_cursor(float_win, { child_row, col })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	vim.notify(string.format("链式标记 %s 创建成功", content), vim.log.levels.INFO)
end

return M
