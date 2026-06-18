// src/constants.ts
var STATE_VERSION = 1;
var RANK_MIN = 2;
var RANK_MAX = 14;
var RANKS = [
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14
];
var SUITS = ["clubs", "diamonds", "hearts", "spades"];
var DECK_SIZE = 52;
var DEAL_SIZE = 26;
var WAR_STAKE = 3;
var PHASE_DEALT = "dealt";
var PHASE_SELECTED = "selected";
var PHASE_FLIPPED = "flipped";
var PHASE_WAR = "war";
var PHASE_PLAYER_WIN = "player_win";
var PHASE_CPU_WIN = "cpu_win";
var WHEN_PRE_FLIP = "pre_flip";
var WHEN_POST_FLIP = "post_flip";
var SPECIAL_CARDS = {
  peek: {
    name: "Scrying Peek",
    when: "pre_flip",
    desc: "Before the flip, glimpse your own top card (reveals it face-up early). Pure information; does not change deck order."
  },
  rank_boost: {
    name: "Rank Surge",
    when: "post_flip",
    desc: "After the flip, add +2 to the rank of your revealed card for this round's comparison only (does not persist on the card)."
  },
  steal_tie: {
    name: "Tie Thief",
    when: "post_flip",
    desc: "If this round is a tie, you win the pot outright instead of triggering a WAR."
  }
};
var SPECIAL_CARD_IDS = [
  "peek",
  "rank_boost",
  "steal_tie"
];

// src/rng.ts
var FNV_OFFSET = 2166136261;
var FNV_PRIME = 16777619;
var NONZERO_FALLBACK = 2654435769;
function u32(v) {
  return v >>> 0;
}
function mulU32(a, b) {
  return Math.imul(a, b) >>> 0;
}
function seedToWord(seed) {
  let h = FNV_OFFSET >>> 0;
  const bytes = new TextEncoder().encode(seed);
  for (let i = 0; i < bytes.length; i++) {
    h = u32(h ^ bytes[i]);
    h = mulU32(h, FNV_PRIME);
  }
  return h === 0 ? NONZERO_FALLBACK : h;
}
function step(x) {
  x = u32(x ^ u32(x << 13));
  x = u32(x ^ x >>> 17);
  x = u32(x ^ u32(x << 5));
  return x;
}
function stateWordFor(seed, seq) {
  let x = seedToWord(seed);
  for (let i = 0; i < seq; i++) {
    x = step(x);
  }
  return x;
}
function nextU32(seed, rng) {
  const seq = rng.seq | 0;
  const word = stateWordFor(seed, seq + 1);
  return { value: word, rng: { seq: seq + 1 } };
}
function nextBelow(seed, rng, n) {
  const s = nextU32(seed, rng);
  return { value: s.value % n, rng: s.rng };
}
function shuffle(seed, array, rng) {
  const out = array.slice();
  let cursor = { seq: rng.seq | 0 };
  let i = out.length - 1;
  while (i > 0) {
    const s = nextBelow(seed, cursor, i + 1);
    const j = s.value;
    cursor = s.rng;
    const tmp = out[i];
    out[i] = out[j];
    out[j] = tmp;
    i -= 1;
  }
  return { array: out, rng: cursor };
}
function seedFrom(_seed) {
  return { seq: 0 };
}
function newRng() {
  return { seq: 0 };
}

// src/special-cards.ts
function cloneCard(c) {
  return { rank: c.rank, suit: c.suit, face_up: c.face_up };
}
function cloneCards(cs) {
  return cs.map(cloneCard);
}
function cloneState(s) {
  return {
    version: s.version,
    seed: s.seed,
    phase: s.phase,
    player_deck: cloneCards(s.player_deck),
    cpu_deck: cloneCards(s.cpu_deck),
    player_pot: cloneCards(s.player_pot),
    cpu_pot: cloneCards(s.cpu_pot),
    rng: { seq: s.rng.seq },
    specials: {
      player: s.specials.player.slice(),
      cpu: s.specials.cpu.slice()
    },
    pending_special: s.pending_special,
    war_depth: s.war_depth
  };
}
function result(ok, state, events, error) {
  return { ok, state, events, error };
}
function ids() {
  return Object.keys(SPECIAL_CARDS);
}
function isValidId(id) {
  return typeof id === "string" && Object.prototype.hasOwnProperty.call(SPECIAL_CARDS, id);
}
function consumeOwned(state, id) {
  const owned = state.specials.player;
  const idx = owned.indexOf(id);
  if (idx < 0) {
    return false;
  }
  owned.splice(idx, 1);
  return true;
}
function resolve(state, specialId) {
  if (!Object.prototype.hasOwnProperty.call(SPECIAL_CARDS, specialId)) {
    return result(false, state, [], "unknown_special");
  }
  const next = cloneState(state);
  const events = [];
  if (!consumeOwned(next, specialId)) {
    return result(false, state, [], "special_not_owned");
  }
  return applyEffect(next, specialId, events);
}
function applyEffect(next, specialId, events) {
  switch (specialId) {
    case "peek": {
      const pot = next.player_pot;
      if (pot.length === 0) {
        return result(false, next, [], "peek_no_card");
      }
      const top = pot[pot.length - 1];
      top.face_up = true;
      events.push({
        type: "special_peek",
        card: { rank: top.rank, suit: top.suit }
      });
      next.pending_special = null;
      return result(true, next, events, "");
    }
    case "rank_boost": {
      const pot = next.player_pot;
      if (pot.length === 0) {
        return result(false, next, [], "rank_boost_no_card");
      }
      const card = pot[pot.length - 1];
      const oldRank = card.rank ?? RANK_MIN;
      const newRank = Math.min(oldRank + 2, RANK_MAX);
      card.rank = newRank;
      events.push({ type: "special_rank_boost", from: oldRank, to: newRank });
      next.pending_special = null;
      return result(true, next, events, "");
    }
    case "steal_tie": {
      next.pending_special = "steal_tie";
      events.push({ type: "special_steal_tie_armed" });
      return result(true, next, events, "");
    }
    default:
      return result(false, next, [], "special_not_implemented");
  }
}

// src/hashing.ts
var IV = [
  1779033703,
  3144134277,
  1013904242,
  2773480762,
  1359893119,
  2600822924,
  528734635,
  1541459225
];
var SHIFTS = [5, 7, 11, 13, 17, 19, 23, 29];
function formatNumber(n) {
  if (!Number.isFinite(n)) {
    throw new Error(`canonicalStringify: non-finite number ${String(n)}`);
  }
  if (Number.isInteger(n)) {
    return String(n === 0 ? 0 : n);
  }
  return String(n);
}
function quoteString(s) {
  return JSON.stringify(s);
}
function encode(value, indent) {
  if (value === null) {
    return "null";
  }
  const t = typeof value;
  if (t === "string") {
    return quoteString(value);
  }
  if (t === "number") {
    return formatNumber(value);
  }
  if (t === "boolean") {
    return value ? "true" : "false";
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return "[]";
    }
    const childIndent = indent + "  ";
    const parts = value.map((el) => childIndent + encode(el, childIndent));
    return "[\n" + parts.join(",\n") + "\n" + indent + "]";
  }
  if (t === "object") {
    const obj = value;
    const childIndent = indent + "  ";
    const keys = Object.keys(obj).filter((k) => obj[k] !== null && obj[k] !== void 0).sort();
    if (keys.length === 0) {
      return "{}";
    }
    const parts = keys.map(
      (k) => childIndent + quoteString(k) + ": " + encode(obj[k], childIndent)
    );
    return "{\n" + parts.join(",\n") + "\n" + indent + "}";
  }
  throw new Error(`canonicalStringify: unsupported value type ${t}`);
}
function canonicalStringify(value) {
  return encode(value, "");
}
function toInt32(x) {
  return x | 0;
}
function laneHex(lane) {
  return (lane >>> 0).toString(16).padStart(8, "0");
}
function hashString(s) {
  const lanes = IV.slice();
  const bytes = new TextEncoder().encode(s);
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    for (let lane = 0; lane < 8; lane++) {
      const h = lanes[lane];
      const shift = SHIFTS[lane];
      lanes[lane] = toInt32(toInt32(h << shift) - h + b);
    }
  }
  let out = "";
  for (let lane = 0; lane < 8; lane++) {
    out += laneHex(lanes[lane]);
  }
  return out;
}
function hashValue(value) {
  return hashString(canonicalStringify(value));
}

// src/engine.ts
function cloneCard2(c) {
  return { rank: c.rank, suit: c.suit, face_up: c.face_up };
}
function cloneCards2(cs) {
  return cs.map(cloneCard2);
}
function cloneState2(s) {
  return {
    version: s.version,
    seed: s.seed,
    phase: s.phase,
    player_deck: cloneCards2(s.player_deck),
    cpu_deck: cloneCards2(s.cpu_deck),
    player_pot: cloneCards2(s.player_pot),
    cpu_pot: cloneCards2(s.cpu_pot),
    rng: { seq: s.rng.seq },
    specials: {
      player: s.specials.player.slice(),
      cpu: s.specials.cpu.slice()
    },
    pending_special: s.pending_special,
    war_depth: s.war_depth
  };
}
function buildDeck() {
  const deck = [];
  for (const suit of SUITS) {
    for (const rank of RANKS) {
      deck.push({ rank, suit, face_up: false });
    }
  }
  return deck;
}
function makeResult(ok, state, events, error) {
  return { ok, state, events, error };
}
function fail(state, error) {
  return makeResult(false, state, [], error);
}
function newGame(seed) {
  let rng = seedFrom();
  const deck0 = buildDeck();
  const shuffled = shuffle(seed, deck0, rng);
  const deck = shuffled.array;
  rng = shuffled.rng;
  const player_deck = deck.slice(0, DEAL_SIZE);
  const cpu_deck = deck.slice(DEAL_SIZE, DEAL_SIZE * 2);
  return {
    version: STATE_VERSION,
    seed,
    phase: PHASE_DEALT,
    player_deck,
    cpu_deck,
    player_pot: [],
    cpu_pot: [],
    rng,
    specials: { player: [], cpu: [] },
    pending_special: null,
    war_depth: 0
  };
}
function checkLegal(state, action) {
  const type = action.type;
  const phase = state.phase;
  if (type === "new_game") {
    return "";
  }
  if (phase === PHASE_PLAYER_WIN || phase === PHASE_CPU_WIN) {
    return "game_over";
  }
  switch (type) {
    case "start_round":
      if (phase !== PHASE_DEALT) {
        return "start_round_wrong_phase";
      }
      if (state.player_deck.length === 0 || state.cpu_deck.length === 0) {
        return "start_round_empty_deck";
      }
      return "";
    case "play_special": {
      const id = action.id;
      if (!Object.prototype.hasOwnProperty.call(SPECIAL_CARDS, id)) {
        return "unknown_special";
      }
      if (!state.specials.player.includes(id)) {
        return "special_not_owned";
      }
      if (state.pending_special !== null) {
        return "special_already_pending";
      }
      const when = SPECIAL_CARDS[id].when;
      if (when === WHEN_PRE_FLIP) {
        if (phase !== PHASE_DEALT && phase !== PHASE_SELECTED) {
          return "pre_flip_wrong_phase";
        }
      } else {
        if (phase !== PHASE_FLIPPED && phase !== PHASE_WAR) {
          return "post_flip_wrong_phase";
        }
      }
      return "";
    }
    case "flip":
      if (phase !== PHASE_SELECTED) {
        return "flip_wrong_phase";
      }
      return "";
    case "resolve":
      if (phase !== PHASE_FLIPPED && phase !== PHASE_WAR) {
        return "resolve_wrong_phase";
      }
      return "";
    case "ack_war":
      if (phase !== PHASE_WAR) {
        return "ack_war_wrong_phase";
      }
      return "";
    default:
      return "unknown_action";
  }
}
function apply(state, action) {
  if (action.type === "new_game") {
    return makeResult(
      true,
      newGame(action.seed),
      [{ type: "new_game", seed: action.seed }],
      ""
    );
  }
  const legalError = checkLegal(state, action);
  if (legalError !== "") {
    return fail(state, legalError);
  }
  const next = cloneState2(state);
  switch (action.type) {
    case "start_round":
      return startRound(next);
    case "play_special":
      return playSpecial(next, action.id);
    case "flip":
      return flip(next);
    case "resolve":
      if (next.phase === PHASE_WAR) {
        return ackWar(next);
      }
      return resolveRound(next);
    case "ack_war":
      return ackWar(next);
    default:
      return fail(state, "unknown_action");
  }
}
function startRound(next) {
  const pCard = next.player_deck.shift();
  const cCard = next.cpu_deck.shift();
  pCard.face_up = false;
  cCard.face_up = false;
  next.player_pot.push(pCard);
  next.cpu_pot.push(cCard);
  next.war_depth = 0;
  next.pending_special = null;
  next.phase = PHASE_SELECTED;
  return makeResult(true, next, [{ type: "round_staged" }], "");
}
function playSpecial(next, id) {
  const res = resolve(next, id);
  if (!res.ok) {
    return fail(next, res.error);
  }
  return makeResult(true, res.state, res.events, "");
}
function flip(next) {
  const pp = next.player_pot;
  const cp = next.cpu_pot;
  const pTop = pp[pp.length - 1];
  const cTop = cp[cp.length - 1];
  pTop.face_up = true;
  cTop.face_up = true;
  const pRank = pTop.rank;
  const cRank = cTop.rank;
  const events = [
    {
      type: "flip",
      player: topSummary(pp),
      cpu: topSummary(cp)
    }
  ];
  if (pRank === cRank && next.pending_special !== "steal_tie") {
    events.push({ type: "tie", rank: pRank });
    next.war_depth = 1;
    next.phase = PHASE_WAR;
  } else {
    next.phase = PHASE_FLIPPED;
  }
  return makeResult(true, next, events, "");
}
function resolveRound(next) {
  const pp = next.player_pot;
  const cp = next.cpu_pot;
  const pRank = pp[pp.length - 1].rank;
  const cRank = cp[cp.length - 1].rank;
  const events = [];
  if (pRank > cRank) {
    awardPotsTo(next, "player", events);
    next.pending_special = null;
    next.war_depth = 0;
    return finishRound(next, events);
  } else if (cRank > pRank) {
    awardPotsTo(next, "cpu", events);
    next.pending_special = null;
    next.war_depth = 0;
    return finishRound(next, events);
  } else {
    if (next.pending_special === "steal_tie") {
      events.push({ type: "steal_tie_fired" });
      awardPotsTo(next, "player", events);
      next.pending_special = null;
      next.war_depth = 0;
      return finishRound(next, events);
    }
    events.push({ type: "tie", rank: pRank });
    next.pending_special = null;
    next.war_depth = Math.max(1, next.war_depth);
    next.phase = PHASE_WAR;
    return makeResult(true, next, events, "");
  }
}
function ackWar(next) {
  const pd = next.player_deck;
  const cd = next.cpu_deck;
  const need = WAR_STAKE + 1;
  const pShort = pd.length < need;
  const cShort = cd.length < need;
  const events = [];
  if (pShort || cShort) {
    let winner;
    if (pShort && cShort) {
      winner = pd.length > cd.length ? "player" : "cpu";
    } else if (pShort) {
      winner = "cpu";
    } else {
      winner = "player";
    }
    events.push({ type: "war_forfeit", winner });
    awardPotsTo(next, winner, events);
    next.pending_special = null;
    next.war_depth = 0;
    next.phase = winner === "player" ? PHASE_PLAYER_WIN : PHASE_CPU_WIN;
    events.push({ type: "game_over", winner });
    return makeResult(true, next, events, "");
  }
  for (let i = 0; i < WAR_STAKE; i++) {
    const pfd = pd.shift();
    const cfd = cd.shift();
    pfd.face_up = false;
    cfd.face_up = false;
    next.player_pot.push(pfd);
    next.cpu_pot.push(cfd);
  }
  const pDec = pd.shift();
  const cDec = cd.shift();
  pDec.face_up = true;
  cDec.face_up = true;
  next.player_pot.push(pDec);
  next.cpu_pot.push(cDec);
  next.war_depth = next.war_depth + 1;
  const pRank = pDec.rank;
  const cRank = cDec.rank;
  events.push({
    type: "war_decide",
    depth: next.war_depth,
    player: pRank,
    cpu: cRank
  });
  if (pRank > cRank) {
    awardPotsTo(next, "player", events);
    next.pending_special = null;
    next.war_depth = 0;
    return finishRound(next, events);
  } else if (cRank > pRank) {
    awardPotsTo(next, "cpu", events);
    next.pending_special = null;
    next.war_depth = 0;
    return finishRound(next, events);
  } else {
    events.push({ type: "tie", rank: pRank });
    next.phase = PHASE_WAR;
    return makeResult(true, next, events, "");
  }
}
function awardPotsTo(next, winner, events) {
  const winnerDeck = winner === "player" ? next.player_deck : next.cpu_deck;
  let won = 0;
  for (const card of next.player_pot) {
    card.face_up = false;
    winnerDeck.push(card);
    won += 1;
  }
  for (const card of next.cpu_pot) {
    card.face_up = false;
    winnerDeck.push(card);
    won += 1;
  }
  next.player_pot = [];
  next.cpu_pot = [];
  events.push({ type: "award", winner, cards: won });
}
function finishRound(next, events) {
  next.phase = PHASE_DEALT;
  return checkWin(next, events);
}
function checkWin(next, events) {
  const p = next.player_deck.length;
  const c = next.cpu_deck.length;
  if (c === 0 && p > 0) {
    next.phase = PHASE_PLAYER_WIN;
    events.push({ type: "game_over", winner: "player" });
  } else if (p === 0 && c > 0) {
    next.phase = PHASE_CPU_WIN;
    events.push({ type: "game_over", winner: "cpu" });
  }
  return makeResult(true, next, events, "");
}
function topSummary(pot) {
  if (pot.length === 0) {
    return {};
  }
  const top = pot[pot.length - 1];
  return { rank: top.rank, suit: top.suit };
}
function stateHash(state) {
  return hashValue(state);
}

export { DEAL_SIZE, DECK_SIZE, PHASE_CPU_WIN, PHASE_DEALT, PHASE_FLIPPED, PHASE_PLAYER_WIN, PHASE_SELECTED, PHASE_WAR, RANKS, RANK_MAX, RANK_MIN, SPECIAL_CARDS, SPECIAL_CARD_IDS, STATE_VERSION, SUITS, WAR_STAKE, WHEN_POST_FLIP, WHEN_PRE_FLIP, apply, canonicalStringify, hashString, hashValue, ids, isValidId, newGame, newRng, nextBelow, nextU32, resolve, seedFrom, seedToWord, shuffle, stateHash };
//# sourceMappingURL=index.js.map
//# sourceMappingURL=index.js.map