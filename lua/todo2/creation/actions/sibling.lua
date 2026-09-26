-- lua/todo2/creation/actions/sibling.lua
-- 同级任务创建动作（继承父子关系）
---@module "todo2.creation.actions.sibling"

local service = require("todo2.creation.service")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")
local operations = require("todo2.creation.actions.operations")

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

	-- 继承父任务（同级任务必须继承父子关系）
	local parent_id = current.parent and current.parent.id or nil

	-- 生成新任务 ID
	local id = id_utils.generate_id()
	if not id_utils.is_valid(id) then
		return false, "生成的ID格式无效"
	end

	-- 缩进与当前任务一致
	local indent = string.rep("  ", current.level)
	local content = "新任务"

	-- 插入位置：当前任务的最后一个后代之后
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

	-- 插入任务行（不写入 store，稍后手动写入）
	local result = service.insert_task_line(target.bufnr, insert_line, {
		indent = indent,
		id = id,
		content = content,
		update_store = false,
		autosave = false,
	})

	if not result then
		return false, "插入同级任务失败"
	end

	local new_line = result.line_num

	-- 手动写入存储层，并继承 parent_id
	service.create_todo_link(path, new_line, id, content, {
		parent_id = parent_id,
	})

	local ok, err = operations.finish_creation(context, target, id, content, new_line)
	if not ok then
		return false, err
	end

	return true, string.format("同级任务 %s 创建成功", id)
end
