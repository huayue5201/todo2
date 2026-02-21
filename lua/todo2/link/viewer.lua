-- lua/todo2/link/viewer.lua (优化版 - 修复缺失函数)
local M = {}

local config = require("todo2.config")
local parser = require("todo2.core.parser")
local store_types = require("todo2.store.types")
local tag_manager = require("todo2.utils.tag_manager")
local format = require("todo2.utils.format")
local store_link = require("todo2.store.link")
local fm = require("todo2.ui.file_manager")

---------------------------------------------------------------------
-- 配置缓存（避免重复获取）
---------------------------------------------------------------------
local CONFIG_CACHE = {
	show_icons = true,
	show_child_count = true,
	file_header_style = "─ %s ──[ %d tasks ]",
	checkbox_icons = { todo = "◻", done = "✓" },
	indent_icons = { top = "│ ", middle = "├╴", last = "└╴", ws = "  " },
}

-- 刷新配置缓存
local function refresh_config_cache()
	CONFIG_CACHE.checkbox_icons = config.get("checkbox_icons") or CONFIG_CACHE.checkbox_icons
	CONFIG_CACHE.indent_icons = config.get("viewer_icons.indent") or CONFIG_CACHE.indent_icons
	CONFIG_CACHE.show_icons = config.get("viewer_show_icons") ~= false
	CONFIG_CACHE.show_child_count = config.get("viewer_show_child_count") ~= false
end

-- 初始化缓存
refresh_config_cache()

---------------------------------------------------------------------
-- 任务缓存（避免重复解析）
---------------------------------------------------------------------
local TASK_CACHE = {
	by_file = {}, -- 按文件路径缓存解析结果
	by_id = {}, -- 按 ID 缓存 code_link
	timestamp = {},
}

local CACHE_TTL = 5000 -- 5秒缓存

local function get_cached_tasks(filepath, force_refresh)
	local now = vim.loop.now()
	local cached = TASK_CACHE.by_file[filepath]

	if not force_refresh and cached and (now - (TASK_CACHE.timestamp[filepath] or 0)) < CACHE_TTL then
		return cached.tasks, cached.roots
	end

	local cfg = config.get("parser") or {}
	local tasks, roots
	if cfg.context_split then
		tasks, roots = parser.parse_main_tree(filepath, force_refresh)
	else
		tasks, _, _ = parser.parse_file(filepath, force_refresh)
		roots = tasks
	end

	TASK_CACHE.by_file[filepath] = { tasks = tasks, roots = roots }
	TASK_CACHE.timestamp[filepath] = now
	return tasks, roots
end

-- 缓存 code_link
local function get_cached_code_link(id)
	local now = vim.loop.now()
	local cached = TASK_CACHE.by_id[id]

	if cached and (now - cached.timestamp) < CACHE_TTL then
		return cached.link
	end

	local link = store_link.get_code(id, { verify_line = true })
	TASK_CACHE.by_id[id] = { link = link, timestamp = now }
	return link
end

---------------------------------------------------------------------
-- ⭐ 修复：添加缺失的辅助函数
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

local function get_tasks_for_view(path, force_refresh)
	local cfg = config.get("parser") or {}
	if cfg.context_split then
		return parser.parse_main_tree(path, force_refresh)
	else
		return parser.parse_file(path, force_refresh)
	end
end

---------------------------------------------------------------------
-- 本地辅助函数
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

local function get_context_indicator(code_link)
	if not code_link then
		return ""
	end
	if not code_link.context then
		return ""
	end
	if code_link.context_valid == false then
		return " ⚠️"
	end

	if code_link.context_similarity then
		if code_link.context_similarity < 60 then
			return " 🔴"
		elseif code_link.context_similarity < 80 then
			return " 🟡"
		else
			return " 🟢"
		end
	end
	return " 📍"
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
-- ⭐ 优化：预分配表大小，减少动态扩容
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

---------------------------------------------------------------------
-- ⭐ 优化：使用 table.concat 替代 string.format 多次调用
---------------------------------------------------------------------
local function build_task_display_text(task, code_link, indent_prefix, tag, icon, state_icon, cleaned_content)
	if not code_link then
		return ""
	end

	local parts = {}

	-- 缩进
	parts[#parts + 1] = indent_prefix

	-- 图标
	if CONFIG_CACHE.show_icons and icon ~= "" then
		parts[#parts + 1] = icon
		parts[#parts + 1] = " "
	end

	-- 标签和子任务计数
	parts[#parts + 1] = "["
	parts[#parts + 1] = tag

	if CONFIG_CACHE.show_child_count and task.children and #task.children > 0 then
		parts[#parts + 1] = string.format(" (%d)", #task.children)
	end
	parts[#parts + 1] = "]"

	-- 状态图标
	if state_icon ~= "" then
		parts[#parts + 1] = " "
		parts[#parts + 1] = state_icon
	end

	-- 内容
	parts[#parts + 1] = " "
	parts[#parts + 1] = cleaned_content

	-- 上下文指示器
	parts[#parts + 1] = get_context_indicator(code_link)

	-- 归档状态标签
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
-- ⭐ 优化：分批处理避免阻塞 UI
---------------------------------------------------------------------
local function process_tasks_in_batches(tasks, batch_size, callback)
	batch_size = batch_size or 50
	local index = 1
	local results = {}

	local function process_next()
		local batch_end = math.min(index + batch_size - 1, #tasks)
		for i = index, batch_end do
			results[i] = callback(tasks[i], i)
		end

		index = batch_end + 1
		if index <= #tasks then
			-- 让出事件循环，避免 UI 卡顿
			vim.defer_fn(process_next, 5)
		end
	end

	process_next()
	return results
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

	-- 预分配容量，减少动态扩容
	local loc_items = {}
	local estimated_count = #todo_files * 10 -- 估算
	if estimated_count > 0 then
		loc_items = {}
	end

	for _, todo_path in ipairs(todo_files) do
		local tasks, _ = get_cached_tasks(todo_path, false) -- 使用缓存

		for _, task in ipairs(tasks) do
			if task.id and should_display_task(task, need_filter_archived) then
				local code_link = get_cached_code_link(task.id) -- 使用缓存
				if code_link and code_link.path == current_path then
					local tag = tag_manager.get_tag_for_user_action(task.id)
					local is_completed = store_types.is_completed_status(code_link.status)
					local icon = CONFIG_CACHE.show_icons and get_status_icon(is_completed) or ""

					local cleaned_content = format.clean_content(task.content, tag)
					local state_icon = get_state_icon(code_link)

					local text = build_task_display_text(task, code_link, "", tag, icon, state_icon, cleaned_content)

					loc_items[#loc_items + 1] = {
						filename = current_path,
						lnum = code_link.line,
						text = text,
					}
				end
			end
		end
	end

	if #loc_items == 0 then
		vim.notify("当前 buffer 没有有效的 TAG 标记", vim.log.levels.INFO)
		return
	end

	-- 使用更高效的排序（快速排序已经很快，但可以避免创建闭包）
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

	-- 刷新配置缓存
	refresh_config_cache()

	local cfg = config.get("parser") or {}
	local need_filter_archived = not cfg.context_split

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	-- 预分配容量
	local qf_items = {}
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
		local tasks, roots = get_cached_tasks(todo_path, false)
		local file_tasks = {}
		local count = 0

		-- 使用本地函数避免重复创建闭包
		local function process_task(task, depth, is_last_stack, is_last)
			if not task.id then
				return
			end

			if not should_display_task(task, need_filter_archived) then
				return
			end

			local code_link = get_cached_code_link(task.id)
			if not code_link then
				return
			end

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

		-- 在文件之间添加空行（除了最后一个）
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
