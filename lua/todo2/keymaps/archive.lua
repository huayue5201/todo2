-- lua/todo2/keymaps/archive.lua
--- @module todo2.keymaps.archive
--- @brief 归档与撤销归档的按键处理器

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local core = require("todo2.core")
local store_link = require("todo2.store.link")
local format = require("todo2.utils.format")
local parser = require("todo2.core.parser")
local ui = require("todo2.ui")
local conceal = require("todo2.ui.conceal")
local config = require("todo2.config")
local archive = require("todo2.core.archive")

---------------------------------------------------------------------
-- 归档当前文件中所有已完成任务
---------------------------------------------------------------------
function M.archive_completed_tasks()
	if not core or not core.archive_completed_tasks then
		vim.notify("归档模块未加载", vim.log.levels.ERROR)
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	core.archive_completed_tasks(bufnr)
end

---------------------------------------------------------------------
-- 撤销归档当前光标所在任务
---------------------------------------------------------------------
function M.unarchive_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

	-- 1. 提取任务ID
	local id = line:match("{#(%w+)}")
	if not id then
		vim.notify("当前行不是有效任务", vim.log.levels.WARN)
		return
	end

	-- 2. 获取存储模块
	if not store_link then
		vim.notify("store.link 模块未加载", vim.log.levels.ERROR)
		return
	end

	-- 3. 调用存储层：取消归档（archived → completed）
	local ok = store_link.unarchive_link(id)
	if not ok then
		vim.notify("取消归档失败，任务可能不是归档状态", vim.log.levels.ERROR)
		return
	end

	-- 4. 删除当前归档行
	vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, {})

	-- 5. 确定插入位置（正文区：第一个非“## Archived”的行）
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local insert_line = 1
	for i, l in ipairs(lines) do
		if not l:match("^## Archived") then
			insert_line = i
			break
		end
	end

	-- 6. 获取任务最新信息（存储中已改为 completed）
	local task = store_link.get_todo(id, { verify_line = false })
	if not task then
		vim.notify("无法获取任务信息", vim.log.levels.ERROR)
		return
	end

	-- 7. 生成新的任务行（已完成状态）
	local new_line = format.format_task_line({
		indent = "", -- 缩进可根据需要调整，此处置零
		checkbox = "[x]", -- 已完成
		id = id,
		tag = task.tag or "TODO",
		content = task.content or "",
	})

	-- 8. 插入新行
	vim.api.nvim_buf_set_lines(bufnr, insert_line - 1, insert_line - 1, false, { new_line })

	-- 9. 清理解析器缓存，刷新 UI
	if parser then
		parser.invalidate_cache(vim.api.nvim_buf_get_name(bufnr))
	end
	if ui and ui.refresh then
		ui.refresh(bufnr, true)
	end

	-- 10. 刷新所有已加载代码缓冲区的 conceal（保持视觉一致）
	if conceal then
		local all_bufs = vim.api.nvim_list_bufs()
		for _, buf in ipairs(all_bufs) do
			if vim.api.nvim_buf_is_loaded(buf) then
				local name = vim.api.nvim_buf_get_name(buf)
				if name and not name:match("%.todo%.md$") then
					conceal.apply_buffer_conceal(buf)
				end
			end
		end
	end

	vim.notify("任务已取消归档，恢复为已完成", vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- 归档清理处理器
---------------------------------------------------------------------
function M.cleanup_expired_archives()
	if not archive or not archive.cleanup_all_archives then
		vim.notify("归档模块未加载", vim.log.levels.ERROR)
		return
	end

	local days = config.get("archive.retention_days") or 90
	local report = archive.cleanup_all_archives(days)
	vim.notify(string.format("已清理 %d 个过期归档任务", report.total_deleted), vim.log.levels.INFO)
end

return M
