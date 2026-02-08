-- /Users/lijia/todo2/lua/todo2/link/chain.lua
-- 链式标记模块 - 修复CR映射失效完整版
local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 状态管理（新增全局可查的状态，方便调试）
---------------------------------------------------------------------
M.state = {
	selecting_parent = false,
	pending = {
		code_buf = nil,
		code_row = nil,
		todo_buf = nil, -- 新增：记录当前绑定的todo缓冲区
		todo_win = nil, -- 新增：记录当前浮窗ID
	},
}

---------------------------------------------------------------------
-- 清理状态（重构：使用模块级状态）
---------------------------------------------------------------------
local function cleanup_state()
	M.state.selecting_parent = false
	M.state.pending.code_buf = nil
	M.state.pending.code_row = nil
	M.state.pending.todo_buf = nil
	M.state.pending.todo_win = nil
end

---------------------------------------------------------------------
-- ⭐ 核心修复：强制清理所有临时映射（不管缓冲区是否有效）
---------------------------------------------------------------------
function M.clear_temp_maps()
	-- 1. 清理当前记录的todo缓冲区映射
	local todo_buf = M.state.pending.todo_buf
	if todo_buf and vim.api.nvim_buf_is_valid(todo_buf) then
		-- 强制删除，忽略错误
		pcall(vim.keymap.del, "n", "<CR>", { buffer = todo_buf })
		pcall(vim.keymap.del, "n", "<ESC>", { buffer = todo_buf })
	end

	-- 2. 兜底：遍历所有缓冲区，清理残留的CR/ESC映射（防止漏网）
	local all_bufs = vim.api.nvim_list_bufs()
	for _, buf in ipairs(all_bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.keymap.del, "n", "<CR>", { buffer = buf, desc = "选择父任务并创建链式标记" })
			pcall(vim.keymap.del, "n", "<ESC>", { buffer = buf, desc = "取消创建链式标记" })
		end
	end
end

---------------------------------------------------------------------
-- 链式标记工具函数（保持不变）
---------------------------------------------------------------------
local function is_chain_mark(content)
	return content and content:match("^链%d+:%s*观察点")
end

local function get_chain_order(content)
	local order = content:match("^链(%d+)")
	return order and tonumber(order) or 0
end

local function format_chain_content(order)
	return string.format("链%d: 观察点", order)
end

local function get_parsed_task_at_line(bufnr, row)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		vim.notify("[调试] 不是todo.md文件：" .. path, vim.log.levels.DEBUG)
		return nil
	end

	local parser = module.get("core.parser")
	if not parser then
		vim.notify("[调试] 无法获取core.parser模块", vim.log.levels.DEBUG)
		return nil
	end

	local tasks, _ = parser.parse_file(path)
	if not tasks then
		vim.notify("[调试] 解析todo文件失败：" .. path, vim.log.levels.DEBUG)
		return nil
	end

	for _, task in ipairs(tasks) do
		if task.line_num == row then
			vim.notify("[调试] 找到父任务：" .. vim.inspect(task.id), vim.log.levels.DEBUG)
			return task
		end
	end

	vim.notify("[调试] 第" .. row .. "行不是有效任务行", vim.log.levels.DEBUG)
	return nil
end

local function reorder_chain_marks(parent_id)
	local store = module.get("store")
	if not store then
		return
	end

	local parent = store.get_todo_link(parent_id)
	if not parent then
		return
	end

	local all_tasks = store.find_todo_links_by_file(parent.path)
	local parent_task = nil
	for _, task in ipairs(all_tasks) do
		if task.id == parent_id then
			parent_task = task
			break
		end
	end

	if not parent_task or not parent_task.children then
		return
	end

	local chain_marks = {}
	for _, child_id in ipairs(parent_task.children) do
		local child = store.get_todo_link(child_id)
		if child and is_chain_mark(child.content) then
			table.insert(chain_marks, child)
		end
	end

	table.sort(chain_marks, function(a, b)
		local order_a = get_chain_order(a.content) or 9999
		local order_b = get_chain_order(b.content) or 9999
		if order_a == order_b then
			return (a.line or 0) < (b.line or 0)
		end
		return order_a < order_b
	end)

	for i, mark in ipairs(chain_marks) do
		local current_order = get_chain_order(mark.content)
		if current_order ~= i then
			local new_content = format_chain_content(i)
			local updated = store.get_todo_link(mark.id)
			if updated then
				updated.content = new_content
				store.set_key("todo.links.todo." .. mark.id, updated)
			end
		end
	end
end

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
-- ⭐ 核心：创建链式标记（终极修复版）
---------------------------------------------------------------------
function M.create_chain_from_code()
	-- 第一步：强制清理之前的残留映射（关键！）
	M.clear_temp_maps()

	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]

	-- 检查已有标记
	if line and line:match("%u+:ref:%w+") then
		vim.notify("当前行已有标记，请选择其他位置", vim.log.levels.WARN)
		return
	end

	-- 保存代码位置
	M.state.pending.code_buf = bufnr
	M.state.pending.code_row = row

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

		-- 记录当前todo缓冲区和窗口（关键）
		M.state.pending.todo_buf = todo_buf
		M.state.pending.todo_win = todo_win

		-- 强制设置状态（优先级最高）
		M.state.selecting_parent = true
		vim.notify("请选择父任务，然后按<CR>创建链式标记（调试模式）", vim.log.levels.INFO)

		-- ⭐ 核心修复：强制绑定CR键（不依赖silent，显示错误）
		-- 删除原有映射（如果有）
		pcall(vim.keymap.del, "n", "<CR>", { buffer = todo_buf })
		-- 重新绑定（关闭silent，方便看错误）
		vim.keymap.set("n", "<CR>", function()
			vim.notify(
				"[调试] CR键触发，selecting_parent: " .. tostring(M.state.selecting_parent),
				vim.log.levels.DEBUG
			)
			if M.state.selecting_parent then
				-- 强制执行CR逻辑，忽略状态临时异常
				local success, err = pcall(M.on_cr_in_todo)
				if not success then
					vim.notify("[错误] CR逻辑执行失败：" .. err, vim.log.levels.ERROR)
				end
				M.clear_temp_maps()
			else
				vim.cmd("normal! <CR>")
			end
		end, {
			buffer = todo_buf,
			noremap = true,
			desc = "选择父任务并创建链式标记",
			unique = true,
			silent = false, -- 关闭静默，显示键位绑定错误
		})

		-- 绑定ESC键
		pcall(vim.keymap.del, "n", "<ESC>", { buffer = todo_buf })
		vim.keymap.set("n", "<ESC>", function()
			vim.notify("[调试] ESC键触发，清理状态", vim.log.levels.DEBUG)
			M.state.selecting_parent = false
			cleanup_state()
			M.clear_temp_maps()
			vim.notify("已取消创建链式标记", vim.log.levels.INFO)
		end, {
			buffer = todo_buf,
			noremap = true,
			desc = "取消创建链式标记",
			unique = true,
			silent = false,
		})

		-- 双重保障：窗口关闭自动清理
		vim.api.nvim_create_autocmd({ "BufDelete", "WinClosed" }, {
			buffer = todo_buf,
			window = todo_win,
			once = true,
			callback = function()
				vim.notify("[调试] 浮窗/缓冲区关闭，自动清理映射", vim.log.levels.DEBUG)
				M.clear_temp_maps()
				cleanup_state()
			end,
		})
	end)
end

---------------------------------------------------------------------
-- ⭐ CR键核心逻辑（终极修复版）
---------------------------------------------------------------------
function M.on_cr_in_todo()
	-- 强制校验：不管状态，先执行核心逻辑
	local float_win = vim.api.nvim_get_current_win()
	local tbuf = vim.api.nvim_get_current_buf()
	local trow = vim.api.nvim_win_get_cursor(0)[1]

	vim.notify("[调试] 执行CR核心逻辑，行号：" .. trow, vim.log.levels.DEBUG)

	-- 1. 获取父任务（带调试日志）
	local parent_task = get_parsed_task_at_line(tbuf, trow)
	if not parent_task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return
	end

	-- 2. 确保父任务有ID
	local utils = module.get("core.utils")
	if not utils then
		vim.notify("无法获取core.utils模块", vim.log.levels.ERROR)
		return
	end

	local parent_id = utils.ensure_task_id(tbuf, trow, parent_task)
	if not parent_id then
		vim.notify("无法为父任务生成 ID", vim.log.levels.ERROR)
		return
	end

	-- 3. 生成ID
	local link_module = module.get("link")
	local new_id = link_module and link_module.generate_id() or nil
	if not new_id then
		vim.notify("无法生成链式标记ID", vim.log.levels.ERROR)
		return
	end

	-- 4. 计算序号
	local order = calculate_chain_order(parent_id)
	local content = format_chain_content(order)

	-- 5. 创建子任务
	local link_service = module.get("link.service")
	if not link_service then
		vim.notify("无法获取link.service模块", vim.log.levels.ERROR)
		return
	end

	local child_row = link_service.create_child_task(tbuf, parent_task, new_id, content, "TODO")
	if not child_row then
		vim.notify("无法创建链式标记子任务", vim.log.levels.ERROR)
		return
	end

	-- 6. 插入代码标记
	if M.state.pending.code_buf and M.state.pending.code_row then
		local link_utils = module.get("link.utils")
		if link_utils then
			link_utils.insert_code_tag_above(M.state.pending.code_buf, M.state.pending.code_row, new_id, "TODO")
		end

		-- 创建代码链接
		local cleaned_content = content
		local tag_manager = module.get("todo2.utils.tag_manager")
		if tag_manager then
			cleaned_content = tag_manager.clean_content(content, "TODO")
		end

		if link_service.create_code_link then
			link_service.create_code_link(
				M.state.pending.code_buf,
				M.state.pending.code_row,
				new_id,
				cleaned_content,
				"TODO"
			)
		end
	end

	-- 7. 重排链式标记
	reorder_chain_marks(parent_id)

	-- 8. 清理状态
	cleanup_state()

	-- 9. 定位光标
	if vim.api.nvim_win_is_valid(float_win) then
		vim.api.nvim_set_current_win(float_win)
		if vim.api.nvim_win_get_buf(float_win) ~= tbuf then
			vim.api.nvim_win_set_buf(float_win, tbuf)
		end
		local col = vim.fn.col("$") - 1
		vim.api.nvim_win_set_cursor(float_win, { child_row, col })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	vim.notify(string.format("链式标记 %s 创建成功（调试模式）", content), vim.log.levels.INFO)
end

-- 暴露调试接口（可选）
function M.debug_state()
	vim.notify("[调试] 当前状态：" .. vim.inspect(M.state), vim.log.levels.INFO)
end

return M
