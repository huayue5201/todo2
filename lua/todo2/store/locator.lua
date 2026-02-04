-- lua/todo2/store/locator.lua
--- @module todo2.store.locator
--- 智能定位系统：解决行号错位问题

local M = {}

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	MAX_SCAN_LINES = 1000, -- 最大扫描行数
	SIMILARITY_THRESHOLD = 60, -- 相似度阈值（0-100）
	SCAN_WINDOW = 20, -- 扫描窗口大小
}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
local function read_file_lines(filepath)
	if vim.fn.filereadable(filepath) == 1 then
		return vim.fn.readfile(filepath)
	end
	return {}
end

-- 计算简单哈希（用于内容验证）
local function calculate_content_hash(content)
	if not content or content == "" then
		return "00000000"
	end
	local hash = 0
	for i = 1, math.min(#content, 100) do
		hash = (hash * 31 + string.byte(content, i)) % 4294967296
	end
	return string.format("%08x", hash)
end

-- 查找任务ID在行中的位置
local function find_id_in_line(line, id)
	if not line then
		return false
	end
	return line:match("{#" .. id .. "}") or line:match(":ref:" .. id)
end

---------------------------------------------------------------------
-- 定位策略1：ID精确匹配
---------------------------------------------------------------------
function M._locate_by_id(filepath, id)
	local lines = read_file_lines(filepath)
	for line_num = 1, #lines do
		if find_id_in_line(lines[line_num], id) then
			return line_num
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 定位策略2：内容和标签匹配
---------------------------------------------------------------------
function M._locate_by_content(filepath, link)
	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_match = nil
	local best_score = 0

	-- 只扫描前1000行（性能优化）
	local max_line = math.min(#lines, CONFIG.MAX_SCAN_LINES)

	for line_num = 1, max_line do
		local line = lines[line_num]
		local score = 0

		-- 1. 检查标签（TODO/FIX等）
		if link.tag and line:match("%[" .. link.tag .. "%]") then
			score = score + 40
		end

		-- 2. 检查内容哈希
		if link.content_hash then
			local line_hash = calculate_content_hash(line)
			if line_hash == link.content_hash then
				score = score + 50
			end
		end

		-- 3. 检查行内容
		if link.content and line:match(link.content:sub(1, 20)) then
			score = score + 30
		end

		-- 4. 行号接近度（如果原有行号有效）
		if link.line and link.line > 0 then
			local distance = math.abs(line_num - link.line)
			if distance < CONFIG.SCAN_WINDOW then
				score = score + math.max(0, 20 - distance)
			end
		end

		-- 更新最佳匹配
		if score > best_score then
			best_score = score
			best_match = line_num
		end
	end

	-- 只有达到阈值才认为匹配成功
	if best_match and best_score >= CONFIG.SIMILARITY_THRESHOLD then
		return best_match
	end

	return nil
end

---------------------------------------------------------------------
-- 主定位函数
---------------------------------------------------------------------
function M.locate_task(link)
	if not link or not link.path or not link.id then
		return link
	end

	local filepath = link.path

	-- 检查文件是否存在
	if vim.fn.filereadable(filepath) ~= 1 then
		link.line_verified = false
		return link
	end

	-- 读取文件内容
	local lines = read_file_lines(filepath)

	-- 检查当前行号是否仍然有效
	if link.line and link.line >= 1 and link.line <= #lines then
		local current_line = lines[link.line]
		if find_id_in_line(current_line, link.id) then
			-- 行号仍然有效
			link.line_verified = true
			return link
		end
	end

	-- 开始重新定位
	local new_line = nil

	-- 策略1：尝试通过ID精确匹配
	new_line = M._locate_by_id(filepath, link.id)

	-- 策略2：如果ID匹配失败，尝试内容和标签匹配
	if not new_line then
		new_line = M._locate_by_content(filepath, link)
	end

	-- 更新链接
	if new_line and new_line ~= link.line then
		link.line = new_line
		link.line_verified = true
		link.updated_at = os.time()

		-- 更新内容哈希
		if lines[new_line] then
			link.content_hash = calculate_content_hash(lines[new_line])
		end

		-- 记录修复日志
		vim.schedule(function()
			vim.notify(
				string.format("修复链接 %s: 行号 %d → %d", link.id:sub(1, 6), link.line or 0, new_line),
				vim.log.levels.INFO
			)
		end)
	elseif link.line then
		-- 保持原行号但标记为未验证
		link.line_verified = false
	end

	return link
end

---------------------------------------------------------------------
-- 批量定位
---------------------------------------------------------------------
function M.locate_file_tasks(filepath, link_type)
	local index = require("todo2.store.index")
	local store = require("todo2.store.nvim_store")
	local types = require("todo2.store.types")

	-- 收集所有链接
	local links = {}

	if not link_type or link_type == "todo" then
		local todo_links = index.find_todo_links_by_file(filepath)
		for _, link in ipairs(todo_links) do
			table.insert(links, link)
		end
	end

	if not link_type or link_type == "code" then
		local code_links = index.find_code_links_by_file(filepath)
		for _, link in ipairs(code_links) do
			table.insert(links, link)
		end
	end

	-- 定位每个链接
	local located = 0
	for _, link in ipairs(links) do
		local old_line = link.line
		local located_link = M.locate_task(link)

		if located_link.line ~= old_line then
			-- 保存更新
			local key_prefix = link.type == types.LINK_TYPES.TODO_TO_CODE and "todo.links.todo." or "todo.links.code."
			store.set_key(key_prefix .. link.id, located_link)
			located = located + 1
		end
	end

	return {
		located = located,
		total = #links,
	}
end

---------------------------------------------------------------------
-- 工具函数导出
---------------------------------------------------------------------
M.calculate_content_hash = calculate_content_hash

return M
