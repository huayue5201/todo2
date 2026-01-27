-- lua/todo2/link/creator.lua
--- @module todo2.link.creator
--- @brief 创建代码 ↔ TODO 双链（专业版：buffer 写入 + 事件驱动刷新）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- ⭐ 专业版：向 TODO 文件插入任务（使用 buffer API）
---------------------------------------------------------------------
local function add_task_to_todo_file(todo_path, id)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")

	-- 加载 TODO 文件 buffer
	local bufnr = vim.fn.bufnr(todo_path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(bufnr)
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("无法加载 TODO 文件: " .. todo_path, vim.log.levels.ERROR)
		return
	end

	-- 获取当前行内容
	local utils = module.get("link.utils")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local insert_line = utils.find_task_insert_position(lines)

	-- 插入任务行
	local task_line = string.format("- [ ] {#%s} 新任务", id)
	vim.api.nvim_buf_set_lines(bufnr, insert_line - 1, insert_line - 1, false, { task_line })

	-- 写入 store
	local store = module.get("store")
	store.add_todo_link(id, {
		path = todo_path,
		line = insert_line,
		content = "新任务",
		created_at = os.time(),
	})

	-- 自动写盘（触发 autosave → BufWritePost → sync → 事件系统 → 刷新）
	local autosave = module.get("core.autosave")
	autosave.request_save(bufnr)

	-- 打开 TODO 文件浮窗并跳到新任务
	local ui = module.get("ui")
	ui.open_todo_file(todo_path, "float", insert_line, {
		enter_insert = true,
	})

	vim.notify("已创建 TODO 链接: " .. id, vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- ⭐ 主函数：创建链接（支持 TAG 选择 + 新建 TODO 文件）
---------------------------------------------------------------------
function M.create_link()
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	local lnum = vim.fn.line(".")

	if file_path == "" then
		vim.notify("无法创建链接：当前 buffer 没有文件路径", vim.log.levels.ERROR)
		return
	end

	local utils = module.get("link.utils")
	local id = utils.generate_id()

	-----------------------------------------------------------------
	-- 1. 选择 TAG
	-----------------------------------------------------------------
	local link_mod = module.get("link")
	local render_cfg = link_mod.get_render_config()
	local tag_choices = {}

	for tag, style in pairs(render_cfg.tags or {}) do
		table.insert(tag_choices, {
			tag = tag,
			display = string.format("%s  %s", style.icon or "", tag),
		})
	end

	vim.ui.select(tag_choices, {
		prompt = "选择标签类型",
		format_item = function(item)
			return item.display
		end,
	}, function(tag_item)
		if not tag_item then
			return
		end

		local selected_tag = tag_item.tag

		-----------------------------------------------------------------
		-- 2. 选择 TODO 文件
		-----------------------------------------------------------------
		local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
		local file_manager = module.get("ui.file_manager")
		local todo_files = file_manager.get_todo_files(project)

		local choices = {}

		for _, f in ipairs(todo_files) do
			table.insert(choices, {
				type = "existing",
				path = f,
				display = vim.fn.fnamemodify(f, ":t"),
				project = project,
			})
		end

		table.insert(choices, {
			type = "new",
			path = nil,
			display = "🆕 新建 TODO 文件",
			project = project,
		})

		if #todo_files == 0 then
			table.insert(choices, {
				type = "info",
				path = nil,
				display = "当前项目没有 TODO 文件，请新建一个",
				project = project,
			})
		end

		vim.ui.select(choices, {
			prompt = "选择 TODO 文件",
			format_item = function(item)
				return item.display
			end,
		}, function(choice)
			if not choice or choice.type == "info" then
				return
			end

			-----------------------------------------------------------------
			-- 3. 确定 TODO 文件路径
			-----------------------------------------------------------------
			local todo_path = nil

			if choice.type == "existing" then
				todo_path = choice.path
			elseif choice.type == "new" then
				local ui = module.get("ui")
				todo_path = ui.create_todo_file()
				if not todo_path or todo_path == "" then
					vim.notify("已取消创建 TODO 文件", vim.log.levels.INFO)
					return
				end
			end

			-----------------------------------------------------------------
			-- 4. 插入代码 TAG
			-----------------------------------------------------------------
			utils.insert_code_tag_above(bufnr, lnum, id)

			local store = module.get("store")
			store.add_code_link(id, {
				path = file_path,
				line = lnum - 1,
				content = "",
				created_at = os.time(),
			})

			-- 自动写盘（触发事件系统）
			local autosave = module.get("core.autosave")
			autosave.request_save(bufnr)

			-----------------------------------------------------------------
			-- 5. 插入 TODO 文件任务（buffer API）
			-----------------------------------------------------------------
			add_task_to_todo_file(todo_path, id)
		end)
	end)
end

return M
