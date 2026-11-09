# Parity fixtures

Shared rule checks run by both simulations:

- Server: `cd server && npx tsx --test tests/parity.test.ts`
- Client: `Godot --headless --path . res://scripts/tests/parity_tests.tscn`

Single-player (GDScript) is the reference. `expect` values come from the client; when the server disagrees, the server is wrong unless the fixture is being changed on purpose.

## File format

Each `*.json` file is an array of cases:

```json
{
  "name": "unique_name",
  "map": { "width": 30, "height": 30, "objects": [{ "type": "wall_straight", "from": [10, 10], "to": [20, 10] }] },
  "soldiers": [{ "team": 1, "id": 1, "cell": [15, 5], "facing": [0, 1], "stance": "up", "stress": 0, "weapon": "m1_garand" }],
  "query": { "kind": "los", "shooter": [1, 1], "target": [2, 1] },
  "expect": { },
  "knownDrift": "optional: why the server currently disagrees (sim-parity Step 3 item)"
}
```

- `objects`: `at` for one cell, or `from`/`to` for a straight row or column (inclusive). Types are plain map object ids (`wall_straight`, `tree`, `haybail`); no asset family.
- `soldiers`: team 1 = USA, 2 = Germany, ids 1-4. Soldiers not listed are marked dead. Optional fields: `facing` (default `[0, 1]`), `stance` (`up`/`down`), `stress`, `weapon`, `marksman`, `sustainedFire`, `engagedTarget` (`[team, id]`).
- `knownDrift`: the server runner reports the case as a TODO instead of failing. Remove it when the server fix lands.

## Query kinds

| kind | query fields | expect fields |
|---|---|---|
| `los` | `shooter`, `target` | `status`, `blockingCell`, `coverType`, `cornerPeek`, `peekSide`, `cornerCell`, `targetUsingWallCover` |
| `cover` | `shooter`, `target` | `coverType` |
| `hit_chance` | `shooter`, `target` | `chance` (4 dp) |
| `suppression` | `shooter`, `target` | `gain` (2 dp) |
| `stress_decay` | `stress`, `prone`, `deltaSec` | `stress` (4 dp) |
| `grenade` | `thrower`, `cell` | `stunned` (`[team, id, durationSec]`, sorted), `killed` (always empty: kills are forced off) |
| `auto_target` | `shooter` | `target` (`[team, id]` or null) |
| `arrival_facing` | `cell` | `facing` (`[x, y]` or null) |

Enums: status 0 clear / 1 cover / 2 blocked; cover 0 none / 1 moderate / 2 complete; peek side 0 none / 1 left / 2 right. Missing cells are `null`.

To print what the client currently produces for every case (when adding fixtures), run the client runner with `-- --print`.
