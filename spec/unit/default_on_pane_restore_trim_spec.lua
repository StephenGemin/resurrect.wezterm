-- default_on_pane_restore replays saved scrollback into a pane and appends one
-- "\r\n" *as output*, so the shell's own first prompt paints on the row below
-- the replay. Two quiet failure modes are pinned here. First, the trailing
-- blank-row strip: get_lines_as_escapes() often ends blank rows in a trailing
-- SGR escape (e.g. a color reset) rather than pure whitespace, and a strip
-- that misses those replays every idle row forever, growing per restore.
-- Second, the stdin contract: nothing may ever be written to the shell's
-- stdin during a text restore -- a synthetic Enter makes the line editor
-- accept an empty line once it comes up, printing an extra prompt and, under
-- in-place prompt rewriters (oh-my-posh transient prompts), redrawing over
-- the replayed rows.

local helper = require("spec_helper")

describe("tab_state.default_on_pane_restore trailing blank-row stripping", function()
	local tab_state

	before_each(function()
		local wz = helper.new_wezterm()
		tab_state = helper.load("resurrect.tab_state", wz)
	end)

	local function make_pane()
		local injected
		local stdin_writes = {}
		local pane = {}
		function pane.inject_output(_, text)
			injected = text
		end
		function pane.send_text(_, text)
			table.insert(stdin_writes, text)
		end
		-- default_on_pane_restore registers the replayed text with
		-- restore_baseline, which needs an id and cursor position.
		function pane.pane_id(_)
			return 1
		end
		function pane.get_cursor_position(_)
			return { x = 0, y = 0 }
		end
		return pane, function()
			return injected
		end, stdin_writes
	end

	it("strips trailing blank rows even when they end in a trailing escape sequence", function()
		local pane, get_injected = make_pane()
		-- Mirrors what get_lines_as_escapes() actually produced in the field: blank
		-- rows separated by \r\n, with a trailing SGR reset that isn't whitespace.
		local text = "real content\27[39m\r\n\r\n\r\n\r\n\27[39m"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		-- The trailing escape immediately after "real content" is stripped too --
		-- harmless, since the shell's own prompt redraw resets attributes anyway.
		assert.are.equal("real content\r\n", get_injected())
	end)

	it("strips trailing blank rows ending in an OSC sequence terminated by BEL", function()
		local pane, get_injected = make_pane()
		-- Mirrors OSC 133 (shell-integration prompt marker) left trailing after
		-- clear: a bare-BEL-terminated OSC sequence that the old CSI-only pass
		-- couldn't recognize, which blocked stripping of the blank rows above it.
		local text = "real content\27[39m\r\n\r\n\r\n\27]133;A\7"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content\r\n", get_injected())
	end)

	it("strips trailing blank rows ending in an OSC sequence terminated by ST", function()
		local pane, get_injected = make_pane()
		-- Same as above but with the ESC-\ (String Terminator) form some shells emit
		-- instead of BEL.
		local text = "real content\27[39m\r\n\r\n\r\n\27]133;A\27\\"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content\r\n", get_injected())
	end)

	it("strips interleaved trailing CSI and OSC sequences", function()
		local pane, get_injected = make_pane()
		-- Proves the alternating loop handles a CSI reset directly followed by an
		-- OSC marker (and blank rows between/around them), not just one kind alone.
		local text = "real content\27[39m\r\n\r\n\27]133;A\7\27[0m"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content\r\n", get_injected())
	end)

	it("strips trailing blank rows ending in a charset-designation escape", function()
		local pane, get_injected = make_pane()
		-- Mirrors a real fresh-workspace capture: get_lines_as_escapes emits an
		-- ESC ( B charset designation at the start of every row, so a capture
		-- ending mid-blank-row leaves one as the final token, which the
		-- whitespace/CSI/OSC passes alone couldn't get past.
		local text = "real content\27[39m\r\n\r\n\r\n\r\n\27(B"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content\r\n", get_injected())
	end)

	it("appends exactly one \\r\\n to text with no trailing blank rows", function()
		local pane, get_injected = make_pane()
		local text = "real content"
		tab_state.default_on_pane_restore({ pane = pane, text = text })
		assert.are.equal("real content\r\n", get_injected())
	end)

	it("injects nothing at all when the saved text strips down to empty", function()
		local pane, get_injected = make_pane()
		tab_state.default_on_pane_restore({ pane = pane, text = "\r\n\r\n\27[39m" })
		assert.is_nil(get_injected())
	end)

	it("never writes to the shell's stdin", function()
		local pane, _, stdin_writes = make_pane()
		tab_state.default_on_pane_restore({ pane = pane, text = "real content" })
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		assert.are.same({}, stdin_writes)
	end)
end)
