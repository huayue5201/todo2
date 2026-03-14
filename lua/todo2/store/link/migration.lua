-- lua/todo2/store/migration.lua
-- 将旧数据迁移到新格式

function M.migrate_all()
	local old_todo = require("todo2.store.link").get_all_todo()
	local old_code = require("todo2.store.link").get_all_code()
	local migrated = 0

	-- 按ID分组
	local groups = {}
	for id, todo in pairs(old_todo) do
		groups[id] = groups[id] or {}
		groups[id].todo = todo
	end
	for id, code in pairs(old_code) do
		groups[id] = groups[id] or {}
		groups[id].code = code
	end

	-- 迁移到新格式
	for id, pair in pairs(groups) do
		local internal = require("todo2.store.adapter").to_internal(pair.todo, pair.code)
		if internal then
			local key = "todo.links.internal." .. id
			require("todo2.store.nvim_store").set_key(key, internal)
			migrated = migrated + 1
		end
	end

	return migrated
end
