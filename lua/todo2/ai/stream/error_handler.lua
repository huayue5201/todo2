local M = {}

-- 统一格式化错误消息
function M.format(err)
	if not err or err == "" then
		return "未知错误"
	end

	-- curl 连接失败
	if err:match("Failed to connect") or err:match("Connection refused") then
		return "无法连接到模型服务（可能未启动或端口错误）"
	end

	-- 超时
	if err:match("timed out") or err:match("timeout") then
		return "模型响应超时"
	end

	-- JSON 解析失败
	if err:match("JSON") or err:match("json") then
		return "模型返回了无效的 JSON 数据"
	end

	-- 模型不存在
	if err:match("model") and err:match("not found") then
		return "模型不存在（请检查模型名称）"
	end

	-- 空输出
	if err:match("no output") then
		return "模型未返回任何内容（可能连接失败）"
	end

	return err
end

return M
