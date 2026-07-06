-- Restore into the current workspace without switching (MLFlexer-equivalent behavior).
-- The restored windows spawn into the current workspace, which is then renamed to the
-- saved name; the active workspace never changes.
resurrect.workspace_state.restore_workspace(state, {
	spawn_in_workspace = false,
	switch_workspace = false,
})
