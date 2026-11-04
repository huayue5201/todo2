-- 示例配置必须与代码保持同步：
--   1) examples/config.lua 里的每个键都必须在 config.defaults 里真实存在（没有死配置）
--   2) doc/todo2.txt 的 setup 示例与 examples/config.lua 逐键相等（两处不会漂移）
--   3) 这份配置能被 setup() 直接消费
-- 运行：nvim --headless -u NONE -l test/example_config.lua

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

require("todo2").setup({})
local defaults = require("todo2.config").defaults

local function from_doc()
	local lines = vim.fn.readfile(root .. "/doc/todo2.txt")
	local out, inside = {}, false
	for _, l in ipairs(lines) do
		if l == "    vim.g.todo2_config = {" then
			inside = true
		elseif inside and l == "    }" then
			break
		elseif inside then
			out[#out + 1] = (l:gsub("^    ", ""))
		end
	end
	assert(#out > 0, "setup example not found in doc/todo2.txt")
	return assert(loadstring("return {\n" .. table.concat(out, "\n") .. "\n}"))()
end

local example = assert(loadfile(root .. "/examples/config.lua"))()
local doc = from_doc()

---------------------------------------------------------------------
-- 1) 没有死配置：示例里的每个键都能在 defaults 里找到
---------------------------------------------------------------------
local function islist(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n > 0 and t[1] ~= nil and t[n] ~= nil
end

local dead = {}
local function walk(cfg, def, trail)
	for k, v in pairs(cfg) do
		local path = trail == "" and k or (trail .. "." .. k)
		if type(v) == "table" and islist(v) then
			if def == nil then
				dead[#dead + 1] = path
			end
		elseif type(v) == "table" then
			if type(def) ~= "table" then
				dead[#dead + 1] = path
			else
				walk(v, def[k], path)
			end
		elseif def == nil then
			dead[#dead + 1] = path
		end
	end
end
walk(example, defaults, "")
check("every example key exists in defaults", #dead == 0, table.concat(dead, ", "))

---------------------------------------------------------------------
-- 2) doc 示例与 examples/config.lua 完全一致
---------------------------------------------------------------------
local function diff(x, y, trail, out)
	out = out or {}
	local keys = {}
	for k in pairs(x) do
		keys[k] = true
	end
	for k in pairs(y) do
		keys[k] = true
	end
	for k in pairs(keys) do
		local path = trail == "" and k or (trail .. "." .. k)
		if type(x[k]) ~= type(y[k]) then
			out[#out + 1] = path .. ": type " .. type(x[k]) .. " vs " .. type(y[k])
		elseif type(x[k]) == "table" then
			diff(x[k], y[k], path, out)
		elseif x[k] ~= y[k] then
			out[#out + 1] = path .. ": " .. tostring(x[k]) .. " vs " .. tostring(y[k])
		end
	end
	return out
end
local drift = diff(example, doc, "")
check("doc example == examples/config.lua", #drift == 0, table.concat(drift, "; "))

---------------------------------------------------------------------
-- 3) 示例配置本身可用
---------------------------------------------------------------------
local ok, err = pcall(require("todo2").setup, example)
check("setup() accepts the example", ok, err)
check("example customises a status icon", require("todo2.core.status").get_definition("archived").icon == "📦")
check("example wires icons.progress", require("todo2.config").get("icons.progress.filled") == "▰")

print(fails == 0 and string.format("\nALL PASS (%d checks)", total) or string.format("\n%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
