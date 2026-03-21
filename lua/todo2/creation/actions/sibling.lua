-- lua/todo2/creation/actions/sibling.lua
-- 同级任务创建动作（继承父子关系）
---@module "todo2.creation.actions.sibling"

local link_service = require("todo2.creation.service")
local link_utils = require("todo2.task.utils")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")

---校验行号是否有效
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	return line and line >= 1 and line <= total
end

---同级任务创建动作
---@param context table 创建上下文
---@param target table 目标位置信息
---@return boolean, string
return function(context, target)
	local path = vim.api.nvim_buf_get_name(target.bufnr)

	-- 获取任务树
	local tasks, _, id_map = scheduler.get_parse_tree(path, false)
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

	----------------------------------------------------------------------
	-- ⭐ 继承父任务（同级任务必须继承父子关系）
	----------------------------------------------------------------------
	local parent_id = current.parent and current.parent.id or nil

	-- 生成新任务 ID
	local id = id_utils.generate_id()
	if not id_utils.is_valid(id) then
		return false, "生成的ID格式无效"
	end

	-- 缩进与当前任务一致
	local indent = string.rep("  ", current.level)
	local content = "新任务"
	local tag = context.selected_tag or "TODO"

	----------------------------------------------------------------------
	-- ⭐ 插入位置：当前任务的最后一个后代之后
	----------------------------------------------------------------------
	local insert_line = current.line_num
	if current.children and #current.children > 0 then
		local function last_descendant(t)
			if not t.children or #t.children == 0 then
				return t.line_num
			end
			return last_descendant(t.children[#t.children])
		end
		insert_line = last_descendant(current)
	end

	----------------------------------------------------------------------
	-- 插入任务行（不写入 store）
	----------------------------------------------------------------------
	local result = link_service.insert_task_line(target.bufnr, insert_line, {
		indent = indent,
		id = id,
		content = content,
		tag = tag,
		update_store = false, -- ⭐ 不写入 store
		autosave = false,
	})

	if not result then
		return false, "插入同级任务失败"
	end

	local new_line = result.line_num

	----------------------------------------------------------------------
	-- ⭐ 手动写入存储层，并继承 parent_id
	----------------------------------------------------------------------
	link_service.create_todo_link(path, new_line, id, content, {
		tags = { tag },
		parent_id = parent_id, -- ⭐ 继承父子关系
	})

	----------------------------------------------------------------------
	-- 插入代码标记
	----------------------------------------------------------------------
	if not validate_line_number(context.code_buf, context.code_line) then
		return false, "代码行号无效"
	end

	local ok = link_utils.insert_code_tag_above(context.code_buf, context.code_line, id, tag, {
		preserve_indent = true,
	})
	if not ok then
		return false, "插入代码标记失败"
	end

	-- 创建代码链接
	link_service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	----------------------------------------------------------------------
	-- 光标定位
	----------------------------------------------------------------------
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { new_line, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, string.format("同级任务 %s 创建成功", id)
end
