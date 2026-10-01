-- lua/todo2/ui/archive.lua
-- UI层：只负责用户交互，调用 core 层
---@module "todo2.ui.archive"

local M = {}

local core_archive = require("todo2.core.archive")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local cursor = require("todo2.task.cursor")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---获取任务的根任务ID
---@param task_id string? 任务ID（可能为nil）
---@return string? 根任务ID
local function get_root_task_id(task_id)
	if not task_id then
		return nil
	end

	local ancestors = relation.get_ancestors(task_id)
	if #ancestors > 0 then
		return ancestors[1] -- 第一个是根任务
	end
	return task_id -- 本身就是根任务
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---归档当前任务组
function M.archive_task_group()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	-- 1. 获取当前行的任务ID
	local task_id = cursor.get_id(bufnr, lnum)
	if not task_id then
		vim.notify("当前行不是任务", vim.log.levels.WARN)
		return
	end

	-- 2. 验证任务存在
	local task = core.get_task(task_id)
	if not task then
		vim.notify("任务不存在于存储中", vim.log.levels.WARN)
		return
	end

	-- 3. 找到任务组根节点ID
	local root_id = get_root_task_id(task_id)
	if not root_id then
		vim.notify("无法获取根任务ID", vim.log.levels.WARN)
		return
	end

	-- 4. 调用归档函数（内部会自动定位到任务所属的 TODO 文件）
	local ok, msg = core_archive.archive_task_group(root_id)

	if ok then
		vim.notify("✅ " .. msg, vim.log.levels.INFO)
	else
		vim.notify("❌ " .. msg, vim.log.levels.ERROR)
	end
end

return M
