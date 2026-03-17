-- ai/dialog_box/session.lua
local M = {}

M.sessions = {}

local function new_session()
	return {
		messages = {},
		next_id = 1,
	}
end

function M.get(task_id)
	if not M.sessions[task_id] then
		M.sessions[task_id] = new_session()
	end
	return M.sessions[task_id]
end

function M.add_message(task_id, msg)
	local s = M.get(task_id)
	msg.id = s.next_id
	s.next_id = s.next_id + 1
	table.insert(s.messages, msg)
	return msg
end

return M
