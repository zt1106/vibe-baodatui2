## Code style
- use simplified chinese in text which are displayed to users

## Testing Notes
- Headless GUT runs do not always deliver GUI input; add the `Viewport`, `SceneTree.root`, and `Input` as receivers when simulating clicks.
- If simulated input fails, log state with `gut.p` and fall back to emitting the relevant signal so the scene logic is still exercised.
- Guard `get_node` lookups with `get_node_or_null` and `assert_not_null` to fail fast when scene paths drift.
