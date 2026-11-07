-- lua/todo2/utils/task_text.lua
-- 任务行「后缀」的唯一实现：到期日 / 标签 / git 元数据。
--
-- 抽屉、quickfix、viewer 三处渲染各有各的前缀（缩进、折叠图标、进度条……），
-- 但后缀的顺序和格式必须一致——否则同一个任务在不同视图里长得不一样。
-- 这里同时提供 segments（带高亮，抽屉用）和纯文本（按空格拼接）两种形态。

local M = {}

local due_utils = require("todo2.utils.due")
local tags_utils = require("todo2.utils.tags")
local git_integration = require("todo2.integrations.git")

---@class Todo2TextOpts
---@field due? boolean 是否显示到期日
---@field due_hl? boolean 到期日按紧迫度上色（无高亮时整段省略，抽屉专用）
---@field tags? boolean 是否显示标签（默认 true）
---@field git? boolean 是否显示 git 元数据

--- 任务行的后缀片段，顺序固定：到期日 → 标签 → git 元数据 → 锚点 git 归因。
---@param full table|nil 类 store 任务
---@param opts? Todo2TextOpts
---@return { [1]: string, [2]: string|nil }[]
function M.suffix_segments(full, opts)
	opts = opts or {}
	if not full then
		return {}
	end
	local core_data = full.core or {}
	local out = {}

	if opts.due and core_data.due then
		local text = " " .. due_utils.format_short(core_data.due)
		if opts.due_hl then
			local hl = due_utils.hl(core_data.due, core_data.status)
			if hl then
				out[#out + 1] = { text, hl }
			end
		else
			out[#out + 1] = { text }
		end
	end

	if opts.tags ~= false and core_data.tags and #core_data.tags > 0 then
		out[#out + 1] = { tags_utils.format(core_data.tags), "TodoTag" }
	end

	if opts.git then
		if full.git then
			local meta = git_integration.format_meta(full.git)
			if meta ~= "" then
				out[#out + 1] = { meta, "Comment" }
			end
		end
		-- 锚点失效的 git 归因（由 code_tracker 重锚定时写入）
		if full.verification and full.verification.git then
			local ameta = git_integration.format_anchor_git(full.verification.git)
			if ameta ~= "" then
				out[#out + 1] = { ameta, "Comment" }
			end
		end
	end

	return out
end

--- 后缀的纯文本形态（片段之间用空格连接）。
---@param full table|nil
---@param opts? Todo2TextOpts
---@return string
function M.suffix_text(full, opts)
	local parts = {}
	for _, seg in ipairs(M.suffix_segments(full, opts)) do
		parts[#parts + 1] = seg[1]
	end
	return table.concat(parts)
end

return M
