-- 元数据块高亮测试：`@key` 加粗、值按字段着色（到期日仍按紧迫度）。
-- 运行：nvim --headless -u NONE -l test/meta_highlight.lua

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
vim.fn.chdir(dir)
require("todo2").setup({})

local project = require("todo2.utils.project")
local project_dir = project.current().dir
vim.fn.mkdir(project_dir, "p")

local line = "- [d] 写点东西 @id(aaa111) @created(1730000000) @due(2020-01-01) #fix"
local path = project_dir .. "/meta.todo.md"
vim.fn.writefile({ line }, path)
require("todo2.core.sync").sync_todo_file(path)

vim.cmd.edit(path)
require("todo2.render.scheduler").refresh(0)
vim.wait(3000, function()
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
		if mark[4].hl_group == "TodoMetaKey" then
			return true
		end
	end
	return false
end)

---按 highlight 组收集被标记的文本
local by_hl = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
	local detail = mark[4]
	if detail.hl_group then
		local text = vim.api.nvim_buf_get_text(0, mark[2], mark[3], mark[2], detail.end_col, {})[1]
		by_hl[detail.hl_group] = by_hl[detail.hl_group] or {}
		table.insert(by_hl[detail.hl_group], text)
	end
end

local function has(group, text)
	return vim.tbl_contains(by_hl[group] or {}, text)
end

check("key `@id` is bold-highlighted", has("TodoMetaKey", "@id"), vim.inspect(by_hl))
check("key `@due` is bold-highlighted", has("TodoMetaKey", "@due"), vim.inspect(by_hl))
check("id value uses its own group", has("TodoMetaId", "(aaa111)"), vim.inspect(by_hl))
check("created uses the timestamp group", has("TodoTime", "(1730000000)"), vim.inspect(by_hl))
check("overdue due value uses the urgency group", has("TodoDueOverdue", "(2020-01-01)"), vim.inspect(by_hl))
check("tags keep their group", has("TodoTag", "#fix"), vim.inspect(by_hl))
check("metadata is not hidden (still plain text)", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == line)

---------------------------------------------------------------------
-- @created 被 conceal，@id 保持可见
---------------------------------------------------------------------
require("todo2.render.conceal").apply_buffer_conceal(0)

local ns_meta = require("todo2.constants").ns("meta_conceal")
local concealed, plain = {}, {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns_meta, 0, -1, { details = true })) do
	table.insert(concealed, vim.api.nvim_buf_get_text(0, mark[2], mark[3], mark[2], mark[4].end_col, {})[1])
end
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
	if mark[4].hl_group then
		table.insert(plain, vim.api.nvim_buf_get_text(0, mark[2], mark[3], mark[2], mark[4].end_col, {})[1])
	end
end
check("only @created is concealed", vim.deep_equal(concealed, { "@created(1730000000)" }), vim.inspect(concealed))
check("@id stays visible", vim.tbl_contains(plain, "@id") and vim.tbl_contains(plain, "(aaa111)"), vim.inspect(plain))
check("tags and due stay visible", vim.tbl_contains(plain, "(2020-01-01)") and vim.tbl_contains(plain, "#fix"), vim.inspect(plain))

---------------------------------------------------------------------
-- 高亮组确实定义了属性（不是空名字）
---------------------------------------------------------------------
local key_hl = vim.api.nvim_get_hl(0, { name = "TodoMetaKey" })
check("TodoMetaKey is bold", key_hl.bold == true, vim.inspect(key_hl))
local id_hl = vim.api.nvim_get_hl(0, { name = "TodoMetaId" })
check("TodoMetaId is italic", id_hl.italic == true, vim.inspect(id_hl))

vim.cmd("bwipeout!")
vim.fn.delete(project_dir, "rf")
vim.fn.delete(dir, "rf")
print(fails == 0 and string.format("\nALL PASS (%d checks)", total) or string.format("\n%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
