-- lua/todo2/render/code_render.lua
-- 只修改渲染函数，增加行号有效性检查

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

---------------------------------------------------------------------
-- extmark 命名空间
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("code_status")

---------------------------------------------------------------------
-- ⭐ 新增：行号有效性检查
---------------------------------------------------------------------
local function is_valid_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	return row >= 0 and row < line_count
end

---------------------------------------------------------------------
-- 获取任务的层级关系（从解析树）- 保留供其他逻辑使用
---------------------------------------------------------------------
--- 获取任务的所有子任务ID
--- @param task_id string 任务ID
--- @param id_to_task table ID到任务的映射
--- @return table 子任务ID列表
local function get_child_ids_from_parse_tree(task_id, id_to_task)
	local children = {}
	local task = id_to_task[task_id]

	if task and task.children then
		for _, child in ipairs(task.children) do
			if child.id then
				table.insert(children, child.id)
				-- 递归获取孙任务
				local grand_children = get_child_ids_from_parse_tree(child.id, id_to_task)
				vim.list_extend(children, grand_children)
			end
		end
	end

	return children
end

--- ⭐ 从解析树获取任务组所有成员
--- @param root_id string 根任务ID
--- @param id_to_task table ID到任务的映射
--- @param result table 用于收集结果的表
--- @return table 任务ID列表
local function collect_task_group_from_parse_tree(root_id, id_to_task, result)
	result = result or {}

	-- 添加自身
	if not result[root_id] then
		result[root_id] = true
	end

	-- 获取所有子任务
	local children = get_child_ids_from_parse_tree(root_id, id_to_task)
	for _, child_id in ipairs(children) do
		if not result[child_id] then
			result[child_id] = true
		end
	end

	return result
end

---------------------------------------------------------------------
-- 构造行渲染状态
---------------------------------------------------------------------
local function compute_render_state(bufnr, row)
	-- ⭐ 先检查行号有效性
	if not is_valid_line(bufnr, row) then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line then
		return nil
	end

	-- 提取代码行中的ID（只有双链任务才有）
	local tag, id = format.extract_from_code_line(line)
	if not id then
		-- ⭐ 普通任务：不渲染任何东西
		return nil
	end

	-- 从存储获取TODO链接（只有双链任务才有）
	local link = link_mod.get_todo(id, { verify_line = true })
	if not link then
		return nil
	end

	-- ⭐ 修改：从调度器获取解析树（共享缓存）
	local path = link.path
	local _, _, id_to_task = scheduler.get_parse_tree(path, false)
	local task = id_to_task and id_to_task[id]

	-- 获取渲染用的标签
	local render_tag = nil
	if tag_manager and tag_manager.get_tag_for_render then
		render_tag = tag_manager.get_tag_for_render(id)
	else
		render_tag = link.tag or "TODO"
	end

	-- 任务文本
	local raw_text = ""
	if task and utils and utils.get_task_text then
		raw_text = utils.get_task_text(task, 40)
	else
		raw_text = link.content or ""
	end

	local text = raw_text
	if format and format.clean_content then
		text = format.clean_content(raw_text, render_tag)
	end

	-- 图标
	local checkbox_icons = config.get("checkbox_icons") or { todo = "◻", done = "✓" }
	local is_completed = types.is_completed_status(link.status)
	local icon = is_completed and checkbox_icons.done or checkbox_icons.todo

	-- ⭐ 进度条：复用 core.stats 的双轨统计
	local progress = nil
	if task and task.children and #task.children > 0 then
		progress = stats.calc_group_progress(task)
		-- 只有有子任务才显示进度条
		if progress and progress.total <= 1 then
			progress = nil
		end
	end

	-- 状态组件
	local components = {}
	if status_mod and status_mod.get_display_components then
		components = status_mod.get_display_components(link)
	end

	return {
		id = id,
		tag = render_tag,
		status = link.status,
		components = components,
		icon = icon,
		text = text,
		progress = progress,
		is_completed = is_completed,
		raw_text = raw_text,
		has_children = task and task.children and #task.children > 0,
	}
end

---------------------------------------------------------------------
-- 核心渲染函数
---------------------------------------------------------------------
function M.render_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 先检查行号是否有效
	if not is_valid_line(bufnr, row) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
		return
	end

	-- 先清除该行的所有 extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

	-- 计算渲染状态
	local new = compute_render_state(bufnr, row)
	if not new then
		return
	end

	local tags = {}
	if config and config.get then
		tags = config.get("tags") or {}
	end
	local style = tags[new.tag] or tags["TODO"] or { hl = "Normal" }

	local show_status = true
	if config and config.get then
		show_status = config.get("show_status") ~= false
	end

	local virt = {}

	-- 图标
	table.insert(virt, {
		"  " .. new.icon,
		new.is_completed and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	-- 任务文本
	if new.text and new.text ~= "" then
		if new.is_completed then
			table.insert(virt, { " " .. new.text, "TodoStrikethrough" })
		else
			table.insert(virt, { " " .. new.text, style.hl })
		end
	end

	-- ⭐ 使用配置模块格式化进度条
	if new.has_children and new.progress then
		local progress_virt = config.format_progress_bar(new.progress)
		vim.list_extend(virt, progress_virt)
	end

	-- 状态组件
	if show_status and new.components then
		if new.components.icon and new.components.icon ~= "" then
			table.insert(virt, { " " .. new.components.icon, new.components.icon_highlight or "Normal" })
		end
		if new.components.time and new.components.time ~= "" then
			table.insert(virt, { " " .. new.components.time, new.components.time_highlight or "Normal" })
		end
		table.insert(virt, { " ", "Normal" })
	end

	-- 设置 extmark
	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, -1, {
		virt_text = virt,
		virt_text_pos = "inline",
		hl_mode = "combine",
		right_gravity = true,
		priority = 100,
	})
end

---------------------------------------------------------------------
-- ⭐ 核心修复：渲染整个缓冲区（增加动态行数获取）
---------------------------------------------------------------------
function M.render_code_status(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 先清除所有extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	-- ⭐ 动态获取当前行数
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- ⭐ 存储当前行数用于调试
	vim.b[bufnr].todo2_last_line_count = line_count

	-- 逐行渲染
	for row = 0, line_count - 1 do
		-- 使用pcall防止单行错误影响整体
		pcall(function()
			M.render_line(bufnr, row)
		end)
	end
end

return M
