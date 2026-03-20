-- lua/todo2/migration_cleanup.lua
-- 一次性迁移脚本：清理 todo.links.internal.* 旧结构

local M = {}

local store = require("todo2.store.nvim_store")

--- 扫描并删除所有旧结构 key
--- @return { removed: integer, keys: string[] }
function M.run()
	local prefix = "todo.links.internal"
	local keys = store.get_namespace_keys(prefix) or {}

	local removed = 0
	local removed_keys = {}

	for _, key in ipairs(keys) do
		store.delete_key(key)
		removed = removed + 1
		table.insert(removed_keys, key)
	end

	vim.notify(
		string.format("[todo2] Migration cleanup complete. Removed %d legacy keys.", removed),
		vim.log.levels.INFO
	)

	return {
		removed = removed,
		keys = removed_keys,
	}
end

return M
