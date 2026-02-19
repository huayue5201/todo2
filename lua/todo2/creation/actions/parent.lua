-- lua/todo2/creation/actions/parent.lua
local link_service = require("todo2.creation.service")
local link_utils = require("todo2.link.utils")
local task_id = require("todo2.utils.id")

--- 校验行号有效性（局部复用）
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total_lines = vim.api.nvim_buf_line_count(bufnr)
	return line and line >= 1 and line <= total_lines
end

return function(context, target)
	local id = task_id.generate_id()
	local content = "新任务"
	local tag = context.selected_tag or "TODO"

	-- 1. 在 TODO 文件中插入任务行
	local new_line_num = link_service.insert_task_line(target.bufnr, target.line, {
		id = id,
		tag = tag,
		content = content,
		update_store = true,
		autosave = true,
	})
	if not new_line_num then
		return false, "插入任务行失败"
	end

	-- ⭐ 调试：确认代码位置
	print(string.format("[DEBUG] 代码位置: buf=%d, line=%d", context.code_buf, context.code_line))

	-- 2. 行号二次校验（核心修复）
	if not validate_line_number(context.code_buf, context.code_line) then
		return false,
			string.format(
				"代码行号%d无效！缓冲区%d总行数：%d",
				context.code_line,
				context.code_buf,
				vim.api.nvim_buf_line_count(context.code_buf)
			)
	end

	-- 3. 在代码中插入标记
	local success =
		link_utils.insert_code_tag_above(context.code_buf, context.code_line, id, tag, { preserve_indent = true })
	if not success then
		return false, "插入代码标记失败"
	end

	-- 4. 创建代码链接 - 这里会调用 create_code_link（已做行号校准）
	link_service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	-- 5. 光标定位
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { new_line_num, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, string.format("✅ 独立任务 %s 创建成功", id)
end
