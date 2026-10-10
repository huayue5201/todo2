-- lua/todo2/ui/archive.lua
-- UI层：只负责用户交互，调用 core 层
---@module "todo2.ui.archive"

local M = {}

local core_archive = require("todo2.core.archive")
local relation = require("todo2.store.task.relation")
local picker = require("todo2.task.picker")

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
---@param opts? { force?: boolean }
function M.archive_task_group(opts)
	picker.pick({ none_msg = "Current line is not a task" }, function(task)
		-- 找到任务组根节点ID
		local root_id = get_root_task_id(task.id)
		if not root_id then
			vim.notify("Cannot get the root task ID", vim.log.levels.WARN)
			return
		end

		-- 调用归档函数（内部会自动定位到任务所属的 TODO 文件）
		local ok, msg = core_archive.archive_task_group(root_id, opts)
		if ok then
			vim.notify("✅ " .. msg, vim.log.levels.INFO)
		else
			vim.notify("❌ " .. msg, vim.log.levels.ERROR)
		end
	end)
end

---反归档：从归档库选择一个任务组恢复到 TODO 文件
function M.unarchive()
	local store_archive = require("todo2.store.archive")
	local nvim_store = require("todo2.store.nvim_store")

	local roots = store_archive.forest()
	if not roots or #roots == 0 then
		vim.notify("📦 No archived tasks", vim.log.levels.INFO)
		return
	end

	local items = {}
	for _, node in ipairs(roots) do
		local t = node.task
		local at = t.timestamps and t.timestamps.archived
		items[#items + 1] = {
			root_id = t.id,
			display = (t.core.content or "?") .. (at and ("  [" .. os.date("%Y-%m-%d", at) .. "]") or ""),
		}
	end

	vim.ui.select(items, {
		prompt = "Unarchive which group?",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		if not choice then
			return
		end
		local ids = nvim_store.with_active(store_archive.STORE_NAME, function()
			return relation.get_subtree_ids(choice.root_id)
		end)
		local ok, msg = core_archive.unarchive_task_group(ids)
		if ok then
			vim.notify("✅ " .. msg, vim.log.levels.INFO)
		else
			vim.notify("❌ " .. msg, vim.log.levels.ERROR)
		end
	end)
end

---加载归档库并报告数量
function M.open()
	local store_archive = require("todo2.store.archive")
	local n = store_archive.count()
	vim.notify("📦 Archive store loaded (" .. n .. " tasks)", vim.log.levels.INFO)
end

---卸载归档库（释放内存）
function M.close()
	local store_archive = require("todo2.store.archive")
	store_archive.close()
	vim.notify("📦 Archive store unloaded", vim.log.levels.INFO)
end

---导入旧 `## Archived` 段数据到冷存储
function M.import_legacy()
	local ok, msg = core_archive.import_legacy_archive()
	if ok then
		vim.notify("✅ " .. msg, vim.log.levels.INFO)
	else
		vim.notify("❌ " .. msg, vim.log.levels.ERROR)
	end
end

return M
