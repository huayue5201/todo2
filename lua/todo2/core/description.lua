-- lua/todo2/core/description.lua
-- 任务正文（描述）：任务行下方、缩进更深的一串「非任务行」。
--
-- 文件里就是这样写的（同时是合法 Markdown：列表项内容列的续行）：
--
--   - [ ] todo:abc123 加 jar 自动更新 cookie
--         需要支持：
--         1. 从 config 读 jar 路径
--
--         参考 `src/http_client.rs`
--     - [ ] todo:def456 子任务（任务行 → 正文到此结束）
--
-- 判据只依赖既有的两件事：`format.is_task_line`（区分任务行与散文）与缩进。
-- 本模块是纯行运算：不读写 buffer、不碰 store，便于单独测试。

local M = {}

local format = require("todo2.utils.format")
local line_utils = require("todo2.utils.line")

---@class todo2.DescriptionBlock
---@field text string 去掉公共缩进后的正文（多行以 \n 连接）
---@field start_line number 正文首行（1-based）
---@field end_line number 正文末行（含）
---@field indent number 正文自身的公共缩进（用来写回时可恢复正常）

--- 行的缩进宽度（字符数）
---@param line string
---@return number
function M.indent_of(line)
	return #(line:match("^%s*") or "")
end

--- 任务行对应的正文写入缩进（比任务深一级）
---@param task_line string
---@param indent_width number
---@return number
function M.base_indent(task_line, indent_width)
	return M.indent_of(task_line) + indent_width
end

--- 是否属于正文行：非空、非任务行、且缩进深于任务行
---@param line string
---@param task_indent number
---@return boolean
local function is_body_line(line, task_indent)
	if line:match("^%s*$") or format.is_task_line(line) then
		return false
	end
	return M.indent_of(line) > task_indent
end

--- 取某个任务行之后的正文块（自动去掉正文自身的公共缩进）。
--- 规则：
---   * 从任务行的下一行开始连续收集正文行
---   * 空行先「挂起」：其后若仍有正文行，才算作正文内的空行（支持多段）
---   * 遇到任务行、或缩进不深于任务的行 → 结束
---   * 去缩进以正文行的最小缩进为准，与任务/正文的绝对缩进无关
---@param lines string[]
---@param task_lnum number 任务行号（1-based）
---@return todo2.DescriptionBlock|nil
function M.block_at(lines, task_lnum)
	local task_line = lines[task_lnum]
	if not task_line then
		return nil
	end

	local task_indent = M.indent_of(task_line)
	local raw, start_line, end_line, blanks = {}, nil, nil, 0
	local min_indent = math.huge

	for i = task_lnum + 1, #lines do
		local line = lines[i]
		if line:match("^%s*$") then
			blanks = blanks + 1
		elseif is_body_line(line, task_indent) then
			start_line = start_line or i
			for _ = 1, blanks do
				raw[#raw + 1] = ""
			end
			blanks = 0
			raw[#raw + 1] = line
			min_indent = math.min(min_indent, M.indent_of(line))
			end_line = i
		else
			break
		end
	end

	if not start_line then
		return nil
	end
	if min_indent == math.huge then
		min_indent = 0
	end

	-- 去公共缩进，保留内部相对缩进
	local body = {}
	for _, l in ipairs(raw) do
		body[#body + 1] = l == "" and "" or l:sub(math.min(min_indent, M.indent_of(l)) + 1)
	end

	return {
		text = table.concat(body, "\n"),
		start_line = start_line,
		end_line = end_line,
		indent = min_indent,
	}
end

--- 扫描整个文件，返回 { [任务行号] = 正文块 }
---@param lines string[]
---@return table<number, todo2.DescriptionBlock>
function M.scan(lines)
	local out = {}
	for i = 1, #lines do
		if format.is_task_line(lines[i]) then
			local block = M.block_at(lines, i)
			if block then
				out[i] = block
			end
		end
	end
	return out
end

--- 按行指纹在 lines 中查找与 text 对应的连续区间（行内容相同即命中，容忍缩进差异）。
--- 用于任务行被手动删除后把悬空正文找回（不依赖行号）。
---@param lines string[]
---@param text string 期望的正文（去公共缩进后的多行文本）
---@param from number 起始行（1-based，含）
---@return number|nil start_line
---@return number|nil end_line
function M.find_run(lines, text, from)
	if not text or text == "" then
		return nil
	end

	local want = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		want[#want + 1] = line_utils.fingerprint(line)
	end

	for i = math.max(1, from or 1), #lines - #want + 1 do
		local hit = true
		for j = 1, #want do
			if line_utils.fingerprint(lines[i + j - 1]) ~= want[j] then
				hit = false
				break
			end
		end
		if hit then
			return i, i + #want - 1
		end
	end

	return nil
end

--- 把正文渲染成待写入的行（每行加缩进；空行保持为空）
---@param text string|nil
---@param indent string 缩进字符串
---@return string[]
function M.to_lines(text, indent)
	local out = {}
	if not text or text == "" then
		return out
	end
	for line in (text .. "\n"):gmatch("(.-)\n") do
		out[#out + 1] = line == "" and "" or (indent .. line)
	end
	return out
end

return M
