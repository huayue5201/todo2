-- lua/todo2/link/renderer.lua
local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 配置模块
---------------------------------------------------------------------
local config = require("todo2.config")

-- ⭐⭐ 修改点1：导入统一的格式模块
local format = require("todo2.utils.format")

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
-- ⭐ 统一缓存管理器
---------------------------------------------------------------------
local cache = require("todo2.cache")

---------------------------------------------------------------------
-- ⭐ 标签管理器（新增）
---------------------------------------------------------------------
local tag_manager = module.get("todo2.utils.tag_manager")

---------------------------------------------------------------------
-- ⭐ 构造行渲染状态（基于 parser + store + tag_manager）
---------------------------------------------------------------------
local function compute_render_state(bufnr, row)
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line then
		return nil
	end

	-- ⭐⭐ 修改点2：使用 format.extract_from_code_line 解析代码行
	local tag, id = format.extract_from_code_line(line)
	if not id then
		return nil
	end

	-- ⭐⭐ 关键修复：使用正确的模块获取 TODO 链接
	local link_mod = module.get("store.link")
	if not link_mod then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return nil
	end

	-- 获取 TODO 链接（路径 + 行号）
	local link = link_mod.get_todo(id, { verify_line = true })
	if not link then
		return nil
	end

	-- ⭐ 直接从 Parser 的统一缓存获取任务
	local parser = module.get("core.parser")
	local task = nil
	if parser and parser.get_task_by_id then
		task = parser.get_task_by_id(link.path, id)
	end

	if not task then
		return nil
	end

	-- ⭐ 修改：使用tag_manager获取标签
	local tag = nil
	if tag_manager and tag_manager.get_tag_for_render then
		tag = tag_manager.get_tag_for_render(id)
	else
		tag = link.tag or "TODO"
	end

	-- ⭐ 修改：获取原始文本后使用tag_manager清理标签前缀
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

	local icon = "○"
	local is_done = false
	if utils and utils.get_task_status then
		icon, is_done = utils.get_task_status(task)
	else
		is_done = task.is_done or false
		icon = is_done and "✓" or "○"
	end

	local progress = nil
	if utils and utils.get_task_progress then
		progress = utils.get_task_progress(task)
	end

	-- ⭐ 使用新的分离组件 API 获取状态和时间戳
	local status = link.status or "normal"
	local components = {}
	if status_mod and status_mod.get_display_components then
		components = status_mod.get_display_components(link)
	end

	return {
		id = id,
		tag = tag, -- ⭐ 使用统一标签
		status = status,
		components = components,
		icon = icon,
		text = text, -- 使用清理后的文本
		progress = progress,
		is_done = is_done,
		raw_text = raw_text, -- 保存原始文本用于比较
	}
end

---------------------------------------------------------------------
-- ⭐ 渲染单行（增量 diff）
---------------------------------------------------------------------
function M.render_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- ⭐ 获取缓存
	local cached = nil
	if cache and cache.get_cached_render then
		cached = cache.get_cached_render(bufnr, row)
	end

	local new = compute_render_state(bufnr, row)

	-- 无 TAG → 清除
	if not new then
		if cached then
			if cache and cache.delete then
				cache.delete("renderer", cache.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row)
			end
			vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
		end
		return
	end

	-- diff：如果内容一致 → 不重绘（包含状态和时间戳比较）
	-- ⭐ 修改：比较清理后的文本和标签
	if
		cached
		and cached.id == new.id
		and cached.icon == new.icon
		and cached.text == new.text
		and cached.tag == new.tag -- 比较标签
		and cached.status == new.status
		-- ⭐ 修改：比较分离的组件
		and ((not cached.components and not new.components) or (cached.components and new.components and cached.components.icon == new.components.icon and cached.components.time == new.components.time))
		and (
			(not cached.progress and not new.progress)
			or (
				cached.progress
				and new.progress
				and cached.progress.done == new.progress.done
				and cached.progress.total == new.progress.total
			)
		)
	then
		return
	end

	-- 更新缓存
	if cache and cache.cache_render then
		cache.cache_render(bufnr, row, new)
	end

	-- 清除旧 extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

	-- ⭐ 修改：从新配置模块获取标签样式
	local tags = {}
	if config and config.get then
		tags = config.get("tags") or {}
	end

	local style = tags[new.tag] or tags["TODO"] or { hl = "Normal" }

	-- ⭐ 修改：从配置获取是否显示状态
	local show_status = true
	if config and config.get then
		show_status = config.get("show_status") ~= false
	end

	-- 构造虚拟文本
	local virt = {}

	-- 任务状态图标
	table.insert(virt, {
		new.icon,
		new.is_done and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	-- 任务文本（已经清理过标签前缀）
	if new.text and new.text ~= "" then
		table.insert(virt, { " " .. new.text, style.hl })
	end

	-- 进度
	if new.progress then
		-- ⭐ 修改：从配置获取进度条样式
		local ps = 5
		if config and config.get then
			ps = config.get("progress_style") or 5
		end

		if ps == 5 then
			-- 进度条模式
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
			-- 数字 / 百分比
			local text = ps == 3 and string.format("%d%%", new.progress.percent)
				or string.format("(%d/%d)", new.progress.done, new.progress.total)

			table.insert(virt, { " " .. text, "Todo2ProgressDone" })
		end
	end

	-- ⭐ 修改：分离渲染状态图标和时间戳（根据配置决定是否显示）
	if show_status and new.components then
		-- 状态图标（任务状态）
		if new.components.icon and new.components.icon ~= "" then
			table.insert(virt, { " " .. new.components.icon, new.components.icon_highlight or "Normal" })
		end

		-- 时间戳
		if new.components.time and new.components.time ~= "" then
			-- 时间戳前加一个空格分隔
			table.insert(virt, { " " .. new.components.time, new.components.time_highlight or "Normal" })
		end

		-- 在最后添加一个空格作为分隔符（可选）
		table.insert(virt, { " ", "Normal" })
	end

	-- 设置 extmark
	vim.api.nvim_buf_set_extmark(bufnr, ns, row, -1, {
		virt_text = virt,
		virt_text_pos = "eol",
		hl_mode = "combine",
		right_gravity = false,
		priority = 100,
	})
end

---------------------------------------------------------------------
-- ⭐ 全量渲染（内部仍是增量 diff）
---------------------------------------------------------------------
function M.render_code_status(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- 渲染所有行
	for row = 0, line_count - 1 do
		M.render_line(bufnr, row)
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：清理渲染缓存
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

---------------------------------------------------------------------
-- ⭐ 新增：清理单行渲染缓存
---------------------------------------------------------------------
function M.invalidate_render_cache_for_line(bufnr, row)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not cache then
		return
	end

	-- 清理单行缓存
	if cache.delete then
		cache.delete("renderer", cache.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row)
	end

	-- 清除这行的extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
end

---------------------------------------------------------------------
-- ⭐ 新增：批量清理行渲染缓存
---------------------------------------------------------------------
function M.invalidate_render_cache_for_lines(bufnr, rows)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not cache then
		return
	end

	-- 清理缓存和extmark
	for _, row in ipairs(rows) do
		if cache and cache.delete then
			cache.delete("renderer", cache.KEYS.RENDERER_BUFFER .. bufnr .. ":" .. row)
		end
		vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
	end
end

return M
