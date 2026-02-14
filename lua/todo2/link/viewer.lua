-- lua/todo2/link/viewer.lua
--- @brief 展示 TAG:ref:id（QF / LocList）
---
--- 重构要点：
--- 1. 适配 parser.context_split 配置，自动选择主树（活动任务）或完整树
--- 2. 启用上下文隔离时，不再依赖状态字段过滤归档任务，直接使用 parse_main_tree
--- 3. 保留兼容模式，未启用隔离时仍过滤 ARCHIVED 状态
--- 4. 统一解析入口，减少重复代码
--- 5. 统一的归档任务判断函数

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
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
	indent = {
		top = "│ ",
		middle = "╴",
		last = "╰╴",
		ws = "  ",
	},
}

---------------------------------------------------------------------
-- 私有辅助函数
---------------------------------------------------------------------

--- 根据当前配置获取待展示的任务树
--- @param path string 文件路径
--- @param force_refresh boolean 是否强制刷新解析缓存
--- @return table[] tasks 任务列表
--- @return table[] roots 根任务列表
--- @return table id_to_task ID映射表
local function get_tasks_for_view(path, force_refresh)
	local cfg = config.get("parser") or {}
	if cfg.context_split then
		-- 启用归档隔离：只展示主任务树（活动任务）
		return parser.parse_main_tree(path, force_refresh)
	else
		-- 兼容模式：展示完整任务树（旧行为）
		return parser.parse_file(path, force_refresh)
	end
end

--- 判断任务是否应该显示
--- @param task table 任务对象
--- @param need_filter_archived boolean 是否需要过滤归档
--- @return boolean
local function should_display_task(task, need_filter_archived)
	if not task or not task.id then
		return false
	end

	-- 如果不需要过滤归档，直接显示
	if not need_filter_archived then
		return true
	end

	-- 检查任务是否归档
	local todo_link = store_link.get_todo(task.id, { verify_line = false })
	if not todo_link then
		return true -- 没有存储记录，显示（可能是新任务）
	end

	-- 归档任务不显示
	return todo_link.status ~= store_types.STATUS.ARCHIVED
end

--- 获取任务图标（完成/未完成）
local function get_status_icon(is_done)
	local icons = config.get("viewer_icons") or { todo = "◻", done = "✓" }
	return is_done and icons.done or icons.todo
end

--- 获取任务状态图标（紧急、等待、归档等）
local function get_state_icon(code_link)
	if not code_link or not code_link.status then
		return ""
	end

	-- 从配置获取状态定义
	local status_definitions = config.get("status_definitions") or {}
	local status_info = status_definitions[code_link.status]

	if status_info and status_info.icon then
		return status_info.icon
	end

	-- 默认图标映射
	local icon_map = {
		[store_types.STATUS.COMPLETED] = "✓",
		[store_types.STATUS.URGENT] = "⚠",
		[store_types.STATUS.WAITING] = "⌛",
		[store_types.STATUS.ARCHIVED] = "📁", -- 归档任务显示文件夹图标
	}

	return icon_map[code_link.status] or "○"
end

--- 构建缩进前缀（树形显示）
local function build_indent_prefix(depth, is_last_stack)
	local indent = VIEWER_CONFIG.indent
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

--- 获取任务的默认 TAG
local function get_task_tag(task)
	if not task or not task.id then
		return "TODO"
	end
	return tag_manager.get_tag_for_user_action(task.id)
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
	local need_filter_archived = not cfg.context_split -- 兼容模式需过滤归档状态

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local loc_items = {}

	for _, todo_path in ipairs(todo_files) do
		-- 根据配置选择解析方式
		local tasks, _, _ = get_tasks_for_view(todo_path)

		for _, task in ipairs(tasks) do
			-- 统一使用 should_display_task 判断是否显示
			if task.id and should_display_task(task, need_filter_archived) then
				local code_link = store_link.get_code(task.id, { verify_line = true })
				if code_link and code_link.path == current_path then
					local tag = get_task_tag(task)
					local is_completed = store_types.is_completed_status(code_link.status)
					local icon = VIEWER_CONFIG.show_icons and get_status_icon(is_completed) or ""
					local icon_space = VIEWER_CONFIG.show_icons and " " or ""

					local cleaned_content = format.clean_content(task.content, tag)
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
	local need_filter_archived = not cfg.context_split -- 兼容模式需过滤归档状态

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local qf_items = {}
	local file_counts = {}

	local function sort_tasks(a, b)
		local order_a = a.order or 0
		local order_b = b.order or 0
		if order_a ~= order_b then
			return order_a < order_b
		end
		return (a.id or "") < (b.id or "")
	end

	for _, todo_path in ipairs(todo_files) do
		-- 根据配置选择解析方式
		local tasks, roots = get_tasks_for_view(todo_path)
		local file_tasks = {}
		local count = 0

		local function process_task(task, depth, is_last_stack, is_last)
			if not task.id then
				return
			end

			-- 统一使用 should_display_task 判断是否显示
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
			local has_children = task.children and #task.children > 0

			local state_icon = get_state_icon(code_link)
			local state_display = state_icon ~= "" and " " .. state_icon or ""

			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			local indent_prefix = build_indent_prefix(depth, current_is_last_stack)

			local child_count = 0
			if task.children then
				child_count = #task.children
			end

			local child_info = ""
			if VIEWER_CONFIG.show_child_count and child_count > 0 then
				child_info = string.format(" (%d)", child_count)
			end

			local cleaned_content = format.clean_content(task.content, tag)
			local display_icon = icon
			local icon_space = VIEWER_CONFIG.show_icons and " " or ""

			local text = string.format(
				"%s%s%s[%s%s]%s %s",
				indent_prefix,
				display_icon,
				icon_space,
				tag,
				child_info,
				state_display,
				cleaned_content
			)

			-- 如果是归档任务，添加归档标记
			if code_link.status == store_types.STATUS.ARCHIVED then
				text = text .. " 📦"
			end

			if code_link.status and code_link.status ~= store_types.STATUS.NORMAL then
				local status_definitions = config.get("status_definitions") or {}
				local status_info = status_definitions[code_link.status]
				if status_info and status_info.label then
					text = text .. string.format("（%s）", status_info.label)
				end
			end

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
				child_count = child_count,
				has_children = has_children,
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
