-- Capture-time trailing-prompt stripping: a restored pane's settle snapshot
-- measures what one organic prompt adds to the pane (row count + final-row
-- rendering), and captures taken after real activity get exactly that block
-- stripped -- persisted text stops where the live prompt begins, so the next
-- restore's fresh shell completes the screen instead of duplicating the
-- prompt. The exemplar is measured, never pattern-matched: the same code
-- path must hold for a single-row bash prompt, a multi-row oh-my-posh-style
-- prompt full of color escapes, and a pwsh prompt whose process reports as
-- pwsh.exe. Every guard fails toward persisting the capture unmodified,
-- because a wrong strip is quiet data loss.

local helper = require("spec_helper")

describe("capture-time trailing-prompt stripping (restore_baseline exemplar)", function()
	local wz, tab_state, pane_tree

	before_each(function()
		wz = helper.new_wezterm()
		tab_state = helper.load("resurrect.tab_state", wz)
		-- Plain require so pane_tree shares tab_state's restore_baseline
		-- instance; a second helper.load would reset package.loaded and give
		-- the two modules different registries.
		pane_tree = require("resurrect.pane_tree")
	end)

	local next_pane_id = 0

	local function make_pane(opts)
		next_pane_id = next_pane_id + 1
		local id = next_pane_id
		local pane = { content = opts.content or "" }
		function pane.pane_id(_)
			return id
		end
		function pane.inject_output(_, _) end
		function pane.send_text(_, _) end
		function pane.get_domain_name(_)
			return "local"
		end
		function pane.get_current_working_dir(_)
			return { file_path = "/tmp" }
		end
		function pane.is_alt_screen_active(_)
			return false
		end
		function pane.get_dimensions(_)
			return { scrollback_rows = 100 }
		end
		function pane.get_lines_as_escapes(_, _)
			return pane.content
		end
		function pane.get_foreground_process_info(_)
			return opts.process
		end
		return pane
	end

	-- The harness records call_after callbacks instead of executing them on a
	-- timer, and each settle poll schedules the next until the pane settles.
	-- settle_step fires one pending poll; settle drains the whole chain.
	local function settle_step()
		for _, call in ipairs(wz._rec.calls) do
			if call.name == "call_after" and not call.done then
				call.done = true
				call.fn()
				return true
			end
		end
		return false
	end

	local function settle()
		while settle_step() do
		end
	end

	local function capture(pane)
		local tree = pane_tree.create_pane_tree({
			{ pane = pane, left = 0, top = 0, width = 80, height = 24, is_active = true },
		})
		return tree.text
	end

	-- A multi-row oh-my-posh-style prompt: path row with color escapes, then
	-- a prompt-glyph row. Written in the canonical capture form (no trailing
	-- whitespace/escapes -- capture_pane_text strips those), matching what
	-- both the settle snapshot and later captures actually contain.
	local OMP_PROMPT = "\27[34m~/repos/demo\27[0m \27[90mmain\27[0m\r\n\27[35m\226\157\175"
	local ZSH = { name = "zsh", executable = "/bin/zsh" }

	it("persists a pristine restored pane as empty text while untouched", function()
		local pane = make_pane({ process = ZSH })
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		pane.content = OMP_PROMPT -- organic first prompt painted
		settle()
		assert.are.equal("", capture(pane))
	end)

	it("strips the measured multi-row prompt block from captures after activity", function()
		local pane = make_pane({ process = ZSH })
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		pane.content = OMP_PROMPT
		settle()
		-- The user ran a command: transient-style leftover, output, and a
		-- freshly painted prompt block identical in shape to the exemplar.
		local activity = "\226\157\175 ls\r\nfile_a  file_b"
		pane.content = activity .. "\r\n" .. OMP_PROMPT
		assert.are.equal(activity, capture(pane))
	end)

	it("strips a single-row prompt measured on a pane restored with a replay", function()
		local pane = make_pane({ process = { name = "bash", executable = "/bin/bash" }, content = "make: done" })
		tab_state.default_on_pane_restore({ pane = pane, text = "make: done" })
		pane.content = "make: done\r\nuser@host:~$"
		settle()
		pane.content = "make: done\r\nuser@host:~$ make\r\nok\r\nuser@host:~$"
		assert.are.equal("make: done\r\nuser@host:~$ make\r\nok", capture(pane))
	end)

	it("strips a pwsh prompt when the foreground process reports as pwsh.exe", function()
		local pane = make_pane({
			process = { name = "pwsh.exe", executable = "C:\\Program Files\\PowerShell\\7\\pwsh.exe" },
		})
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		pane.content = "PS C:\\Users\\sg>"
		settle()
		pane.content = "PS C:\\Users\\sg> dir\r\nreadme.md\r\nPS C:\\Users\\sg>"
		assert.are.equal("PS C:\\Users\\sg> dir\r\nreadme.md", capture(pane))
	end)

	it("does not strip when the final row no longer renders like the exemplar (typed command)", function()
		local pane = make_pane({ process = ZSH })
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		pane.content = OMP_PROMPT
		settle()
		local typed = "out\r\n" .. OMP_PROMPT .. " git st"
		pane.content = typed
		-- capture_pane_text strips nothing here (no trailing blanks), so the
		-- persisted text must be the capture, byte-identical.
		assert.are.equal(typed, capture(pane))
	end)

	it("does not strip when the foreground process is not a shell", function()
		local pane = make_pane({ process = { name = "node", executable = "/usr/bin/node" } })
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		pane.content = OMP_PROMPT
		settle()
		local busy = "out\r\n" .. OMP_PROMPT
		pane.content = busy
		assert.are.equal(busy, capture(pane))
	end)

	it("does not strip when a command is running at save time", function()
		local o = { process = ZSH }
		local pane = make_pane(o)
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		pane.content = OMP_PROMPT
		settle()
		o.process = { name = "node", executable = "/usr/bin/node" }
		local busy = "out\r\n" .. OMP_PROMPT
		pane.content = busy
		assert.are.equal(busy, capture(pane))
	end)

	it("learns the exemplar even when the prompt paints several polls late", function()
		local pane = make_pane({ process = ZSH })
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		-- Cold-start contention: the pane stays blank through the first polls.
		settle_step()
		settle_step()
		settle_step()
		pane.content = OMP_PROMPT
		settle()
		local activity = "\226\157\175 ls\r\nout"
		pane.content = activity .. "\r\n" .. OMP_PROMPT
		assert.are.equal(activity, capture(pane))
	end)

	it("falls back to idle-only tracking when no prompt is ever observed", function()
		local pane = make_pane({ process = ZSH, content = "make: done" })
		tab_state.default_on_pane_restore({ pane = pane, text = "make: done" })
		settle() -- drains the whole poll budget; the pane never grows
		-- Idle saves still persist the replay byte-stably...
		assert.are.equal("make: done", capture(pane))
		-- ...but with no exemplar, a capture after activity keeps its tail.
		pane.content = "make: done\r\nuser@host:~$"
		assert.are.equal("make: done\r\nuser@host:~$", capture(pane))
	end)

	it("does not strip when another region row renders like the exemplar's final row", function()
		local pane = make_pane({ process = ZSH })
		tab_state.default_on_pane_restore({ pane = pane, text = "" })
		pane.content = OMP_PROMPT
		settle()
		-- A transient-style leftover command row directly above the final
		-- prompt-glyph row: stripping the measured two rows would eat it, so
		-- the strip must decline and persist the capture unmodified.
		local suspicious = "out\r\n\226\157\175 pwd\r\n\27[35m\226\157\175"
		pane.content = suspicious
		assert.are.equal(suspicious, capture(pane))
	end)

	it("never strips a reused pane's settle growth, but keeps it idle-stable", function()
		local pane = make_pane({ process = ZSH })
		tab_state.default_on_pane_restore({ pane = pane, text = "hello", reused_pane = true })
		-- The already-running shell's own first prompt and the cd exchange
		-- land around the replay in no clean single-prompt shape.
		pane.content = "hello\r\n\226\157\175 cd /tmp\r\n" .. OMP_PROMPT
		settle()
		assert.are.equal("hello", capture(pane))
		pane.content = pane.content .. "\r\nout"
		local live = pane.content
		assert.are.equal(live, capture(pane))
	end)
end)

describe("utils capture-row helpers", function()
	local utils

	before_each(function()
		local wz = helper.new_wezterm()
		utils = helper.load("resurrect.utils", wz)
	end)

	it("row_plaintext removes CSI, OSC, and charset escapes and trims whitespace", function()
		local row = "\27(B\27[35m\226\157\175\27[0m \27]133;A\7\r"
		assert.are.equal("\226\157\175", utils.row_plaintext(row))
	end)

	it("strip_last_rows drops rows across \\r\\n separators without leaving a dangling \\r", function()
		assert.are.equal("a\r\nb", utils.strip_last_rows("a\r\nb\r\nc\r\nd", 2))
	end)

	it("strip_last_rows returns empty when n covers the whole text", function()
		assert.are.equal("", utils.strip_last_rows("a\r\nb", 2))
		assert.are.equal("", utils.strip_last_rows("only-row", 1))
	end)

	it("count_text_rows counts 0 for empty and rows otherwise", function()
		assert.are.equal(0, utils.count_text_rows(""))
		assert.are.equal(1, utils.count_text_rows("a"))
		assert.are.equal(3, utils.count_text_rows("a\r\nb\r\nc"))
	end)

	it("split_rows splits on row separators and returns {} for empty text", function()
		assert.are.same({}, utils.split_rows(""))
		assert.are.same({ "a", "", "c" }, utils.split_rows("a\r\n\r\nc"))
	end)
end)
