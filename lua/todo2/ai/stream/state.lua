-- lua/todo2/ai/stream/state.lua
-- 负责管理流式引擎的内部状态

local M = {}

------------------------------------------------------------
-- 创建一个新的状态对象
------------------------------------------------------------
function M.new()
	return {
		active = false,
		closing = false,
		finished = false,

		bufnr = nil,
		path = nil,
		todo = nil,
		ctx = nil,
		code_link = nil,

		-- 协议/范围
		protocol = nil,
		range = nil,
		write_mode = "overwrite",

		-- 原始区域备份
		original_backup = {},

		-- 流式相关
		buffer = "",
		queue = {},
		writing = false,
		current_line = nil,
	}
end

------------------------------------------------------------
-- 重置状态（start 时调用）
------------------------------------------------------------
function M.reset(state, opts, original_lines)
	state.active = true
	state.closing = false
	state.finished = false

	state.bufnr = vim.fn.bufnr(opts.path)
	state.path = opts.path
	state.todo = opts.todo
	state.ctx = opts.ctx
	state.code_link = opts.code_link

	state.protocol = nil
	state.range = nil
	state.write_mode = "overwrite"

	state.original_backup = vim.deepcopy(original_lines)

	state.buffer = ""
	state.queue = {}
	state.writing = false
	state.current_line = nil
end

return M
