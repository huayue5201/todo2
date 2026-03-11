-- lua/todo2/utils/tag_manager.lua
-- 精简版 - 统一标签获取逻辑

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local link_mod = require("todo2.store.link")

function M.get_configured_tags()
	return config.get("tags") or {}
end

--- 获取标签（存储优先，实时校验）
function M.get_tag(id, opts)
	opts = opts or {}
	local context = opts.context or "default"

	-- 获取存储中的标签（主来源）
	local storage_tag = M._get_storage_tag(id)

	-- 如果是存储操作或配置获取，直接返回存储标签
	if context == "storage" or context == "config" then
		return storage_tag
	end

	-- 获取实时标签
	local realtime_tag = M._get_realtime_tag(id)

	-- 如果不一致，根据策略处理
	if storage_tag ~= realtime_tag and realtime_tag ~= "TODO" then
		if opts.validate then
			M._fix_tag_inconsistency(id, storage_tag, realtime_tag)
			return realtime_tag
		elseif opts.force_realtime then
			return realtime_tag
		end
		M._log_tag_inconsistency(id, storage_tag, realtime_tag)
	end

	return storage_tag
end

function M._get_storage_tag(id)
	if not link_mod then
		return "TODO"
	end

	local code_link = link_mod.get_code(id, { verify_line = true })
	if code_link and code_link.tag and code_link.tag ~= "TODO" then
		return code_link.tag
	end

	local todo_link = link_mod.get_todo(id, { verify_line = true })
	if todo_link and todo_link.tag and todo_link.tag ~= "TODO" then
		return todo_link.tag
	end

	return "TODO"
end

function M._get_realtime_tag(id)
	if not link_mod then
		return "TODO"
	end

	-- 1. 尝试从代码文件获取
	local code_link = link_mod.get_code(id, { verify_line = true })
	if code_link and code_link.path then
		local ok, lines = pcall(vim.fn.readfile, code_link.path)
		if ok and lines and code_link.line and code_link.line <= #lines then
			local code_line = lines[code_link.line]
			if code_line then
				-- ✅ 使用统一的标签提取
				local code_tag = format.extract_tag(code_line)
				if code_tag ~= "TODO" then
					return code_tag
				end
			end
		end
	end

	-- 2. 尝试从TODO文件获取
	local todo_link = link_mod.get_todo(id, { verify_line = true })
	if todo_link and todo_link.path then
		local ok, lines = pcall(vim.fn.readfile, todo_link.path)
		if ok and lines and todo_link.line and todo_link.line <= #lines then
			local todo_line = lines[todo_link.line]
			if todo_line then
				local task_tag = format.extract_tag(todo_line)
				if task_tag ~= "TODO" then
					return task_tag
				end
			end
		end
	end

	return "TODO"
end

function M._fix_tag_inconsistency(id, old_tag, new_tag)
	if not link_mod then
		return
	end

	if old_tag == "TODO" and new_tag ~= "TODO" then
		local code_link = link_mod.get_code(id, { verify_line = true })
		if code_link then
			code_link.tag = new_tag
			link_mod.add_code(id, code_link)
		end

		local todo_link = link_mod.get_todo(id, { verify_line = true })
		if todo_link then
			todo_link.tag = new_tag
			link_mod.add_todo(id, todo_link)
		end

		vim.notify(string.format("修复标签不一致: %s → %s", old_tag, new_tag), vim.log.levels.INFO)
	end
end

function M._log_tag_inconsistency(id, storage_tag, realtime_tag)
	vim.notify(
		string.format("标签不一致: 存储=%s, 文件=%s (ID: %s)", storage_tag, realtime_tag, id:sub(1, 6)),
		vim.log.levels.DEBUG
	)
end

function M.get_tag_for_render(id)
	return M.get_tag(id, {
		force_realtime = true,
		context = "render",
	})
end

function M.get_tag_for_user_action(id)
	local storage_tag = M.get_tag(id, { context = "storage" })
	local realtime_tag = M.get_tag(id, { force_realtime = true })

	if storage_tag == "TODO" and realtime_tag ~= "TODO" then
		return realtime_tag
	end

	return storage_tag
end

return M
