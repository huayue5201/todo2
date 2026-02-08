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
-- ⭐ 新增：导入存储类型常量
---------------------------------------------------------------------
local store_types = require("todo2.store.types")

---------------------------------------------------------------------
-- ⭐ 标签管理器（新增）
---------------------------------------------------------------------
local tag_manager = module.get("todo2.utils.tag_manager")

---------------------------------------------------------------------
-- 硬编码配置（不需要用户调整的部分）
---------------------------------------------------------------------
local VIEWER_CONFIG = {
	-- 这些配置硬编码，不需要用户调整
	show_icons = true,
	show_child_count = true,
	file_header_style = "─ %s ──[ %d tasks ]",

	-- ⭐ 修改：调整缩进符号，确保对齐
	indent = {
		top = "│ ",
		middle = "╴",
		last = "╰╴",
		fold_open = "", -- 简化折叠图标
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

--- ⭐ 修复：获取任务状态显示图标（使用store_types常量）
local function get_state_icon(code_link)
	if not code_link or not code_link.status then
		return ""
	end

	local status_definitions = config.get("status_definitions") or {}
	local status_info = status_definitions[code_link.status]

	if status_info and status_info.icon then
		return status_info.icon
	end

	-- ⭐ 修复：使用store_types常量
	if code_link.status == store_types.STATUS.COMPLETED then
		return "✓"
	elseif code_link.status == store_types.STATUS.URGENT then
		return "⚠"
	elseif code_link.status == store_types.STATUS.WAITING then
		return "⌛"
	elseif code_link.status == store_types.STATUS.ARCHIVED then
		return "📁"
	else
		return "○"
	end
end

--- ⭐ 修改：构建缩进前缀
local function build_indent_prefix(depth, is_last_stack)
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

	return prefix
end

--- ⭐ 修复：检查任务是否已归档（同时检查status和archived_at）
--- @param task_id string 任务ID
--- @param store_link table store.link模块
--- @return boolean 是否已归档
local function is_task_archived(task_id, store_link)
	if not task_id then
		return false
	end

	-- ⭐ 修复：使用正确的模块和函数名
	local todo_link = store_link.get_todo(task_id, { verify_line = true })
	if not todo_link then
		return false
	end

	-- ⭐ 修复：同时检查status和archived_at字段
	return todo_link.status == store_types.STATUS.ARCHIVED or todo_link.archived_at ~= nil
end

---------------------------------------------------------------------
-- ⭐ 修改：增强的 get_task_tag 函数（使用tag_manager）
---------------------------------------------------------------------
--- 获取任务标签（使用统一标签管理器）
--- @param task table 任务对象
--- @param store_link table store.link模块
--- @return string 标签名
local function get_task_tag(task, store_link)
	if not task or not task.id then
		return "TODO"
	end

	-- ⭐ 修改：使用tag_manager获取标签
	local tag = tag_manager.get_tag_for_user_action(task.id)
	return tag
end

---------------------------------------------------------------------
-- LocList：简单显示当前buffer的任务（修复存储API调用）
---------------------------------------------------------------------
function M.show_buffer_links_loclist()
	-- ⭐ 修复：使用正确的存储模块API
	local store_link = module.get("store.link")
	local fm = module.get("ui.file_manager")
	local parser_mod = module.get("core.parser")

	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

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
				-- ⭐ 修改：检查任务是否已归档
				if is_task_archived(task.id, store_link) then
					goto continue
				end

				-- ⭐ 修复：使用正确的函数名
				local code_link = store_link.get_code(task.id, { verify_line = true })
				if code_link and code_link.path == current_path then
					-- ⭐ 修改：使用tag_manager获取标签
					local tag = get_task_tag(task, store_link)
					local icon = VIEWER_CONFIG.show_icons and get_status_icon(task.is_done) or ""
					local icon_space = VIEWER_CONFIG.show_icons and " " or ""

					-- ⭐ 修改：使用tag_manager清理内容
					local cleaned_content = tag_manager.clean_content(task.content, tag)

					-- ⭐ 修改：获取状态图标并添加到标记后面
					local state_icon = get_state_icon(code_link)
					local state_display = state_icon ~= "" and " " .. state_icon or ""

					local text = string.format("%s%s[%s]%s %s", icon, icon_space, tag, state_display, cleaned_content)

					table.insert(loc_items, {
						filename = current_path,
						lnum = code_link.line,
						text = text,
					})
				end
			end
			::continue::
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
-- QF：展示整个项目的任务树（修复存储API调用）
---------------------------------------------------------------------
function M.show_project_links_qf()
	-- ⭐ 修复：使用正确的存储模块API
	local store_link = module.get("store.link")
	local fm = module.get("ui.file_manager")
	local parser_mod = module.get("core.parser")

	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

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

			-- ⭐ 修改：检查任务是否已归档
			if is_task_archived(task.id, store_link) then
				return
			end

			-- ⭐ 修复：使用正确的函数名
			local code_link = store_link.get_code(task.id, { verify_line = true })
			if not code_link then
				return
			end

			-- ⭐ 修改：使用tag_manager获取标签
			local tag = get_task_tag(task, store_link)
			local icon = VIEWER_CONFIG.show_icons and get_status_icon(task.is_done) or ""
			local has_children = task.children and #task.children > 0

			-- ⭐ 修改：获取状态图标
			local state_icon = get_state_icon(code_link)
			local state_display = state_icon ~= "" and " " .. state_icon or ""

			-- 构建当前节点的状态栈
			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			-- ⭐ 修改：构建缩进前缀（简化版本）
			local indent_prefix = build_indent_prefix(depth, current_is_last_stack)

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

			-- ⭐ 修改：使用tag_manager清理内容
			local cleaned_content = tag_manager.clean_content(task.content, tag)

			-- 根据配置决定显示内容
			local display_icon = icon
			local icon_space = VIEWER_CONFIG.show_icons and " " or ""

			-- ⭐ 修改：调整显示格式，保持原有结构，只在标记后面添加状态图标
			local text = string.format(
				"%s%s%s[%s%s]%s %s",
				indent_prefix,
				display_icon,
				icon_space,
				tag,
				child_info,
				state_display, -- 状态图标放在标记后面
				cleaned_content
			)

			-- ⭐ 修复：添加状态标签（使用store_types常量）
			if code_link.status and code_link.status ~= store_types.STATUS.NORMAL then
				local status_definitions = config.get("status_definitions") or {}
				local status_info = status_definitions[code_link.status]
				if status_info and status_info.label then
					text = text .. string.format("（%s）", status_info.label)
				end
			end

			-- 添加到当前文件任务列表
			table.insert(file_tasks, {
				node = task,
				depth = depth,
				indent = indent_prefix,
				tag = tag,
				icon = icon,
				state_icon = state_icon,
				code_link = code_link,
				content = task.content,
				cleaned_content = cleaned_content, -- 保存清理后的内容
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
