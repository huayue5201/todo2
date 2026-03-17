-- lua/todo2/ai/stream/chat_engine.lua
-- 纯对话流式引擎：不写入 buffer，不使用 patch 协议

local normalizer = require("todo2.ai.stream.normalizer")

local M = {}
local chats = {} -- key = chat_id, value = state

------------------------------------------------------------
-- state 结构
------------------------------------------------------------
-- state = {
--   active = true/false,
--   finished = true/false,
--   bufnr = number | nil,
--   buffer = string,         -- 累积的完整回答
--   on_chunk = function | nil,
--   on_finish = function | nil,
--   on_error = function | nil,
-- }

------------------------------------------------------------
-- 启动对话流
------------------------------------------------------------
--- 启动一个对话流式任务
--- @param chat_id string 唯一 id（通常用 task_id 或 "dialog:"..task_id）
--- @param bufnr number|nil 关联的 buffer（可选，仅用于你自己在回调里用）
--- @param prompt string 发送给大模型的完整 prompt
--- @param callbacks table { on_chunk?, on_finish?, on_error? }
function M.start(chat_id, bufnr, prompt, callbacks)
	if chats[chat_id] and chats[chat_id].active then
		-- 已有同名对话在跑，先停掉
		M.stop(chat_id)
	end

	local state = {
		active = true,
		finished = false,
		bufnr = bufnr,
		buffer = "",
		on_chunk = callbacks and callbacks.on_chunk or nil,
		on_finish = callbacks and callbacks.on_finish or nil,
		on_error = callbacks and callbacks.on_error or nil,
	}

	chats[chat_id] = state

	local ok, err = pcall(function()
		require("todo2.ai.executor").run_stream(prompt, {
			on_chunk = function(chunk)
				M.on_chunk(chat_id, chunk)
			end,
			on_finish = function()
				M.finish(chat_id)
			end,
			on_error = function(msg)
				M.error(chat_id, msg)
			end,
		})
	end)

	if not ok then
		M.error(chat_id, err)
	end

	return chat_id
end

------------------------------------------------------------
-- 处理 chunk
------------------------------------------------------------
function M.on_chunk(chat_id, chunk)
	local state = chats[chat_id]
	if not state or not state.active or state.finished then
		return
	end
	if not chunk or chunk == "" then
		return
	end

	chunk = normalizer.normalize(chunk)
	if chunk == "" then
		return
	end

	state.buffer = state.buffer .. chunk

	if state.on_chunk then
		-- 交给上层（dialog_box）去更新 UI
		pcall(state.on_chunk, chunk, state)
	end
end

------------------------------------------------------------
-- 正常结束
------------------------------------------------------------
function M.finish(chat_id)
	local state = chats[chat_id]
	if not state then
		return
	end
	if state.finished then
		return
	end

	state.active = false
	state.finished = true

	if state.on_finish then
		pcall(state.on_finish, state.buffer, state)
	end

	chats[chat_id] = nil
end

------------------------------------------------------------
-- 错误结束
------------------------------------------------------------
function M.error(chat_id, msg)
	local state = chats[chat_id]
	if not state then
		return
	end

	state.active = false
	state.finished = true

	if state.on_error then
		pcall(state.on_error, msg, state)
	end

	chats[chat_id] = nil
end

------------------------------------------------------------
-- 主动停止
------------------------------------------------------------
function M.stop(chat_id)
	local state = chats[chat_id]
	if not state then
		return false, "对话不存在"
	end

	state.active = false
	state.finished = true

	-- 这里没有底层连接可断（executor.run_stream 内部自己处理），
	-- 所以我们只是在逻辑上标记结束，后续 chunk 会被丢弃。
	chats[chat_id] = nil
	return true
end

------------------------------------------------------------
-- 查询状态（可选）
------------------------------------------------------------
function M.get(chat_id)
	return chats[chat_id]
end

return M
