-- lua/todo2/creation/actions/child.lua
-- 子任务创建动作
---@module "todo2.creation.actions.child"

local service = require("todo2.creation.service")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")
local operations = require("todo2.creation.actions.operations")

---子任务创建动作
---@param context table 创建上下文
---@param target table 目标位置信息
---@return boolean, string
return function(context, target)
	local path = vim.api.nvim_buf_get_name(target.bufnr)

	-- 获取任务树，查找父任务
	local tasks, _, id_map = scheduler.get_parse_tree(path)
	if not tasks then
		return false, "Cannot get the task tree"
	end

	local parent = id_map[target.id]
	if not parent then
		for _, t in ipairs(tasks) do
			if t.line_num == target.line then
				parent = t
				break
			end
		end
	end
	if not parent then
		return false, "Current line is not a valid task"
	end

	-- 生成子任务ID
	local child_id = id_utils.generate_id()
	if not id_utils.is_valid(child_id) then
		return false, "Generated ID has an invalid format"
	end

	local content = "Subtask"

	-- 创建子任务（返回 InsertTaskResult 对象）
	local result = service.create_child_task(target.bufnr, parent, child_id, content)
	if not result then
		return false, "Failed to create subtask"
	end

	local ok, err = operations.finish_creation(context, target, child_id, content, result.line_num)
	if not ok then
		return false, err
	end

	return true, string.format("✅ Subtask %s created", child_id)
end
