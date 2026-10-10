-- lua/todo2/render/code_render.lua
-- 代码文件渲染：基于存储，在代码行旁显示任务状态

local M = {}

local format = require("todo2.utils.format")
local file = require("todo2.utils.file")
local core = require("todo2.store.task.core")
local index = require("todo2.store.index")
local task_virt = require("todo2.render.task_virt")
local config = require("todo2.config")
local constants = require("todo2.constants")
local checkbox = require("todo2.render.checkbox")
local status_domain = require("todo2.core.status")
local tags_utils = require("todo2.utils.tags")
local hierarchy = require("todo2.store.task.hierarchy")

local NS = constants.ns("code_render")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 根据当前窗口宽度计算任务内容的动态截断长度.
--- 以窗口宽度的 40% 为基准，并限制在 [20, 60] 区间内。
---@return number 截断长度（字符数）
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
	if len > 60 then
		len = 60
	end
	return len
end

---------------------------------------------------------------------
-- sign 图标
---------------------------------------------------------------------

--- 取任务在 sign 列（statuscolumn 的 %s）显示的图标 + 高亮。
--- 与循环状态系统统一：使用状态定义里的 icon，而不是复选框图标。
--- 图标里可能带尾随空格（如 cycle 定义），sign 列窄，需去掉。
---@param status string
---@param fallback_icon string 状态无定义时的回退图标
---@param fallback_hl string 回退高亮组
---@return string icon, string hl
local function sign_for(status, fallback_icon, fallback_hl)
	local def = status_domain.get_definition(status)
	local icon = def and vim.trim(def.icon or "") or ""
	if icon == "" then
		return fallback_icon, fallback_hl
	end
	return icon, status_domain.get_hl_group(status) or fallback_hl
end

---------------------------------------------------------------------
-- 单任务虚拟文本构建
---------------------------------------------------------------------

--- 构建单个任务的虚拟文本块（不含行首箭头）。
---@param task table 任务对象
---@return table[] virt 虚拟文本块
---@return string sign_icon sign 列图标
---@return string sign_hl sign 列高亮组
local function build_task_virt(task)
	local virt = {}

	-- 是否完成（含归档，用于内容删除线）
	local content_hl = status_domain.get_content_hl(task.core.status)

	-- 复选框图标（与 TODO 文件 / 抽屉一致，共用 checkbox 模块）
	local icon, icon_hl = checkbox.get(task.core.status)
	table.insert(virt, {
		" " .. icon,
		icon_hl,
	})

	-- 任务内容
	local content = task.core.content or ""
	if content ~= "" then
		local truncate_len = get_dynamic_truncate_length()
		local text = format.truncate and format.truncate(content, truncate_len) or content
		table.insert(virt, { " " .. text, content_hl })
	end

	-- 标签（#tag）：内容之后、进度/状态之前
	if task.core.tags and #task.core.tags > 0 then
		table.insert(virt, { tags_utils.format(task.core.tags), "TodoTag" })
	end

	-- 子任务进度条 + 状态图标（统一由 task_virt 构建）
	task_virt.build_progress(task.id, virt)
	task_virt.build_status(task, virt)

	-- sign 列（statuscolumn 的 %s）用循环状态图标，与状态系统统一
	local sign_icon, sign_hl = sign_for(task.core.status, icon, icon_hl)

	return virt, sign_icon, sign_hl
end

---------------------------------------------------------------------
-- 同一代码行的分组渲染
---------------------------------------------------------------------

local ARROW_ABOVE = "󱞡 "
local ARROW_BELOW = "󱞽 "

--- 同组内后代任务的缩进前缀（根为空）。
---@param depth number
---@return string
local function tree_prefix(depth)
	if depth <= 0 then
		return ""
	end
	return string.rep("  ", depth - 1) .. "└ "
end

--- 给虚拟文本块加上行首箭头 / 层级缩进，构成一条完整的虚拟行。
---@param virt table[]
---@param arrow string
---@param depth number
---@return table[]
local function with_arrow(virt, arrow, depth)
	local line = { { arrow, "TodoCodeRenderArrow" } }
	if depth and depth > 0 then
		table.insert(line, { tree_prefix(depth), "TodoCodeRenderTree" })
	end
	vim.list_extend(line, virt)
	return line
end

--- 把「折叠提示」追加到虚拟文本块末尾。
---@param virt table[]
---@param more number 被折叠隐藏的任务数
local function append_more(virt, more)
	if more > 0 then
		table.insert(virt, { "  +" .. more, "TodoCodeRenderMore" })
	end
end

--- 渲染同一代码行上的所有任务。
--- 一次只写一个 extmark，避免同一行多次渲染互相清除。
--- above/below 模式堆叠虚拟行；超过 max_lines 时折叠为「代表 + +N」。
--- inline 模式用分隔符连接；同样按 max_lines 折叠。
---@param bufnr number 缓冲区号
---@param row number 行号（0-based）
---@param tasks table[] 该行关联的任务列表（至少一个）
function M.render_group(bufnr, row, tasks)
	if not tasks or #tasks == 0 then
		return
	end

	-- 清除旧标记（整行）
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	-- 按层级排序：祖先（组）在前，后代缩进跟随
	local ordered = hierarchy.build(tasks)
	local total = #ordered
	local rep = ordered[1].task

	local max_lines = config.get("code_render.max_lines") or 3
	if max_lines < 1 then
		max_lines = 1
	end
	local collapsed = total > max_lines

	local rep_virt, sign_icon, sign_hl = build_task_virt(rep)
	local position = config.get("code_render.position")

	-- above 在首行无法挂载（没有前一行），回退为行内渲染
	local use_virt_lines = (position == "above" and row > 0) or position == "below"

	if use_virt_lines then
		local above = position == "above"
		local arrow = above and ARROW_ABOVE or ARROW_BELOW

		local lines = {}
		if collapsed then
			local line = with_arrow(rep_virt, arrow, 0)
			append_more(line, total - 1)
			table.insert(lines, line)
		else
			for _, entry in ipairs(ordered) do
				local virt = build_task_virt(entry.task)
				table.insert(lines, with_arrow(virt, arrow, entry.depth))
			end
		end

		pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
			virt_lines = lines,
			virt_lines_above = above,
			sign_text = sign_icon,
			sign_hl_group = sign_hl,
			hl_mode = "combine",
			priority = 50,
		})
	else
		-- 行内渲染：无箭头，多任务用分隔符连接，后代加缩进前缀
		local virt = {}
		if collapsed then
			vim.list_extend(virt, rep_virt)
			append_more(virt, total - 1)
		else
			for i, entry in ipairs(ordered) do
				if i > 1 then
					table.insert(virt, { " │ ", "TodoCodeRenderArrow" })
				end
				if entry.depth > 0 then
					table.insert(virt, { tree_prefix(entry.depth), "TodoCodeRenderTree" })
				end
				local one = build_task_virt(entry.task)
				vim.list_extend(virt, one)
			end
		end

		pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, -1, {
			virt_text = virt,
			virt_text_pos = "inline",
			sign_text = sign_icon,
			sign_hl_group = sign_hl,
			hl_mode = "combine",
			right_gravity = true,
			priority = 50,
		})
	end
end

---------------------------------------------------------------------
-- 全量 / 增量渲染
---------------------------------------------------------------------

--- 收集「行号(1-based) → 任务列表」，跳过失联与越界行。
---@param bufnr number
---@param tasks table[]
---@return table<number, table[]>
local function group_by_line(bufnr, tasks)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local by_line = {}
	for _, task in ipairs(tasks) do
		if task.locations.code and not core.is_anchor_lost(task) then
			local line = task.locations.code.line
			if line >= 1 and line <= line_count then
				by_line[line] = by_line[line] or {}
				table.insert(by_line[line], task)
			end
		end
	end
	return by_line
end

--- 对指定缓冲区进行全量任务渲染.
--- 先清空命名空间下的所有标记，再按代码行分组、逐行渲染该行关联的所有任务。
---@param bufnr number 缓冲区号
---@return number 实际渲染的任务数量
function M.render_file(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	local path = vim.api.nvim_buf_get_name(bufnr)
	local tasks = index.find_code_links_by_file(path)
	local by_line = group_by_line(bufnr, tasks)

	local rendered = 0
	for line, group in pairs(by_line) do
		M.render_group(bufnr, line - 1, group)
		rendered = rendered + #group
	end

	return rendered
end

--- 对指定缓冲区进行增量渲染，仅处理发生变化的任务及被删除的位置.
--- 同一行只要有任务变化/被删除，就对该行的所有任务整组重绘，避免互相擦除。
---@param bufnr number 缓冲区号
---@param changed_ids string[]|nil 发生变化的任务 ID 列表
---@param deleted_locations table[]|nil 被删除的位置列表，每项含 path、line 字段
---@return number 实际渲染的任务数量
function M.render_changed(bufnr, changed_ids, deleted_locations)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	local norm_path = file.normalize_path(path)
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	local id_set = {}
	for _, id in ipairs(changed_ids or {}) do
		id_set[id] = true
	end

	local tasks = index.find_code_links_by_file(path)

	-- 失联标记的旧 extmark 会随文本移动、位置不可预知，无法按行增量清除；
	-- 一旦涉及失联就整体重绘（render_file 会跳过失联标记）。
	for _, task in ipairs(tasks) do
		if id_set[task.id] and core.is_anchor_lost(task) then
			return M.render_file(bufnr)
		end
	end

	local by_line = group_by_line(bufnr, tasks)

	-- 需要重绘的行：被删除/移走的位置 ∪ 变更任务当前所在行
	local rows = {}
	if deleted_locations and #deleted_locations > 0 then
		for _, loc in ipairs(deleted_locations) do
			if file.normalize_path(loc.path) == norm_path then
				vim.api.nvim_buf_clear_namespace(bufnr, NS, loc.line - 1, loc.line)
				rows[loc.line] = true
			end
		end
	end

	for _, task in ipairs(tasks) do
		if id_set[task.id] and task.locations.code and not core.is_anchor_lost(task) then
			local line = task.locations.code.line
			if line >= 1 and line <= line_count then
				rows[line] = true
			end
		end
	end

	-- 逐行整组重绘：同一行的所有任务一起渲染，避免互相擦除
	local rendered = 0
	for line in pairs(rows) do
		local group = by_line[line]
		if group and #group > 0 then
			M.render_group(bufnr, line - 1, group)
			rendered = rendered + #group
		end
	end

	return rendered
end

---------------------------------------------------------------------
-- 清理接口
---------------------------------------------------------------------

--- 清除指定缓冲区中由本模块写入的所有渲染标记.
---@param bufnr number 缓冲区号
function M.clear(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

return M
