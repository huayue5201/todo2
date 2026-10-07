-- lua/todo2/core/code_tracker.lua
-- 代码文件行号追踪：当代码文件发生行号变化（插入/删除行）时，
-- 同步更新存储中代码标记（locations.code.line），使标记始终跟随代码。

local M = {}

local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")
local offset = require("todo2.store.task.offset")
local query = require("todo2.store.task.query")
local core = require("todo2.store.task.core")
local code_block = require("todo2.code_block")

local events = require("todo2.core.events")
local async_util = require("todo2.utils.async")
local line_utils = require("todo2.utils.line")
local config = require("todo2.config")

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local attached = {}
local refresh_tasks = {}
-- bufnr -> string[]：上一版本的缓冲区内容，用于变更区域的行级 diff
local snapshots = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---对变更区域内的代码标记尝试内容匹配重定位。
---relocate_code_location 自身会落库锚点状态（ok/stale/lost），这里只负责筛选与回传。
---@param path string 文件路径
---@param firstline number 0-indexed 起始行（含）
---@param lastline number 0-indexed 结束行（不含）
---@param lines string[] 当前文件行内容
---@param only_ids table<string, boolean> 需要重定位的 id 集合（来自 remap 的 unresolved）
---@return string[] affected 重新定位过的 id（供渲染刷新）
local function relocate_region(path, firstline, lastline, lines, only_ids)
	local file_tasks = query.find_by_file(path)
	local affected = {}

	for id, task in pairs(file_tasks.code) do
		local loc = task.locations and task.locations.code
		if loc and only_ids[id] then
			local l0 = loc.line - 1
			if l0 >= firstline and l0 < lastline then
				core.relocate_code_location(id, lines)
				affected[#affected + 1] = id
			end
		end
	end

	return affected
end

---------------------------------------------------------------------
-- 上下文刷新：函数重命名后重新解析标记所在代码块
---------------------------------------------------------------------

local function refresh_one_context(bufnr, target)
	local loc = target.loc
	local line = loc.line

	local raw = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
	local fp = line_utils.fingerprint(raw)

	local new_ctx = code_block.get_block_at_line_async(bufnr, line)
	local old = loc.context

	-- 保留旧上下文中新块未提供的字段（如 relative_line）
	if old and new_ctx and new_ctx.relative_line == nil and old.relative_line ~= nil then
		new_ctx.relative_line = old.relative_line
	end

	-- 行指纹变化本身也要写回（供后续定位校验/纠正）
	local changed = fp ~= loc.line_text

	-- 仅在新块提供了对应字段且内容变化时写回，
	-- 避免用信息更少的降级结果（如 indent 块）覆盖原有上下文
	if new_ctx then
		if not old then
			changed = true
		else
			local sig_changed = new_ctx.signature ~= nil
				and new_ctx.signature ~= ""
				and new_ctx.signature ~= old.signature
			local name_changed = new_ctx.name ~= nil and new_ctx.name ~= "" and new_ctx.name ~= old.name
			local rel_changed = new_ctx.relative_line ~= nil
				and old.relative_line ~= nil
				and new_ctx.relative_line ~= old.relative_line
			if sig_changed or name_changed or rel_changed then
				changed = true
			end
		end
	end

	if changed then
		loc.line_text = fp
		if new_ctx then
			loc.context = code_block.to_context(new_ctx)
			-- 同步块范围（供后续定位时的指纹搜索限定范围）
			loc.block_start = new_ctx.start_line or loc.block_start
			loc.block_end = new_ctx.end_line or loc.block_end
		end
		target.task.timestamps = target.task.timestamps or {}
		target.task.timestamps.updated = os.time()
		core.save_task(target.id, target.task)
	end
end

---重新解析缓冲区中所有代码标记的上下文（函数名/签名等）。
---带 300ms 防抖，避免输入过程中频繁触发。
---@param bufnr number 缓冲区号
function M.refresh_contexts(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local path = buffer.get_path(bufnr)
	if path == "" or file.is_todo_file(path) then
		return
	end

	async_util.debounce(refresh_tasks, bufnr, 300, function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		local file_tasks = query.find_by_file(path)
		local targets = {}

		for id, task in pairs(file_tasks.code) do
			local loc = task.locations and task.locations.code
			-- 失联标记的行号已指向别处，重解析只会把锚点覆盖成错误的块，跳过。
			if loc and loc.line and loc.line >= 1 and not core.is_anchor_lost(task) then
				targets[#targets + 1] = { id = id, task = task, loc = loc }
			end
		end

		for _, target in ipairs(targets) do
			refresh_one_context(bufnr, target)
		end
	end)
end

---------------------------------------------------------------------
-- 指纹自愈：打开 / 重载 / 保存后重新锚定
---------------------------------------------------------------------

--- 给已失效的锚点补一条 git 归因：最近一次改变该代码的提交。
--- 仅在启用 git 集成且当前目录是仓库时执行；按需调用，不做全量 git 扫描。
---@param id string
---@param path string
local function annotate_git(id, path)
	if not config.get("git.enable") then
		return
	end
	local git = require("todo2.integrations.git")
	if not git.available() then
		return
	end
	local task = core.get_task(id)
	if not task then
		return
	end

	local state = core.anchor_state(task)
	if state == core.ANCHOR.OK then
		-- 重新锚定成功：清掉历史归因
		if task.verification and task.verification.git then
			core.set_anchor_git(id, nil)
		end
		return
	end

	local loc = task.locations and task.locations.code
	local culprit
	if state == core.ANCHOR.LOST or not loc or not loc.block_start then
		-- 已不可定位：退化为看该文件的最近一次提交
		culprit = git.log(nil, 1, nil, loc and loc.path or path)[1]
	else
		local all = git.blame(loc.path, loc.block_start, loc.block_end or loc.block_start)
		-- blame 返回「旧 → 新」，取最新一次改变该段的提交
		culprit = all[#all]
	end
	if culprit then
		core.set_anchor_git(id, {
			sha = culprit.sha,
			author = culprit.author,
			date = culprit.date,
			lost = state == core.ANCHOR.LOST,
		})
	end
end

--- 对该文件的所有代码标记做一次「行指纹 + 上下文」重定位。
--- 外部改动（大模型直接改盘、:edit 重载）不会触发 on_lines，靠这里自愈。
--- 快路径：存储行的指纹仍匹配则跳过，只处理漂移/失联的。
---@param bufnr number
---@return string[] affected
function M.reanchor(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end
	local path = buffer.get_path(bufnr)
	if path == "" or file.is_todo_file(path) then
		return {}
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local affected = {}

	for id, task in pairs(query.find_by_file(path).code) do
		local loc = task.locations and task.locations.code
		if loc and loc.line then
			local fp = loc.line_text
			local line = loc.line
			local anchor_ok = fp
				and fp ~= ""
				and lines[line] ~= nil
				and line_utils.fingerprint(lines[line]) == fp
			if not anchor_ok or core.anchor_state(task) ~= core.ANCHOR.OK then
				core.relocate_code_location(id, lines)
				affected[#affected + 1] = id
				annotate_git(id, path)
			end
		end
	end

	if #affected > 0 then
		-- 位置可能整体漂移：代码侧整体重绘，确保清掉旧位置的标记
		pcall(function()
			require("todo2.render.code_render").render_file(bufnr)
		end)
		events.emit("code_reanchor", {
			file = path,
			bufnr = bufnr,
			changed_ids = affected,
		})
	end
	return affected
end

---------------------------------------------------------------------
-- 变更捕获（维护快照）
---------------------------------------------------------------------

--- 取变更前的区域内容，并把快照同步为变更后的内容。
--- 快照为「区域内部」的行级 diff 提供旧内容；缺失时返回 nil（调用方回退旧逻辑）。
---@param buf number
---@param firstline number 0-based 变更起始行
---@param lastline number 0-based 旧变更结束行（不含）
---@param new_lastline number 0-based 新变更结束行（不含）
---@return string[]|nil old_region, string[] new_region
local function capture_change(buf, firstline, lastline, new_lastline)
	local snap = snapshots[buf]
	local new_region = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)
	if not snap or #snap < lastline then
		return nil, new_region
	end

	local old_region = {}
	for i = firstline, lastline - 1 do
		old_region[#old_region + 1] = snap[i + 1]
	end

	-- 就地同步快照：区域前 + 新区域 + 区域后
	local updated = {}
	for i = 1, firstline do
		updated[i] = snap[i]
	end
	for i = 1, #new_region do
		updated[firstline + i] = new_region[i]
	end
	for i = lastline + 1, #snap do
		updated[#updated + 1] = snap[i]
	end
	snapshots[buf] = updated

	return old_region, new_region
end

---------------------------------------------------------------------
-- on_lines 回调
---------------------------------------------------------------------

---@param event string 事件名（"lines"）
---@param buf number 缓冲区号
---@param changedtick number
---@param firstline number 0-indexed 变更起始行（含）
---@param lastline number 0-indexed 旧变更结束行（不含）
---@param new_lastline number 0-indexed 新变更结束行（不含）
local function on_lines(event, buf, changedtick, firstline, lastline, new_lastline)
	if event ~= "lines" then
		return
	end

	local path = buffer.get_path(buf)
	if path == "" or file.is_todo_file(path) then
		return
	end

	-- 任何代码变更（含重命名等不改变行数的场景）都刷新上下文，
	-- 避免函数重命名后标记上下文过期、后续行号漂移时无法重定位
	M.refresh_contexts(buf)

	-- 取变更前区域内容（快照），并把快照同步为变更后内容
	local old_region, new_region = capture_change(buf, firstline, lastline, new_lastline)

	local delta = new_lastline - lastline
	if delta == 0 then
		return
	end

	async_util.defer(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		-- 变更区域下方的标记整体平移 delta
		offset.shift_lines(path, lastline + 1, delta, { skip_archived = false })

		-- 变更区域内部的标记：优先用行级 diff 精确重映射
		local remap = offset.remap_region(path, firstline, lastline, old_region, new_region, {
			skip_archived = false,
		})

		-- diff 无法唯一确定的，回退到内容匹配重定位
		if #remap.unresolved > 0 then
			local only = {}
			for _, id in ipairs(remap.unresolved) do
				only[id] = true
			end
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local affected = relocate_region(path, firstline, lastline, lines, only)
			-- 重定位可能把标记判为失联：立即刷新，隐藏代码标记并点亮 TODO 行的 ⚠️
			if #affected > 0 then
				events.emit("code_anchor_relocated", {
					file = path,
					bufnr = buf,
					changed_ids = affected,
				})
			end
		end
	end)
end

---------------------------------------------------------------------
-- 缓冲区附加
---------------------------------------------------------------------

local function attach(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or attached[bufnr] then
		return
	end

	local path = buffer.get_path(bufnr)
	if path == "" or file.is_todo_file(path) then
		return
	end

	attached[bufnr] = true
	snapshots[bufnr] = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = on_lines,
		on_reload = function()
			-- 外部改动（大模型直接改盘）/ :edit 重载：on_lines 不触发，重载后自愈
			snapshots[bufnr] = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			async_util.defer(function()
				if vim.api.nvim_buf_is_valid(bufnr) then
					M.reanchor(bufnr)
				end
			end)
		end,
		on_detach = function()
			attached[bufnr] = nil
			snapshots[bufnr] = nil
			async_util.cancel(refresh_tasks, bufnr)
		end,
	})

	-- 打开时也自愈一次（文件在未打开期间可能被外部改过）
	async_util.defer(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			M.reanchor(bufnr)
		end
	end)
end

---------------------------------------------------------------------
-- 保存后重新校验
---------------------------------------------------------------------

---文件保存后，对未验证的代码标记做内容匹配重定位
local function setup_reverify_on_write()
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			local path = buffer.get_path(buf)
			if path == "" or file.is_todo_file(path) then
				return
			end

			async_util.defer(function()
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end

				-- 保存是最终判定点：先按指纹自愈（含外部改动/漂移），
				-- 再刷新上下文（函数重命名后同步最新签名/名称）。
				M.reanchor(buf)
				M.refresh_contexts(buf)
			end)
		end,
	})
end

---初始化自动追踪
function M.setup()
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
		pattern = "*",
		callback = function(args)
			async_util.defer(function()
				attach(args.buf)
			end)
		end,
	})

	setup_reverify_on_write()
end

return M
