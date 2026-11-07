-- 键位清单回归测试（headless，自包含）。
-- 运行：./scripts/test.sh keymaps
--
-- 守护三件事：
--   1) 抽屉 / TODO 文件 / 全局的键位清单与文档一致（多一个少一个都会失败）；
--   2) 每条映射都有 desc（`:map` 能看到作用）且都有 callback（不是空壳）；
--   3) 同一 buffer 同一模式内没有重复的 lhs。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)
vim.cmd("runtime! plugin/todo2.lua")

local projdir = "/tmp/todo2-keymaps-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(require("todo2.utils.project").current().dir, "rf")

vim.g.mapleader = " "
vim.g.maplocalleader = ","
require("todo2").setup({})

local actions = require("todo2.ai.actions")
local drawer = require("todo2.ui.drawer")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local function inventory(buf)
	local by_mode = {}
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "")) do
		by_mode[m.mode] = by_mode[m.mode] or {}
		by_mode[m.mode][m.lhs] = m
	end
	return by_mode
end

local function assert_clean(label, buf)
	local maps = vim.api.nvim_buf_get_keymap(buf, "")
	local seen, dup = {}, {}
	local no_desc, no_cb = {}, {}
	for _, m in ipairs(maps) do
		local key = m.mode .. "|" .. m.lhs
		if seen[key] then
			dup[#dup + 1] = m.mode .. " " .. m.lhs
		end
		seen[key] = true
		if not m.desc or m.desc == "" then
			no_desc[#no_desc + 1] = m.mode .. " " .. m.lhs
		end
		if not m.callback then
			no_cb[#no_cb + 1] = m.mode .. " " .. m.lhs
		end
	end
	check(label .. ": no duplicate lhs", #dup == 0, table.concat(dup, ", "))
	check(label .. ": every map has desc", #no_desc == 0, table.concat(no_desc, ", "))
	check(label .. ": every map has callback", #no_cb == 0, table.concat(no_cb, ", "))
end

local function assert_keys(label, buf, expected)
	local inv = inventory(buf)
	for mode, lhs_list in pairs(expected) do
		for _, lhs in ipairs(lhs_list) do
			check(("%s: %s %s mapped"):format(label, mode, lhs), inv[mode] and inv[mode][lhs] ~= nil)
		end
	end
	-- 反向：不应有多余的映射（文档即契约）
	for mode, maps in pairs(inv) do
		for lhs in pairs(maps) do
			local allowed = expected[mode] or {}
			local ok = false
			for _, want in ipairs(allowed) do
				if want == lhs then
					ok = true
					break
				end
			end
			check(("%s: %s %s is documented"):format(label, mode, lhs), ok)
		end
	end
end

local file = actions.create_todo_file("keys")
local parent = actions.create_task({ content = "parent task", path = file.path })
actions.create_task({ content = "child task", path = file.path, parent_id = parent.id })

----------------------------------------------------------------------
-- 抽屉
----------------------------------------------------------------------
drawer.toggle()
vim.wait(300, function()
	return drawer.is_open()
end)
local drawer_buf = vim.api.nvim_get_current_buf()
check("drawer buffer has drawer filetype", vim.bo[drawer_buf].filetype == "todo2drawer", vim.bo[drawer_buf].filetype)
assert_clean("drawer", drawer_buf)
assert_keys("drawer", drawer_buf, {
	n = {
		"<LeftMouse>",
		"<CR>",
		"<Tab>",
		"o",
		"P",
		"e",
		"E",
		"c",
		"y",
		"p",
		"a",
		"r",
		"d",
		"<BS>",
		"x",
		"<S-Tab>",
		"s",
		"t",
		"D",
		"S",
		"C",
		"i",
		"L",
		"f",
		"+",
		"-",
		"F",
		"Q",
		"O",
		"za",
		"zo",
		"zc",
		"zR",
		"zM",
		"R",
		"A",
		"?",
		"h",
		"gs",
		"gr",
		"gb",
		"q",
	},
	v = { "<BS>", "x" },
})
drawer.toggle()
vim.wait(100, function()
	return false
end)

----------------------------------------------------------------------
-- TODO 文件
----------------------------------------------------------------------
vim.cmd.edit(vim.fn.fnameescape(file.path))
vim.wait(300, function()
	return false
end)
assert_clean("todo file", vim.api.nvim_get_current_buf())
assert_keys("todo file", vim.api.nvim_get_current_buf(), {
	n = { "q", ",n", ",nc", ",ns" },
	v = { "<CR>" },
})

----------------------------------------------------------------------
-- 全局智能键（plugin/todo2.lua 的 map_fallback 一组）
----------------------------------------------------------------------
local global = {}
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
	global[m.lhs] = m
end
for _, lhs in ipairs({ "<CR>", "<BS>", "<S-Tab>", "<S-CR>", "<C-[>" }) do
	check("global: " .. lhs .. " mapped", global[lhs] ~= nil)
	check("global: " .. lhs .. " has desc", global[lhs] and global[lhs].desc ~= "")
end

if fails == 0 then
	print("ALL PASS")
	vim.cmd("qa!")
else
	print(fails .. " FAILED")
	vim.cmd("cq!")
end
