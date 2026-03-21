local M = {
	name = "indent",
	priority = 10,
}

function M.supports(_)
	return true
end

local function get_indent(line)
	return line:match("^%s*"):len()
end

function M.get_block(bufnr, lnum)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if #lines == 0 then
		return nil
	end

	local target = lines[lnum - 1] or ""
	local target_indent = get_indent(target)

	local start_line = lnum
	for i = lnum - 1, 1, -1 do
		local line = lines[i - 1] or ""
		local indent = get_indent(line)
		if line:match("%S") and indent < target_indent then
			start_line = i + 1
			break
		end
	end

	local end_line = lnum
	for i = lnum, #lines do
		local line = lines[i - 1] or ""
		local indent = get_indent(line)
		if line:match("%S") and indent < target_indent then
			end_line = i - 1
			break
		end
		end_line = i
	end

	if start_line > end_line then
		start_line = lnum
		end_line = lnum
	end

	local first_line = lines[start_line - 1] or ""
	local block_type = "block"
	if first_line:match("^%s*func%s+") then
		block_type = "function"
	elseif first_line:match("^%s*function%s+") then
		block_type = "function"
	elseif first_line:match("^%s*def%s+") then
		block_type = "function"
	elseif first_line:match("^%s*class%s+") then
		block_type = "class"
	elseif first_line:match("^%s*interface%s+") then
		block_type = "interface"
	elseif first_line:match("^%s*type%s+") then
		block_type = "type"
	elseif first_line:match("^%s*enum%s+") then
		block_type = "enum"
	end

	return {
		source = "indent",
		type = block_type,
		start_line = start_line,
		end_line = end_line,
		first_line = first_line,
		indent = target_indent,
	}
end

function M.get_all(_)
	return {}
end

return M
