-- lua/todo2/ai/adapters/ollama.lua
-- 规范化 Ollama 流式适配器（统一接口 + 错误链 + 输出提取）

return function(ai)
	local Base = require("todo2.ai.adapters.base")
	local M = setmetatable({}, { __index = Base })

	---------------------------------------------------------------------
	-- ⭐ 所有配置来自 ai.current_config（由 fzf 切换）
	---------------------------------------------------------------------
	local function get_cfg()
		return ai.current_config -- 动态读取当前模型配置
	end

	---------------------------------------------------------------------
	-- URL 构建
	---------------------------------------------------------------------
	local function build_url(cfg, path)
		local host = cfg.host or "http://127.0.0.1"
		local port = cfg.port and (":" .. tostring(cfg.port)) or ""
		return host .. port .. path
	end

	---------------------------------------------------------------------
	-- ⭐ 流式 generate_stream（核心）
	---------------------------------------------------------------------
	function M.generate_stream(prompt, on_chunk, on_done)
		local cfg = get_cfg()
		if not cfg then
			return false, "未选择模型配置"
		end

		local url = build_url(cfg, "/api/generate")
		local timeout = cfg.timeout or 15

		-- 构建 payload
		local payload = vim.fn.json_encode({
			model = cfg.model,
			prompt = prompt,
			temperature = cfg.temperature,
			max_tokens = cfg.max_tokens,
			top_p = cfg.top_p,
			stream = true,
		})

		-- curl 命令
		local cmd = {
			"curl",
			"-sN",
			"--max-time",
			tostring(timeout),
			"-X",
			"POST",
			"-H",
			"Content-Type: application/json",
			"-d",
			payload,
			url,
		}

		-- 启动流式任务
		local job_id = vim.fn.jobstart(cmd, {
			stdout_buffered = false,

			on_stdout = function(_, data, _)
				for _, line in ipairs(data) do
					if not line or line == "" then
						goto continue
					end

					local ok, decoded = pcall(vim.fn.json_decode, line)
					if ok and decoded then
						if decoded.error then
							on_chunk("[Ollama 错误] " .. tostring(decoded.error))
							goto continue
						end

						local text = Base.extract_text(decoded)
						if text and text ~= "" then
							on_chunk(text)
						end
					end

					::continue::
				end
			end,

			on_stderr = function(_, data, _)
				for _, line in ipairs(data) do
					if line and line ~= "" then
						on_chunk("[stderr] " .. line)
					end
				end
			end,

			on_exit = function()
				if on_done then
					on_done()
				end
			end,
		})

		if job_id <= 0 then
			return false, "jobstart 启动失败"
		end

		return true, nil, job_id
	end

	---------------------------------------------------------------------
	-- 注册适配器
	---------------------------------------------------------------------
	ai.register("ollama", M)
end
