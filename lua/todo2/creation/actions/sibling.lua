-- lua/todo2/creation/actions/sibling.lua
-- 创建同级任务（智能版）

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
	local id = task_id.generate_id()
	local content = "新任务"
	local tag = context.selected_tag or "TODO"

	-- 1. 解析任务树
	local cfg = config.get("parser") or {}
	local tasks = cfg.context_split and parser.parse_main_tree(path) or parser.parse_file(path)

	-- 2. 查找当前任务
	local current_task = nil
	for _, t in ipairs(tasks) do
		if t.line_num == target.line then
			current_task = t
			break
		end
	end

	if not current_task then
		return false, "当前行不是有效任务"
	end

	-- 3. 确定同级任务的缩进级别
	local indent_level = current_task.level or 0
	local indent = string.rep("  ", indent_level)

	-- 4. 确定插入位置：在当前任务下方，但考虑子任务情况
	local insert_line = target.line

	-- 如果当前任务有子任务，需要找到最后一个子任务的位置
	if current_task.children and #current_task.children > 0 then
		-- 递归查找最后一个后代任务
		local function find_last_descendant(task)
			if not task.children or #task.children == 0 then
				return task.line_num
			end
			return find_last_descendant(task.children[#task.children])
		end

		local last_descendant_line = find_last_descendant(current_task)
		if last_descendant_line > insert_line then
			insert_line = last_descendant_line
		end
	end

	-- 5. 插入同级任务
	local new_line_num = link_service.insert_task_line(target.bufnr, insert_line, {
		indent = indent,
		id = id,
		tag = tag,
		content = content,
		update_store = true,
		autosave = true,
	})

	if not new_line_num then
		return false, "插入同级任务失败"
	end

	-- 6. 行号二次校验（核心修复）
	if not validate_line_number(context.code_buf, context.code_line) then
		return false,
			string.format(
				"代码行号%d无效！缓冲区%d总行数：%d",
				context.code_line,
				context.code_buf,
				vim.api.nvim_buf_line_count(context.code_buf)
			)
	end

	-- 7. 在代码中插入标记（尊重缩进）
	local success =
		link_utils.insert_code_tag_above(context.code_buf, context.code_line, id, tag, { preserve_indent = true })
	if not success then
		return false, "插入代码标记失败"
	end

	-- 8. 创建代码链接（已做行号校准）
	link_service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	-- 9. 光标定位
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { new_line_num, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	-- 10. 构建关系信息
	local relation_info = {}
	if indent_level == 0 then
		relation_info = { "顶层任务" }
	else
		-- 查找父任务
		local parent_task = nil
		for i = #tasks, 1, -1 do
			local t = tasks[i]
			if t.line_num < target.line and t.level == indent_level - 1 then
				parent_task = t
				break
			end
		end
		if parent_task then
			table.insert(relation_info, string.format("父任务: %s", parent_task.content:sub(1, 30)))
		end
	end

	table.insert(relation_info, string.format("缩进级别: %d", indent_level))

	return true, string.format("✅ 同级任务 %s 创建成功\n%s", id, table.concat(relation_info, " | "))
end
