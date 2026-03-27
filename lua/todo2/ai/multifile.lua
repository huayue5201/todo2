-- lua/todo2/ai/multifile.lua
-- 多文件输出解析和批量写入

local M = {}

local validate = require("todo2.ai.validate")
local writer = require("todo2.ai.stream.writer")

-- 多文件格式：```lang:path/to/file
local MULTI_FILE_PATTERN = "```([%w_]+):([^\n]+)\n(.-)\n```"

---解析多文件输出
---@param raw string LLM 原始响应
---@return table[]|nil changes 变更列表，每个元素 { path, lang, content, action }
function M.parse(raw)
    if not raw or raw == "" then
        return nil
    end

    local changes = {}
    local pos = 1
    local total_len = #raw

    while pos <= total_len do
        local start_pos = raw:find("```", pos)
        if not start_pos then
            break
        end

        -- 查找代码块结束
        local end_pos = raw:find("```", start_pos + 3)
        if not end_pos then
            break
        end

        local block = raw:sub(start_pos + 3, end_pos - 1)
        local first_line_end = block:find("\n")
        if not first_line_end then
            pos = end_pos + 3
            goto continue
        end

        local header = block:sub(1, first_line_end - 1)
        local content = block:sub(first_line_end + 1)

        -- 解析 header: lang:path
        local lang, path = header:match("^([%w_]+):(.+)$")
        if lang and path then
            path = vim.trim(path)
            if path ~= "" then
                changes[#changes + 1] = {
                    path = path,
                    lang = lang,
                    content = content,
                    action = "write",
                }
            end
        end

        pos = end_pos + 3
        ::continue::
    end

    return #changes > 0 and changes or nil
end

---验证单个变更
---@param change table
---@return boolean ok
---@return string|nil error
local function validate_change(change)
    if not change.path or change.path == "" then
        return false, "缺少文件路径"
    end

    if change.action == "delete" then
        return true, nil
    end

    if not change.content or change.content == "" then
        return false, "文件内容为空"
    end

    -- 语法验证
    if change.lang then
        local ok, err = validate.syntax_check(change.content, change.lang, change.path)
        if not ok then
            return false, "语法错误: " .. (err or "unknown")
        end
    end

    return true, nil
end

---写入单个文件
---@param change table
---@param opts table { create_dirs = boolean, validate = boolean }
---@return boolean success
---@return string|nil error
local function write_change(change, opts)
    opts = opts or {}
    opts.create_dirs = opts.create_dirs ~= false
    opts.validate = opts.validate ~= false

    -- 解析绝对路径
    local cwd = vim.fn.getcwd()
    local abs_path = change.path
    if not vim.startswith(abs_path, "/") then
        abs_path = cwd .. "/" .. change.path
    end

    -- 创建父目录
    if opts.create_dirs then
        local parent = vim.fn.fnamemodify(abs_path, ":h")
        if vim.fn.isdirectory(parent) == 0 then
            local ok = pcall(vim.fn.mkdir, parent, "p")
            if not ok then
                return false, "无法创建目录: " .. parent
            end
        end
    end

    -- 写入文件
    local f = io.open(abs_path, "w")
    if not f then
        return false, "无法打开文件: " .. abs_path
    end
    f:write(change.content)
    f:close()

    -- 刷新 Neovim 缓冲区
    local bufnr = vim.fn.bufnr(abs_path)
    if bufnr ~= -1 then
        vim.cmd("checktime " .. vim.fn.fnameescape(abs_path))
    end

    return true, nil
end

---批量应用变更
---@param changes table[] 变更列表
---@param opts table { create_dirs = boolean, validate = boolean, on_progress = function }
---@return table results { success = number, failed = number, errors = table }
function M.apply_all(changes, opts)
    opts = opts or {}

    local results = {
        success = 0,
        failed = 0,
        errors = {},
        files = {},
    }

    for i, change in ipairs(changes) do
        -- 进度回调
        if opts.on_progress then
            opts.on_progress(i, #changes, change.path)
        end

        -- 验证
        local ok, err = validate_change(change)
        if not ok then
            results.failed = results.failed + 1
            results.errors[#results.errors + 1] = {
                path = change.path,
                error = err,
            }
            goto continue
        end

        -- 写入
        local write_ok, write_err = write_change(change, opts)
        if write_ok then
            results.success = results.success + 1
            results.files[#results.files + 1] = change.path
        else
            results.failed = results.failed + 1
            results.errors[#results.errors + 1] = {
                path = change.path,
                error = write_err,
            }
        end

        ::continue::
    end

    return results
end

---检测变更是否有文件冲突
---@param changes table[]
---@return table conflicts { file, changes[] }
function M.detect_conflicts(changes)
    local file_map = {}
    local conflicts = {}

    for _, change in ipairs(changes) do
        local path = change.path
        if not file_map[path] then
            file_map[path] = {}
        end
        table.insert(file_map[path], change)
    end

    for path, change_list in pairs(file_map) do
        if #change_list > 1 then
            conflicts[#conflicts + 1] = {
                file = path,
                changes = change_list,
            }
        end
    end

    return conflicts
end

---合并冲突的变更（简单合并：取最后一个）
---@param conflicts table[]
---@return table[] 合并后的变更列表
function M.merge_conflicts(conflicts)
    if #conflicts == 0 then
        return {}
    end

    local merged = {}
    for _, conflict in ipairs(conflicts) do
        -- 取最后一个变更
        local last = conflict.changes[#conflict.changes]
        merged[#merged + 1] = last
    end

    return merged
end

return M
