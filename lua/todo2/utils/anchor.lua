-- lua/todo2/utils/anchor.lua
-- 代码锚点的「列」工具：捕获光标处的单词片段，并在代码改动后重新定位列。
--
-- 列号语义统一为 Neovim 的 0-based byte 列（与 nvim_win_get_cursor 一致）。
-- snippet 只是身份提示：找到了就按它纠正列，找不到就夹紧旧列，不影响行级重定位。

local M = {}

local WORD = "[%w_]"

--- 把列夹紧到 [0, #text]。
---@param text string|nil
---@param col any
---@return integer
function M.clamp(text, col)
	col = tonumber(col) or 0
	if col < 0 then
		col = 0
	end
	local len = text and #text or 0
	if col > len then
		col = len
	end
	return math.floor(col)
end

--- 判断某个 1-based byte 位置是否为单词字符（ASCII 标识符字符）。
---@param text string
---@param i integer
---@return boolean
local function is_word(text, i)
	local ch = text:sub(i, i)
	return ch ~= "" and ch:match(WORD) ~= nil
end

--- 捕获光标列所在的单词片段。
--- 光标不在单词上（空白/符号/EOL）时只返回夹紧后的列，snippet 为 nil。
---@param text string|nil
---@param col any 0-based byte 列
---@return integer col 0-based 起始列
---@return integer end_col 0-based 结束列（不含）
---@return string|nil snippet
function M.capture(text, col)
	if not text or text == "" then
		return 0, 0, nil
	end

	local c = M.clamp(text, col)
	local i = c + 1
	if i > #text then
		i = #text
	end
	if i < 1 or not is_word(text, i) then
		return c, c, nil
	end

	local s = i
	while s > 1 and is_word(text, s - 1) do
		s = s - 1
	end
	local e = i
	while e < #text and is_word(text, e + 1) do
		e = e + 1
	end

	local snippet = text:sub(s, e)
	if snippet == "" then
		return c, c, nil
	end
	return s - 1, e, snippet
end

--- 在（可能已变化的）同一行内按 snippet 重新定位列。
--- 多处命中时取离旧列最近的一处；snippet 找不到则夹紧旧列。
---@param text string|nil
---@param col any
---@param end_col any
---@param snippet string|nil
---@return integer col
---@return integer end_col
function M.refine(text, col, end_col, snippet)
	if not text then
		return M.clamp(nil, col), M.clamp(nil, end_col or col)
	end

	local old = M.clamp(text, col)
	if type(snippet) == "string" and snippet ~= "" then
		local best_s, best_e, best_dist
		local init = 1
		while true do
			local s, e = text:find(snippet, init, true)
			if not s then
				break
			end
			local dist = math.abs((s - 1) - old)
			if not best_dist or dist < best_dist then
				best_s, best_e, best_dist = s, e, dist
			end
			init = e + 1
		end
		if best_s then
			return best_s - 1, best_e
		end
	end

	local ec = M.clamp(text, end_col or old)
	if ec < old then
		ec = old
	end
	return old, ec
end

return M
