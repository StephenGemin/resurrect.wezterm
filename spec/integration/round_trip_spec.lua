-- Real filesystem save → load round-trip tests.
--
-- These use lunajson for actual JSON encode/decode so the full pipeline is
-- exercised: state table → json_encode → sanitize_json → atomic write to
-- disk → read_file → json_parse → table. Failures here mean saved state
-- files are corrupt or unreadable on a real user machine.
--
-- Requires: luarocks install lunajson

local helper = require("spec_helper")
local lunajson = require("lunajson")

local sep = package.config:sub(1, 1) == "\\" and "\\" or "/"

local function make_tmpdir()
	local base = "/tmp/resurrect_rt_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
	os.execute("mkdir -p " .. base)
	for _, t in ipairs({ "workspace", "window", "tab" }) do
		os.execute("mkdir -p " .. base .. sep .. t)
	end
	return base
end

local function load_state_manager(tmpdir)
	local wz = helper.new_wezterm({
		patch = function(w, _)
			w.json_encode = function(t) return lunajson.encode(t) end
			w.json_parse = function(s) return lunajson.decode(s) end
			w.run_child_process = function(args)
				if args[1] == "mkdir" then
					local rc = os.execute("mkdir -p " .. args[2])
					return (rc == 0 or rc == true), "", ""
				end
				return true, "", ""
			end
		end,
	})
	local sm = helper.load("resurrect.state_manager", wz)
	sm.save_state_dir = tmpdir .. sep
	return sm
end

describe("save_state → load_state round-trip (real filesystem)", function()
	local state_manager, tmpdir

	before_each(function()
		math.randomseed(os.time())
		tmpdir = make_tmpdir()
		state_manager = load_state_manager(tmpdir)
	end)

	after_each(function()
		os.execute("rm -rf " .. tmpdir)
	end)

	it("workspace state survives a save → load cycle intact", function()
		local state = { workspace = "myproject", window_states = { { tabs = {} } } }
		state_manager.save_state(state)

		local loaded = state_manager.load_state("myproject", "workspace")
		assert.are.equal("myproject", loaded.workspace)
		assert.is_table(loaded.window_states)
	end)

	it("creates the file at the expected path on disk", function()
		state_manager.save_state({ workspace = "diskcheck", window_states = {} })

		local expected = tmpdir .. sep .. "workspace" .. sep .. "diskcheck.json"
		local f = io.open(expected, "r")
		assert.not_nil(f, "file was not created at " .. expected)
		if f then f:close() end
	end)

	it("written file contains valid JSON with the original data", function()
		state_manager.save_state({ workspace = "jsoncheck", window_states = {} })

		local f = assert(io.open(tmpdir .. sep .. "workspace" .. sep .. "jsoncheck.json", "r"))
		local content = f:read("*a")
		f:close()

		local parsed = lunajson.decode(content)
		assert.is_table(parsed)
		assert.are.equal("jsoncheck", parsed.workspace)
	end)

	it("sanitises special characters in workspace names to keep files in the type dir", function()
		state_manager.save_state({ workspace = "team/project", window_states = {} })

		local safe_path = tmpdir .. sep .. "workspace" .. sep .. "team+project.json"
		local f = io.open(safe_path, "r")
		assert.not_nil(f, "sanitised filename was not created at " .. safe_path)
		if f then f:close() end
	end)

	it("load_state returns {} without error when the file does not exist", function()
		local loaded = state_manager.load_state("nonexistent", "workspace")
		assert.are.same({}, loaded)
	end)

	it("delete_state removes the file from disk", function()
		state_manager.save_state({ workspace = "todelete", window_states = {} })

		local full_path = tmpdir .. sep .. "workspace" .. sep .. "todelete.json"
		local f = io.open(full_path, "r")
		assert.not_nil(f, "precondition failed: file must exist before delete")
		if f then f:close() end

		state_manager.delete_state("workspace" .. sep .. "todelete.json")

		f = io.open(full_path, "r")
		assert.is_nil(f, "file should be removed after delete_state")
	end)
end)
