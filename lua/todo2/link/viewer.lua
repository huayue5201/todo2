-- lua/todo2/link/viewer.lua
--- @brief 展示 TAG:ref:id（QF / LocList）
--- ⭐ 增强：添加上下文指示（修复：移除不存在的 get_status_label 调用）

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local parser = require("todo2.core.parser")
local store_types = require("todo2.store.types")
local tag_manager = require("todo2.utils.tag_manager")
local format = require("todo2.utils.format")
local store_link = require("todo2.store.link")
local fm = require("todo2.ui.file_manager")

---------------------------------------------------------------------
-- 硬编码配置
---------------------------------------------------------------------
local VIEWER_CONFIG = {
	show_icons = true,
	show_child_count = true,
	file_header_style = "─ %s ──[ %d tasks ]",
}

---------------------------------------------------------------------
-- ⭐ 新增：获取状态标签的辅助函数
---------------------------------------------------------------------
local function get_status_label(status)
	local labels = {
		[store_types.STATUS.ARCHIVED] = "归档",
		[store_types.STATUS.COMPLETED] = "完成",
		[store_types.STATUS.URGENT] = "紧急",
		[store_types.STATUS.WAITING] = "等待",
	}
	return labels[status] or ""
end

---------------------------------------------------------------------
-- 私有辅助函数
---------------------------------------------------------------------

local function get_tasks_for_view(path, force_refresh)
	local cfg = config.get("parser") or {}
	if cfg.context_split then
		return parser.parse_main_tree(path, force_refresh)
	else
		return parser.parse_file(path, force_refresh)
	end
end

local function should_display_task(task, need_filter_archived)
	if not task or not task.id then
		return false
	end

	if not need_filter_archived then
		return true
	end

	local todo_link = store_link.get_todo(task.id, { verify_line = false })
	if not todo_link then
		return true
	end

	return todo_link.status ~= store_types.STATUS.ARCHIVED
end

local function get_status_icon(is_done)
	local icons = config.get("checkbox_icons") or { todo = "◻", done = "✓" }
	return is_done and icons.done or icons.todo
end

local function get_state_icon(code_link)
	if not code_link or not code_link.status then
		return ""
	end

	return config.get_status_icon(code_link.status)
end

local function build_indent_prefix(depth, is_last_stack)
	local indent = config.get("viewer_icons.indent")
		or {
			top = "│ ",
			middle = "├╴",
			last = "└╴",
			ws = "  ",
		}

	local prefix = ""

	for i = 1, depth do
		if i == depth then
			if is_last_stack[i] then
				prefix = prefix .. indent.last
			else
				prefix = prefix .. indent.middle
			end
		else
			if is_last_stack[i] then
				prefix = prefix .. indent.ws
			else
				prefix = prefix .. indent.top
			end
		end
	end

	return prefix
end

local function get_task_tag(task)
	if not task or not task.id then
		return "TODO"
	end
	return tag_manager.get_tag_for_user_action(task.id)
end

---------------------------------------------------------------------
-- ⭐ 修改：构建任务显示文本（使用本地 get_status_label）
---------------------------------------------------------------------
local function build_task_display_text(task, code_link, indent_prefix, tag, icon, state_icon, cleaned_content)
	local is_completed = store_types.is_completed_status(code_link.status)
	local has_children = task.children and #task.children > 0

	local child_count = 0
	if task.children then
		child_count = #task.children
	end

	local child_info = ""
	if VIEWER_CONFIG.show_child_count and child_count > 0 then
		child_info = string.format(" (%d)", child_count)
	end

	local icon_space = VIEWER_CONFIG.show_icons and " " or ""
	local display_icon = icon

	-- ⭐ 添加上下文指示
	local context_indicator = ""
	if code_link and code_link.context then
		if code_link.context_valid == false then
			context_indicator = " ⚠️"
		elseif code_link.context_similarity and code_link.context_similarity < 80 then
			context_indicator = string.format(" 🔍%d%%", code_link.context_similarity)
		end
	end

	local text = string.format(
		"%s%s%s[%s%s]%s %s%s",
		indent_prefix,
		display_icon,
		icon_space,
		tag,
		child_info,
		state_icon ~= "" and " " .. state_icon or "",
		cleaned_content,
		context_indicator
	)

	-- ⭐ 修复：使用本地 get_status_label 函数
	if code_link.status == store_types.STATUS.ARCHIVED then
		local label = get_status_label("archived")
		if label and label ~= "" then
			text = text .. string.format("（%s）", label)
		end
	end

	if code_link.status and code_link.status ~= store_types.STATUS.NORMAL then
		local label = get_status_label(code_link.status)
		if label and label ~= "" then
			text = text .. string.format("（%s）", label)
		end
	end

	return text
end

---------------------------------------------------------------------
-- LocList：显示当前 buffer 中引用的任务
---------------------------------------------------------------------
function M.show_buffer_links_loclist()
	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	local current_buf = vim.api.nvim_get_current_buf()
	local current_path = vim.api.nvim_buf_get_name(current_buf)
	if current_path == "" then
		vim.notify("当前 buffer 未保存", vim.log.levels.WARN)
		return
	end

	local cfg = config.get("parser") or {}
	local need_filter_archived = not cfg.context_split

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local loc_items = {}

	for _, todo_path in ipairs(todo_files) do
		local tasks, _, _ = get_tasks_for_view(todo_path)

		for _, task in ipairs(tasks) do
			if task.id and should_display_task(task, need_filter_archived) then
				local code_link = store_link.get_code(task.id, { verify_line = true })
				if code_link and code_link.path == current_path then
					local tag = get_task_tag(task)
					local is_completed = store_types.is_completed_status(code_link.status)
					local icon = VIEWER_CONFIG.show_icons and get_status_icon(is_completed) or ""
					local icon_space = VIEWER_CONFIG.show_icons and " " or ""

					local cleaned_content = format.clean_content(task.content, tag)
					local state_icon = get_state_icon(code_link)

					-- 使用新的构建函数
					local text = build_task_display_text(task, code_link, "", tag, icon, state_icon, cleaned_content)

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
	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	local cfg = config.get("parser") or {}
	local need_filter_archived = not cfg.context_split

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local qf_items = {}
	local file_counts = {}
	-- 新增：记录有任务的文件列表
	local files_with_tasks = {}

	local function sort_tasks(a, b)
		local order_a = a.order or 0
		local order_b = b.order or 0
		if order_a ~= order_b then
			return order_a < order_b
		end
		return (a.id or "") < (b.id or "")
	end

	for _, todo_path in ipairs(todo_files) do
		local tasks, roots = get_tasks_for_view(todo_path)
		local file_tasks = {}
		local count = 0

		local function process_task(task, depth, is_last_stack, is_last)
			if not task.id then
				return
			end

			if not should_display_task(task, need_filter_archived) then
				return
			end

			local code_link = store_link.get_code(task.id, { verify_line = true })
			if not code_link then
				return
			end

			local tag = get_task_tag(task)
			local is_completed = store_types.is_completed_status(code_link.status)
			local icon = VIEWER_CONFIG.show_icons and get_status_icon(is_completed) or ""

			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			local indent_prefix = build_indent_prefix(depth, current_is_last_stack)

			local state_icon = get_state_icon(code_link)

			local cleaned_content = format.clean_content(task.content, tag)

			-- 使用新的构建函数
			local text = build_task_display_text(task, code_link, indent_prefix, tag, icon, state_icon, cleaned_content)

			table.insert(file_tasks, {
				node = task,
				depth = depth,
				indent = indent_prefix,
				tag = tag,
				icon = icon,
				state_icon = state_icon,
				code_link = code_link,
				content = task.content,
				cleaned_content = cleaned_content,
				child_count = task.children and #task.children or 0,
				has_children = task.children and #task.children > 0,
				display_text = text,
			})
			count = count + 1

			if task.children then
				table.sort(task.children, sort_tasks)

				for i, child in ipairs(task.children) do
					local child_is_last = i == #task.children
					process_task(child, depth + 1, current_is_last_stack, child_is_last)
				end
			end
		end

		table.sort(roots, sort_tasks)

		for i, root in ipairs(roots) do
			local is_last_root = i == #roots
			process_task(root, 0, {}, is_last_root)
		end

		if count > 0 then
			file_counts[todo_path] = count
			-- 将有任务的文件加入列表
			table.insert(files_with_tasks, todo_path)

			local filename = vim.fn.fnamemodify(todo_path, ":t")
			table.insert(qf_items, {
				filename = "",
				lnum = 1,
				text = string.format(VIEWER_CONFIG.file_header_style, filename, count),
			})

			for _, ft in ipairs(file_tasks) do
				table.insert(qf_items, {
					filename = ft.code_link.path,
					lnum = ft.code_link.line,
					text = ft.display_text,
				})
			end
		end
	end

	-- 重构：只在多个有任务的文件之间插入空行
	for i, todo_path in ipairs(files_with_tasks) do
		-- 不是最后一个有任务的文件时才插入空行
		if i < #files_with_tasks then
			table.insert(qf_items, {
				filename = "",
				lnum = 1,
				text = "",
			})
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
