-- 结构层测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/tree_orphan.lua
--
-- 覆盖：缩进→父子（严格）、缺中间层级的显式 orphan、child_indent、
--       raw_subtree 原样回放。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local parser = require("todo2.core.parser")
local tree = require("todo2.core.tree")

local lines = {
	"## Main",
	"- [ ] todo:a1 root1",
	"      正文第一行",
	"      正文第二行",
	"  - [ ] todo:b2 child1",
	"    - [ ] todo:c3 grandchild",
	"- [ ] todo:d4 root2",
	"    - [ ] todo:o5 deep-orphan",
}

local path = "/tmp/todo2-tree-orphan.md"
local roots
local _, r = parser.parse_lines(path, lines)
roots = r

local function find(id)
	return tree.index_by_id(roots)[id]
end

check("a1 is root", find("a1") and find("a1").parent == nil)
check("a1 indent 0", find("a1") and find("a1").indent_cols == 0)
check("b2 parent a1", find("b2") and find("b2").parent == find("a1"))
check("c3 parent b2", find("c3") and find("c3").parent == find("b2"))
check("d4 is root", find("d4") and find("d4").parent == nil)
check("o5 orphan flagged", find("o5") and find("o5").orphan == true)
check("o5 not attached", find("o5") and find("o5").parent == nil)


-- forest（from_parser 会补全 raw/indent）
local forest = parser.parse(path, lines)

-- raw_subtree 原样回放（含正文，缩进不重算）
local raw = tree.raw_subtree(forest.by_id["a1"])
check("raw_subtree lines", #raw == 5, vim.inspect(raw))
check(
	"raw byte-equal",
	vim.deep_equal(raw, {
		lines[2],
		lines[3],
		lines[4],
		lines[5],
		lines[6],
	}),
	vim.inspect(raw)
)

check("forest orphans count 1", forest.orphans == 1, forest.orphans)
check("forest by_id", forest.by_id["c3"] ~= nil)

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
