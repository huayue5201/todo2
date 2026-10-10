-- lua/todo2/task/viewer.lua
---@module "todo2.task.viewer"
---@description 任务视图模块：负责在 quickfix 和 location list 中显示任务树

local M = {}

local config = require("todo2.config")
local git_integration = require("todo2.integrations.git")
local scheduler = require("todo2.render.scheduler")
local store_types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local fm = require("todo2.ui.file_manager")
local index = require("todo2.store.index")
local project_utils = require("todo2.utils.project")
local tree = require("todo2.utils.tree")
local status_domain = require("todo2.core.status")
local tags_utils = require("todo2.utils.tags")
local checkbox = require("todo2.render.checkbox")

---------------------------------------------------------------------
-- 配置缓存
---------------------------------------------------------------------
---@class ViewerConfigCache
---@field show_icons boolean
---@field show_child_count boolean
---@field file_header_style string
local CONFIG_CACHE = {}

---刷新配置缓存（默认值统一由 config.lua 提供，这里只做缓存，不重复定义）
local function refresh_config_cache()
	CONFIG_CACHE.show_icons = config.get("viewer_show_icons")
	CONFIG_CACHE.show_child_count = config.get("viewer_show_child_count")
	CONFIG_CACHE.file_header_style = config.get("viewer_file_header_style")
	CONFIG_CACHE.show_git = config.get("git.show_metadata")
end

refresh_config_cache()

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------

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

---获取复选框图标（统一走共享 checkbox 模块）
---@param task table 任务对象
---@return string
local function get_checkbox_icon(task)
	local icon = checkbox.get(task and task.core.status)
	return icon or ""
end

---获取状态图标（来自状态定义）
---@param task table 任务对象
---@return string
local function get_state_icon(task)
	if not task or not task.core.status then
		return ""
	end
	local def = status_domain.get_definition(task.core.status)
	return def and def.icon or ""
end

---构建任务显示文本
---@param task table 解析树中的任务节点
---@param t table 存储中的任务对象
---@param indent_prefix string 缩进前缀
---@param icon string 复选框图标
---@param state_icon string 状态图标
---@return string
local function build_task_display_text(task, t, indent_prefix, icon, state_icon)
	local parts = {}

	parts[#parts + 1] = indent_prefix

	if CONFIG_CACHE.show_icons and icon ~= "" then
		parts[#parts + 1] = icon .. " "
	end

	if CONFIG_CACHE.show_child_count and task.children and #task.children > 0 then
		parts[#parts + 1] = string.format("[%d] ", #task.children)
	end

	if state_icon ~= "" then
		parts[#parts + 1] = state_icon .. " "
	end

	parts[#parts + 1] = t.core.content

	-- 标签（多值）：以 #tag 形式附在内容之后
	if t.core.tags and #t.core.tags > 0 then
		parts[#parts + 1] = tags_utils.format(t.core.tags)
	end

	-- git 元数据：关联提交 / 分支 / 作者
	if CONFIG_CACHE.show_git and t.git then
		parts[#parts + 1] = git_integration.format_meta(t.git)
	end

	-- 锚点失效的 git 归因（由 code_tracker 重锚定时写入）
	if CONFIG_CACHE.show_git and t.verification and t.verification.git then
		parts[#parts + 1] = git_integration.format_anchor_git(t.verification.git)
	end

	if t.core.status and t.core.status ~= status_domain.get_default() then
		local def = status_domain.get_definition(t.core.status)
		local label = def and def.label or t.core.status
		if label ~= "" then
			parts[#parts + 1] = " (" .. label .. ")"
		end
	end

	return table.concat(parts)
end

---------------------------------------------------------------------
-- 公共API
---------------------------------------------------------------------

---显示当前 buffer 的所有代码任务到 location list
---@return nil
function M.show_buffer_links_loclist()
	local current_buf = vim.api.nvim_get_current_buf()
	local current_path = vim.api.nvim_buf_get_name(current_buf)
	if current_path == "" then
		vim.notify("Current buffer is not saved", vim.log.levels.WARN)
		return
	end

	-- 从索引获取当前文件的所有代码任务
	local tasks = index.find_code_links_by_file(current_path)
	if not tasks or #tasks == 0 then
		vim.notify("Current buffer has no linked tasks", vim.log.levels.INFO)
		return
	end

	local loc_items = {}

	for _, task in ipairs(tasks) do
		local code_loc = task.locations.code
		-- 只列“自身锚点且未失联”的任务 = 代码里实际渲染的标记；
		-- 继承锚点（补充任务）与失联任务在代码里都没有标记，不列入。
		if code_loc and code_loc.path == current_path and not core.is_anchor_lost(task) then
			local display_text = task.core.content or ""
			if task.core.tags and #task.core.tags > 0 then
				display_text = display_text .. tags_utils.format(task.core.tags)
			end

			loc_items[#loc_items + 1] = {
				filename = current_path,
				lnum = code_loc.line,
				text = display_text,
			}
		end
	end

	if #loc_items == 0 then
		vim.notify("Current buffer has no linked tasks", vim.log.levels.INFO)
		return
	end

	table.sort(loc_items, function(a, b)
		return a.lnum < b.lnum
	end)

	vim.fn.setloclist(0, loc_items, "r")
	vim.cmd("lopen")
end

---显示项目级的所有代码任务到 quickfix
---@return nil
function M.show_project_links_qf()
	refresh_config_cache()

	local parser_cfg = config.get("parser")
	local need_filter_archived = not parser_cfg.context_split

	local project = project_utils.get_project_name()
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
			-- 只列“自身锚点且未失联”的任务（代码里实际渲染的标记）
			if not t or not t.locations.code or core.is_anchor_lost(t) then
				return
			end

			processed_ids[task.id] = true

			local icon = CONFIG_CACHE.show_icons and get_checkbox_icon(t) or ""

			local current_is_last_stack = {}
			for i = 1, #is_last_stack do
				current_is_last_stack[i] = is_last_stack[i]
			end
			current_is_last_stack[depth] = is_last

			local indent_prefix = tree.build_indent(depth, current_is_last_stack)
			local state_icon = get_state_icon(t)

			local text = build_task_display_text(task, t, indent_prefix, icon, state_icon)

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
		vim.notify("No linked tasks in the project", vim.log.levels.INFO)
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

---显示归档任务树到 quickfix（复习 / 再现：保留树结构，可跳转冻结锚点）
---@return nil
function M.show_archive_view()
	refresh_config_cache()

	local archive = require("todo2.store.archive")
	local roots = archive.forest()
	if not roots or #roots == 0 then
		vim.notify("No archived tasks", vim.log.levels.INFO)
		return
	end

	local qf_items = {}

	local function walk(node, depth, stack)
		local t = node.task
		local icon = CONFIG_CACHE.show_icons and get_checkbox_icon(t) or ""
		local indent_prefix = tree.build_indent(depth, stack)
		local text = build_task_display_text({ children = node.children }, t, indent_prefix, icon, "")

		local at = t.timestamps and t.timestamps.archived
		if at then
			text = text .. "  [" .. os.date("%Y-%m-%d", at) .. "]"
		end

		-- 锚点重解析状态：冷库加载时会跑一次 refresh_anchors，这里把 ok/stale/lost 显式标出
		local vstate = t.verification and t.verification.state
		if vstate == core.ANCHOR.LOST then
			text = text .. "  ⚠ lost"
		elseif vstate == core.ANCHOR.STALE then
			text = text .. "  ~ stale"
		end

		local filename, lnum
		if t.locations and t.locations.code then
			filename, lnum = t.locations.code.path, t.locations.code.line
		elseif t.locations and t.locations.todo then
			filename, lnum = t.locations.todo.path, t.locations.todo.line
		end

		qf_items[#qf_items + 1] = {
			filename = filename or "",
			lnum = lnum or 1,
			text = text,
		}

		for i, child in ipairs(node.children) do
			local ns = {}
			for k = 1, depth do
				ns[k] = stack[k]
			end
			ns[depth + 1] = (i == #node.children)
			walk(child, depth + 1, ns)
		end
	end

	for i, root in ipairs(roots) do
		walk(root, 0, {})
	end

	vim.fn.setqflist(qf_items, "r")
	vim.cmd("copen")
end

---平铺所有归档任务的冻结锚点到 quickfix（批量导航 / :cdo）
---@return nil
function M.show_archive_qf()
	refresh_config_cache()

	local archive = require("todo2.store.archive")
	local _, task_list = archive.forest()
	if not task_list or #task_list == 0 then
		vim.notify("No archived tasks", vim.log.levels.INFO)
		return
	end

	table.sort(task_list, function(a, b)
		local pa = a.locations and a.locations.code and a.locations.code.path or ""
		local pb = b.locations and b.locations.code and b.locations.code.path or ""
		if pa ~= pb then
			return pa < pb
		end
		local la = a.locations and a.locations.code and a.locations.code.line or 0
		local lb = b.locations and b.locations.code and b.locations.code.line or 0
		return la < lb
	end)

	local qf_items = {}
	for _, t in ipairs(task_list) do
		local loc = (t.locations and (t.locations.code or t.locations.todo)) or nil
		if loc and loc.path then
			local name = t.core.content or ""
			if t.core.tags and #t.core.tags > 0 then
				name = name .. tags_utils.format(t.core.tags)
			end
			local vstate = t.verification and t.verification.state
			if vstate == core.ANCHOR.LOST then
				name = name .. "  ⚠ lost"
			elseif vstate == core.ANCHOR.STALE then
				name = name .. "  ~ stale"
			end
			qf_items[#qf_items + 1] = {
				filename = loc.path,
				lnum = loc.line or 1,
				text = name,
			}
		end
	end

	if #qf_items == 0 then
		vim.notify("No archived anchors", vim.log.levels.INFO)
		return
	end

	vim.fn.setqflist(qf_items, "r")
	vim.cmd("copen")
end

return M
