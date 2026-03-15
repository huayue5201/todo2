-- lua/todo2/creation/actions/sibling.lua
local link_service = require("todo2.creation.service")
local link_utils = require("todo2.task.utils")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")

local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	return line and line >= 1 and line <= total
end

return function(context, target)
	local path = vim.api.nvim_buf_get_name(target.bufnr)

	local tasks, roots, id_map = scheduler.get_parse_tree(path)
	if not tasks then
		return false, "无法获取任务树（scheduler）"
	end

	-- 查找当前任务
	local current = id_map[target.id]
	if not current then
		for _, t in ipairs(tasks) do
			if t.line_num == target.line then
				current = t
				break
			end
		end
	end
	if not current then
		return false, "当前行不是有效任务"
	end

	-- 生成 ID
	local id = id_utils.generate_id()
	if not id_utils.is_valid(id) then
		return false, "生成的ID格式无效"
	end

	-- ✅ 直接从 current 取 content，不拼接
	local content = current.content or "新任务"
	local tag = context.selected_tag or "TODO"

	-- 计算插入位置
	local insert_line = current.line_num
	if current.children and #current.children > 0 then
		local function last_desc(t)
			if not t.children or #t.children == 0 then
				return t.line_num
			end
			return last_desc(t.children[#t.children])
		end
		insert_line = last_desc(current)
	end

	-- 插入同级任务
	local new_line = link_service.insert_task_line(target.bufnr, insert_line, {
		indent = string.rep("  ", current.level),
		id = id,
		tag = tag,
		content = content,
		update_store = true,
		autosave = true,
	})
	if not new_line then
		return false, "插入同级任务失败"
	end

	-- 校验代码行号
	if not validate_line_number(context.code_buf, context.code_line) then
		return false, "代码行号无效"
	end

	-- 插入代码标记
	local ok = link_utils.insert_code_tag_above(context.code_buf, context.code_line, id, tag, {
		preserve_indent = true,
	})
	if not ok then
		return false, "插入代码标记失败"
	end

	-- 创建代码链接
	link_service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	-- 光标定位
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { new_line, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, string.format("✅ 同级任务 %s 创建成功", id)
end
