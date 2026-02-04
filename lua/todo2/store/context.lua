-- lua/todo2/store/context.lua
--- @module todo2.store.context

local M = {}

----------------------------------------------------------------------
-- 工具函数
----------------------------------------------------------------------
local function normalize(s)
	if not s then
		return ""
	end
	s = s:gsub("%-%-.*$", "")
	s = s:gsub("^%s+", "")
	s = s:gsub("%s+$", "")
	s = s:gsub("%s+", " ")
	return s
end

local function hash(s)
	local h = 0
	for i = 1, #s do
		h = (h * 131 + s:byte(i)) % 2 ^ 31
	end
	return tostring(h)
end

local function extract_struct(lines)
	local path = {}

	for _, line in ipairs(lines) do
		local l = normalize(line)

		local f1 = l:match("^function%s+([%w_%.]+)%s*%(")
		if f1 then
			table.insert(path, "func:" .. f1)
		end

		local f2 = l:match("^local%s+function%s+([%w_%.]+)")
		if f2 then
			table.insert(path, "local_func:" .. f2)
		end

		local f3 = l:match("^([%w_%.]+)%s*=%s*function%s*%(")
		if f3 then
			table.insert(path, "assign_func:" .. f3)
		end

		local c1 = l:match("^([%w_]+)%s*=%s*{}$")
		if c1 then
			table.insert(path, "class:" .. c1)
		end
	end

	if #path == 0 then
		return nil
	end
	return table.concat(path, " > ")
end

----------------------------------------------------------------------
-- 上下文构建与匹配
----------------------------------------------------------------------
--- 构建上下文指纹
--- @param prev string
--- @param curr string
--- @param next string
--- @return Context
function M.build(prev, curr, next)
	prev = prev or ""
	curr = curr or ""
	next = next or ""

	local n_prev = normalize(prev)
	local n_curr = normalize(curr)
	local n_next = normalize(next)

	local window = table.concat({ n_prev, n_curr, n_next }, "\n")
	local window_hash = hash(window)

	local struct_path = extract_struct({ prev, curr, next })

	return {
		raw = { prev = prev, curr = curr, next = next },
		fingerprint = {
			hash = hash(window_hash .. (struct_path or "")),
			struct = struct_path,
			n_prev = n_prev,
			n_curr = n_curr,
			n_next = n_next,
			window_hash = window_hash,
		},
	}
end

--- 匹配两个上下文
--- @param old_ctx Context
--- @param new_ctx Context
--- @return boolean
function M.match(old_ctx, new_ctx)
	if not old_ctx or not new_ctx then
		return false
	end

	-- ⭐ 将旧格式转换为新格式进行比较
	local old_fp, new_fp = old_ctx, new_ctx

	-- 如果是旧格式（只有 fingerprint 或直接是 fingerprint）
	if old_ctx.fingerprint or old_ctx.n_curr then
		old_fp = old_ctx.fingerprint or old_ctx
	end

	if new_ctx.fingerprint or new_ctx.n_curr then
		new_fp = new_ctx.fingerprint or new_ctx
	end

	-- 确保有至少 fingerprint 部分
	if not old_fp or not new_fp then
		return false
	end

	-- 比较逻辑（与原来相同）
	if old_fp.hash == new_fp.hash then
		return true
	end

	if old_fp.struct and new_fp.struct and old_fp.struct == new_fp.struct then
		return true
	end

	local score = 0
	if old_fp.n_curr == new_fp.n_curr then
		score = score + 2
	end
	if old_fp.n_prev == new_fp.n_prev then
		score = score + 1
	end
	if old_fp.n_next == new_fp.n_next then
		score = score + 1
	end

	return score >= 2
end

return M
