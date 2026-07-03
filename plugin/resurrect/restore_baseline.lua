local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")

-- Restored panes replay their saved scrollback via inject_output, and the
-- restore's trailing "\r\n" makes the live shell print one genuinely new
-- prompt. A later save that re-captures such a pane therefore persists
-- [replay + fresh prompt] -- one extra prompt block per save->restore cycle,
-- forever. This module remembers what was replayed into each restored pane,
-- snapshots the pane's rendered content once that fresh prompt has painted,
-- and treats "a capture still equals the snapshot" as proof the pane is
-- untouched, persisting the replay byte-identically instead of re-capturing.
-- Any content change at all falls back to a live capture, so real activity
-- can never be mistaken for idleness. (OSC 133 semantic zones were tried
-- first and are unreliable on wezterm 20240203: the restore's own "\r\n"
-- creates spurious Output zones under transient prompts, while real command
-- output sometimes creates none.)
local pub = {}

---@type {[integer]: {text: string, snapshot: string?}}
local _baselines = {}

-- How long after the restore's "\r\n" the fresh prompt is given to paint
-- before the settle snapshot is taken. Too early and the snapshot misses the
-- prompt (every later save then mismatches and captures live -- the old,
-- compounding behavior); there is no correctness risk in being generous.
local SETTLE_DELAY_SECONDS = 1.0

-- A settle snapshot may exceed the rendered replay by a fresh prompt block,
-- nothing more. Growth beyond this many rows means the user was already
-- active during the settle window; freezing that activity into the snapshot
-- would let a later idle save silently persist the pre-activity replay, so
-- the registration is dropped instead (normal captures from then on).
local MAX_SETTLE_GROWTH_ROWS = 8

local function count_rows(text)
	local _, n = text:gsub("\n", "")
	return n
end

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
---inject_output and before the "\r\n" that triggers the fresh prompt; the
---settle snapshot is scheduled from here.
---@param pane Pane
---@param text string the exact text passed to inject_output
function pub.register(pane, text)
	sweep()
	-- Lazy require: pane_tree requires this module back, so a top-level
	-- require would be circular.
	local max_nlines = require("resurrect.pane_tree").max_nlines
	local pane_id = pane:pane_id()
	local entry = { text = text }
	_baselines[pane_id] = entry
	-- The replay as actually rendered in this pane: long lines re-wrap to the
	-- new pane's width, so the snapshot growth bound must be measured against
	-- this, not against the original text's row count.
	local ok, rendered = pcall(utils.capture_pane_text, pane, max_nlines)
	if not ok then
		_baselines[pane_id] = nil
		wezterm.log_info(("resurrect.restore_baseline: pane %d register capture failed, not tracking"):format(pane_id))
		return
	end
	local rendered_rows = count_rows(rendered)
	wezterm.log_info(
		("resurrect.restore_baseline: pane %d registered replay (%d bytes, %d rendered rows)"):format(
			pane_id,
			#text,
			rendered_rows
		)
	)
	wezterm.time.call_after(SETTLE_DELAY_SECONDS, function()
		if _baselines[pane_id] ~= entry then
			return
		end
		-- pcall: the pane may have closed during the settle window.
		local snap_ok, snapshot = pcall(utils.capture_pane_text, pane, max_nlines)
		if not snap_ok then
			_baselines[pane_id] = nil
			wezterm.log_info(
				("resurrect.restore_baseline: pane %d settle capture failed, not tracking"):format(pane_id)
			)
			return
		end
		local snapshot_rows = count_rows(snapshot)
		if snapshot_rows > rendered_rows + MAX_SETTLE_GROWTH_ROWS then
			_baselines[pane_id] = nil
			wezterm.log_info(
				("resurrect.restore_baseline: pane %d grew %d->%d rows during settle (activity), not tracking"):format(
					pane_id,
					rendered_rows,
					snapshot_rows
				)
			)
			return
		end
		entry.snapshot = snapshot
		wezterm.log_info(
			("resurrect.restore_baseline: pane %d settled (%d rows), idle saves will persist the replay"):format(
				pane_id,
				snapshot_rows
			)
		)
	end)
end

---Decide what to persist for a pane given its freshly captured content.
---Returns the originally replayed text when the capture proves the pane is
---untouched since restore (byte-identical to the settle snapshot); otherwise
---returns the capture. A mismatch drops the registration: the pane has seen
---real activity, and live captures are the truth from there on (repeated
---captures of a live pane don't compound).
---@param pane Pane
---@param captured string the pane's current content as captured by pane_tree
---@return string
function pub.text_to_persist(pane, captured)
	local entry = _baselines[pane:pane_id()]
	if not entry then
		return captured
	end
	local pane_id = pane:pane_id()
	if not entry.snapshot then
		wezterm.log_info(("resurrect.restore_baseline: pane %d saved before settle, capturing live"):format(pane_id))
		return captured
	end
	if captured == entry.snapshot then
		wezterm.log_info(("resurrect.restore_baseline: pane %d idle, persisting replay"):format(pane_id))
		return entry.text
	end
	_baselines[pane_id] = nil
	wezterm.log_info(
		("resurrect.restore_baseline: pane %d changed since restore, capturing live from now on"):format(pane_id)
	)
	return captured
end

return pub
