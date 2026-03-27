-- lua/todo2/ai/stream/state.lua
-- 管理流式引擎的内部状态

local M = {}

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
		parser = nil, -- 新增：协议解析器
		range = nil,
		write_mode = "overwrite",

		-- 原始区域备份
		original_backup = {},

		-- 流式相关
		buffer = "",
		queue = {},
		writing = false,
		current_line = nil,
		in_code = false,

		-- 进度相关
		received_chunk = false,
		start_time = nil,
		model_full_name = nil,
		marker_line = nil,
		error_message = nil,
	}
end

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
	state.parser = nil -- 由 engine 创建
	state.range = nil
	state.write_mode = "overwrite"

	state.original_backup = vim.deepcopy(original_lines)

	state.buffer = ""
	state.queue = {}
	state.writing = false
	state.current_line = nil
	state.in_code = false

	state.received_chunk = false
	state.start_time = vim.loop.hrtime() / 1e6
	state.model_full_name = opts.model_name or "AI"
	state.marker_line = opts.code_link and opts.code_link.line or opts.ctx.start_line
	state.error_message = nil
end

return M
