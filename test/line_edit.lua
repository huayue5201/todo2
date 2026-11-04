-- line_edit 测试：一次改多行、行号以文件原始坐标为基准、每个文件只写一次。
-- 运行：nvim --headless -u NONE -l test/line_edit.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local fails, total = 0, 0
local function check(name, cond, extra)
	total = total + 1
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":p")
vim.fn.mkdir(dir, "p")
local paths = {}
local function file(name)
	local p = dir .. "/" .. name
	paths[#paths + 1] = p
	return p
end
local function write(p, lines)
	vim.fn.writefile(lines, p)
end
local function read(p)
	return vim.fn.readfile(p)
end

local line_edit = require("todo2.core.line_edit")

---------------------------------------------------------------------
-- 1) 同一文件多次编辑：行号是原始坐标，从下往上互不干扰
---------------------------------------------------------------------
local path = file("many.todo.md")
write(path, { "a", "b", "c", "d", "e" })
line_edit.apply({
	{ path = path, lnum = 2, count = 1 }, -- 删 b
	{ path = path, lnum = 4, count = 1 }, -- 删 d
	{ path = path, lnum = 5, count = 1, lines = { "E" } }, -- 替换 e
	{ path = path, lnum = 1, count = 1, lines = { "A" } }, -- 替换 a
	{ path = path, lnum = 3, count = 0, lines = { "c1", "c2" } }, -- 在 c 之前插入
}, { sync = false })
check("edits apply against original line numbers", vim.deep_equal(read(path), { "A", "c1", "c2", "c", "E" }), table.concat(read(path), "|"))

---------------------------------------------------------------------
-- 2) 纯插入到文件末尾（lnum = #lines + 1）
---------------------------------------------------------------------
path = file("append.todo.md")
write(path, { "only" })
line_edit.apply({ { path = path, lnum = 2, count = 0, lines = { "tail" } } }, { sync = false })
check("insert at end", vim.deep_equal(read(path), { "only", "tail" }), table.concat(read(path), "|"))

---------------------------------------------------------------------
-- 3) 越界编辑被忽略，文件不变
---------------------------------------------------------------------
path = file("range.todo.md")
write(path, { "x" })
line_edit.apply({ { path = path, lnum = 99, count = 1, lines = { "y" } } }, { sync = false })
check("out of range edit is ignored", vim.deep_equal(read(path), { "x" }), table.concat(read(path), "|"))

---------------------------------------------------------------------
-- 4) 空编辑列表：不动任何文件
---------------------------------------------------------------------
local touched = line_edit.apply({}, { sync = false })
check("empty edit list touches nothing", #touched == 0)

vim.fn.delete(dir, "rf")
print(fails == 0 and string.format("\nALL PASS (%d checks)", total) or string.format("\n%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
