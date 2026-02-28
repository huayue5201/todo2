local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")

local link_mod = require("todo2.store.link")

---------------------------------------------------------------------
-- 标签提取函数（统一放在一个地方）
---------------------------------------------------------------------

--- 获取配置中的标签定义
function M.get_configured_tags()
	return config.get("tags") or {}
end

---------------------------------------------------------------------
-- 统一标签获取函数（核心）- 保持不变
---------------------------------------------------------------------

--- 获取标签（存储优先，实时校验）
--- @param id string 任务ID
--- @param opts table 选项
---   - force_realtime: boolean 强制使用实时数据
---   - validate: boolean 验证并修复不一致
---   - context: string 使用场景
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
			-- 验证模式：修复存储中的标签
			M._fix_tag_inconsistency(id, storage_tag, realtime_tag)
			return realtime_tag
		elseif opts.force_realtime then
			-- 强制实时模式：使用实时标签
			return realtime_tag
		end
		-- 默认：优先使用存储标签，但记录不一致
		M._log_tag_inconsistency(id, storage_tag, realtime_tag)
	end

	return storage_tag
end

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------

-- 从存储获取标签
function M._get_storage_tag(id)
	if not link_mod then
		return "TODO"
	end

	-- 优先从代码链接获取（更准确）
	local code_link = link_mod.get_code(id, { verify_line = true })
	if code_link and code_link.tag and code_link.tag ~= "TODO" then
		return code_link.tag
	end

	-- 其次从TODO链接获取
	local todo_link = link_mod.get_todo(id, { verify_line = true })
	if todo_link and todo_link.tag and todo_link.tag ~= "TODO" then
		return todo_link.tag
	end

	return "TODO"
end

-- ⭐ 修改 _get_realtime_tag 函数，使用 format.extract_from_code_line
function M._get_realtime_tag(id)
	if not link_mod then
		return "TODO"
	end

	-- 1. 尝试从代码文件获取
	local code_link = link_mod.get_code(id, { verify_line = true })
	if code_link and code_link.path then
		local ok, lines = pcall(vim.fn.readfile, code_link.path)
		if ok and code_link.line <= #lines then
			local code_line = lines[code_link.line]
			local code_tag, _ = format.extract_from_code_line(code_line)
			if code_tag ~= "TODO" then
				return code_tag
			end
		end
	end

	-- 2. 尝试从TODO文件获取
	local todo_link = link_mod.get_todo(id, { verify_line = true })
	if todo_link and todo_link.path then
		local ok, lines = pcall(vim.fn.readfile, todo_link.path)
		if ok and todo_link.line <= #lines then
			local todo_line = lines[todo_link.line]
			local task_tag = format.extract_tag(todo_line)
			if task_tag ~= "TODO" then
				return task_tag
			end
		end
	end

	return "TODO"
end

-- 修复标签不一致
function M._fix_tag_inconsistency(id, old_tag, new_tag)
	if not link_mod then
		return
	end

	-- 只有在明显不一致时才修复（如TODO vs FIX）
	if old_tag == "TODO" and new_tag ~= "TODO" then
		-- 更新存储中的标签
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

-- 记录标签不一致（用于调试）
function M._log_tag_inconsistency(id, storage_tag, realtime_tag)
	-- 可以记录到日志，但不会修复
	vim.notify(
		string.format("标签不一致: 存储=%s, 文件=%s (ID: %s)", storage_tag, realtime_tag, id:sub(1, 6)),
		vim.log.levels.DEBUG
	)
end

---------------------------------------------------------------------
-- 场景专用函数
---------------------------------------------------------------------

--- 获取渲染用标签（实时优先）
function M.get_tag_for_render(id)
	return M.get_tag(id, {
		force_realtime = true,
		context = "render",
	})
end

--- 获取存储用标签（存储优先）
function M.get_tag_for_storage(id)
	return M.get_tag(id, {
		context = "storage",
	})
end

--- 获取用户操作标签（智能合并）
function M.get_tag_for_user_action(id)
	-- 用户操作时，优先显示存储标签
	-- 但如果存储是TODO而文件不是，显示文件标签
	local storage_tag = M.get_tag(id, { context = "storage" })
	local realtime_tag = M.get_tag(id, { force_realtime = true })

	if storage_tag == "TODO" and realtime_tag ~= "TODO" then
		return realtime_tag
	end

	return storage_tag
end

return M
