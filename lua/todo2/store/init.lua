-- lua/todo2/store/init.lua（修复版）
--- @module todo2.store

local M = {}

---------------------------------------------------------------------
-- 模块导入
---------------------------------------------------------------------
local link = require("todo2.store.link")
local index = require("todo2.store.index")
local meta = require("todo2.store.meta")
local autofix = require("todo2.store.autofix")
local context = require("todo2.store.context")
local consistency = require("todo2.store.consistency")
local state_machine = require("todo2.store.state_machine")
local cleanup = require("todo2.store.cleanup")

---------------------------------------------------------------------
-- 路径规范化（直接代理）
---------------------------------------------------------------------
function M._normalize_path(path)
	return index._normalize_path(path)
end

---------------------------------------------------------------------
-- 初始化
---------------------------------------------------------------------
function M.setup()
	-- 初始化元数据
	meta.init()

	-- 设置自动修复
	autofix.setup_autofix()

	return M
end

---------------------------------------------------------------------
-- 链接操作API
---------------------------------------------------------------------
-- 添加链接
M.add_todo_link = link.add_todo
M.add_code_link = link.add_code

-- 获取链接
M.get_todo_link = link.get_todo
M.get_code_link = link.get_code

-- 批量获取
M.get_all_todo_links = link.get_all_todo
M.get_all_code_links = link.get_all_code

-- 删除链接
M.delete_todo_link = link.delete_todo
M.delete_code_link = link.delete_code

-- 归档链接
M.archive_link = link.archive_link
M.restore_archived_link = link.restore_archived_link
M.get_archived_links = link.get_archived_links
M.safe_archive = link.safe_archive
M.verify_archive_integrity = link.verify_archive_integrity

---------------------------------------------------------------------
-- 状态管理API
---------------------------------------------------------------------
-- 状态更新
M.update_status = link.update_status

-- 快捷状态方法
M.mark_completed = link.mark_completed
M.mark_urgent = link.mark_urgent
M.mark_normal = link.mark_normal
M.mark_waiting = link.mark_waiting
M.restore_previous_status = link.restore_previous_status

---------------------------------------------------------------------
-- 索引查询API
---------------------------------------------------------------------
M.find_todo_links_by_file = index.find_todo_links_by_file
M.find_code_links_by_file = index.find_code_links_by_file

---------------------------------------------------------------------
-- 定位修复API
---------------------------------------------------------------------
M.fix_link_location = link.fix_link_location
M.fix_file_locations = link.fix_file_locations
M.fix_current_file = autofix.fix_current_file

---------------------------------------------------------------------
-- 上下文API
---------------------------------------------------------------------
M.build_context = context.build
M.context_match = context.match

---------------------------------------------------------------------
-- 一致性检查API
---------------------------------------------------------------------
M.check_link_consistency = consistency.check_link_pair_consistency
M.repair_link_inconsistency = consistency.repair_link_pair

---------------------------------------------------------------------
-- 状态机API
---------------------------------------------------------------------
M.get_status_display_info = state_machine.get_status_display_info
M.is_transition_allowed = state_machine.is_transition_allowed

---------------------------------------------------------------------
-- 清理API
---------------------------------------------------------------------
M.cleanup_expired = cleanup.cleanup
M.cleanup_completed = cleanup.cleanup_completed
M.cleanup_expired_archives = cleanup.cleanup_expired_archives
M.cleanup_orphan_archives = cleanup.cleanup_orphan_archives
M.validate_all_links = cleanup.validate_all
M.repair_links = cleanup.repair_links

---------------------------------------------------------------------
-- 向后兼容API
---------------------------------------------------------------------
function M.migrate_status_fields()
	-- 简化：总是成功
	return true
end

---------------------------------------------------------------------
-- 立即同步API
---------------------------------------------------------------------
M.sync_link_pair_immediately = link.sync_link_pair_immediately
M.force_sync_all = function()
	local todo_links = link.get_all_todo()
	local code_links = link.get_all_code()
	local synced = 0

	for id, _ in pairs(todo_links) do
		if link.sync_link_pair_immediately(id) then
			synced = synced + 1
		end
	end

	for id, _ in pairs(code_links) do
		if link.sync_link_pair_immediately(id) then
			synced = synced + 1
		end
	end

	return synced
end
---------------------------------------------------------------------
-- 错误处理包装器
---------------------------------------------------------------------
local function wrap_api(fn)
	return function(...)
		local ok, result = pcall(fn, ...)
		if not ok then
			vim.notify("todo2.store错误: " .. tostring(result), vim.log.levels.ERROR)
			return nil
		end
		return result
	end
end

-- 包装所有公共API
for name, fn in pairs(M) do
	if type(fn) == "function" and not name:match("^_") then
		M[name] = wrap_api(fn)
	end
end

return M
