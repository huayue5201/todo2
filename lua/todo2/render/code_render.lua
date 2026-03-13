-- lua/todo2/render/code_render.lua
-- 代码侧状态渲染：统一 snapshot，任务内容来自 TODO 文件，不使用代码注释内容

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local format = require("todo2.utils.format")
local status_mod = require("todo2.status")
local utils = require("todo2.core.utils")
local tag_manager = require("todo2.utils.tag_manager")
local link_mod = require("todo2.store.link")
local types = require("todo2.store.types")
local stats = require("todo2.core.stats")
local scheduler = require("todo2.render.scheduler")
local progress_render = require("todo2.render.progress")

---------------------------------------------------------------------
-- extmark 命名空间
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("code_status")

---------------------------------------------------------------------
-- 行号有效性检查
---------------------------------------------------------------------
local function is_valid_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	return row >= 0 and row < line_count
end

---------------------------------------------------------------------
-- 从解析树获取子任务 ID（带区域过滤）
---------------------------------------------------------------------
local function get_child_ids_from_parse_tree(task_id, id_to_task, current_region_id)
	local children = {}
	local task = id_to_task[task_id]

	if task and task.children then
		for _, child in ipairs(task.children) do
			if child.id then
				if not current_region_id or (child.region and child.region.id == current_region_id) then
					table.insert(children, child.id)
					local grand_children = get_child_ids_from_parse_tree(child.id, id_to_task, current_region_id)
					vim.list_extend(children, grand_children)
				end
			end
		end
	end

	return children
end

local function collect_task_group_from_parse_tree(root_id, id_to_task, result)
	result = result or {}

	local task = id_to_task[root_id]
	if not task then
		return result
	end

	if not result[root_id] then
		result[root_id] = true
	end

	local children = get_child_ids_from_parse_tree(root_id, id_to_task, task.region and task.region.id)
	for _, child_id in ipairs(children) do
		if not result[child_id] then
			result[child_id] = true
		end
	end

	return result
end

---------------------------------------------------------------------
-- 构造行渲染状态（统一 snapshot，任务内容来自 TODO 文件）
---------------------------------------------------------------------
local function compute_render_state(bufnr, row)
	if not is_valid_line(bufnr, row) then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line then
		return nil
	end

	-- 从代码行提取 tag + id（只用作引用，不用作内容）
	local tag, id = format.extract_from_code_line(line)
	if not id then
		return nil
	end

	-- 先拿到 link（TODO 或 CODE），这是 ID → 文件 的桥梁
	local link = link_mod.get_todo(id) or link_mod.get_code(id)
	if not link or not link.path then
		return nil
	end

	-- 解析 TODO 文件的 snapshot（唯一真相源）
	local _, _, id_to_task = scheduler.get_parse_tree(link.path, false)
	local task = id_to_task and id_to_task[id] or nil

	-- tag：优先 tag_manager，其次 link.tag，最后 "TODO"
	local render_tag = nil
	if tag_manager and tag_manager.get_tag_for_render then
		render_tag = tag_manager.get_tag_for_render(id)
	else
		render_tag = link.tag or tag or "TODO"
	end

	-- 任务内容：永远来自 TODO 任务（snapshot），绝不使用代码注释内容
	local raw_text = ""
	if task and utils and utils.get_task_text then
		raw_text = utils.get_task_text(task, 40)
	else
		-- 兼容旧数据：link.content 作为兜底
		raw_text = link.content or ""
	end

	local text = raw_text
	if format and format.clean_content then
		text = format.clean_content(raw_text, render_tag)
	end

	-- 状态：优先 snapshot 中的 _store_status，其次 link.status
	local status_val = nil
	if task and task._store_status ~= nil then
		status_val = task._store_status
	else
		status_val = link.status
	end

	local checkbox_icons = config.get("checkbox_icons") or { todo = "◻", done = "✓" }
	local is_completed = types.is_completed_status(status_val)
	local icon = is_completed and checkbox_icons.done or checkbox_icons.todo

	-- 进度：基于 snapshot 任务树
	local progress = nil
	if task and task.children and #task.children > 0 then
		progress = stats.calc_group_progress(task)
		if progress and progress.total <= 1 then
			progress = nil
		end
	end

	-- 状态组件：基于 snapshot link（scheduler 中的 _link 是深拷贝）
	local components = {}
	if status_mod and status_mod.get_display_components then
		components = status_mod.get_display_components(link)
	end

	return {
		id = id,
		tag = render_tag,
		status = status_val,
		components = components,
		icon = icon,
		text = text,
		progress = progress,
		is_completed = is_completed,
		raw_text = raw_text,
		has_children = task and task.children and #task.children > 0,
		region = task and task.region,
	}
end

---------------------------------------------------------------------
-- 渲染单行
---------------------------------------------------------------------
function M.render_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if not is_valid_line(bufnr, row) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

	local new = compute_render_state(bufnr, row)
	if not new then
		return
	end

	local tags = config.get("tags") or {}
	local style = tags[new.tag] or tags["TODO"] or { hl = "Normal" }

	local show_status = config.get("show_status") ~= false

	local virt = {}

	-- checkbox 图标
	table.insert(virt, {
		" " .. new.icon,
		new.is_completed and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	-- 任务内容（来自 TODO 文件）
	if new.text and new.text ~= "" then
		if new.is_completed then
			table.insert(virt, { " " .. new.text, "TodoStrikethrough" })
		else
			table.insert(virt, { " " .. new.text, style.hl })
		end
	end

	-- 进度条
	if new.has_children and new.progress then
		local progress_virt = progress_render.build(new.progress)
		vim.list_extend(virt, progress_virt)
	end

	-- 状态组件（icon + time）
	if show_status and new.components then
		if new.components.icon and new.components.icon ~= "" then
			table.insert(virt, { " " .. new.components.icon, new.components.icon_highlight or "Normal" })
		end
		if new.components.time and new.components.time ~= "" then
			table.insert(virt, { " " .. new.components.time, new.components.time_highlight or "Normal" })
		end
		table.insert(virt, { " ", "Normal" })
	end

	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, -1, {
		virt_text = virt,
		virt_text_pos = "inline",
		hl_mode = "combine",
		right_gravity = true,
		priority = 100,
	})
end

---------------------------------------------------------------------
-- ⭐ 按任务 ID 增量渲染代码行
---------------------------------------------------------------------
function M.render_task_id(task_id)
	if not task_id or task_id == "" then
		return
	end

	local code_link = link_mod.get_code(task_id)
	if not code_link or not code_link.path or not code_link.line then
		return
	end

	local target_bufnr = nil
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_valid(b)
			and vim.api.nvim_buf_is_loaded(b)
			and vim.api.nvim_buf_get_name(b) == code_link.path
		then
			target_bufnr = b
			break
		end
	end

	if not target_bufnr then
		return
	end

	local row = code_link.line - 1
	M.render_line(target_bufnr, row)
end

---------------------------------------------------------------------
-- 全量渲染
---------------------------------------------------------------------
function M.render_code_status(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	vim.b[bufnr].todo2_last_line_count = line_count

	for row = 0, line_count - 1 do
		pcall(function()
			M.render_line(bufnr, row)
		end)
	end
end

return M
