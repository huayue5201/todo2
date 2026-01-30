-- lua/todo2/link/renderer.lua
--- @module todo2.link.renderer
--- @brief 基于 parser 的专业级渲染器（状态 / 文本 / 进度全部来自任务树）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")
local highlight = require("todo2.link.highlight") -- 新增：导入高亮模块
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
-- ⭐ 行级渲染缓存（只缓存渲染状态，不缓存任务数据）
---------------------------------------------------------------------
local render_cache = {}

local function ensure_cache(bufnr)
	if not render_cache[bufnr] then
		render_cache[bufnr] = {}
	end
	return render_cache[bufnr]
end

---------------------------------------------------------------------
-- ⭐ 移除独立的任务树缓存，完全依赖 Parser 的统一缓存
---------------------------------------------------------------------

---------------------------------------------------------------------
-- ⭐ 构造行渲染状态（基于 parser + store）
---------------------------------------------------------------------
local function compute_render_state(bufnr, row)
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line then
		return nil
	end

	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		return nil
	end

	-- 获取 TODO 链接（路径 + 行号）
	local store = module.get("store")
	local link = store.get_todo_link(id, { force_relocate = true })
	if not link then
		return nil
	end

	-- ⭐ 直接从 Parser 的统一缓存获取任务
	local parser = module.get("core.parser")
	local task = parser.get_task_by_id(link.path, id)
	if not task then
		return nil
	end

	-- 状态 / 文本 / 进度
	local icon, is_done = utils.get_task_status(task)
	local text = utils.get_task_text(task, 40)
	local progress = utils.get_task_progress(task)

	-- 获取状态信息（新增）
	local status = link.status or "normal"
	local status_display = status_mod.get_status_display(link)
	local status_highlight = status_mod.get_highlight(status) -- ✅ 修正为 get_highlight

	return {
		id = id,
		tag = tag,
		status = status,
		status_display = status_display,
		status_highlight = status_highlight,
		icon = icon,
		text = text,
		progress = progress,
		is_done = is_done,
	}
end

---------------------------------------------------------------------
-- ⭐ 渲染单行（增量 diff）
---------------------------------------------------------------------
function M.render_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local cache = ensure_cache(bufnr)
	local new = compute_render_state(bufnr, row)

	-- 无 TAG → 清除
	if not new then
		if cache[row] then
			cache[row] = nil
			vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
		end
		return
	end

	-- diff：如果内容一致 → 不重绘
	local old = cache[row]
	if
		old
		and old.id == new.id
		and old.icon == new.icon
		and old.text == new.text
		and (
			(not old.progress and not new.progress)
			or (
				old.progress
				and new.progress
				and old.progress.done == new.progress.done
				and old.progress.total == new.progress.total
			)
		)
	then
		return
	end

	-- 更新缓存
	cache[row] = new

	-- 清除旧 extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

	-- 获取 TAG 样式
	local link_mod = module.get("link")
	local cfg = link_mod.get_render_config()
	local style = cfg.tags and cfg.tags[new.tag] or cfg.tags["TODO"]

	-- 构造虚拟文本
	local virt = {}

	-- 状态图标
	table.insert(virt, {
		new.icon,
		new.is_done and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	-- 文本
	if new.text and new.text ~= "" then
		table.insert(virt, { " " .. new.text, style.hl })
	end

	-- 进度
	if new.progress then
		local ps = cfg.progress_style or 1

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

	-- 1. 状态和时间显示（新增）
	if new.status_display and new.status_display ~= "" then
		table.insert(virt, { new.status_display, new.status_highlight })
		table.insert(virt, { " ", "Normal" }) -- 分隔符
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

	local cache = ensure_cache(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local max_row = #lines - 1

	-- 清理缓存中已不存在的行
	for row in pairs(cache) do
		if row > max_row then
			cache[row] = nil
			vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
		end
	end

	-- 渲染所有行
	for row = 0, max_row do
		M.render_line(bufnr, row)
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：清理渲染缓存
---------------------------------------------------------------------
function M.invalidate_render_cache(bufnr)
	if bufnr then
		render_cache[bufnr] = {}
	else
		render_cache = {}
	end
end

return M
