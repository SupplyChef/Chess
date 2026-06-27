# config.jl — Feature flags for the chess engine.
#
# Every search heuristic and evaluation term can be toggled independently.
# The primary use-case is ablation testing: disable one feature, run a
# self-play match against the full-strength engine, and measure the ELO delta.
#
# Usage:
#   cfg = EngineConfig(null_move = false)          # everything on except null move
#   selfplay(DEFAULT_CONFIG, cfg; games=20, time_ms=200)

"""
    EngineConfig

Feature flags for the engine.  All fields default to `true` (full strength).
Create a modified instance with keyword syntax:

    EngineConfig(lmr = false)          # disable LMR only
    EngineConfig(eval_mobility = false) # disable mobility eval only
"""
Base.@kwdef struct EngineConfig
    # ── Search heuristics ──────────────────────────────────────────────────────
    # Each heuristic trades search accuracy for speed (or vice-versa).
    # Disabling one typically costs ELO but also changes node count per move.

    null_move        ::Bool = true
    # Null-move pruning: skip our turn and search at depth−R−1.  If the
    # opponent can't beat beta even with two moves in a row, prune.
    # R=2 at depth 3–5, R=3 at depth ≥6.  Skipped in check and K+P endings.

    aspiration       ::Bool = true
    # Aspiration windows: search with a ±75 cp window around the previous
    # iteration's score instead of a full [−∞, +∞] window.  Saves ~80% of
    # nodes when the score is stable; costs a re-search when it isn't.
    # Starts at depth 5 (earlier depths are too unstable to benefit).

    lmr              ::Bool = true
    # Late-move reductions: after the first 3 moves, search quiet
    # non-checking moves at depth−1 (depth−2 for move index >8).  Re-search
    # at full depth if the reduced search beats alpha.

    futility         ::Bool = true
    # Futility pruning: at depth 1–2, if static eval + 150/300 cp is still
    # below alpha, skip quiet moves (they can't save the position).

    check_extensions ::Bool = true
    # Check extensions: moves that give check are searched 1 ply deeper,
    # ensuring forced mating sequences are found through LMR reductions.

    pvs              ::Bool = true
    # Principal variation search: the first move at each node is searched with
    # the full (α, β) window; every later move gets a cheap null-window scout
    # search (α, α+1) and is only re-searched with the full window if the scout
    # beats α.  With good move ordering the scout almost always fails low,
    # saving most of the work on non-PV moves.

    see              ::Bool = true
    # Static exchange evaluation: resolve the full capture sequence on the
    # target square (with x-rays) to decide whether a capture loses material.
    # Used to (a) order SEE-losing captures after quiet moves and (b) prune
    # them entirely in quiescence search.

    lazy_eval        ::Bool = true
    # Lazy evaluation: when the cheap eval core (material + tapered PST +
    # tempo) is more than LAZY_EVAL_MARGIN outside the (α, β) window, return
    # the core directly instead of computing mobility / king safety / pawn
    # structure.  The remaining terms cannot move the score back inside the
    # window, so the bound-relative search result is unchanged.

    # ── Evaluation terms ───────────────────────────────────────────────────────
    # Each term adds a centipawn bonus/penalty to the static eval.
    # Disabling one shows how much it contributes to play quality.

    eval_mobility    ::Bool = true
    # +2/2/2/1 cp per safe reachable square for N/B/R/Q (own-piece squares excluded).
    # Rewards active pieces; penalises blocked bishops and rooks behind pawns.

    eval_pins        ::Bool = true
    # Bonus (piece_value÷8) for each opponent piece pinned against its king
    # along a file, rank, or diagonal.  Rewards holding a slider on the pin ray.

    eval_pawn_storm  ::Bool = true
    # +6 cp per rank advanced (beyond rank 3) for pawns within 2 files of the
    # enemy king, when kings are on opposite flanks (file distance ≥3).

    eval_space       ::Bool = true
    # +3 cp per safe center square (ranks 4–6, files c–f) our pawns attack
    # but the opponent's pawns do not.

    eval_king_tropism::Bool = true
    # Endgame king activity (scales with 24−phase):
    #   own king → own passers (+4 cp/sq), own king → enemy passers (+2 cp/sq),
    #   enemy king near edge/corner (+6 cp/unit of corner proximity).

    eval_center      ::Bool = true
    # +3 cp per piece (any type) that attacks any of d4/d5/e4/e5.

    eval_rook_passer ::Bool = true
    # Rook behind own passed pawn (+45 cp): the classic battery that makes the
    # pawn nearly unstoppable.  Rook blockading enemy passed pawn (+20 cp):
    # rewards the defender for cutting off the advance.
    # Both bonuses are awarded to the rook owner.

    eval_complexity  ::Bool = true
    # When a side is materially down (≥60 cp) and queens are still on the board,
    # add +20 cp for that side.  The trailing side has more fighting chances with
    # queens than in a simplified endgame, so this discourages queen trades when
    # behind and encourages them when ahead.

    eval_ocb_discount ::Bool = true
    # Opposite-colored bishop discount: when each side has exactly one bishop on
    # opposite square colors and no other pieces (rooks/queens/knights), passed
    # pawn bonuses are halved.  OCB endings are notoriously drawish even with an
    # extra pawn or two because the attacking bishop cannot cover the defender's
    # key blockade squares.

    eval_wrong_bishop ::Bool = true
    # Wrong-color bishop draw: K+B+rook-pawn vs lone K is a theoretical draw when
    # the bishop does not control the promotion square.  We apply a large penalty
    # (-150 cp) to the "winning" side when this condition is detected.

    eval_rook_cutoff  ::Bool = true
    # Rook rank cut-off in K+R+P vs K+R endings: a rook that cuts the enemy king
    # off by rank (placing itself between the king and the promotion zone) wins
    # significant time for the pawn to advance.  Bonus: +30 cp per passed pawn
    # whose enemy king is cut off from the promotion side of the board.

    eval_pawn_majority    ::Bool = true
    # Flank pawn majority: +20 cp base per flank where we outnumber the
    # opponent, plus +5 cp per rank the trailing majority pawn has advanced
    # (rewards keeping the group moving), minus 8 cp per rank of gap beyond 2
    # between the leading and trailing pawn (penalises lone-wolf advances).

    eval_connected_passers ::Bool = true
    # Connected passed pawns bonus: two or more passed pawns on adjacent files
    # support each other and are very difficult to stop.  +25 cp per pawn that
    # has another passer on an adjacent file.

    eval_knight_distance ::Bool = true
    # Knight distance penalty in deep endgames (phase < 10): a knight far from
    # all pawns is nearly useless.  Penalty = min_pawn_distance × (10-phase) ÷ 5
    # centipawns, capped at 20 cp.  Incentivises repositioning the knight.

    # ── New search heuristics ──────────────────────────────────────────────────

    rfp              ::Bool = true
    # Reverse futility pruning (static null move): at depth ≤ 7, if
    # static_eval − 90×depth ≥ beta the position is already too good to
    # bother searching — return the margin-adjusted score immediately.

    lmp              ::Bool = true
    # Late move pruning: at depth ≤ 3, once we have searched more than
    # LMP_QUIET_LIMIT[depth] quiet moves without raising alpha, skip the rest.
    # Positions where many quiet moves all fail low are almost always resolved
    # by the first few moves; additional quiet moves cost time for no gain.

    iir              ::Bool = true
    # Internal iterative reduction: when no hash move is available at depth ≥ 4
    # the move ordering is poor, so reduce depth by 1 to cheaply find a good
    # move for the TT.  The next iteration then starts with a reliable hash move.

    history_malus    ::Bool = true
    # History malus: quiet moves that were searched and failed to raise alpha
    # (i.e. lost material or were simply bad) have their history score penalised
    # by −depth².  This improves move ordering by making the history table
    # reflect not just which moves cause cutoffs but also which moves fail low.

    # ── New evaluation terms ───────────────────────────────────────────────────

    countermove      ::Bool = true
    # Countermove heuristic: record the quiet move that caused a beta cutoff in
    # response to each opponent move.  Score it at 65,000 in move ordering so it
    # is tried just after killers.  Refines ordering when killers don't apply.

    probcut          ::Bool = true
    # Probcut: at depth ≥ 5, run a shallow null-window search on captures with
    # beta+200 as the threshold.  If a capture beats the raised threshold, the
    # position is "too good" and we return immediately without a full search.

    singular_ext     ::Bool = true
    # Singular extensions: when the TT move at depth ≥ 6 is the only good option
    # (all other moves fail below tt_score−2*depth in a reduced search), extend
    # it by 1 ply to explore the forced line more deeply.

    eval_kbnk        ::Bool = true
    # K+B+N vs lone K endgame evaluation: add a mating bonus that guides the
    # winning king to the bishop-coloured corner and penalises the losing king
    # for staying near the centre.  Without this the engine often fails to
    # convert within the 50-move rule.

    eval_mopup       ::Bool = true
    # Mopup evaluation: when one side has an overwhelming material lead and the
    # opponent has a lone king (or near-bare king), add a large bonus for
    # (a) driving the bare king to an edge/corner and (b) bringing our king
    # close.  Activates only when phase < 6 and material advantage > 400 cp.
end

"""The default full-strength configuration (all features enabled)."""
const DEFAULT_CONFIG = EngineConfig()
