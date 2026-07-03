-- NixOS resolves vim/nvim/gvim (and their python/ruby host providers) to
-- immutable, hash-suffixed /nix/store paths. Those paths go stale across Nix
-- generations or a garbage collection, so replaying a saved argv verbatim can
-- fail to restore the pane. create_pane_tree should collapse the executable
-- to its bare command name and drop any --cmd/-c flag whose value points into
-- /nix/store, while leaving non-vim executables and their argv untouched.

local helper = require("spec_helper")

describe("pane_tree nix store sanitization", function()
	local pane_tree

	before_each(function()
		local wz = helper.new_wezterm()
		pane_tree = helper.load("resurrect.pane_tree", wz)
	end)

	local function make_pane(process_info)
		local pane = {}
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
		return pane
	end

	local function capture(process_info)
		local pane = make_pane(process_info)
		local tree = pane_tree.create_pane_tree({
			{ pane = pane, left = 0, top = 0, width = 80, height = 24, is_active = true },
		})
		return tree.process
	end

	it("collapses a nix-store nvim executable to its bare name", function()
		local process = capture({
			name = "nvim",
			executable = "/nix/store/jx332jllgyrqbnzi8svnk8xbygc9nbmp-neovim-unwrapped-0.11.5/bin/nvim",
			argv = { "/nix/store/jx332jllgyrqbnzi8svnk8xbygc9nbmp-neovim-unwrapped-0.11.5/bin/nvim", "Cargo.toml" },
		})
		assert.are.equal("nvim", process.executable)
		assert.are.same({ "nvim", "Cargo.toml" }, process.argv)
	end)

	it("drops --cmd/-c flags whose value is a nix store path", function()
		local process = capture({
			name = "nvim",
			executable = "/nix/store/jx332jllgyrqbnzi8svnk8xbygc9nbmp-neovim-unwrapped-0.11.5/bin/nvim",
			argv = {
				"/nix/store/jx332jllgyrqbnzi8svnk8xbygc9nbmp-neovim-unwrapped-0.11.5/bin/nvim",
				"--cmd",
				"lua vim.g.python3_host_prog='/nix/store/252cmdyhmr8ai7qz266yrawgmx7nfz5h-neovim-0.11.5/bin/nvim-python3'",
				"Cargo.toml",
			},
		})
		assert.are.same({ "nvim", "Cargo.toml" }, process.argv)
	end)

	it("keeps a --cmd flag whose value is not a nix store path", function()
		local process = capture({
			name = "nvim",
			executable = "/nix/store/jx332jllgyrqbnzi8svnk8xbygc9nbmp-neovim-unwrapped-0.11.5/bin/nvim",
			argv = {
				"/nix/store/jx332jllgyrqbnzi8svnk8xbygc9nbmp-neovim-unwrapped-0.11.5/bin/nvim",
				"--cmd",
				"set number",
			},
		})
		assert.are.same({ "nvim", "--cmd", "set number" }, process.argv)
	end)

	it("only sanitizes the executable for non-vim nix store binaries, leaving argv alone", function()
		local process = capture({
			name = "htop",
			executable = "/nix/store/abc123-htop-3.2.0/bin/htop",
			argv = { "/nix/store/abc123-htop-3.2.0/bin/htop", "--tree" },
		})
		assert.are.equal("htop", process.executable)
		assert.are.same({ "htop", "--tree" }, process.argv)
	end)

	it("leaves non-nix executables untouched", function()
		local process = capture({
			name = "nvim",
			executable = "/usr/bin/nvim",
			argv = { "/usr/bin/nvim", "Cargo.toml" },
		})
		assert.are.equal("/usr/bin/nvim", process.executable)
		assert.are.same({ "/usr/bin/nvim", "Cargo.toml" }, process.argv)
	end)
end)
