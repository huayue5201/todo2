-- lua/todo2/task/viewer.lua
-- 纯功能平移：使用新接口获取任务数据

local M = {}

local config = require("todo2.config")
local scheduler = require("todo2.render.scheduler")
local store_types = require("todo2.store.types")
local tag_manager = require("todo2.utils.tag_manager")
local format = require("todo2.utils.format")
local core = require("todo2.store.link.core") -- 改为 core
local fm = require("todo2.ui.file_manager")

---------------------------------------------------------------------
-- 配置缓存
---------------------------------------------------------------------
local CONFIG_CACHE = {
	show_icons = true,
	show_child_count = true,
	file_header_style = "─ %s ──[ %d tasks ]",
	checkbox_icons = { todo = "◻", done = "✓" },
	indent_icons = { top = "│ ", middle = "├╴", last = "└╴", ws = "  " },
}

local function refresh_config_cache()
	CONFIG_CACHE.checkbox_icons = config.get("checkbox_icons") or CONFIG_CACHE.checkbox_icons
	CONFIG_CACHE.indent_icons = config.get("viewer_icons.indent") or CONFIG_CACHE.indent_icons
	CONFIG_CACHE.show_icons = config.get("viewer_show_icons") ~= false
	CONFIG_CACHE.show_child_count = config.get("viewer_show_child_count") ~= false
	CONFIG_CACHE.file_header_style = config.get("viewer_file_header_style") or CONFIG_CACHE.file_header_style
end

refresh_config_cache()

---------------------------------------------------------------------
-- 批量获取任务（减少 core 调用次数）
---------------------------------------------------------------------
local function build_id_set_from_roots(roots)
	local ids = {}
	local seen = {}

	local function collect(task)
		if not task or not task.id then
			return
		end
		if seen[task.id] then
			return
		end
		seen[task.id] = true
		table.insert(ids, task.id)

		if task.children then
			for _, child in ipairs(task.children) do
				collect(child)
			end
		end
	end

	for _, root in ipairs(roots or {}) do
		collect(root)
	end

	return ids
end

---------------------------------------------------------------------
-- 获取任务 maps（从内部格式）
---------------------------------------------------------------------
local function get_tasks_map(ids)
	local map = {}
	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task then
			map[id] = task
		end
	end
	return map
end

---------------------------------------------------------------------
-- 过滤逻辑
---------------------------------------------------------------------
local function should_display_task(task, need_filter_archived, tasks_map)
	if not task or not task.id then
		return false
	end
	if not need_filter_archived then
		return true
	end

	local t = tasks_map[task.id]
	if not t then
		return true
	end

	return t.core.status ~= store_types.STATUS.ARCHIVED
end

---------------------------------------------------------------------
-- 显示文本构建
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

local function get_status_icon(is_done)
	return is_done and CONFIG_CACHE.checkbox_icons.done or CONFIG_CACHE.checkbox_icons.todo
end

local function get_state_icon(task)
	if not task or not task.core.status then
		return ""
	end
	return config.get_status_icon(task.core.status)
end

local function build_indent_prefix(depth, is_last_stack)
	local indent = CONFIG_CACHE.indent_icons
	local parts = {}

	for i = 1, depth do
		if i == depth then
			parts[i] = is_last_stack[i] and indent.last or indent.middle
		else
			parts[i] = is_last_stack[i] and indent.ws or indent.top
		end
	end

	return table.concat(parts)
end

local function build_task_display_text(task, t, indent_prefix, tag, icon, state_icon, cleaned_content)
	local parts = {}

	parts[#parts + 1] = indent_prefix

	if CONFIG_CACHE.show_icons and icon ~= "" then
		parts[#parts + 1] = icon .. " "
	end

	parts[#parts + 1] = "[" .. tag
	if CONFIG_CACHE.show_child_count and task.children and #task.children > 0 then
		parts[#parts + 1] = string.format(" (%d)", #task.children)
	end
	parts[#parts + 1] = "]"

	if state_icon ~= "" then
		parts[#parts + 1] = " " .. state_icon
	end

	parts[#parts + 1] = " " .. cleaned_content

	if t.core.status == store_types.STATUS.ARCHIVED then
		parts[#parts + 1] = "（归档）"
	elseif t.core.status and t.core.status ~= store_types.STATUS.NORMAL then
		local label = get_status_label(t.core.status)
		if label ~= "" then
			parts[#parts + 1] = "（" .. label .. "）"
		end
	end

	return table.concat(parts)
end

---------------------------------------------------------------------
-- LocList：当前 buffer 的所有 TAG
---------------------------------------------------------------------
function M.show_buffer_links_loclist()
	local current_buf = vim.api.nvim_get_current_buf()
	local current_path = vim.api.nvim_buf_get_name(current_buf)
	if current_path == "" then
		vim.notify("当前 buffer 未保存", vim.log.levels.WARN)
		return
	end

	local parser_cfg = config.get("parser") or {}
	local need_filter_archived = not parser_cfg.context_split

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local loc_items = {}
	local seen_ids = {}

	for _, todo_path in ipairs(todo_files) do
		local _, roots, id_to_task = scheduler.get_parse_tree(todo_path, false)
		local ids = build_id_set_from_roots(roots)
		local tasks_map = need_filter_archived and get_tasks_map(ids) or {}

		local function collect_all(root)
			if root.id and should_display_task(root, need_filter_archived, tasks_map) then
				local id = root.id
				if not seen_ids[id] then
					local t = core.get_task(id)
					if t and t.locations.code and t.locations.code.path == current_path then
						seen_ids[id] = true

						local tag = tag_manager.get_tag_for_user_action(id)
						local is_completed = store_types.is_completed_status(t.core.status)
						local icon = CONFIG_CACHE.show_icons and get_status_icon(is_completed) or ""
						local cleaned_content = format.clean_content(root.content, tag)
						local state_icon = get_state_icon(t)

						local text = build_task_display_text(root, t, "", tag, icon, state_icon, cleaned_content)

						loc_items[#loc_items + 1] = {
							filename = current_path,
							lnum = t.locations.code.line,
							text = text,
						}
					end
				end
			end

			if root.children then
				for _, child in ipairs(root.children) do
					collect_all(child)
				end
			end
		end

		for _, root in ipairs(roots) do
			collect_all(root)
		end
	end

	if #loc_items == 0 then
		vim.notify("当前 buffer 没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	table.sort(loc_items, function(a, b)
		return a.lnum < b.lnum
	end)

	vim.fn.setloclist(0, loc_items, "r")
	vim.cmd("lopen")
end

---------------------------------------------------------------------
-- QF：项目级 TAG 视图
---------------------------------------------------------------------
function M.show_project_links_qf()
	refresh_config_cache()

	local parser_cfg = config.get("parser") or {}
	local need_filter_archived = not parser_cfg.context_split

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local processed_ids = {}
	local qf_items = {}
	local files_with_tasks = {}

	for _, todo_path in ipairs(todo_files) do
		local _, roots = scheduler.get_parse_tree(todo_path, false)
		local ids = build_id_set_from_roots(roots)
		local tasks_map = need_filter_archived and get_tasks_map(ids) or {}

		local file_tasks = {}
		local count = 0

		local function process_task(task, depth, is_last_stack, is_last)
			if not task.id or processed_ids[task.id] then
				return
			end

			if not should_display_task(task, need_filter_archived, tasks_map) then
				return
			end

			local t = core.get_task(task.id)
			if not t or not t.locations.code then
				return
			end

			processed_ids[task.id] = true

			local tag = tag_manager.get_tag_for_user_action(task.id)
			local is_completed = store_types.is_completed_status(t.core.status)
			local icon = CONFIG_CACHE.show_icons and get_status_icon(is_completed) or ""

			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			local indent_prefix = build_indent_prefix(depth, current_is_last_stack)
			local state_icon = get_state_icon(t)
			local cleaned_content = format.clean_content(task.content, tag)

			local text = build_task_display_text(task, t, indent_prefix, tag, icon, state_icon, cleaned_content)

			file_tasks[#file_tasks + 1] = {
				code_path = t.locations.code.path,
				code_line = t.locations.code.line,
				display_text = text,
			}
			count = count + 1

			if task.children then
				for i, child in ipairs(task.children) do
					process_task(child, depth + 1, current_is_last_stack, i == #task.children)
				end
			end
		end

		for i, root in ipairs(roots) do
			process_task(root, 0, {}, i == #roots)
		end

		if count > 0 then
			table.insert(files_with_tasks, {
				path = todo_path,
				tasks = file_tasks,
				count = count,
			})
		end
	end

	if #files_with_tasks == 0 then
		vim.notify("项目中没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	for i, file_info in ipairs(files_with_tasks) do
		local filename = vim.fn.fnamemodify(file_info.path, ":t")
		qf_items[#qf_items + 1] = {
			filename = "",
			lnum = 1,
			text = string.format(CONFIG_CACHE.file_header_style, filename, file_info.count),
		}

		for _, task_info in ipairs(file_info.tasks) do
			qf_items[#qf_items + 1] = {
				filename = task_info.code_path,
				lnum = task_info.code_line,
				text = task_info.display_text,
			}
		end

		if i < #files_with_tasks then
			qf_items[#qf_items + 1] = { filename = "", lnum = 1, text = "" }
		end
	end

	vim.fn.setqflist(qf_items, "r")
	vim.cmd("copen")
end

return M
