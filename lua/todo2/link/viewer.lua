-- lua/todo2/link/viewer.lua
--- @module todo2.link.viewer
--- @brief 展示 TAG:ref:id（QF / LocList）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 从TODO内容提取标签
local function extract_tag_from_content(content)
	local tag = content:match("^%[([A-Z]+)%]") or content:match("^([A-Z]+):") or content:match("^([A-Z]+)%s")
	return tag or "TODO"
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
		local tasks = parser_mod.parse_file(todo_path)

		for _, task in ipairs(tasks) do
			if task.id then
				local code_link = store_mod.get_code_link(task.id)
				if code_link and code_link.path == current_path then
					local tag = extract_tag_from_content(task.content)
					local text = string.format("[%s %s] %s", tag, task.id, task.content)

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

	-- 按文件处理
	for _, todo_path in ipairs(todo_files) do
		local tasks, roots = parser_mod.parse_file(todo_path)
		local file_tasks = {}
		local count = 0

		-- 递归构建任务树（简化版，去掉竖线）
		local function process_task(task, depth, is_last)
			if not task.id then
				return
			end

			local code_link = store_mod.get_code_link(task.id)
			if not code_link then
				return
			end

			local tag = extract_tag_from_content(task.content)

			-- 判断是否有子任务
			local has_children = task.children and #task.children > 0

			-- 构建前缀：根据深度和是否是最后一个子任务
			local prefix = ""
			if depth == 0 then
				-- 根任务：在原有前缀前加上>标记（如果有子任务）
				prefix = has_children and "│ ↪ " or "│   "
			else
				-- 简化版：只使用空格缩进和连接线，去掉竖线
				local indent = string.rep("", depth - 1)
				if is_last then
					-- 如果是最后一个子任务，加上>标记（如果有子任务）
					prefix = has_children and indent .. "└─ ↪ " or indent .. "└─   "
				else
					-- 如果不是最后一个子任务，加上>标记（如果有子任务）
					prefix = has_children and indent .. " ↪ " or indent .. "   "
				end
			end

			-- 计算子任务数量
			local child_count = 0
			if task.children then
				child_count = #task.children
			end

			-- 添加到当前文件任务列表
			table.insert(file_tasks, {
				node = task,
				depth = depth,
				prefix = prefix,
				tag = tag,
				code_link = code_link,
				content = task.content,
				child_count = child_count,
				has_children = has_children,
			})
			count = count + 1

			-- 递归处理子任务
			if task.children then
				-- 按order排序子任务
				table.sort(task.children, function(a, b)
					return (a.order or 0) < (b.order or 0)
				end)

				for i, child in ipairs(task.children) do
					process_task(child, depth + 1, i == #task.children)
				end
			end
		end

		-- 处理当前文件的所有根任务
		for _, root in ipairs(roots) do
			process_task(root, 0, false)
		end

		-- 如果有任务，添加到QF
		if count > 0 then
			file_counts[todo_path] = count

			-- 添加文件名标题
			local filename = vim.fn.fnamemodify(todo_path, ":t")
			table.insert(qf_items, {
				filename = "",
				lnum = 1,
				text = string.format("─── %s (%d) ───", filename, count),
			})

			-- 添加当前文件的所有任务
			for _, ft in ipairs(file_tasks) do
				local text = string.format("%s[%s %s] %s", ft.prefix, ft.tag, ft.node.id, ft.content)

				table.insert(qf_items, {
					filename = ft.code_link.path,
					lnum = ft.code_link.line,
					text = text,
				})
			end

			-- 添加空行分隔（非最后一个文件）
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
