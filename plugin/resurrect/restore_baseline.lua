local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

-- Restored panes replay their saved scrollback via inject_output, and the
-- restore's trailing "\r\n" makes the live shell print one genuinely new
-- prompt. A later save that re-captures such a pane therefore persists
-- [replay + fresh prompt] -- one extra prompt block per save->restore cycle,
-- forever. This module remembers what was replayed into each restored pane
-- and uses the OSC 133 semantic zones WezTerm builds from shell-integration
-- marks to tell "still just showing the replay" apart from real command
-- activity, so idle panes are persisted byte-identically instead of
-- re-captured.
local pub = {}

---@type {[integer]: {text: string, baseline_y: integer}}
local _baselines = {}

-- Entries for closed panes are unreachable (pane ids are never reused); drop
-- them so long-running sessions with many restores don't accumulate dead
-- scrollback copies.
local function sweep()
	local live = {}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(mux_win:tabs()) do
			for _, pane in ipairs(tab:panes()) do
				live[pane:pane_id()] = true
			end
		end
	end
	for pane_id in pairs(_baselines) do
		if not live[pane_id] then
			_baselines[pane_id] = nil
		end
	end
end

---Record the text just replayed into a restored pane. Call after
---inject_output: the cursor then sits at the end of the replay, and anything
---at or below that stable row is post-restore output. inject_output may still
---be mid-flight when the cursor is read, so the replay's newline count serves
---as a lower bound (the replay starts at the top of a freshly spawned pane).
---@param pane Pane
---@param text string the exact text passed to inject_output
function pub.register(pane, text)
	sweep()
	local _, newlines = text:gsub("\n", "")
	_baselines[pane:pane_id()] = {
		text = text,
		baseline_y = math.max(pane:get_cursor_position().y, newlines),
	}
end

---Returns the replayed text when the pane has seen no real command activity
---since restore, or nil when a normal capture should happen instead. Activity
---means an Output zone starting at or below the replay baseline; only a real
---command produces one (OSC 133;C) -- prompt redraws and the restore's own
---"\r\n" never do. The idle verdict additionally requires a live Prompt zone
---below the baseline, proving shell integration emits marks in this pane;
---without marks, idleness cannot be told apart from unmarked activity, so
---fall back to normal capture rather than freezing the saved text forever.
---@param pane Pane
---@return string|nil
function pub.idle_text(pane)
	local entry = _baselines[pane:pane_id()]
	if not entry then
		return nil
	end
	-- pcall: get_semantic_zones requires wezterm 20230320 or newer.
	local ok, output_zones, prompt_zones = pcall(function()
		return pane:get_semantic_zones("Output"), pane:get_semantic_zones("Prompt")
	end)
	if not ok then
		return nil
	end
	for _, zone in ipairs(output_zones) do
		if zone.start_y >= entry.baseline_y then
			-- A command really ran; live captures are the truth from here on
			-- (repeated captures of a live pane don't compound).
			_baselines[pane:pane_id()] = nil
			return nil
		end
	end
	for _, zone in ipairs(prompt_zones) do
		if zone.start_y >= entry.baseline_y then
			return entry.text
		end
	end
	return nil
end

return pub
