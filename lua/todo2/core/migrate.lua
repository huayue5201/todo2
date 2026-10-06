-- lua/todo2/core/migrate.lua
-- Phase 3：状态轴收敛。
--
-- 旧版本把「类型」当作活跃状态使用（fix / refactor / AI）。Phase 3 把状态轴收敛为
-- 纯进度语义（见 config.status.cycle），类型改由**标签**承载。本模块把历史任务的旧
-- 类型状态一次性迁移为标签 + 默认进度状态，并同步回写 TODO 文件里的标记前缀。
--
-- 迁移是幂等的：load_from_new_layout 在读取时已把旧状态转成标签，本模块负责把结果
-- 落盘（store）并重写文件行。

local M = {}

local store = require("todo2.store.nvim_store")
local core = require("todo2.store.task.core")
local status_domain = require("todo2.core.status")
local task_line = require("todo2.utils.task_line")

local TASK_PREFIX = "todo.tasks."
local FLAG_KEY = "todo2.meta.tags_migrated_v1"

--- 迁移所有仍是旧「类型状态」的任务。
---@return number migrated 迁移的任务数量
function M.run()
	local keys = store.get_namespace_keys("todo.tasks") or {}
	local migrated = 0

	for _, id in ipairs(keys) do
		local raw = store.get_key(TASK_PREFIX .. id)
		local raw_status = raw and raw.core and raw.core.status

		if status_domain.legacy_type_tag(raw_status) then
			-- get_task 已在读取时完成「类型 → 标签 + 默认进度状态」的转换
			local task = core.get_task(id)
			if task then
				core.save_task(id, task)
				task_line.rewrite(id)
				migrated = migrated + 1
			end
		end
	end

	return migrated
end

--- 仅在尚未迁移过时执行一次（插件启动时调用）。
---@return number migrated
function M.run_once()
	if store.get_key(FLAG_KEY) then
		return 0
	end
	local migrated = M.run()
	store.set_key(FLAG_KEY, true)
	return migrated
end

return M
