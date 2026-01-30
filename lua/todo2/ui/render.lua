-- lua/todo2/render.lua
--- @module todo2.render
--- @brief 专业版：只负责渲染，不负责解析任务树

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 命名空间（用于 extmark）
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("todo2_render")

---------------------------------------------------------------------
-- 工具函数：安全获取行文本
---------------------------------------------------------------------
local function get_line(bufnr, row)
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	return line or ""
end

---------------------------------------------------------------------
-- 工具函数：从行中提取任务ID
---------------------------------------------------------------------
local function extract_task_id_from_line(line)
	if not line then
		return nil
	end

	-- 支持格式: [ ] 任务内容 {#id}
	return line:match("{#(%w+)}")
end

---------------------------------------------------------------------
-- 渲染单个任务（添加边界检查 + 状态时间戳）
---------------------------------------------------------------------
function M.render_task(bufnr, task)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local row = task.line_num - 1
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- ⭐ 修复1：检查行号是否在有效范围内
	if row < 0 or row >= line_count then
		return -- 行号无效，跳过渲染
	end

	local line = get_line(bufnr, row)
	local line_len = #line

	-----------------------------------------------------------------
	-- 删除线（优先级高）
	-----------------------------------------------------------------
	if task.is_done then
		-- ⭐ 修复2：确保 end_row 不超出范围
		local end_row = math.min(row, line_count - 1)
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
			end_row = end_row,
			end_col = line_len,
			hl_group = "TodoStrikethrough",
			hl_mode = "combine",
			priority = 200,
		})

		-- 灰色高亮（优先级略低）
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
			end_row = end_row,
			end_col = line_len,
			hl_group = "TodoCompleted",
			hl_mode = "combine",
			priority = 190,
		})
	end

	-----------------------------------------------------------------
	-- 构建行尾虚拟文本：状态 + 时间戳 + 子任务统计
	-----------------------------------------------------------------
	local virt_text_parts = {}

	-- 1. 子任务统计（如果存在）
	if task.children and #task.children > 0 and task.stats then
		local done = task.stats.done or 0
		local total = task.stats.total or #task.children

		-- ⭐ 只有在有子任务时才显示统计
		if total > 0 then
			-- 如果已有内容，添加分隔符
			if #virt_text_parts > 0 then
				table.insert(virt_text_parts, { " ", "Normal" })
			end
			table.insert(virt_text_parts, {
				string.format("(%d/%d)", done, total),
				"Comment",
			})
		end
	end

	-- 2. 提取任务ID并获取状态信息
	local task_id = task.id or extract_task_id_from_line(line)

	if task_id then
		-- 获取store模块
		local store = module.get("store")
		if store then
			-- 获取TODO链接信息（不强制重新定位，使用缓存）
			local link = store.get_todo_link(task_id)
			if link then
				-- 获取状态模块
				local status_mod = require("todo2.status")
				if status_mod then
					-- 获取状态显示（图标+时间戳）
					local status_display = status_mod.get_status_display(link)
					local status_highlight = status_mod.get_highlight(link.status or "normal")

					if status_display and status_display ~= "" then
						-- 添加状态显示
						table.insert(virt_text_parts, { status_display, status_highlight })
					end
				end
			end
		end
	end

	-- 3. 设置虚拟文本extmark（如果有内容）
	if #virt_text_parts > 0 then
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, -1, {
			virt_text = virt_text_parts,
			virt_text_pos = "eol",
			hl_mode = "combine",
			right_gravity = false,
			priority = 300, -- 优先级比删除线低，但比灰色高亮高
		})
	end
end

---------------------------------------------------------------------
-- 递归渲染任务树
---------------------------------------------------------------------
local function render_tree(bufnr, task)
	M.render_task(bufnr, task)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child)
	end
end

---------------------------------------------------------------------
-- ⭐ 增强版：自动从 parser 缓存获取任务树，并强制刷新缓存
---------------------------------------------------------------------
function M.render_all(bufnr, force_parse)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	-- 清除旧渲染（幂等）
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	-- 通过模块管理器获取 parser 模块
	local parser = module.get("core.parser")
	local stats = module.get("core.stats")

	-- 获取文件路径
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return 0
	end

	-- 根据参数决定是否强制重新解析
	local tasks, roots
	if force_parse then
		-- 强制重新解析文件（清除缓存）
		tasks, roots = parser.parse_file(path, true)
	else
		-- 使用 parser 缓存
		tasks, roots = parser.parse_file(path)
	end

	-- roots 可能为 nil（空文件 / 无任务）
	roots = roots or {}

	-- ⭐ 修复3：检查 tasks 是否为 nil
	if not tasks then
		return 0
	end

	-- ⭐ 修复4：计算任务统计信息
	if stats and stats.calculate_all_stats then
		stats.calculate_all_stats(tasks)
	end

	-- 渲染所有根任务
	for _, task in ipairs(roots) do
		render_tree(bufnr, task)
	end

	-- 返回渲染的任务数量
	local total_rendered = 0
	for _, _ in pairs(tasks) do
		total_rendered = total_rendered + 1
	end

	return total_rendered
end

---------------------------------------------------------------------
-- 清理命名空间缓存（可选）
---------------------------------------------------------------------
function M.clear_cache()
	-- 清理命名空间
	local bufnrs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufnrs) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		end
	end
end

return M
