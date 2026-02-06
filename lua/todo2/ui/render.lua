-- lua/todo2/ui/render.lua
--- @module todo2.render
--- @brief 专业版：遵循核心权威树的渲染模块

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

-- ⭐⭐ 修改点1：直接导入 format 模块
local format = require("todo2.utils.format")

---------------------------------------------------------------------
-- 命名空间（用于 extmark）
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("todo2_render")

---------------------------------------------------------------------
-- 工具函数：安全获取行文本
---------------------------------------------------------------------
local function get_line(bufnr, row)
	-- 添加边界检查
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if row < 0 or row >= line_count then
		return ""
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	return line or ""
end

---------------------------------------------------------------------
-- 工具函数：从行中提取任务ID
---------------------------------------------------------------------
local function extract_task_id_from_line(line)
	-- ⭐⭐ 修改点2：直接使用 format.extract_id
	return format.extract_id(line)
end

---------------------------------------------------------------------
-- 渲染单个任务（添加边界检查 + 状态时间戳）
---------------------------------------------------------------------
function M.render_task(bufnr, task)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- ⭐ 修复1：确保行号为整数
	local row = math.floor(task.line_num or 1) - 1
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- 检查行号是否在有效范围内
	if row < 0 or row >= line_count then
		return -- 行号无效，跳过渲染
	end

	local line = get_line(bufnr, row)
	local line_len = #line

	----------------------------------------------------------------
	-- 删除线（优先级高）
	----------------------------------------------------------------
	if task.is_done then
		-- ⭐ 修复2：end_row 应该等于 row（单行任务）
		local end_row = row
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

	----------------------------------------------------------------
	-- 构建行尾虚拟文本：状态 + 时间戳 + 子任务统计
	----------------------------------------------------------------
	local virt_text_parts = {}

	-- 1. 子任务统计（如果存在）
	if task.children and #task.children > 0 and task.stats then
		-- ⭐ 修复3：使用安全的类型访问
		local done = task.stats.done or 0
		local total = task.stats.total or #task.children

		-- 只有在有子任务时才显示统计
		if total > 0 then
			-- 如果已有内容，添加分隔符
			if #virt_text_parts > 0 then
				table.insert(virt_text_parts, { " ", "Normal" })
			end
			table.insert(virt_text_parts, {
				string.format("(%d/%d)", math.floor(done), math.floor(total)),
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
					-- ⭐⭐ 关键修复：使用原来的显示组件API，不要改变渲染方式
					local components = status_mod.get_display_components(link)

					-- 状态图标
					if components and components.icon and components.icon ~= "" then
						-- ⭐ 保持原来的格式：图标前加空格
						if #virt_text_parts > 0 then
							table.insert(virt_text_parts, { " ", "Normal" })
						end
						table.insert(virt_text_parts, { "" .. components.icon, components.icon_highlight })
					end

					-- 时间戳
					if components and components.time and components.time ~= "" then
						if #virt_text_parts > 0 then
							table.insert(virt_text_parts, { " ", "Normal" })
						end
						table.insert(virt_text_parts, { components.time, components.time_highlight })
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
			priority = 300,
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
-- ⭐⭐ 关键修复：使用核心权威树进行渲染
---------------------------------------------------------------------
function M.render_all(bufnr, force_parse)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	-- 清除旧渲染（幂等）
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	-- ⭐ 修改：使用核心模块而不是直接调用解析器
	local core = module.get("core")
	if not core then
		return 0
	end

	-- 获取文件路径
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return 0
	end

	-- ⭐ 修改：通过核心模块获取任务树
	local tasks, roots
	if force_parse then
		-- 强制刷新核心模块缓存
		core.clear_cache()
		tasks, roots = core.parse_file(path)
	else
		-- 使用核心模块的缓存
		tasks, roots = core.parse_file(path)
	end

	-- roots 可能为 nil（空文件 / 无任务）
	roots = roots or {}

	-- ⭐ 修复4：检查 tasks 是否为 nil 或有效的表格
	if not tasks or type(tasks) ~= "table" then
		return 0
	end

	-- ⭐ 修复5：使用核心模块计算统计
	core.calculate_all_stats(tasks)

	-- 渲染所有根任务
	for _, task in ipairs(roots) do
		render_tree(bufnr, task)
	end

	-- 返回渲染的任务数量
	local total_rendered = 0
	for _, _ in pairs(tasks) do
		total_rendered = total_rendered + 1
	end

	return math.floor(total_rendered) -- 确保返回整数
end

---------------------------------------------------------------------
-- ⭐ 新增：基于核心权威树的增量渲染
---------------------------------------------------------------------
function M.incremental_render(bufnr, changed_lines, force_parse)
	-- 如果有变化行，只重新渲染受影响的任务
	if changed_lines and #changed_lines > 0 then
		-- 获取核心模块
		local core = module.get("core")
		if not core then
			return M.render_all(bufnr, force_parse)
		end

		local path = vim.api.nvim_buf_get_name(bufnr)

		-- ⭐ 修改：通过核心模块获取任务树
		local tasks, roots
		if force_parse then
			core.clear_cache()
			tasks, roots = core.parse_file(path)
		else
			tasks, roots = core.parse_file(path)
		end

		if not tasks then
			return M.render_all(bufnr, force_parse)
		end

		-- 记录受影响的根任务
		local affected_roots = {}

		-- 找出受影响的根任务
		for _, lnum in ipairs(changed_lines) do
			local task = tasks[lnum]
			if task then
				local root = task
				while root.parent do
					root = root.parent
				end

				if not vim.tbl_contains(affected_roots, root) then
					table.insert(affected_roots, root)
				end
			end
		end

		-- 如果没有找到受影响的任务，回退到全量渲染
		if #affected_roots == 0 then
			return M.render_all(bufnr, force_parse)
		end

		-- ⭐ 修改：使用核心模块计算统计
		core.calculate_all_stats(tasks)

		-- 只清除并重新渲染受影响的根任务及其子树
		for _, root in ipairs(affected_roots) do
			-- 清除这个根任务的渲染
			M._clear_task_and_children(bufnr, root)
			-- 重新渲染
			render_tree(bufnr, root)
		end

		return #affected_roots
	else
		-- 没有指定变化行，回退到全量渲染
		return M.render_all(bufnr, force_parse)
	end
end

function M._clear_task_and_children(bufnr, task)
	if not task then
		return
	end

	local start_line = task.line_num - 1
	local end_line = start_line

	-- 计算任务占用的行数（包括子任务）
	local function count_lines(t)
		local count = 1
		for _, child in ipairs(t.children or {}) do
			count = count + count_lines(child)
		end
		return count
	end

	end_line = start_line + count_lines(task) - 1

	-- 清除这个范围内的渲染
	vim.api.nvim_buf_clear_namespace(bufnr, ns, start_line, end_line + 1)
end

---------------------------------------------------------------------
-- ⭐ 新增：基于核心事件系统的渲染
---------------------------------------------------------------------
function M.render_with_core_events(bufnr, event_data)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	-- 获取核心模块
	local core = module.get("core")
	if not core then
		return 0
	end

	-- 如果事件数据包含任务ID，进行增量渲染
	if event_data and event_data.ids and #event_data.ids > 0 then
		-- 找出受影响的行号
		local affected_lines = {}
		local path = vim.api.nvim_buf_get_name(bufnr)

		-- 通过核心模块获取任务树
		local tasks, _ = core.parse_file(path)

		if tasks then
			-- 查找受影响的ID对应的行号
			for _, id in ipairs(event_data.ids) do
				for _, task in pairs(tasks) do
					if task.id == id then
						table.insert(affected_lines, task.line_num)
						break
					end
				end
			end

			if #affected_lines > 0 then
				return M.incremental_render(bufnr, affected_lines, true)
			end
		end
	end

	-- 默认全量渲染
	return M.render_all(bufnr, true)
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

---------------------------------------------------------------------
-- 新增：遵循核心权威的渲染接口
---------------------------------------------------------------------

--- 基于核心模块的渲染接口
--- @param bufnr number 缓冲区句柄
--- @param options table 渲染选项
function M.render_with_core(bufnr, options)
	options = vim.tbl_extend("force", {
		force_refresh = false,
		incremental = false,
		changed_lines = {},
		event_source = nil,
	}, options or {})

	if options.incremental and #options.changed_lines > 0 then
		return M.incremental_render(bufnr, options.changed_lines, options.force_refresh)
	elseif options.event_source then
		return M.render_with_core_events(bufnr, options.event_source)
	else
		return M.render_all(bufnr, options.force_refresh)
	end
end

return M
