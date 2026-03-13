-- lua/todo2/ai/apply.lua
-- 将 AI 生成的代码写回 CODE 标记下一行（最终修复版）

local M = {}

local link = require("todo2.store.link")
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 将代码写回 CODE 文件（写入 CODE 标记下一行）
---------------------------------------------------------------------
function M.write_code(id, code)
	-- 获取 CODE 链接
	local code_link = link.get_code(id, { force_relocate = true })
	if not code_link then
		return { ok = false, error = "未找到 CODE 链接" }
	end

	-- TODO:ref:400095
	local path = code_link.path
	local code_line = code_link.line -- CODE 标记所在行

	if not path or not code_line then
		return { ok = false, error = "CODE 链接缺少路径或行号" }
	end

	-----------------------------------------------------------------
	-- ⭐ 读取整个文件（使用 scheduler 缓存，保持行号一致）
	-----------------------------------------------------------------
	local lines = scheduler.get_file_lines(path, true)
	if not lines or #lines == 0 then
		return { ok = false, error = "无法读取文件" }
	end

	-----------------------------------------------------------------
	-- ⭐ 将 AI 内容拆成行
	-----------------------------------------------------------------
	local new_lines = vim.split(code, "\n", { plain = true })

	-----------------------------------------------------------------
	-- ⭐ 写入到 CODE 标记下一行（不覆盖文件）
	-----------------------------------------------------------------
	local insert_at = code_line -- 下一行就是 code_line + 1

	-- 插入多行
	for i, l in ipairs(new_lines) do
		table.insert(lines, insert_at + i, l)
	end

	-----------------------------------------------------------------
	-- ⭐ 写回文件（覆盖整个文件内容，但不改变结构）
	-----------------------------------------------------------------
	local ok, err = pcall(vim.fn.writefile, lines, path)
	if not ok then
		return { ok = false, error = "写入文件失败: " .. tostring(err) }
	end

	-----------------------------------------------------------------
	-- ⭐ 刷新渲染（增量）
	-----------------------------------------------------------------
	scheduler.invalidate_cache(path)

	local bufnr = vim.fn.bufnr(path)
	if bufnr ~= -1 then
		scheduler.refresh(bufnr, {
			from_event = true,
			changed_ids = { id },
		})
	end

	return { ok = true }
end

return M
