-- default_on_pane_restore replayed saved scrollback into a pane and then sent a
-- trailing "\r\n" to force a fresh prompt. The trailing-whitespace strip on the
-- replayed text (`%s+$`) was meant to keep that from compounding, but
-- get_lines_as_escapes() often ends blank rows in a trailing SGR escape (e.g. a
-- color reset) rather than pure whitespace, so the strip silently did nothing --
-- every idle row present at save time got replayed forever, growing by one more
-- "\r\n" every subsequent restore.

local helper = require("spec_helper")

describe("tab_state.default_on_pane_restore trailing blank-row stripping", function()
	local tab_state

	before_each(function()
		local wz = helper.new_wezterm()
		tab_state = helper.load("resurrect.tab_state", wz)
	end)

	local function make_pane()
		local injected
		local pane = {}
		function pane.inject_output(_, text)
			injected = text
		end
		function pane.send_text(_, _) end
		return pane, function()
			return injected
		end
	end

	it("strips trailing blank rows even when they end in a trailing escape sequence", function()
		local pane, get_injected = make_pane()
		-- Mirrors what get_lines_as_escapes() actually produced in the field: blank
		-- rows separated by \r\n, with a trailing SGR reset that isn't whitespace.
		local text = "real content\27[39m\r\n\r\n\r\n\r\n\27[39m"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		-- The trailing escape immediately after "real content" is stripped too --
		-- harmless, since the shell's own prompt redraw resets attributes anyway.
		assert.are.equal("real content", get_injected())
	end)

	it("strips trailing blank rows ending in an OSC sequence terminated by BEL", function()
		local pane, get_injected = make_pane()
		-- Mirrors OSC 133 (shell-integration prompt marker) left trailing after
		-- clear: a bare-BEL-terminated OSC sequence that the old CSI-only pass
		-- couldn't recognize, which blocked stripping of the blank rows above it.
		local text = "real content\27[39m\r\n\r\n\r\n\27]133;A\7"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content", get_injected())
	end)

	it("strips trailing blank rows ending in an OSC sequence terminated by ST", function()
		local pane, get_injected = make_pane()
		-- Same as above but with the ESC-\ (String Terminator) form some shells emit
		-- instead of BEL.
		local text = "real content\27[39m\r\n\r\n\r\n\27]133;A\27\\"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content", get_injected())
	end)

	it("strips interleaved trailing CSI and OSC sequences", function()
		local pane, get_injected = make_pane()
		-- Proves the alternating loop handles a CSI reset directly followed by an
		-- OSC marker (and blank rows between/around them), not just one kind alone.
		local text = "real content\27[39m\r\n\r\n\27]133;A\7\27[0m"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content", get_injected())
	end)

	it("leaves text with no trailing blank rows unchanged", function()
		local pane, get_injected = make_pane()
		local text = "real content"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content", get_injected())
	end)
end)
