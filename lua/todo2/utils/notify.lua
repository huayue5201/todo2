-- lua/todo2/utils/notify.lua
-- 统一的用户提示：成功 / 失败 / 警告 / 信息。
--
-- 约定：✅ 前缀 = 已生效的成功操作，❌ = 失败（或用户需要处理的问题），
-- 两者都只在真正成功/失败时用；中间态用 info/warn，避免给用户造成「成功了」的错觉。

local M = {}

---@param msg string
---@param level integer
local function send(msg, level)
	vim.notify("[todo2] " .. msg, level)
end

--- 成功：✅ 前缀。
---@param msg string
function M.ok(msg)
	vim.notify("✅ " .. msg, vim.log.levels.INFO)
end

--- 失败：❌ 前缀。
---@param msg string
function M.err(msg)
	vim.notify("❌ " .. msg, vim.log.levels.ERROR)
end

--- 普通信息。
---@param msg string
function M.info(msg)
	send(msg, vim.log.levels.INFO)
end

--- 警告（配置不支持、被跳过等，不算失败）。
---@param msg string
function M.warn(msg)
	send(msg, vim.log.levels.WARN)
end

return M
