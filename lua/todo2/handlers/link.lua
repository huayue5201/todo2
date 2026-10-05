-- lua/todo2/handlers/link.lua
-- 双链 / 预览处理器

local M = {}

local buffer = require("todo2.utils.buffer")
local line = require("todo2.utils.line")
local file_utils = require("todo2.utils.file")
local core = require("todo2.store.task.core")
local index = require("todo2.store.index")
local cursor = require("todo2.task.cursor")
local link_preview = require("todo2.task.preview")
local link_viewer = require("todo2.task.viewer")
local fm = require("todo2.ui.file_manager")
local project_utils = require("todo2.utils.project")

--- 把当前光标所在代码行绑定到指定任务。
--- 单锚点：任务已链接时，重新指定会替换旧锚点（并清掉旧文件索引）。
---@param bufnr number
---@param lnum number
---@param id string
function M.link(bufnr, lnum, id)
	local task = core.get_task(id)
	if not task then
		vim.notify("找不到任务: " .. tostring(id), vim.log.levels.ERROR)
		return false
	end

	local new_path = file_utils.normalize_path(buffer.get_path(bufnr))
	local old = task.locations and task.locations.code
	local was_lost = core.is_anchor_lost(task)
	local content = task.core.content or ""

	-- 复用创建路径：对已存在的任务会替换其 code 位置（含 context 与索引）
	require("todo2.creation.service").create_code_link(bufnr, lnum, id, content, function(ok)
		if not ok then
			return -- create_code_link 已提示过失败原因；不要报“成功”
		end

		local function short(p)
			return (p and p ~= "") and vim.fn.fnamemodify(p, ":t") or "?"
		end

		local msg
		if not old then
			msg = ("已将 %s 关联到 %s:%d"):format(id, short(new_path), lnum)
		elseif was_lost then
			msg = ("已恢复 %s 的锚点：%s:%d"):format(id, short(new_path), lnum)
		elseif old.path == new_path and old.line == lnum then
			msg = ("已刷新 %s 的锚点（%s:%d）"):format(id, short(new_path), lnum)
		elseif old.path == new_path then
			msg = ("已将 %s 从第 %d 行改到第 %d 行"):format(id, old.line, lnum)
		else
			msg = ("已将 %s 的锚点从 %s:%d 改到 %s:%d"):format(id, short(old.path), old.line, short(new_path), lnum)
		end
		vim.schedule(function()
			vim.notify(msg, vim.log.levels.INFO)
		end)
	end)
	return true
end

--- 把当前光标所在代码行绑定到已有任务（补齐“只能从代码新建任务”的缺口）。
---@param id? string 任务 ID；省略则弹出当前项目的任务列表
function M.link_task(id)
	local bufnr = vim.api.nvim_get_current_buf()
	local path = buffer.get_path(bufnr)
	local lnum = vim.fn.line(".")

	if path == "" or file_utils.is_todo_file(path) then
		vim.notify("请在代码文件中使用该命令", vim.log.levels.WARN)
		return
	end

	-- 目标行已被占用：只放行“同一任务原地刷新”，其余一律拒绝
	local occupied = index.find_code_task_at_line(path, lnum)
	if occupied and occupied.id ~= id then
		vim.notify(("第 %d 行已关联任务 %s，请先解除或换一行"):format(lnum, occupied.id), vim.log.levels.WARN)
		return
	end

	if id and id ~= "" then
		M.link(bufnr, lnum, id)
		return
	end

	-- 收集当前项目的任务供选择
	local items = {}
	for _, file in ipairs(fm.get_todo_files(project_utils.get_project_name())) do
		for _, t in ipairs(index.find_todo_links_by_file(file)) do
			items[#items + 1] = { id = t.id, content = t.core.content or "" }
		end
	end

	if #items == 0 then
		vim.notify("当前项目没有可关联的任务", vim.log.levels.WARN)
		return
	end
	table.sort(items, function(a, b)
		return a.content < b.content
	end)

	vim.ui.select(items, {
		prompt = "关联到任务：",
		format_item = function(item)
			return ("%s  %s"):format(item.id, item.content)
		end,
	}, function(choice)
		if choice then
			M.link(bufnr, lnum, choice.id)
		end
	end)
end

--- 预览任务内容（代码预览或 TODO 预览）
function M.preview_content()
	local info = buffer.get_current_info()
	local task = nil

	if info.is_todo_file then
		local analysis = line.analyze_current_line()
		if analysis.id then
			task = core.get_task(analysis.id)
		end
	else
		task = cursor.get_task(info.bufnr, vim.fn.line("."))
	end

	if task then
		if info.is_todo_file then
			link_preview.preview_code()
		else
			link_preview.preview_todo()
		end
	end
end

--- 在 quickfix 中显示项目所有链接
function M.show_project_links_qf()
	link_viewer.show_project_links_qf()
end

--- 在 location list 中显示当前缓冲区链接
function M.show_buffer_links_loclist()
	link_viewer.show_buffer_links_loclist()
end

return M
