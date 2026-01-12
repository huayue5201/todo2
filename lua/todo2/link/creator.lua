--- @module todo2.link.creator
--- @brief 创建代码 ↔ TODO 双链（支持 TAG 选择）

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local utils
local ui
local file_manager
local link_mod

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

local function get_utils()
	if not utils then
		utils = require("todo2.link.utils")
	end
	return utils
end

local function get_ui()
	if not ui then
		ui = require("todo2.ui")
	end
	return ui
end

local function get_file_manager()
	if not file_manager then
		file_manager = require("todo2.ui.file_manager")
	end
	return file_manager
end

local function get_link_mod()
	if not link_mod then
		link_mod = require("todo2.link")
	end
	return link_mod
end

---------------------------------------------------------------------
-- 内部函数：向 TODO 文件插入任务
---------------------------------------------------------------------

local function add_task_to_todo_file(todo_path, id)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")

	local ok, lines = pcall(vim.fn.readfile, todo_path)
	if not ok then
		vim.notify("无法读取 TODO 文件: " .. todo_path, vim.log.levels.ERROR)
		return
	end

	local insert_line = get_utils().find_task_insert_position(lines)

	local task_line = string.format("- [ ] {#%s} 新任务", id)
	table.insert(lines, insert_line, task_line)

	local fd = io.open(todo_path, "w")
	if not fd then
		vim.notify("无法写入 TODO 文件", vim.log.levels.ERROR)
		return
	end
	fd:write(table.concat(lines, "\n"))
	fd:close()

	get_store().add_todo_link(id, {
		path = todo_path,
		line = insert_line,
		content = "新任务",
		created_at = os.time(),
	})

	get_ui().open_todo_file(todo_path, "float", insert_line, {
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

	local id = get_utils().generate_id()

	-----------------------------------------------------------------
	-- ⭐ 第一步：选择 TAG
	-----------------------------------------------------------------

	local render_cfg = get_link_mod().get_render_config()
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
		-- ⭐ 第二步：选择 TODO 文件
		-----------------------------------------------------------------

		local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
		local todo_files = get_file_manager().get_todo_files(project)

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
			-- ⭐ 第三步：确定 TODO 文件路径（existing 或 new）
			-----------------------------------------------------------------

			local todo_path = nil

			if choice.type == "existing" then
				todo_path = choice.path
			elseif choice.type == "new" then
				-- ⭐ 用户命名（可能取消）
				todo_path = get_ui().create_todo_file()

				-- ⭐ 用户取消 → 不插入标签
				if not todo_path or todo_path == "" then
					vim.notify("已取消创建 TODO 文件", vim.log.levels.INFO)
					return
				end
			end

			-----------------------------------------------------------------
			-- ⭐ 第四步：插入代码标记（只有在 todo_path 确定后才执行）
			-----------------------------------------------------------------

			local comment = get_utils().get_comment_prefix()
			local insert_line = string.format("%s %s:ref:%s", comment, selected_tag, id)

			vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { insert_line })

			get_store().add_code_link(id, {
				path = file_path,
				line = lnum + 1,
				content = "",
				created_at = os.time(),
			})

			-----------------------------------------------------------------
			-- ⭐ 第五步：插入 TODO 文件任务
			-----------------------------------------------------------------

			add_task_to_todo_file(todo_path, id)

			-----------------------------------------------------------------
			-- 自动刷新渲染
			-----------------------------------------------------------------

			vim.schedule(function()
				require("todo2.link.renderer").render_code_status(bufnr)
			end)
		end)
	end)
end

return M
