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

    # ── Evaluation terms ───────────────────────────────────────────────────────
    # Each term adds a centipawn bonus/penalty to the static eval.
    # Disabling one shows how much it contributes to play quality.

    eval_mobility    ::Bool = true
    # +4/3/2/1 cp per reachable square for N/B/R/Q (own-piece squares excluded).
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
end

"""The default full-strength configuration (all features enabled)."""
const DEFAULT_CONFIG = EngineConfig()
