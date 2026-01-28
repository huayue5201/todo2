-- lua/todo2/link/creator.lua
--- @module todo2.link.creator
--- @brief 创建代码 ↔ TODO 双链

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 主函数：创建链接
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
			utils.insert_code_tag_above(bufnr, lnum, id, selected_tag)

			-----------------------------------------------------------------
			-- 5. 使用统一服务创建代码链接
			-----------------------------------------------------------------
			local link_service = module.get("link.service")
			local content = "" -- 可以在将来扩展为让用户输入内容
			link_service.create_code_link(bufnr, lnum, id, content)

			-----------------------------------------------------------------
			-- 6. 插入 TODO 文件任务
			-----------------------------------------------------------------
			local insert_line = link_service.insert_task_to_todo_file(todo_path, id, "新任务")

			if insert_line then
				-- 打开 TODO 文件浮窗并跳到新任务
				local ui = module.get("ui")
				ui.open_todo_file(todo_path, "float", insert_line, {
					enter_insert = true,
				})

				vim.notify("已创建 TODO 链接: " .. id, vim.log.levels.INFO)
			end
		end)
	end)
end

return M
