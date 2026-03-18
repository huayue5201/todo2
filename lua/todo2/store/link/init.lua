-- lua/todo2/store/link/init.lua
-- 链接模块统一导出（清理重复，统一API）

local M = {}

-- 警告记录
local warned = {}

local function warn_deprecated(old_name, new_name)
	if not warned[old_name] then
		vim.notify(
			string.format("[todo2] link.%s is deprecated, please use link.%s instead", old_name, new_name),
			vim.log.levels.WARN
		)
		warned[old_name] = true
	end
end

---------------------------------------------------------------------
-- 核心模块
---------------------------------------------------------------------
local core = require("todo2.store.link.core")

-- 核心CRUD（这些是唯一入口，保留）
M.get_task = core.get_task
M.save_task = core.save_task
M.delete_task = core.delete_task
M.create_task = core.create_task

-- 行号管理（核心功能）
M.verify_and_update_line = core.verify_and_update_line
M.get_authoritative_line = core.get_authoritative_line

-- 位置相关
M.get_todo_location = core.get_todo_location
M.get_code_location = core.get_code_location
M.update_todo_location = core.update_todo_location
M.update_code_location = core.update_code_location

-- 任务属性更新
M.update_content = core.update_content
M.update_status = core.update_status
M.update_tags = core.update_tags
M.update_ai_executable = core.update_ai_executable

-- 文件重命名
M.handle_file_rename = core.handle_file_rename

-- 内部函数（供其他子模块使用）
M._get_internal = core._get_internal
M._save_internal = core._save_internal
M._delete_internal = core._delete_internal

---------------------------------------------------------------------
-- ⚠️ 废弃的core查询API（转发到query并带警告）
---------------------------------------------------------------------

---@deprecated 请使用 link.get_todo_tasks()
M.get_all_todo_tasks = function(...)
	warn_deprecated("get_all_todo_tasks", "get_todo_tasks")
	return require("todo2.store.link.query").get_todo_tasks(...)
end

---@deprecated 请使用 link.get_code_tasks()
M.get_all_code_tasks = function(...)
	warn_deprecated("get_all_code_tasks", "get_code_tasks")
	return require("todo2.store.link.query").get_code_tasks(...)
end

---@deprecated 请使用 link.get_all_tasks()（但推荐使用更具体的查询）
M.get_all_tasks = function(...)
	warn_deprecated("get_all_tasks", "更具体的查询函数如 get_todo_tasks()")
	return require("todo2.store.link.query").get_all_tasks(...)
end

---------------------------------------------------------------------
-- 查询功能（推荐使用）
---------------------------------------------------------------------
local query = require("todo2.store.link.query")

-- 这些是推荐使用的查询API
M.get_todo_tasks = query.get_todo_tasks -- 替代 get_all_todo_tasks
M.get_code_tasks = query.get_code_tasks -- 替代 get_all_code_tasks
M.get_archived_tasks = query.get_archived_tasks
M.find_by_file = query.find_by_file
M.find_by_tag = query.find_by_tag
M.find_by_status = query.find_by_status
M.get_task_group = query.get_task_group
M.get_group_progress = query.get_group_progress

-- 保留一个全量查询（但警告）
M.get_all_tasks = query.get_all_tasks -- 上面已定义带警告版本

---------------------------------------------------------------------
-- 状态管理
---------------------------------------------------------------------
local status = require("todo2.store.link.status")
M.mark_completed = status.mark_completed
M.reopen_link = status.reopen_link
M.update_active_status = status.update_active_status
M.is_completed = status.is_completed
M.is_archived = status.is_archived

---------------------------------------------------------------------
-- 归档管理
---------------------------------------------------------------------
local archive = require("todo2.store.link.archive")
M.mark_archived = archive.mark_archived
M.unarchive_link = archive.unarchive_link
M.save_archive_snapshot = archive.save_archive_snapshot
M.get_archive_snapshot = archive.get_archive_snapshot
M.delete_archive_snapshot = archive.delete_archive_snapshot
M.get_all_archive_snapshots = archive.get_all_archive_snapshots
M.restore_from_snapshot = archive.restore_from_snapshot
M.batch_restore_from_snapshots = archive.batch_restore_from_snapshots

---------------------------------------------------------------------
-- 行号管理
---------------------------------------------------------------------
local line = require("todo2.store.link.line")
M.shift_lines = line.shift_lines
M.handle_line_shift = line.handle_line_shift
M.get_task_at_line = line.get_task_at_line

---------------------------------------------------------------------
-- 转换函数（如果core中确实没有，需要实现或移除）
---------------------------------------------------------------------
-- 如果这些函数在core中不存在，应该移除或提供实现
-- 暂时注释掉，避免错误
-- M._to_old_todo = core._to_old_todo
-- M._to_old_code = core._to_old_code
-- M._create_internal_from_old = core._create_internal_from_old

return M
