-- lua/todo2/store/tombstone.lua
-- 删除墓碑：记录「已被显式删除」的任务 id，避免删除结果在 store 侧的
-- 还原通道（孤儿还原 / 归档反归档）中被悄悄复活。
--
-- 注意：文件（.todo.md）是唯一真源。墓碑【不】阻止文件重新出现该 id 时重建任务
-- ——那正是编辑器撤销（u）/ 手工回写的语义；重建时 core.create_task 会清除墓碑。
--
-- 与归档墓碑（todo.archive.index）语义相反：那一类表示「已移入冷库、可反归档」，
-- 本模块表示「已删除」，因此使用独立命名空间 todo.deleted.<id>。
--
-- 数据形状：todo.deleted.<id> = { deleted_at = number, reason = string }
---@module "todo2.store.tombstone"

local M = {}

local store = require("todo2.store.nvim_store")

---墓碑键前缀
local PREFIX = "todo.deleted."

--- 标记任务已被删除。
--- 幂等：已存在墓碑时不覆盖（保留首次删除时间）。
---@param id string 任务ID
---@param reason? string 删除来源标签（默认 "delete"）
function M.mark(id, reason)
	if not id or id == "" then
		return
	end
	if store.get_key(PREFIX .. id) then
		return
	end
	store.set_key(PREFIX .. id, {
		deleted_at = os.time(),
		reason = reason or "delete",
	})
end

--- 该 id 是否已在删除墓碑中。
---@param id string
---@return boolean
function M.is_deleted(id)
	return id ~= nil and id ~= "" and store.get_key(PREFIX .. id) ~= nil
end

--- 清除墓碑（显式取消删除：之后文件里若再次出现该 id，允许重建）。
---@param id string
function M.clear(id)
	if id and id ~= "" then
		store.delete_key(PREFIX .. id)
	end
end

return M
