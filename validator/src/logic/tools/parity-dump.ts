/**
 * Parity dump — the TypeScript half of the byte-for-byte parity proof.
 *
 * Runs the ONE fixed scripted scenario shared with the GDScript verifier
 * (game/tools/verify_determinism.gd) and prints "TS_HASH <step> <hash>" lines.
 * Compare line-by-line against the "GD_HASH <step> <hash>" lines from Godot.
 *
 * Scenario: seed "WAR-PARITY-1", then 9 applies:
 *   new_game(seed) -> start_round -> flip -> resolve
 *                  -> start_round -> flip -> resolve
 *                  -> start_round -> flip -> resolve
 *
 * Run: cd validator/src/logic && bun tools/parity-dump.ts
 */

import { apply, newGame, stateHash } from "../src/index.js";
import type { Action, GameState } from "../src/index.js";

const SEED = "WAR-PARITY-1";

const SCRIPT: Action[] = [
  { type: "start_round" },
  { type: "flip" },
  { type: "resolve" },
  { type: "start_round" },
  { type: "flip" },
  { type: "resolve" },
  { type: "start_round" },
  { type: "flip" },
  { type: "resolve" },
];

function main(): void {
  let state: GameState = newGame(SEED);
  let step = 0;
  // Step 0 = after new_game.
  console.log(`TS_HASH ${step} ${stateHash(state)}`);
  for (const action of SCRIPT) {
    step += 1;
    const r = apply(state, action);
    if (!r.ok) {
      console.log(
        `TS_HASH ${step} ERROR action=${action.type} error=${r.error} phase=${state.phase}`,
      );
      process.exit(1);
    }
    state = r.state;
    console.log(`TS_HASH ${step} ${stateHash(state)}`);
  }
}

main();
