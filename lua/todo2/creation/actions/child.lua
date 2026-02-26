-- lua/todo2/creation/actions/child.lua
local link_service = require("todo2.creation.service")
local link_utils = require("todo2.task.utils")
local task_id = require("todo2.utils.id")
local parser = require("todo2.core.parser")
local config = require("todo2.config")

--- 校验行号有效性（局部复用）
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total_lines = vim.api.nvim_buf_line_count(bufnr)
	return line and line >= 1 and line <= total_lines
end

return function(context, target)
	local path = vim.api.nvim_buf_get_name(target.bufnr)

	-- 1. 根据配置选择解析方式
	local cfg = config.get("parser") or {}
	local tasks
	if cfg.context_split then
		-- 启用隔离：只解析主区域任务，并验证目标行不在归档区
		local main_tasks = parser.parse_main_tree(path)
		-- 注意：parse_main_tree 返回的是任务列表，第一个返回值是 tasks
		tasks = main_tasks

		-- 额外保护：检查目标行是否在主区域内（可选，parse_main_tree 已保证）
		local archive_sections = parser.detect_archive_sections
				and parser.detect_archive_sections(vim.fn.readfile(path))
			or {}
		local in_archive = vim.tbl_contains(archive_sections, function(sec)
			return target.line >= sec.start_line and target.line <= sec.end_line
		end)
		if in_archive then
			return false, "归档区域内禁止创建子任务"
		end
	else
		-- 兼容模式：使用完整树（旧行为）
		tasks = parser.parse_file(path)
	end

	-- 2. 查找父任务
	local parent_task = nil
	for _, t in ipairs(tasks) do
		if t.line_num == target.line then
			parent_task = t
			break
		end
	end
	if not parent_task then
		return false, "当前行不是有效任务"
	end

	local id = task_id.generate_id()
	local content = "子任务"
	local tag = context.selected_tag or "TODO"

	-- 3. 创建子任务
	local child_line = link_service.create_child_task(target.bufnr, parent_task, id, content, tag)
	if not child_line then
		return false, "创建子任务失败"
	end

	-- 4. 行号二次校验（核心修复）
	if not validate_line_number(context.code_buf, context.code_line) then
		return false,
			string.format(
				"代码行号%d无效！缓冲区%d总行数：%d",
				context.code_line,
				context.code_buf,
				vim.api.nvim_buf_line_count(context.code_buf)
			)
	end

	-- 5. 插入代码标记（尊重缩进）
	local success =
		link_utils.insert_code_tag_above(context.code_buf, context.code_line, id, tag, { preserve_indent = true })
	if not success then
		return false, "插入代码标记失败"
	end

	-- 6. 创建代码链接（已做行号校准）
	link_service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	-- 7. 光标定位
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { child_line, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, string.format("✅ 子任务 %s 创建成功", id)
end
