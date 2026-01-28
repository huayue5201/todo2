-- lua/todo2/link/viewer.lua
--- @module todo2.link.viewer
--- @brief 展示 TAG:ref:id（QF / LocList）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
-- 树形缩进符号配置
local INDENT = {
	top = "│ ",
	middle = "├╴",
	last = "└╴",
	fold_open = " ",
	fold_closed = " ",
	ws = "  ",
	-- 可选的连接线样式
	connector = {
		vertical = "│ ",
		horizontal = "─",
		corner = "└─",
		tee = "├─",
		end_branch = "╰─",
		mid_branch = "├─",
		empty = "  ",
	},
}

-- 任务状态图标
local TASK_ICONS = {
	TODO = "◻", -- 空心方框
	DOING = "󰝦", -- 进行中
	DONE = "✓", -- 完成
	WAIT = "⏳", -- 等待
	FIXME = "", -- 修复
	NOTE = "", -- 笔记
	IDEA = "💡", -- 想法
	WARN = "⚠", -- 警告
	BUG = "", -- Bug
	-- 默认图标
	DEFAULT = "",
}

-- 折叠状态（可扩展为支持折叠功能）
local folded = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 从TODO内容提取标签
local function extract_tag_from_content(content)
	local tag = content:match("^%[([A-Z]+)%]") or content:match("^([A-Z]+):") or content:match("^([A-Z]+)%s")
	return tag or "TODO"
end

--- 获取任务图标
local function get_task_icon(tag)
	return TASK_ICONS[tag] or TASK_ICONS.DEFAULT
end

--- 构建缩进前缀
local function build_indent_prefix(depth, is_last_stack, has_children, is_folded)
	local prefix = ""

	-- 处理每一层的缩进
	for i = 1, depth do
		if i == depth then
			-- 当前层：根据是否是最后一个子节点选择连接线
			if is_last_stack[i] then
				prefix = prefix .. INDENT.last
			else
				prefix = prefix .. INDENT.middle
			end
		else
			-- 上层：根据该层是否是最后一个子节点选择垂直线或空白
			if is_last_stack[i] then
				prefix = prefix .. INDENT.ws
			else
				prefix = prefix .. INDENT.top
			end
		end
	end

	-- 添加折叠图标（如果有子任务）
	if has_children then
		if is_folded then
			prefix = prefix .. INDENT.fold_closed
		else
			prefix = prefix .. INDENT.fold_open
		end
	else
		-- 没有子任务的情况，添加适当的间距
		prefix = prefix .. "  "
	end

	return prefix
end

--- 构建连接线缩进（更精细的样式）
local function build_connector_indent(depth, is_last_stack, has_children, is_folded)
	local lines = {}

	-- 构建完整的树形连接线
	for i = 1, depth do
		local line_parts = {}

		-- 上层的连接线
		for j = 1, i - 1 do
			if is_last_stack[j] then
				table.insert(line_parts, INDENT.ws)
			else
				table.insert(line_parts, INDENT.connector.vertical)
			end
		end

		-- 当前层的连接线
		if i == depth then
			-- 当前节点层
			if is_last_stack[i] then
				if has_children then
					table.insert(line_parts, INDENT.connector.corner)
				else
					table.insert(line_parts, INDENT.connector.end_branch)
				end
			else
				if has_children then
					table.insert(line_parts, INDENT.connector.tee)
				else
					table.insert(line_parts, INDENT.connector.mid_branch)
				end
			end
		else
			-- 中间层
			if is_last_stack[i] then
				table.insert(line_parts, INDENT.ws)
			else
				table.insert(line_parts, INDENT.connector.vertical)
			end
		end

		lines[i] = table.concat(line_parts)
	end

	-- 添加折叠图标
	local prefix = ""
	if depth > 0 then
		prefix = lines[depth] .. " "
	end

	if has_children then
		if is_folded then
			prefix = prefix .. INDENT.fold_closed
		else
			prefix = prefix .. INDENT.fold_open
		end
	end

	return prefix
end

---------------------------------------------------------------------
-- LocList：简单显示当前buffer的任务（使用精简缩进）
---------------------------------------------------------------------
function M.show_buffer_links_loclist()
	local store_mod = module.get("store")
	local fm = module.get("ui.file_manager")
	local parser_mod = module.get("core.parser")

	-- 获取当前buffer路径
	local current_buf = vim.api.nvim_get_current_buf()
	local current_path = vim.api.nvim_buf_get_name(current_buf)
	if current_path == "" then
		vim.notify("当前buffer未保存", vim.log.levels.WARN)
		return
	end

	-- 获取项目中的TODO文件
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local loc_items = {}

	-- 遍历所有TODO文件
	for _, todo_path in ipairs(todo_files) do
		local tasks = parser_mod.parse_file(todo_path)

		for _, task in ipairs(tasks) do
			if task.id then
				local code_link = store_mod.get_code_link(task.id)
				if code_link and code_link.path == current_path then
					local tag = extract_tag_from_content(task.content)
					local icon = get_task_icon(tag)
					local text = string.format("%s [%s] %s", icon, task.id, task.content)

					table.insert(loc_items, {
						filename = current_path,
						lnum = code_link.line,
						text = text,
					})
				end
			end
		end
	end

	if #loc_items == 0 then
		vim.notify("当前 buffer 没有有效的 TAG 标记", vim.log.levels.INFO)
		return
	end

	-- 按行号排序
	table.sort(loc_items, function(a, b)
		return a.lnum < b.lnum
	end)

	vim.fn.setloclist(0, loc_items, "r")
	vim.cmd("lopen")
end

---------------------------------------------------------------------
-- QF：展示整个项目的任务树（使用精细缩进）
---------------------------------------------------------------------
function M.show_project_links_qf()
	local store_mod = module.get("store")
	local fm = module.get("ui.file_manager")
	local parser_mod = module.get("core.parser")

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local qf_items = {}
	local file_counts = {}

	-- 自定义排序：优先按order，再按id
	local function sort_tasks(a, b)
		local order_a = a.order or 0
		local order_b = b.order or 0
		if order_a ~= order_b then
			return order_a < order_b
		end
		return (a.id or "") < (b.id or "")
	end

	-- 按文件处理
	for _, todo_path in ipairs(todo_files) do
		local tasks, roots = parser_mod.parse_file(todo_path)
		local file_tasks = {}
		local count = 0

		-- 递归构建任务树（使用精细缩进）
		local function process_task(task, depth, is_last_stack, is_last)
			if not task.id then
				return
			end

			local code_link = store_mod.get_code_link(task.id)
			if not code_link then
				return
			end

			local tag = extract_tag_from_content(task.content)
			local icon = get_task_icon(tag)
			local has_children = task.children and #task.children > 0
			local task_id = task.id or "no-id"

			-- 构建当前节点的状态栈
			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			-- 构建缩进前缀（两种风格可选）
			local indent_prefix = build_indent_prefix(depth, current_is_last_stack, has_children, false)
			-- 或者使用连接线风格的缩进：
			-- local indent_prefix = build_connector_indent(depth, current_is_last_stack, has_children, false)

			-- 计算子任务数量
			local child_count = 0
			if task.children then
				child_count = #task.children
			end

			-- 构建显示文本
			local child_info = ""
			if child_count > 0 then
				child_info = string.format(" (%d)", child_count)
			end

			local text = string.format("%s%s [%s%s] %s", indent_prefix, icon, tag, child_info, task.content)

			-- 添加到当前文件任务列表
			table.insert(file_tasks, {
				node = task,
				depth = depth,
				indent = indent_prefix,
				tag = tag,
				icon = icon,
				code_link = code_link,
				content = task.content,
				child_count = child_count,
				has_children = has_children,
				display_text = text,
			})
			count = count + 1

			-- 递归处理子任务（如果没有折叠）
			if task.children and not folded[task.id] then
				-- 排序子任务
				table.sort(task.children, sort_tasks)

				for i, child in ipairs(task.children) do
					local child_is_last = i == #task.children
					process_task(child, depth + 1, current_is_last_stack, child_is_last)
				end
			end
		end

		-- 排序根任务
		table.sort(roots, sort_tasks)

		-- 处理当前文件的所有根任务
		for i, root in ipairs(roots) do
			local is_last_root = i == #roots
			process_task(root, 0, {}, is_last_root)
		end

		-- 如果有任务，添加到QF
		if count > 0 then
			file_counts[todo_path] = count

			-- 添加文件名标题（使用连接线样式）
			local filename = vim.fn.fnamemodify(todo_path, ":t")
			table.insert(qf_items, {
				filename = "",
				lnum = 1,
				text = string.format("─ %s ──[ %d tasks ]", filename, count),
			})

			-- 添加当前文件的所有任务
			for _, ft in ipairs(file_tasks) do
				table.insert(qf_items, {
					filename = ft.code_link.path,
					lnum = ft.code_link.line,
					text = ft.display_text,
				})
			end

			-- 添加分隔线
			if todo_path ~= todo_files[#todo_files] then
				table.insert(qf_items, {
					filename = "",
					lnum = 1,
					text = "",
				})
			end
		end
	end

	if #qf_items == 0 then
		vim.notify("项目中没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	vim.fn.setqflist(qf_items, "r")
	vim.cmd("copen")
end

---------------------------------------------------------------------
-- 折叠/展开功能（可选）
---------------------------------------------------------------------
function M.toggle_fold(task_id)
	if folded[task_id] then
		folded[task_id] = nil
	else
		folded[task_id] = true
	end
	-- 刷新显示
	M.show_project_links_qf()
end

---------------------------------------------------------------------
-- 简洁模式（可选）
---------------------------------------------------------------------
function M.show_simple_qf()
	-- 使用简单缩进的版本，可以在这里实现
	-- 或者通过配置切换显示模式
end

return M
