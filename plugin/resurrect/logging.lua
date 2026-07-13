local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local is_debug_enabled = os.getenv("RESURRECT_DEBUG") == "1"
local pub = {}

---@param on boolean
function pub.set_debug(on)
	is_debug_enabled = on == true
end

-- Guard eager arguments with this; Lua evaluates arguments before the call
---@return boolean
function pub.is_debug_enabled()
	return is_debug_enabled
end

---@param fmt string
---@param ... any
function pub.debug(fmt, ...)
	if is_debug_enabled then
		wezterm.log_info("resurrect.debug: " .. fmt:format(...))
	end
end

return pub
