-- lua/todo2/task/viewer.lua (完整修复版)
local M = {}

local config = require("todo2.config")
local parser = require("todo2.core.parser")
local store_types = require("todo2.store.types")
local tag_manager = require("todo2.utils.tag_manager")
local format = require("todo2.utils.format")
local store_link = require("todo2.store.link")
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
end

refresh_config_cache()

---------------------------------------------------------------------
-- 任务缓存（优化版）
---------------------------------------------------------------------
local TASK_CACHE = {
	by_file = {},
	by_id = {},
	timestamp = {},
	last_status = {}, -- ⭐ 新增：记录上次的状态，用于检测变化
}

-- ⭐ 缩短缓存时间到 1秒，兼顾性能和实时性
local CACHE_TTL = 1000

-- ⭐ 改进的缓存获取函数
local function get_cached_tasks(filepath, force_refresh)
	local now = vim.loop.now()
	local cached = TASK_CACHE.by_file[filepath]

	-- 如果强制刷新，跳过缓存
	if force_refresh then
		cached = nil
	end

	-- 缓存有效且未过期
	if not force_refresh and cached and (now - (TASK_CACHE.timestamp[filepath] or 0)) < CACHE_TTL then
		return cached.tasks, cached.roots, cached.id_map
	end

	-- 重新解析
	local cfg = config.get("parser") or {}
	local tasks, roots, id_map

	if cfg.context_split then
		tasks, roots, id_map = parser.parse_main_tree(filepath, force_refresh)
	else
		tasks, _, _ = parser.parse_file(filepath, force_refresh)
		roots = tasks
		id_map = {}
	end

	-- 更新缓存
	TASK_CACHE.by_file[filepath] = {
		tasks = tasks,
		roots = roots,
		id_map = id_map,
		timestamp = now,
	}
	TASK_CACHE.timestamp[filepath] = now

	return tasks, roots, id_map
end

-- ⭐ 改进的 code_link 获取函数
local function get_cached_code_link(id, force_refresh)
	local now = vim.loop.now()
	local cached = TASK_CACHE.by_id[id]

	-- 如果强制刷新或缓存过期，重新获取
	if force_refresh or not cached or (now - cached.timestamp) >= CACHE_TTL then
		local link = store_link.get_code(id, { verify_line = true })

		-- ⭐ 检测状态是否变化
		if cached and cached.link and cached.link.status ~= link.status then
			-- 状态变化了，强制刷新文件缓存
			if cached.link.path then
				TASK_CACHE.by_file[cached.link.path] = nil
			end
		end

		TASK_CACHE.by_id[id] = { link = link, timestamp = now }
		return link
	end

	return cached.link
end

-- ⭐ 新增：手动刷新缓存
function M.refresh_cache()
	TASK_CACHE.by_file = {}
	TASK_CACHE.by_id = {}
	TASK_CACHE.timestamp = {}
	TASK_CACHE.last_status = {}
	vim.notify("任务缓存已刷新", vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------
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

local function get_state_icon(code_link)
	if not code_link or not code_link.status then
		return ""
	end
	return config.get_status_icon(code_link.status)
end

---------------------------------------------------------------------
-- 构建显示文本
---------------------------------------------------------------------
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

local function build_task_display_text(task, code_link, indent_prefix, tag, icon, state_icon, cleaned_content)
	if not code_link then
		return ""
	end

	local parts = {}

	parts[#parts + 1] = indent_prefix

	if CONFIG_CACHE.show_icons and icon ~= "" then
		parts[#parts + 1] = icon
		parts[#parts + 1] = " "
	end

	parts[#parts + 1] = "["
	parts[#parts + 1] = tag

	if CONFIG_CACHE.show_child_count and task.children and #task.children > 0 then
		parts[#parts + 1] = string.format(" (%d)", #task.children)
	end
	parts[#parts + 1] = "]"

	if state_icon ~= "" then
		parts[#parts + 1] = " "
		parts[#parts + 1] = state_icon
	end

	parts[#parts + 1] = " "
	parts[#parts + 1] = cleaned_content

	if code_link.status == store_types.STATUS.ARCHIVED then
		local label = get_status_label("archived")
		if label and label ~= "" then
			parts[#parts + 1] = "（"
			parts[#parts + 1] = label
			parts[#parts + 1] = "）"
		end
	elseif code_link.status and code_link.status ~= store_types.STATUS.NORMAL then
		local label = get_status_label(code_link.status)
		if label and label ~= "" then
			parts[#parts + 1] = "（"
			parts[#parts + 1] = label
			parts[#parts + 1] = "）"
		end
	end

	return table.concat(parts)
end

---------------------------------------------------------------------
-- ⭐ 修复版：LocList - 实时刷新
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
	local seen_ids = {}

	-- ⭐ 强制刷新缓存，确保实时性
	local force_refresh = true

	-- 辅助函数：递归收集所有任务
	local function collect_all_tasks(root, result)
		if root.id and should_display_task(root, need_filter_archived) then
			table.insert(result, root)
		end
		if root.children then
			for _, child in ipairs(root.children) do
				collect_all_tasks(child, result)
			end
		end
	end

	for _, todo_path in ipairs(todo_files) do
		-- ⭐ 使用强制刷新
		local _, roots, _ = get_cached_tasks(todo_path, force_refresh)

		-- 从树形结构收集所有任务
		local all_tasks = {}
		for _, root in ipairs(roots) do
			collect_all_tasks(root, all_tasks)
		end

		for _, task in ipairs(all_tasks) do
			if task.id then
				-- ⭐ 使用强制刷新获取最新的状态
				local code_link = get_cached_code_link(task.id, force_refresh)
				if code_link and code_link.path == current_path then
					if not seen_ids[task.id] then
						seen_ids[task.id] = true

						local tag = tag_manager.get_tag_for_user_action(task.id)
						local is_completed = store_types.is_completed_status(code_link.status)
						local icon = CONFIG_CACHE.show_icons and get_status_icon(is_completed) or ""

						local cleaned_content = format.clean_content(task.content, tag)
						local state_icon = get_state_icon(code_link)

						local text =
							build_task_display_text(task, code_link, "", tag, icon, state_icon, cleaned_content)

						loc_items[#loc_items + 1] = {
							filename = current_path,
							lnum = code_link.line,
							text = text,
						}
					end
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
-- ⭐ 修复版：QF - 实时刷新
---------------------------------------------------------------------
function M.show_project_links_qf()
	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	refresh_config_cache()

	local cfg = config.get("parser") or {}
	local need_filter_archived = not cfg.context_split

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local processed_ids = {}
	local qf_items = {}
	local files_with_tasks = {}

	-- ⭐ 强制刷新缓存，确保实时性
	local force_refresh = true

	local function sort_tasks(a, b)
		local order_a = a.order or 0
		local order_b = b.order or 0
		if order_a ~= order_b then
			return order_a < order_b
		end
		return (a.id or "") < (b.id or "")
	end

	for _, todo_path in ipairs(todo_files) do
		-- ⭐ 使用强制刷新
		local _, roots, _ = get_cached_tasks(todo_path, force_refresh)
		local file_tasks = {}
		local count = 0

		local function process_task(task, depth, is_last_stack, is_last)
			if not task.id or processed_ids[task.id] then
				return
			end

			if not should_display_task(task, need_filter_archived) then
				return
			end

			-- ⭐ 使用强制刷新获取最新的状态
			local code_link = get_cached_code_link(task.id, force_refresh)
			if not code_link then
				return
			end

			processed_ids[task.id] = true

			local tag = tag_manager.get_tag_for_user_action(task.id)
			local is_completed = store_types.is_completed_status(code_link.status)
			local icon = CONFIG_CACHE.show_icons and get_status_icon(is_completed) or ""

			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			local indent_prefix = build_indent_prefix(depth, current_is_last_stack)
			local state_icon = get_state_icon(code_link)
			local cleaned_content = format.clean_content(task.content, tag)

			local text = build_task_display_text(task, code_link, indent_prefix, tag, icon, state_icon, cleaned_content)

			file_tasks[#file_tasks + 1] = {
				code_link = code_link,
				display_text = text,
			}
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
			table.insert(files_with_tasks, {
				path = todo_path,
				tasks = file_tasks,
				count = count,
			})
		end
	end

	-- 构建 QF 列表
	for i, file_info in ipairs(files_with_tasks) do
		local filename = vim.fn.fnamemodify(file_info.path, ":t")
		qf_items[#qf_items + 1] = {
			filename = "",
			lnum = 1,
			text = string.format(CONFIG_CACHE.file_header_style, filename, file_info.count),
		}

		for _, task_info in ipairs(file_info.tasks) do
			qf_items[#qf_items + 1] = {
				filename = task_info.code_link.path,
				lnum = task_info.code_link.line,
				text = task_info.display_text,
			}
		end

		if i < #files_with_tasks then
			qf_items[#qf_items + 1] = {
				filename = "",
				lnum = 1,
				text = "",
			}
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
