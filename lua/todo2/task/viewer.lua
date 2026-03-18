-- lua/todo2/task/viewer.lua
---@module "todo2.task.viewer"
---@description 任务视图模块：负责在 quickfix 和 location list 中显示任务树

local M = {}

local config = require("todo2.config")
local scheduler = require("todo2.render.scheduler")
local store_types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local fm = require("todo2.ui.file_manager")

---------------------------------------------------------------------
-- 配置缓存
---------------------------------------------------------------------
---@class ViewerConfigCache
---@field show_icons boolean
---@field show_child_count boolean
---@field file_header_style string
---@field checkbox_icons {todo: string, done: string}
---@field indent_icons {top: string, middle: string, last: string, ws: string}
local CONFIG_CACHE = {
	show_icons = true,
	show_child_count = true,
	file_header_style = "─ %s ──[ %d tasks ]",
	checkbox_icons = { todo = "◻", done = "✓" },
	indent_icons = { top = "│ ", middle = "├╴", last = "└╴", ws = "  " },
}

---刷新配置缓存
local function refresh_config_cache()
	CONFIG_CACHE.checkbox_icons = config.get("checkbox_icons") or CONFIG_CACHE.checkbox_icons
	CONFIG_CACHE.indent_icons = config.get("viewer_icons.indent") or CONFIG_CACHE.indent_icons
	CONFIG_CACHE.show_icons = config.get("viewer_show_icons") ~= false
	CONFIG_CACHE.show_child_count = config.get("viewer_show_child_count") ~= false
	CONFIG_CACHE.file_header_style = config.get("viewer_file_header_style") or CONFIG_CACHE.file_header_style
end

refresh_config_cache()

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------

---获取任务的主标签（用于显示）
---@param task_id string 任务ID
---@return string 主标签，默认为"TODO"
local function get_task_primary_tag(task_id)
	local task = core.get_task(task_id)
	if not task or not task.core.tags or #task.core.tags == 0 then
		return "TODO"
	end
	return task.core.tags[1]
end

---从解析树根节点构建ID集合
---@param roots table[] 解析树根节点列表
---@return string[] 任务ID列表
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

---获取任务映射表（从内部格式）
---@param ids string[] 任务ID列表
---@return table<string, table> 任务ID到任务对象的映射
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

---判断任务是否应该显示
---@param task table 解析树中的任务节点
---@param need_filter_archived boolean 是否需要过滤归档任务
---@param tasks_map table<string, table> 任务映射表
---@return boolean
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

---获取状态标签文本
---@param status string 任务状态
---@return string
local function get_status_label(status)
	local labels = {
		[store_types.STATUS.ARCHIVED] = "归档",
		[store_types.STATUS.COMPLETED] = "完成",
		[store_types.STATUS.URGENT] = "紧急",
		[store_types.STATUS.WAITING] = "等待",
	}
	return labels[status] or ""
end

---获取复选框图标
---@param is_done boolean 是否已完成
---@return string
local function get_status_icon(is_done)
	return is_done and CONFIG_CACHE.checkbox_icons.done or CONFIG_CACHE.checkbox_icons.todo
end

---获取状态图标（来自配置）
---@param task table 任务对象
---@return string
local function get_state_icon(task)
	if not task or not task.core.status then
		return ""
	end
	return config.get_status_icon(task.core.status)
end

---构建缩进前缀
---@param depth number 缩进深度
---@param is_last_stack boolean[] 每层是否为最后一个节点的标记栈
---@return string
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

---构建任务显示文本
---@param task table 解析树中的任务节点
---@param t table 存储中的任务对象
---@param indent_prefix string 缩进前缀
---@param tag string 任务标签
---@param icon string 复选框图标
---@param state_icon string 状态图标
---@return string
local function build_task_display_text(task, t, indent_prefix, tag, icon, state_icon)
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

	parts[#parts + 1] = " " .. t.core.content

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
-- 公共API
---------------------------------------------------------------------

---显示当前 buffer 的所有代码位置 TAG 到 location list
---@return nil
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
		local _, roots = scheduler.get_parse_tree(todo_path, false)
		local ids = build_id_set_from_roots(roots)
		local tasks_map = need_filter_archived and get_tasks_map(ids) or {}

		local function collect_all(root)
			if root.id and should_display_task(root, need_filter_archived, tasks_map) then
				local id = root.id
				if not seen_ids[id] then
					local t = core.get_task(id)
					if t and t.locations.code and t.locations.code.path == current_path then
						seen_ids[id] = true

						local tag = get_task_primary_tag(id)
						local is_completed = store_types.is_completed_status(t.core.status)
						local icon = CONFIG_CACHE.show_icons and get_status_icon(is_completed) or ""
						local state_icon = get_state_icon(t)

						local text = build_task_display_text(root, t, "", tag, icon, state_icon)

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

---显示项目级的所有代码位置 TAG 到 quickfix
---@return nil
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

			local tag = get_task_primary_tag(task.id)
			local is_completed = store_types.is_completed_status(t.core.status)
			local icon = CONFIG_CACHE.show_icons and get_status_icon(is_completed) or ""

			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			local indent_prefix = build_indent_prefix(depth, current_is_last_stack)
			local state_icon = get_state_icon(t)

			local text = build_task_display_text(task, t, indent_prefix, tag, icon, state_icon)

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
