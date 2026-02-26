-- lua/todo2/store/link/init.lua
-- 链接模块统一导出

local M = {}

-- 核心CRUD操作
local core = require("todo2.store.link.core")
M.add_todo = core.add_todo
M.add_code = core.add_code
M.get_todo = core.get_todo
M.get_code = core.get_code
M.update_todo = core.update_todo
M.update_code = core.update_code
M.delete_todo = core.delete_todo
M.delete_code = core.delete_code
M.delete_link_pair = core.delete_link_pair

-- 内部函数（供其他子模块使用）
M._get_link = core._get_link
M._update_link = core._update_link
M._update_link_position = core._update_link_position

-- 状态管理
local status = require("todo2.store.link.status")
M.mark_completed = status.mark_completed
M.reopen_link = status.reopen_link
M.update_active_status = status.update_active_status
M.is_completed = status.is_completed
M.is_archived = status.is_archived
M._check_pair_integrity = status._check_pair_integrity

-- 归档管理
local archive = require("todo2.store.link.archive")
M.mark_archived = archive.mark_archived
M.unarchive_link = archive.unarchive_link
M.save_archive_snapshot = archive.save_archive_snapshot
M.get_archive_snapshot = archive.get_archive_snapshot
M.delete_archive_snapshot = archive.delete_archive_snapshot
M.get_all_archive_snapshots = archive.get_all_archive_snapshots
M.restore_from_snapshot = archive.restore_from_snapshot
M.batch_restore_from_snapshots = archive.batch_restore_from_snapshots

-- 查询功能
local query = require("todo2.store.link.query")
M.get_all_todo = query.get_all_todo
M.get_all_code = query.get_all_code
M.get_archived_links = query.get_archived_links
M.get_group_progress = query.get_group_progress
M.get_task_group = query.get_task_group

-- 行号管理
local line = require("todo2.store.link.line")
M.shift_lines = line.shift_lines
M.handle_line_shift = line.handle_line_shift

return M
