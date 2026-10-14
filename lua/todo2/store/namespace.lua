-- lua/todo2/store/namespace.lua
-- 存储命名空间契约：把 store 拆成两类
--   facts.*  事实：TODO 文件里没有、丢了就真丢的数据（时间戳/校验/git/墓碑/孤儿/归档索引/代码锚点）
--   cache.*  缓存：完全可由文件重建的派生数据（父子关系 / 文件倒排索引），可随时清空重建
-- 唯一真源始终是磁盘上的 *.todo.md 文件；本模块只负责命名空间常量与整体清理。
---@module "todo2.store.namespace"

local M = {}

--- 事实命名空间（不可从文件重建）
M.facts = {
	tasks = "facts.tasks.",
	task_ctx = "facts.task_ctx.",
	tasks_ns = "facts.tasks",
	task_ctx_ns = "facts.task_ctx",
	deleted = "facts.deleted.",
	deleted_ns = "facts.deleted",
	orphan = "facts.orphan.",
	orphan_ns = "facts.orphan",
	archive_index = "facts.archive.index",
	git_cursor = "facts.git_last_synced_commit",
}

--- 缓存命名空间（可由文件重建，可安全清空）
M.cache = {
	parent_to_children = "cache.relation.parent_to_children.",
	child_to_parent = "cache.relation.child_to_parent.",
	relation_ns = "cache.relation",
	file_to_todo = "cache.index.file_to_todo.",
	file_to_code = "cache.index.file_to_code.",
	index_ns = "cache.index",
}

--- 旧命名空间（硬切不迁移：下次启动直接当垃圾清掉，任务由 reconcile 从文件重建）
M.legacy_ns = {
	"todo.tasks",
	"todo.task_ctx",
	"todo.relation",
	"todo.index",
	"todo.orphan",
	"todo.deleted",
}

--- 旧版散键（无命名空间前缀）
M.legacy_keys = {
	"todo.archive.index",
	"git_last_synced_commit",
}

--- 清空一个命名空间下的全部键
--- 注意：nvim-store3 的 namespace_keys 返回的是去掉前缀后的相对后缀，
--- 删除时要拼回完整键。
---@param ns string 命名空间（可带或不带末尾的点）
local function purge_ns(ns)
	local store = require("todo2.store.nvim_store")
	local prefix = ns:gsub("%.$", "")
	local suffixes = store.get_namespace_keys(prefix) or {}
	for _, suffix in ipairs(suffixes) do
		store.delete_key(prefix .. "." .. suffix)
	end
end

--- 清理旧 todo.* 命名空间（硬切：不迁移数据，任务由 reconcile 从文件重建）
function M.purge_legacy()
	for _, ns in ipairs(M.legacy_ns) do
		purge_ns(ns)
	end
	for _, k in ipairs(M.legacy_keys) do
		local store = require("todo2.store.nvim_store")
		store.delete_key(k)
	end
end

--- 清空全部缓存命名空间（可安全调用：缓存会由 reconcile 重建）
function M.reset_cache()
	purge_ns(M.cache.relation_ns)
	purge_ns(M.cache.index_ns)
end

return M
