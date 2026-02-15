-- lua/todo2/link/renderer.lua
--- @module todo2.link.renderer
--- @brief 代码缓冲区渲染器

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local cache = require("todo2.cache")
local status_mod = require("todo2.status")

local parser = require("todo2.core.parser")
local utils = require("todo2.core.utils")
local tag_manager = require("todo2.utils.tag_manager")
local link_mod = require("todo2.store.link")

---------------------------------------------------------------------
-- extmark 命名空间
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("todo2_code_status")

---------------------------------------------------------------------
-- 根据 ID 获取任务（从完整树）
---------------------------------------------------------------------
--- 获取任务对象，始终从完整任务树获取
--- @param path string 文件路径
--- @param id string 任务ID
--- @return table|nil 任务对象
local function get_task_from_full_tree(path, id)
	local _, _, id_to_task = parser.parse_file(path)
	return id_to_task and id_to_task[id]
end

---------------------------------------------------------------------
-- 构造行渲染状态
---------------------------------------------------------------------
local function compute_render_state(bufnr, row)
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line then
		return nil
	end

	local tag, id = format.extract_from_code_line(line)
	if not id then
		return nil
	end

	-- 从存储获取链接
	local link = link_mod.get_todo(id, { verify_line = true })
	if not link then
		return nil
	end

	-- 从完整任务树获取任务对象
	local task = get_task_from_full_tree(link.path, id)

	local render_tag = nil
	if tag_manager and tag_manager.get_tag_for_render then
		render_tag = tag_manager.get_tag_for_render(id)
	else
		render_tag = link.tag or "TODO"
	end

	-- 任务文本：优先使用解析树中的内容
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

	-- 使用统一的复选框图标
	local checkbox_icons = config.get("checkbox_icons") or { todo = "◻", done = "✓" }
	local is_completed = types.is_completed_status(link.status)
	local icon = is_completed and checkbox_icons.done or checkbox_icons.todo

	-- 进度条计算
	local progress = nil
	if task and utils and utils.get_task_progress then
		progress = utils.get_task_progress(task)
	end

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
	}
end

---------------------------------------------------------------------
-- 核心渲染函数
---------------------------------------------------------------------
function M.render_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 先清除该行的所有 extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

	local cached = nil
	if cache and cache.get_cached_render then
		cached = cache.get_cached_render(bufnr, row)
	end

	local new = compute_render_state(bufnr, row)

	if not new then
		if cached then
			if cache and cache.delete then
				cache.delete("renderer", cache.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row)
			end
		end
		return
	end

	-- diff 判断
	if
		cached
		and cached.id == new.id
		and cached.icon == new.icon
		and cached.text == new.text
		and cached.tag == new.tag
		and cached.status == new.status
		and ((not cached.components and not new.components) or (cached.components and new.components and cached.components.icon == new.components.icon and cached.components.time == new.components.time))
		and ((not cached.progress and not new.progress) or (cached.progress and new.progress and cached.progress.done == new.progress.done and cached.progress.total == new.progress.total))
		and cached.is_completed == new.is_completed
	then
		return
	end

	if cache and cache.cache_render then
		cache.cache_render(bufnr, row, new)
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

	-- 添加图标
	table.insert(virt, {
		"  " .. new.icon,
		new.is_completed and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	-- 添加任务文本
	if new.text and new.text ~= "" then
		if new.is_completed then
			table.insert(virt, { " " .. new.text, "TodoStrikethrough" })
		else
			table.insert(virt, { " " .. new.text, style.hl })
		end
	end

	-- 进度条渲染
	if new.progress then
		local ps = 5
		if config and config.get then
			ps = config.get("progress_style") or 5
		end

		if ps == 5 then
			table.insert(virt, { " " })

			local total = new.progress.total
			local len = math.max(5, math.min(20, total))
			local filled = math.floor(new.progress.percent / 100 * len)

			for _ = 1, filled do
				table.insert(virt, { "▰", "Todo2ProgressDone" })
			end
			for _ = filled + 1, len do
				table.insert(virt, { "▱", "Todo2ProgressTodo" })
			end

			table.insert(virt, {
				string.format(" %d%% (%d/%d)", new.progress.percent, new.progress.done, new.progress.total),
				"Todo2ProgressDone",
			})
		else
			local text = ps == 3 and string.format("%d%%", new.progress.percent)
				or string.format("(%d/%d)", new.progress.done, new.progress.total)
			table.insert(virt, { " " .. text, "Todo2ProgressDone" })
		end
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
-- 渲染整个缓冲区
---------------------------------------------------------------------
function M.render_code_status(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for row = 0, line_count - 1 do
		M.render_line(bufnr, row)
	end
end

---------------------------------------------------------------------
-- 缓存管理
---------------------------------------------------------------------
function M.invalidate_render_cache(bufnr)
	if not cache then
		return
	end

	if bufnr then
		if cache.clear_buffer_render_cache then
			cache.clear_buffer_render_cache(bufnr)
		end
	else
		if cache.clear_category then
			cache.clear_category("renderer")
		end
	end
end

function M.invalidate_render_cache_for_line(bufnr, row)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not cache then
		return
	end

	if cache and cache.delete then
		cache.delete("renderer", cache.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row)
	end
end

function M.invalidate_render_cache_for_lines(bufnr, rows)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not cache then
		return
	end

	for _, row in ipairs(rows) do
		if cache and cache.delete then
			cache.delete("renderer", cache.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row)
		end
	end
end

return M
