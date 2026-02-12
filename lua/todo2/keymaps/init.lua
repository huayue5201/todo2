-- lua/todo2/keymaps/init.lua
--- @module todo2.keymaps
--- @brief 统一按键映射管理系统

local M = {}

---------------------------------------------------------------------
-- 按键模式定义
---------------------------------------------------------------------
M.MODE = {
	GLOBAL = "global",
	UI = "ui",
	CODE = "code",
	TODO_EDIT = "todo_edit",
}

---------------------------------------------------------------------
-- 按键处理器仓库
---------------------------------------------------------------------
M.Handlers = {
	global = {},
	ui = {},
	code = {},
	todo_edit = {},
}

---------------------------------------------------------------------
-- 按键映射定义仓库
---------------------------------------------------------------------
M.Mappings = {
	global = {},
	ui = {},
	code = {},
	todo_edit = {},
}

---------------------------------------------------------------------
-- 核心：注册处理器
---------------------------------------------------------------------
function M.register_handler(mode, name, handler, description)
	if not M.Handlers[mode] then
		error(string.format("无效的模式: %s", mode))
	end
	M.Handlers[mode][name] = {
		handler = handler,
		description = description or "",
	}
	return true
end

---------------------------------------------------------------------
-- 核心：定义映射
---------------------------------------------------------------------
function M.define_mapping(mode, lhs, handler_name, opts)
	if not M.Mappings[mode] then
		error(string.format("无效的模式: %s", mode))
	end
	local mapping_opts = opts or {}
	if not mapping_opts.mode then
		mapping_opts.mode = "n"
	end
	local mapping = {
		lhs = lhs,
		handler_name = handler_name,
		opts = mapping_opts,
		mode = mode,
	}
	table.insert(M.Mappings[mode], mapping)
	return mapping
end

---------------------------------------------------------------------
-- 核心：绑定映射
---------------------------------------------------------------------
function M.bind_mapping(bufnr, mode)
	if not M.Mappings[mode] then
		return 0
	end
	local bound_count = 0
	local handlers = M.Handlers[mode]

	for _, mapping in ipairs(M.Mappings[mode]) do
		local handler_info = handlers[mapping.handler_name]
		if handler_info then
			local opts = vim.deepcopy(mapping.opts or {})
			opts.desc = opts.desc or handler_info.description
			local keymap_modes = opts.mode or "n"
			opts.mode = nil
			if mode ~= M.MODE.GLOBAL then
				opts.buffer = bufnr
			end
			if type(keymap_modes) == "table" then
				for _, m in ipairs(keymap_modes) do
					vim.keymap.set(m, mapping.lhs, handler_info.handler, opts)
					bound_count = bound_count + 1
				end
			else
				vim.keymap.set(keymap_modes, mapping.lhs, handler_info.handler, opts)
				bound_count = bound_count + 1
			end
		end
	end
	return bound_count
end

---------------------------------------------------------------------
-- 根据上下文绑定映射
---------------------------------------------------------------------
function M.bind_for_context(bufnr, filetype, is_float_window)
	if filetype == "markdown" and vim.api.nvim_buf_get_name(bufnr):match("%.todo%.md$") then
		if is_float_window then
			return M.bind_mapping(bufnr, M.MODE.UI)
		else
			return M.bind_mapping(bufnr, M.MODE.TODO_EDIT)
		end
	else
		return M.bind_mapping(bufnr, M.MODE.CODE)
	end
end

---------------------------------------------------------------------
-- 为新缓冲区绑定上下文按键映射（自动命令）
---------------------------------------------------------------------
function M.edit_task()
	vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
		group = vim.api.nvim_create_augroup("Todo2Keymaps", { clear = true }),
		callback = function(args)
			local bufnr = args.buf
			if not bufnr or bufnr == 0 then
				return
			end
			local filetype = vim.bo[bufnr].filetype
			local win_id = vim.fn.bufwinid(bufnr)
			local is_float = false
			if win_id ~= -1 then
				local config = vim.api.nvim_win_get_config(win_id)
				is_float = config.relative ~= "" and config.relative ~= "none"
			end
			require("todo2.keymaps").bind_for_context(bufnr, filetype, is_float)
		end,
		desc = "Bind todo2 context keymaps",
	})
end

---------------------------------------------------------------------
-- 初始化：注册全局映射
---------------------------------------------------------------------
function M.setup_global_keymaps()
	return M.bind_mapping(nil, M.MODE.GLOBAL)
end

---------------------------------------------------------------------
-- 清空所有映射（用于热重载）
---------------------------------------------------------------------
function M.clear_all()
	M.Handlers = {
		global = {},
		ui = {},
		code = {},
		todo_edit = {},
	}
	M.Mappings = {
		global = {},
		ui = {},
		code = {},
		todo_edit = {},
	}
end

---------------------------------------------------------------------
-- 初始化函数
---------------------------------------------------------------------
function M.setup()
	M.clear_all()
	M.edit_task()
	local definitions = require("todo2.keymaps.definitions")
	if definitions and definitions.setup then
		definitions.setup()
	else
		vim.notify("无法加载按键映射定义模块", vim.log.levels.ERROR)
	end
	return M
end

return M
