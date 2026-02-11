--- File: /Users/lijia/todo2/lua/todo2/link/renderer.lua ---
-- lua/todo2/link/renderer.lua
local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")
local config = require("todo2.config")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 工具模块
---------------------------------------------------------------------
local utils = module.get("core.utils")
local status_mod = require("todo2.status")

---------------------------------------------------------------------
-- extmark 命名空间
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("todo2_code_status")

---------------------------------------------------------------------
-- 缓存管理器
---------------------------------------------------------------------
local cache = require("todo2.cache")
local tag_manager = module.get("todo2.utils.tag_manager")

---------------------------------------------------------------------
-- 构造行渲染状态（基于 store.link）
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

	local link_mod = module.get("store.link")
	if not link_mod then
		return nil
	end

	-- 从存储获取权威状态
	local link = link_mod.get_todo(id, { verify_line = true })
	if not link then
		return nil
	end

	local parser = module.get("core.parser")
	local task = nil
	if parser and parser.get_task_by_id then
		task = parser.get_task_by_id(link.path, id)
	end

	if not task then
		return nil
	end

	local tag = nil
	if tag_manager and tag_manager.get_tag_for_render then
		tag = tag_manager.get_tag_for_render(id)
	else
		tag = link.tag or "TODO"
	end

	local raw_text = ""
	if utils and utils.get_task_text then
		raw_text = utils.get_task_text(task, 40)
	else
		raw_text = task.content or ""
	end

	local text = raw_text
	if tag_manager and tag_manager.clean_content then
		text = tag_manager.clean_content(raw_text, tag)
	end

	-- 从存储状态判断是否完成
	local is_completed = types.is_completed_status(link.status)
	local icon = is_completed and "✓" or "◻"

	local progress = nil
	if utils and utils.get_task_progress then
		progress = utils.get_task_progress(task)
	end

	local components = {}
	if status_mod and status_mod.get_display_components then
		components = status_mod.get_display_components(link)
	end

	return {
		id = id,
		tag = tag,
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
-- 渲染单行（增量 diff）
---------------------------------------------------------------------
function M.render_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

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
			vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
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

	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

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

	table.insert(virt, {
		new.icon,
		new.is_completed and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	if new.text and new.text ~= "" then
		table.insert(virt, { " " .. new.text, style.hl })
	end

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

	if show_status and new.components then
		if new.components.icon and new.components.icon ~= "" then
			table.insert(virt, { " " .. new.components.icon, new.components.icon_highlight or "Normal" })
		end
		if new.components.time and new.components.time ~= "" then
			table.insert(virt, { " " .. new.components.time, new.components.time_highlight or "Normal" })
		end
		table.insert(virt, { " ", "Normal" })
	end

	vim.api.nvim_buf_set_extmark(bufnr, ns, row, -1, {
		virt_text = virt,
		virt_text_pos = "eol",
		hl_mode = "combine",
		right_gravity = false,
		priority = 100,
	})
end

---------------------------------------------------------------------
-- 全量渲染
---------------------------------------------------------------------
function M.render_code_status(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for row = 0, line_count - 1 do
		M.render_line(bufnr, row)
	end
end

---------------------------------------------------------------------
-- 清理渲染缓存
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
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
end

function M.invalidate_render_cache_for_lines(bufnr, rows)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not cache then
		return
	end

	for _, row in ipairs(rows) do
		if cache and cache.delete then
			cache.delete("renderer", cache.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row)
		end
		vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
	end
end

return M
