-- lua/todo2/link/syncer.lua
--- @module todo2.link.syncer
--- @brief 专业版：只负责同步链接，不直接刷新 UI / code

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 工具函数：扫描文件中的链接（支持 TAG）
---------------------------------------------------------------------
local function scan_code_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		local tag, id = line:match("(%u+):ref:(%w+)")
		if id then
			found[id] = i
		end
	end
	return found
end

local function scan_todo_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		local id = line:match("{#(%w+)}")
		if id then
			found[id] = i
		end
	end
	return found
end

local function get_context_triplet(lines, lnum)
	local prev = lines[lnum - 1]
	local curr = lines[lnum]
	local next = lines[lnum + 1]
	return prev or "", curr or "", next or ""
end

---------------------------------------------------------------------
-- ⭐ 核心修复：确保上下文是新格式
---------------------------------------------------------------------
local function ensure_context_format(ctx)
	if not ctx then
		return nil
	end

	-- 如果已经是新格式，直接返回
	if ctx.raw and ctx.fingerprint then
		return ctx
	end

	-- 获取 context 模块
	local context = module.get("store.context")

	-- 旧格式1: 只有 fingerprint 字段（没有 raw）
	if ctx.fingerprint and not ctx.raw then
		local fp = ctx.fingerprint
		return context.build(fp.n_prev or "", fp.n_curr or "", fp.n_next or "")
	end

	-- 旧格式2: 直接是 fingerprint 对象
	if ctx.n_curr then
		return context.build(ctx.n_prev or "", ctx.n_curr or "", ctx.n_next or "")
	end

	-- 无法识别的格式，返回空上下文
	return context.build("", "", "")
end

---------------------------------------------------------------------
-- ⭐ 同步：代码文件（代码 → TODO）
---------------------------------------------------------------------
function M.sync_code_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = scan_code_links(lines)

	local store_mod = module.get("store")
	local existing = store_mod.find_code_links_by_file(path)

	-----------------------------------------------------------------
	-- 1. 删除文件中已不存在的 code_link
	-----------------------------------------------------------------
	for _, link in ipairs(existing) do
		if not found[link.id] then
			store_mod.delete_code_link(link.id)
		end
	end

	-----------------------------------------------------------------
	-- 2. 写入 / 更新 code_link（确保使用新格式）
	-----------------------------------------------------------------
	for id, lnum in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, lnum)
		local ctx = store_mod.build_context(prev, curr, next)

		-- 确保上下文是新格式
		ctx = ensure_context_format(ctx)

		local old = store_mod.get_code_link(id)
		if old then
			-- ⭐ 关键修复：确保 old.context 也是新格式
			if old.context then
				old.context = ensure_context_format(old.context)
			end

			local need_update = false

			-- 如果 old.context 不存在，需要更新
			if not old.context then
				need_update = true
			else
				-- 使用升级后的上下文进行比较
				need_update = old.line ~= lnum or not store_mod.context_match(old.context, ctx)
			end

			if need_update then
				store_mod.add_code_link(id, {
					path = path,
					line = lnum,
					content = old.content or "",
					created_at = old.created_at or os.time(),
					context = ctx,
				})
			end
		else
			store_mod.add_code_link(id, {
				path = path,
				line = lnum,
				content = "",
				created_at = os.time(),
				context = ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- ⭐ 3. 触发事件（不直接刷新） - 修改版
	-----------------------------------------------------------------
	local events = module.get("core.events")
	local ids = {}
	for id, _ in pairs(found) do
		table.insert(ids, id)
	end

	-- 构建事件数据
	local event_data = {
		source = "sync_code_links",
		file = path,
		bufnr = bufnr,
		ids = ids,
	}

	-- 检查是否已经有相同的事件在处理中
	if not events.is_event_processing(event_data) then
		events.on_state_changed(event_data)
	end
end

---------------------------------------------------------------------
-- ⭐ 同步：TODO 文件（TODO → 代码）
---------------------------------------------------------------------
function M.sync_todo_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if #lines == 0 then
		return
	end

	local store_mod = module.get("store")

	-----------------------------------------------------------------
	-- 1. 扫描当前文件中的 {#id}
	-----------------------------------------------------------------
	local found = scan_todo_links(lines)

	-----------------------------------------------------------------
	-- 2. 清理：删除 store 中指向本文件、但已不存在的 todo_link
	-----------------------------------------------------------------
	local existing_links = store_mod.find_todo_links_by_file(path)
	for _, link in ipairs(existing_links) do
		if not found[link.id] then
			store_mod.delete_todo_link(link.id)
		end
	end

	-----------------------------------------------------------------
	-- 3. 写入 / 更新 todo_link（确保使用新格式）
	-----------------------------------------------------------------
	for id, lnum in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, lnum)
		local ctx = store_mod.build_context(prev, curr, next)

		-- 确保上下文是新格式
		ctx = ensure_context_format(ctx)

		local old = store_mod.get_todo_link(id)
		if old then
			-- ⭐ 关键修复：确保 old.context 也是新格式
			if old.context then
				old.context = ensure_context_format(old.context)
			end

			local need_update = false

			-- 如果 old.context 不存在，需要更新
			if not old.context then
				need_update = true
			else
				-- 使用升级后的上下文进行比较
				need_update = old.line ~= lnum or old.path ~= path or not store_mod.context_match(old.context, ctx)
			end

			if need_update then
				store_mod.add_todo_link(id, {
					path = path,
					line = lnum,
					content = old.content or "",
					created_at = old.created_at or os.time(),
					context = ctx,
				})
			end
		else
			store_mod.add_todo_link(id, {
				path = path,
				line = lnum,
				content = "",
				created_at = os.time(),
				context = ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- ⭐ 4. 触发事件（不直接刷新）
	-----------------------------------------------------------------
	local events = module.get("core.events")
	local ids = {}
	for id, _ in pairs(found) do
		table.insert(ids, id)
	end

	events.on_state_changed({
		source = "sync_todo_links",
		file = path,
		bufnr = bufnr,
		ids = ids,
	})
end

return M
