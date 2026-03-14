-- lua/todo2/render/code_render.lua
-- 纯功能平移：使用新接口获取任务数据

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local format = require("todo2.utils.format")
local status_mod = require("todo2.status")
local core = require("todo2.store.link.core") -- 改为 core
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
-- 动态截断长度：根据窗口宽度
---------------------------------------------------------------------
local function get_dynamic_truncate_length()
	local win = vim.api.nvim_get_current_win()
	if not win or win == 0 then
		return 40
	end

	local width = vim.api.nvim_win_get_width(win)
	if not width or width <= 0 then
		return 40
	end

	local len = math.floor(width * 0.4)
	if len < 20 then
		len = 20
	end

	return len
end

---------------------------------------------------------------------
-- 从任务构造兼容的 link 对象（用于 status_mod）
---------------------------------------------------------------------
local function task_to_link(task)
	if not task then
		return nil
	end

	return {
		id = task.id,
		status = task.core.status,
		previous_status = task.core.previous_status,
		created_at = task.timestamps.created,
		updated_at = task.timestamps.updated,
		completed_at = task.timestamps.completed,
		archived_at = task.timestamps.archived,
		archived_reason = task.timestamps.archived_reason,
	}
end

---------------------------------------------------------------------
-- 构造行渲染状态
---------------------------------------------------------------------
local function compute_render_state(bufnr, row)
	if not is_valid_line(bufnr, row) then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line then
		return nil
	end

	-- 从代码行提取 tag + id
	local tag, id = format.extract_from_code_line(line)
	if not id then
		return nil
	end

	-- 从内部格式获取任务
	local task = core.get_task(id)
	if not task then
		return nil
	end

	---------------------------------------------------------------------
	-- 内容：优先 CODE 位置的 content
	---------------------------------------------------------------------
	local raw_text = nil
	if task.core.content and task.core.content ~= "" then
		raw_text = task.core.content
	else
		raw_text = ""
	end

	local truncate_len = get_dynamic_truncate_length()
	local text = raw_text
	if format and format.truncate then
		text = format.truncate(raw_text, truncate_len)
	end

	---------------------------------------------------------------------
	-- 状态：从 core 获取
	---------------------------------------------------------------------
	local status_val = task.core.status or types.STATUS.NORMAL

	---------------------------------------------------------------------
	-- tag：优先从 tags 数组，其次代码行 tag
	---------------------------------------------------------------------
	local render_tag = task.core.tags[1] or tag or "TODO"

	---------------------------------------------------------------------
	-- snapshot：用于结构信息
	---------------------------------------------------------------------
	local snapshot_task = nil
	if task.locations.todo and task.locations.todo.path then
		local _, _, id_to_task = scheduler.get_parse_tree(task.locations.todo.path, false)
		snapshot_task = id_to_task and id_to_task[id] or nil
	end

	---------------------------------------------------------------------
	-- checkbox 图标
	---------------------------------------------------------------------
	local checkbox_icons = config.get("checkbox_icons") or { todo = "◻", done = "✓" }
	local is_completed = types.is_completed_status(status_val)
	local icon = is_completed and checkbox_icons.done or checkbox_icons.todo

	---------------------------------------------------------------------
	-- 进度：基于 snapshot 结构
	---------------------------------------------------------------------
	local progress = nil
	if snapshot_task and snapshot_task.children and #snapshot_task.children > 0 then
		progress = stats.calc_group_progress(snapshot_task)
		if progress and progress.total <= 1 then
			progress = nil
		end
	end

	---------------------------------------------------------------------
	-- 状态组件：基于任务时间戳
	---------------------------------------------------------------------
	local components = {}
	if status_mod and status_mod.get_display_components then
		components = status_mod.get_display_components(task_to_link(task))
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
		has_children = snapshot_task and snapshot_task.children and #snapshot_task.children > 0,
		region = snapshot_task and snapshot_task.region,
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

	-- 任务内容
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

	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, -1, {
		virt_text = virt,
		virt_text_pos = "inline",
		hl_mode = "combine",
		right_gravity = true,
		priority = 100,
	})
end

---------------------------------------------------------------------
-- 按任务 ID 增量渲染代码行
---------------------------------------------------------------------
function M.render_task_id(task_id)
	if not task_id or task_id == "" then
		return
	end

	local task = core.get_task(task_id)
	if not task or not task.locations.code or not task.locations.code.path or not task.locations.code.line then
		return
	end

	local target_bufnr = nil
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_valid(b)
			and vim.api.nvim_buf_is_loaded(b)
			and vim.api.nvim_buf_get_name(b) == task.locations.code.path
		then
			target_bufnr = b
			break
		end
	end

	if not target_bufnr then
		return
	end

	local row = task.locations.code.line - 1
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
