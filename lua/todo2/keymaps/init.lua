--- File: /Users/lijia/todo2/lua/todo2/keymaps/init.lua ---
-- lua/todo2/keymaps/init.lua
--- @module todo2.keymaps
--- @brief 统一按键映射管理系统

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------

---------------------------------------------------------------------
-- 按键模式定义
---------------------------------------------------------------------
M.MODE = {
	GLOBAL = "global", -- 全局映射
	UI = "ui", -- TODO UI窗口映射
	CODE = "code", -- 代码文件映射
	TODO_EDIT = "todo_edit", -- TODO编辑模式映射
}

---------------------------------------------------------------------
-- 按键处理器仓库（方法分离）
---------------------------------------------------------------------
M.Handlers = {
	-- 全局处理器
	global = {},
	-- UI处理器
	ui = {},
	-- 代码处理器
	code = {},
	-- TODO编辑处理器
	todo_edit = {},
}

---------------------------------------------------------------------
-- 按键映射定义仓库（映射分离）
---------------------------------------------------------------------
M.Mappings = {
	-- 全局映射
	global = {},
	-- UI映射（TODO窗口）
	ui = {},
	-- 代码文件映射
	code = {},
	-- TODO编辑模式映射
	todo_edit = {},
}

---------------------------------------------------------------------
-- 核心：注册处理器（方法）
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

	-- 确保 opts 格式正确
	local mapping_opts = opts or {}

	-- 确保有 mode 字段（vim.keymap.set 需要的模式）
	if not mapping_opts.mode then
		mapping_opts.mode = "n" -- 默认 normal 模式
	end

	local mapping = {
		lhs = lhs,
		handler_name = handler_name,
		opts = mapping_opts, -- 包含 vim.keymap.set 需要的所有选项
		mode = mode, -- 我们自己的模式分类（UI/CODE等）
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

			-- 从 opts 中提取 vim.keymap.set 的 mode 参数
			local keymap_modes = opts.mode or "n"
			opts.mode = nil -- 从 opts 中删除 mode

			-- 如果是缓冲区映射，添加buffer选项
			if mode ~= M.MODE.GLOBAL then
				opts.buffer = bufnr
			end

			-- 处理多种模式的情况
			if type(keymap_modes) == "table" then
				for _, m in ipairs(keymap_modes) do
					vim.keymap.set(m, mapping.lhs, handler_info.handler, opts)
					bound_count = bound_count + 1
				end
			else
				-- 单个模式
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
		-- 代码文件映射
		return M.bind_mapping(bufnr, M.MODE.CODE)
	end
end

function M.edit_task()
	-- ⭐ 新增：为每个新缓冲区绑定上下文按键映射
	vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
		group = vim.api.nvim_create_augroup("Todo2Keymaps", { clear = true }),
		callback = function(args)
			local bufnr = args.buf
			-- 跳过无效缓冲区
			if not bufnr or bufnr == 0 then
				return
			end
			-- 获取文件类型和窗口类型
			local filetype = vim.bo[bufnr].filetype
			local win_id = vim.fn.bufwinid(bufnr)
			local is_float = false
			if win_id ~= -1 then
				local config = vim.api.nvim_win_get_config(win_id)
				is_float = config.relative ~= "" and config.relative ~= "none"
			end
			-- 绑定上下文映射
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
-- 工具函数：获取处理器
---------------------------------------------------------------------
function M.get_handler(mode, name)
	if M.Handlers[mode] then
		return M.Handlers[mode][name]
	end
	return nil
end

---------------------------------------------------------------------
-- 打印映射状态（调试）
---------------------------------------------------------------------
function M.print_status()
	print("=== 按键映射系统状态 ===")
	for mode_name, mappings in pairs(M.Mappings) do
		print(string.format("\n模式: %s (%d个映射)", mode_name, #mappings))
		for _, mapping in ipairs(mappings) do
			local handler = M.get_handler(mode_name, mapping.handler_name)
			local desc = handler and handler.description or "无描述"
			print(string.format("  %s -> %s (%s)", mapping.lhs, mapping.handler_name, desc))
		end
	end
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
-- 初始化函数（必需）
---------------------------------------------------------------------
function M.setup()
	-- 清理缓存
	M.clear_all()

	M.edit_task()

	-- 加载定义模块并初始化
	local definitions = require("todo2.keymaps.definitions")
	if definitions and definitions.setup then
		definitions.setup()
	else
		vim.notify("无法加载按键映射定义模块", vim.log.levels.ERROR)
	end
	return M
end

return M
