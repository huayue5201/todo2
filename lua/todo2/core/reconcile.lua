-- lua/todo2/core/reconcile.lua
-- 全量对账（reindex）：文件是唯一真源，store 只是缓存 + 关系 + 描述。
--
-- 机会式同步（BufRead / TextChanged / BufWritePre）一旦漏掉一个事件，就可能留下
-- 永久漂移（store 与文件不一致，只能靠人肉 :TodoDoctor 修补）。本模块在启动时对
-- 项目内所有 TODO 文件各跑一遍 sync_todo_file，让漂移在下一次启动时自愈。
---@module "todo2.core.reconcile"

local M = {}

local sync = require("todo2.core.sync")
local file_manager = require("todo2.ui.file_manager")
local project_utils = require("todo2.utils.project")

---对账结果
---@class ReconcileResult
---@field files integer 成功对账的文件数
---@field changed integer 位置/内容变更的任务数
---@field added integer 文件里新出现的任务数
---@field removed integer 文件里已消失的任务数

---对项目内所有 TODO 文件做一次全量对账。
---@param project? string 项目名，缺省为当前项目
---@return ReconcileResult
function M.run(project)
	project = project or project_utils.get_project_name()
	local result = { files = 0, changed = 0, added = 0, removed = 0 }

	local files = file_manager.get_todo_files(project, true)
	for _, path in ipairs(files) do
		-- 单个文件失败不能拖垮整体对账
		local ok, r = pcall(sync.sync_todo_file, path)
		if ok and type(r) == "table" then
			result.files = result.files + 1
			result.changed = result.changed + #(r.changed_ids or {})
			result.added = result.added + #(r.added or {})
			result.removed = result.removed + #(r.removed or {})
		end
	end

	return result
end

return M
