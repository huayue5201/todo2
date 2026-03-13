-- lua/todo2/ai/apply.lua
-- 安全替换写回 + spinner 支持
local M = {}

local link = require("todo2.store.link")
local scheduler = require("todo2.render.scheduler")
local comment = require("todo2.utils.comment")
local vim = vim

-- spinner 命名空间与帧
local spinner_ns = vim.api.nvim_create_namespace("todo2_ai_spinner")
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- 启动 spinner，返回 timer 对象（需要在主线程停止）
function M.start_spinner(bufnr, lnum)
	if not bufnr or bufnr == -1 or not lnum then
		return nil
	end
	local frame = 1
	local timer = vim.loop.new_timer()
	timer:start(
		0,
		80,
		vim.schedule_wrap(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				-- 自动停止
				pcall(function()
					timer:stop()
					timer:close()
				end)
				return
			end
			pcall(function()
				vim.api.nvim_buf_set_extmark(bufnr, spinner_ns, lnum - 1, -1, {
					virt_text = { { " " .. spinner_frames[frame], "Todo2Spinner" } },
					virt_text_pos = "eol",
				})
			end)
			frame = frame % #spinner_frames + 1
		end)
	)
	return timer
end

-- 停止 spinner 并清理
function M.stop_spinner(bufnr, timer)
	if timer then
		pcall(function()
			timer:stop()
			timer:close()
		end)
	end
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(function()
			vim.api.nvim_buf_clear_namespace(bufnr, spinner_ns, 0, -1)
		end)
	end
end

-- 内部：将字符串或行表规范为行表
local function to_lines(input)
	if type(input) == "table" then
		return input
	elseif type(input) == "string" then
		return vim.split(input, "\n", { plain = true })
	else
		return {}
	end
end

-- 内部：解析简单 REPLACE 指令（格式: "REPLACE start-end:\n<code...>"）
local function parse_replace_directive(s)
	if not s or type(s) ~= "string" then
		return nil
	end
	local header, body = s:match("^%s*REPLACE%s+(%d+)%-(%d+)%s*:%s*\n(.*)$")
	if not header then
		-- try single-line "REPLACE start-end:\n" with body following
		local start, finish = s:match("^%s*REPLACE%s+(%d+)%-(%d+)%s*:%s*\n(.*)$")
		if start then
			return { start = tonumber(start), finish = tonumber(finish), code = to_lines(body) }
		end
		return nil
	end
	local s1, s2 = s:match("^%s*REPLACE%s+(%d+)%-(%d+)%s*:%s*\n(.*)$")
	if s1 and s2 then
		return { start = tonumber(s1), finish = tonumber(s2), code = to_lines(body) }
	end
	return nil
end

-- 内部：尝试把 code 参数解析为 patch list（table of {start,end,code_lines}）
local function parse_patches(code)
	-- 如果是 table，尝试直接使用
	if type(code) == "table" then
		-- expect { { start=.., finish=.., code = {...} }, ... }
		local ok = true
		for _, p in ipairs(code) do
			if type(p.start) ~= "number" or type(p.finish) ~= "number" or not p.code then
				ok = false
				break
			end
		end
		if ok then
			return code
		end
	end

	-- 如果是 JSON 字符串（ai 可能返回 JSON）
	if type(code) == "string" then
		local ok, decoded = pcall(vim.fn.json_decode, code)
		if ok and type(decoded) == "table" then
			-- try to normalize
			local patches = {}
			for _, p in ipairs(decoded) do
				if p.start and p.finish and p.code then
					table.insert(
						patches,
						{ start = tonumber(p.start), finish = tonumber(p.finish), code = to_lines(p.code) }
					)
				end
			end
			if #patches > 0 then
				return patches
			end
		end

		-- try parse REPLACE directive
		local rep = parse_replace_directive(code)
		if rep then
			return { { start = rep.start, finish = rep.finish, code = rep.code } }
		end
	end

	return nil
end

-- 内部：应用 unified diff 到 lines（支持基本 hunk 应用）
local function apply_unified_diff(lines, diff_text)
	if type(diff_text) ~= "string" then
		return nil, "diff must be string"
	end
	local out = vim.deepcopy(lines)
	local i = 1
	local pos = 1
	local hunks = {}
	for header, body in diff_text:gmatch("(@@%s*%-%d+,%d+%s+%+%d+,%d+%s*@@)(.-)(?=@@%s*%-%d+,%d+%s+%+%d+,%d+%s*@@|$)") do
		table.insert(hunks, { header = header, body = body })
	end
	if #hunks == 0 then
		-- maybe single hunk without trailing; try simpler parse
		local hstart, hend, hplusstart, hpluslen = diff_text:match("@@%s*%-(%d+),(%d+)%s+%+(%d+),(%d+)%s*@@")
		if not hstart then
			return nil, "no hunks found"
		end
	end

	-- apply hunks sequentially; this is a best-effort simple implementation
	-- Note: this implementation assumes hunks apply to the whole file and uses line numbers from + side
	local new_lines = {}
	local cursor = 1
	for _, h in ipairs(hunks) do
		local hs, hlen, ps, plen = h.header:match("@@%s*%-(%d+),(%d+)%s+%+(%d+),(%d+)%s*@@")
		hs = tonumber(hs)
		hlen = tonumber(hlen)
		ps = tonumber(ps)
		plen = tonumber(plen)
		-- copy lines up to ps-1
		while cursor < ps and cursor <= #out do
			table.insert(new_lines, out[cursor])
			cursor = cursor + 1
		end
		-- parse body
		local body_lines = vim.split(h.body, "\n", { plain = true })
		for _, bl in ipairs(body_lines) do
			local first = bl:sub(1, 1)
			local content = bl:sub(2)
			if first == " " or first == "" then
				table.insert(new_lines, content)
				cursor = cursor + 1
			elseif first == "+" then
				table.insert(new_lines, content)
			elseif first == "-" then
				-- skip one from original
				cursor = cursor + 1
			end
		end
	end
	-- append remaining
	while cursor <= #out do
		table.insert(new_lines, out[cursor])
		cursor = cursor + 1
	end

	return new_lines, nil
end

-- 主写回函数：支持 mode = "full"|"patch"|"diff"
-- code: string or table (depends on mode)
-- opts: { mode = "full"|"patch"|"diff", with_spinner = boolean }
function M.write_code(id, code, opts)
	opts = opts or {}
	local mode = opts.mode or "full"
	local code_link = link.get_code(id, { force_relocate = true })
	if not code_link then
		return false, "未找到 CODE 链接"
	end

	local path = code_link.path
	local code_line = code_link.line
	if not path or not code_line then
		return false, "CODE 链接缺少路径或行号"
	end

	local prefix = comment.get_prefix_by_path(path)
	local lines = scheduler.get_file_lines(path, true)
	if not lines or #lines == 0 then
		return false, "无法读取文件"
	end

	-- 找到 END:ID 标记
	local end_line = nil
	for i = code_line + 1, #lines do
		local pat = "^%s*" .. vim.pesc(prefix) .. "%s*END:" .. id
		if lines[i]:match(pat) then
			end_line = i
			break
		end
	end

	if not end_line then
		return false, "未找到 END:" .. id
	end

	-- 记录 bufnr 用于 spinner
	local bufnr = vim.fn.bufnr(path)
	local spinner_timer = nil
	if opts.with_spinner and bufnr and bufnr ~= -1 then
		spinner_timer = M.start_spinner(bufnr, code_line)
	end

	local ok, err = pcall(function()
		if mode == "full" then
			-- 全量替换 CODE 区域内部（不包含标记行）
			local new_lines = to_lines(code)
			-- 删除旧代码
			for _ = code_line + 1, end_line - 1 do
				table.remove(lines, code_line + 1)
			end
			-- 插入新代码
			for i, l in ipairs(new_lines) do
				table.insert(lines, code_line + i, l)
			end
		elseif mode == "patch" then
			-- 解析 patches
			local patches = parse_patches(code)
			if not patches then
				-- fallback: treat as full
				local new_lines = to_lines(code)
				for _ = code_line + 1, end_line - 1 do
					table.remove(lines, code_line + 1)
				end
				for i, l in ipairs(new_lines) do
					table.insert(lines, code_line + i, l)
				end
			else
				-- apply patches in reverse order to keep indices stable
				table.sort(patches, function(a, b)
					return a.start > b.start
				end)
				for _, p in ipairs(patches) do
					local start_idx = math.max(code_line + p.start, code_line + 1)
					local finish_idx = math.min(code_line + p.finish, end_line - 1)
					-- remove range
					for _ = start_idx, finish_idx do
						table.remove(lines, start_idx)
					end
					-- insert new code
					for i = 1, #p.code do
						table.insert(lines, start_idx + i - 1, p.code[i])
					end
				end
			end
		elseif mode == "diff" then
			-- 读取当前 region lines
			local region_lines = {}
			for i = code_line + 1, end_line - 1 do
				table.insert(region_lines, lines[i])
			end
			local new_region, derr = apply_unified_diff(region_lines, code)
			if not new_region then
				-- fallback to full replace
				local new_lines = to_lines(code)
				for _ = code_line + 1, end_line - 1 do
					table.remove(lines, code_line + 1)
				end
				for i, l in ipairs(new_lines) do
					table.insert(lines, code_line + i, l)
				end
			else
				-- replace region with new_region
				for _ = code_line + 1, end_line - 1 do
					table.remove(lines, code_line + 1)
				end
				for i, l in ipairs(new_region) do
					table.insert(lines, code_line + i, l)
				end
			end
		else
			-- unknown mode -> fallback full
			local new_lines = to_lines(code)
			for _ = code_line + 1, end_line - 1 do
				table.remove(lines, code_line + 1)
			end
			for i, l in ipairs(new_lines) do
				table.insert(lines, code_line + i, l)
			end
		end

		-- 写回文件（覆盖）
		pcall(vim.fn.writefile, lines, path)
	end)

	-- 停止 spinner
	if spinner_timer then
		M.stop_spinner(bufnr, spinner_timer)
	end

	if not ok then
		return false, tostring(err)
	end

	-- 刷新渲染与缓存
	scheduler.invalidate_cache(path)
	local bufnr2 = vim.fn.bufnr(path)
	if bufnr2 ~= -1 then
		scheduler.refresh(bufnr2, {
			from_event = true,
			changed_ids = { id },
		})
	end

	return true
end

return M
