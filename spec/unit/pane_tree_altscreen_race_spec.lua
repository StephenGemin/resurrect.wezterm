local helper = require("spec_helper")

describe("pane_tree alt-screen capture race / nil process guard", function()
	local pane_tree

	before_each(function()
		local wz = helper.new_wezterm()
		pane_tree = helper.load("resurrect.pane_tree", wz)
	end)

	local CONTENT = "some scrollback content"

	local function make_pane(process_info)
		local pane = { content = CONTENT }
		function pane.get_domain_name(_)
			return "local"
		end
		function pane.get_current_working_dir(_)
			return { file_path = "/tmp" }
		end
		function pane.is_alt_screen_active(_)
			return true
		end
		function pane.get_foreground_process_info(_)
			return process_info
		end
		function pane.get_dimensions(_)
			return { scrollback_rows = 100 }
		end
		function pane.get_lines_as_escapes(_, _)
			return pane.content
		end
		function pane.pane_id(_)
			return 1
		end
		return pane
	end

	local function capture(process_info)
		local pane = make_pane(process_info)
		local tree = pane_tree.create_pane_tree({
			{ pane = pane, left = 0, top = 0, width = 80, height = 24, is_active = true },
		})
		return tree
	end

	it("still captures the process for a real, non-shell foreground process", function()
		local tree = capture({ name = "nvim", executable = "/usr/bin/nvim", argv = { "/usr/bin/nvim" } })
		assert.is_not_nil(tree.process)
		assert.are.equal("nvim", tree.process.name)
		assert.is_nil(tree.text)
		assert.is_true(tree.alt_screen_active)
	end)

	it("falls through to text capture when the foreground process is a common shell (bash race)", function()
		local tree = capture({ name = "bash", executable = "/bin/bash", argv = { "/bin/bash" } })
		assert.is_nil(tree.process)
		assert.are.equal(CONTENT, tree.text)
		assert.is_false(tree.alt_screen_active)
	end)

	it("matches shell names through a path prefix, .exe suffix, and mixed case", function()
		local tree = capture({ name = "/bin/ZSH.exe", executable = "/bin/ZSH.exe", argv = { "/bin/ZSH.exe" } })
		assert.is_nil(tree.process)
		assert.are.equal(CONTENT, tree.text)
	end)

	it("falls through to text capture instead of crashing when get_foreground_process_info returns nil (top crash)", function()
		local tree = capture(nil)
		assert.is_nil(tree.process)
		assert.are.equal(CONTENT, tree.text)
		assert.is_false(tree.alt_screen_active)
	end)
end)
