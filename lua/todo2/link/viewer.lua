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
local config = require("todo2.config")

---------------------------------------------------------------------
-- 工具模块
---------------------------------------------------------------------
local utils = module.get("core.utils")

---------------------------------------------------------------------
-- 硬编码配置（不需要用户调整的部分）
---------------------------------------------------------------------
local VIEWER_CONFIG = {
	-- 这些配置硬编码，不需要用户调整
	show_icons = true,
	show_child_count = true,
	file_header_style = "─ %s ──[ %d tasks ]",

	-- 缩进符号（固定，用户很少需要调整）
	indent = {
		top = "│ ",
		middle = "╴",
		last = "╰╴",
		fold_open = "⟣ ",
		ws = "  ",
	},
}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 获取任务状态图标（从配置中获取）
local function get_status_icon(is_done)
	-- 从配置中获取图标
	local icons = config.get("viewer_icons") or { todo = "◻", done = "✓" }
	return is_done and icons.done or icons.todo
end

--- 构建缩进前缀
local function build_indent_prefix(depth, is_last_stack, has_children)
	local indent = VIEWER_CONFIG.indent
	local prefix = ""

	-- 处理每一层的缩进
	for i = 1, depth do
		if i == depth then
			-- 当前层：根据是否是最后一个子节点选择连接线
			if is_last_stack[i] then
				prefix = prefix .. indent.last
			else
				prefix = prefix .. indent.middle
			end
		else
			-- 上层：根据该层是否是最后一个子节点选择垂直线或空白
			if is_last_stack[i] then
				prefix = prefix .. indent.ws
			else
				prefix = prefix .. indent.top
			end
		end
	end

	-- 添加折叠图标（如果有子任务）
	if has_children then
		prefix = prefix .. indent.fold_open
	else
		-- 没有子任务的情况，添加一个空格来对齐图标
		prefix = prefix .. "  "
	end

	return prefix
end

---------------------------------------------------------------------
-- LocList：简单显示当前buffer的任务
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
		local tasks, roots, id_to_task = parser_mod.parse_file(todo_path)

		for _, task in ipairs(tasks) do
			if task.id then
				local code_link = store_mod.get_code_link(task.id)
				if code_link and code_link.path == current_path then
					local tag = utils.extract_tag_from_content(task.content)
					local icon = VIEWER_CONFIG.show_icons and get_status_icon(task.is_done) or ""
					local icon_space = VIEWER_CONFIG.show_icons and " " or ""

					local text = string.format("%s%s[%s] %s", icon, icon_space, task.id, task.content)

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
-- QF：展示整个项目的任务树
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

		-- 递归构建任务树
		local function process_task(task, depth, is_last_stack, is_last)
			if not task.id then
				return
			end

			local code_link = store_mod.get_code_link(task.id)
			if not code_link then
				return
			end

			local tag = utils.extract_tag_from_content(task.content)
			local icon = VIEWER_CONFIG.show_icons and get_status_icon(task.is_done) or ""
			local has_children = task.children and #task.children > 0

			-- 构建当前节点的状态栈
			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			-- 构建缩进前缀
			local indent_prefix = build_indent_prefix(depth, current_is_last_stack, has_children)

			-- 计算子任务数量
			local child_count = 0
			if task.children then
				child_count = #task.children
			end

			-- 构建显示文本
			local child_info = ""
			if VIEWER_CONFIG.show_child_count and child_count > 0 then
				child_info = string.format(" (%d)", child_count)
			end

			-- 根据配置决定显示内容
			local display_icon = icon
			local icon_space = VIEWER_CONFIG.show_icons and " " or ""

			local text =
				string.format("%s%s%s[%s%s] %s", indent_prefix, display_icon, icon_space, tag, child_info, task.content)

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

			-- 递归处理子任务
			if task.children then
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

			-- 添加文件名标题
			local filename = vim.fn.fnamemodify(todo_path, ":t")
			table.insert(qf_items, {
				filename = "",
				lnum = 1,
				text = string.format(VIEWER_CONFIG.file_header_style, filename, count),
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

return M
