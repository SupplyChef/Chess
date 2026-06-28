# Alpha-beta search with iterative deepening, quiescence search,
# transposition table, and killer-move ordering.

# ── Constants ─────────────────────────────────────────────────────────────────
const MATE_SCORE = 30_000   # a forced mate scores MATE_SCORE - ply
const MAX_PLY    = 64
const TT_BITS    = 23
const TT_SIZE    = 1 << TT_BITS   # ~8M entries

# TT flag meanings (from the perspective of the side to move at that node):
#   EXACT  — the stored score is the true minimax value (alpha was raised and
#             the search stayed inside the window).
#   LOWER  — score is a lower bound; the node failed high (caused a beta cutoff),
#             so we know the real score is ≥ stored, but not exactly what it is.
#   UPPER  — score is an upper bound; all moves failed to improve alpha,
#             so the real score is ≤ stored.
const TT_EXACT = 0x00
const TT_LOWER = 0x01
const TT_UPPER = 0x02

# ── Transposition table ────────────────────────────────────────────────────────
# The TT maps Zobrist hash → (score, depth, flag, best_move).
# Because the table has ~1M slots and positions are identified by a 64-bit hash,
# we index by hash & (TT_SIZE-1) (fast power-of-2 modulo) and store the full
# hash in the entry to detect collisions from different positions that land on
# the same slot.
struct TTEntry
    key::UInt64
    score::Int32
    depth::Int16
    flag::UInt8
    move::Move
end

const TT_EMPTY = TTEntry(UInt64(0), Int32(0), Int16(-1), TT_EXACT, NULL_MOVE)

@inline function _tt_get(tt::Vector{TTEntry}, hash::UInt64)::TTEntry
    @inbounds tt[(hash & (TT_SIZE - 1)) + 1]
end

# TT replacement policy: replace when the slot is empty or the stored entry is
# from a shallower search (new depth carries more information).  Crucially, a
# same-key entry at greater depth is preserved — a depth-3 re-search must not
# destroy a depth-17 entry that was expensively computed earlier.  Without this
# guard, shallow endgame searches corrupt the deep mating lines in the TT and
# cause the engine to cycle instead of converting a won position.
@inline function _tt_put!(tt::Vector{TTEntry}, hash::UInt64,
                           depth::Int, score::Int, flag::UInt8, move::Move)
    idx = (hash & (TT_SIZE - 1)) + 1
    @inbounds e = tt[idx]
    # Replace if: empty slot, different position (hash collision), or same/shallower
    # depth.  Same-depth replacement is required so aspiration window re-searches
    # (which revisit the same depth with a wider window) can overwrite stale
    # TT_UPPER/LOWER entries from the earlier narrow-window pass.  Only strictly
    # deeper entries (depth > current search depth) are preserved.
    if e.key == 0 || e.key != hash || e.depth <= depth
        @inbounds tt[idx] = TTEntry(hash, Int32(score), Int16(depth), flag, move)
    end
end

# ── Static exchange evaluation ────────────────────────────────────────────────
# _see_ge(b, m, threshold) answers: "does the capture sequence started by m win
# at least `threshold` centipawns for the side to move?"  It resolves the full
# exchange on the target square with the classic swap algorithm: both sides
# keep recapturing with their least valuable attacker (x-ray attackers behind
# the piece that just captured are added as the occupancy shrinks) and each
# side may stop as soon as continuing would lose material.
#
# `swap` tracks the running balance handed to the side about to move; `res`
# flips each time the side to move changes and holds the answer for the side
# that played m if the sequence stopped right now.  A king may recapture only
# when the opponent has no attacker left (otherwise the "recapture" is illegal
# and the result flips back).
#
# Promotions and castles are not handled (callers exclude them); quiet moves
# work (victim value 0) but the main use is captures.
function _see_ge(b::Board, m::Move, threshold::Int)::Bool
    fl = flags(m)
    fr = from_sq(m)
    t  = to_sq(m)

    victim_v = fl == MF_EP ? PIECE_VALUE[Int(Pawn)+1] :
                             @inbounds PIECE_VALUE[Int(b.piece_on[t+1].kind)+1]
    # Best case: we win the victim and nothing recaptures.
    swap = victim_v - threshold
    swap < 0 && return false
    # Worst case: we lose the mover right back.  If that still meets the
    # threshold, no need to look at the board at all.
    swap = @inbounds PIECE_VALUE[Int(b.piece_on[fr+1].kind)+1] - swap
    swap <= 0 && return true

    occupied = all_occ(b) ⊻ sq_bb(fr) ⊻ sq_bb(t)
    if fl == MF_EP
        occupied ⊻= sq_bb(t + (b.side == White ? -8 : 8))
    end

    diag_sliders = bb(b, White, Bishop) | bb(b, Black, Bishop) |
                   bb(b, White, Queen)  | bb(b, Black, Queen)
    orth_sliders = bb(b, White, Rook)   | bb(b, Black, Rook)   |
                   bb(b, White, Queen)  | bb(b, Black, Queen)

    attackers = attackers_to(b, t, occupied)
    stm       = b.side
    res       = true

    while true
        stm = other(stm)
        attackers &= occupied
        stm_attackers = attackers & b.occ[Int(stm)+1]
        stm_attackers == 0 && break
        res = !res

        # Capture with the least valuable attacker.  After removing it from
        # the occupancy, sliders that were lined up behind it join the battle.
        if (pcs = stm_attackers & bb(b, stm, Pawn)) != 0
            (swap = PIECE_VALUE[Int(Pawn)+1] - swap) < Int(res) && break
            occupied ⊻= sq_bb(lsb(pcs))
            attackers |= bishop_attacks(t, occupied) & diag_sliders
        elseif (pcs = stm_attackers & bb(b, stm, Knight)) != 0
            (swap = PIECE_VALUE[Int(Knight)+1] - swap) < Int(res) && break
            occupied ⊻= sq_bb(lsb(pcs))
        elseif (pcs = stm_attackers & bb(b, stm, Bishop)) != 0
            (swap = PIECE_VALUE[Int(Bishop)+1] - swap) < Int(res) && break
            occupied ⊻= sq_bb(lsb(pcs))
            attackers |= bishop_attacks(t, occupied) & diag_sliders
        elseif (pcs = stm_attackers & bb(b, stm, Rook)) != 0
            (swap = PIECE_VALUE[Int(Rook)+1] - swap) < Int(res) && break
            occupied ⊻= sq_bb(lsb(pcs))
            attackers |= rook_attacks(t, occupied) & orth_sliders
        elseif (pcs = stm_attackers & bb(b, stm, Queen)) != 0
            (swap = PIECE_VALUE[Int(Queen)+1] - swap) < Int(res) && break
            occupied ⊻= sq_bb(lsb(pcs))
            attackers |= (bishop_attacks(t, occupied) & diag_sliders) |
                         (rook_attacks(t, occupied)   & orth_sliders)
        else  # king: legal only if the opponent has no attackers left
            return (attackers & occupied & ~b.occ[Int(stm)+1]) != 0 ? !res : res
        end
    end
    res
end

# ── Move ordering ──────────────────────────────────────────────────────────────
# Good move ordering is the single biggest practical speedup for alpha-beta:
# searching the best moves first causes beta cutoffs earlier, pruning more of
# the tree.  Priority order:
#   1. Hash move (best move from a previous TT entry) — already known to be good.
#   2. Captures, ordered by MVV-LVA (see below).
#   3. Queen promotions.
#   4. Killer moves (quiet moves that caused beta cutoffs at this ply before).
#   5. All other quiet moves (score 0, searched in generation order).

# MVV-LVA (Most Valuable Victim – Least Valuable Aggressor):
# Captures are scored by victim value first (high = better) and aggressor value
# second (low = better).  Capturing a queen with a pawn scores highest; capturing
# a pawn with a queen scores lowest among captures.  This heuristic approximates
# Static Exchange Evaluation cheaply: high-value captures are very likely to be
# good moves and should be searched first.
const _MVV = (0, 1, 2, 2, 4, 8, 0)  # NoPiece P N B R Q K

@inline function _move_score(m::Move, b::Board, hash_move::Move,
                              killers::Matrix{Move}, history::Matrix{Int32},
                              countermoves::Matrix{Move}, prev_move::Move,
                              ply::Int, cfg::EngineConfig)::Int
    m == hash_move && return 1_000_000

    fl = flags(m)
    if (fl & MF_CAPTURE) != 0 || fl == MF_EP
        victim  = fl == MF_EP ? Pawn : @inbounds b.piece_on[to_sq(m)+1].kind
        aggr    = @inbounds b.piece_on[from_sq(m)+1].kind
        # Victim weight dominates (×10) so any more-valuable capture outranks
        # any less-valuable capture regardless of the aggressor.
        mvv_lva = _MVV[Int(victim)+1] * 10 - _MVV[Int(aggr)+1]
        # SEE gate: captures of a more valuable piece can never lose material,
        # so the exchange is only resolved when the aggressor outvalues the
        # victim (promo-captures are exempt: the aggressor is always a pawn).
        # Losing captures sort below every quiet move — they are almost always
        # refuted, so searching quiets first finds cutoffs sooner.
        if cfg.see && (fl & MF_PROMO) == 0 &&
           PIECE_VALUE[Int(aggr)+1] > PIECE_VALUE[Int(victim)+1] &&
           !_see_ge(b, m, 0)
            return -100_000 + mvv_lva
        end
        return 100_000 + mvv_lva
    end

    (fl & MF_PROMO) != 0 && return 90_000

    # Killer moves: quiet moves that caused a beta cutoff at this ply in a
    # sibling node.  They are likely good here too because they don't depend on
    # the specific position — a knight fork that refuted one move often refutes
    # others on the same ply.  We store two killers per ply (slot 1 = most recent).
    if 1 <= ply <= MAX_PLY
        @inbounds killers[1, ply] == m && return 80_000
        @inbounds killers[2, ply] == m && return 70_000
    end

    # Countermove: quiet move that best refuted the opponent's previous move.
    # Ordered just below killers — it's move-specific rather than ply-specific.
    if cfg.countermove && prev_move != NULL_MOVE
        fs_p = from_sq(prev_move); ts_p = to_sq(prev_move)
        @inbounds countermoves[fs_p+1, ts_p+1] == m && return 65_000
    end

    # History heuristic: quiet moves that previously caused cutoffs score
    # between 1 and 60_000 — above generic quiet moves but below killers.
    fs = from_sq(m); ts = to_sq(m)
    @inbounds h = Int(history[fs+1, ts+1])
    h > 0 && return min(h, 60_000)

    0
end

# Fill ml.scores with move ordering scores (parallel to ml.moves).
@inline function _score_moves!(ml::MoveList, b::Board, hash_move::Move,
                               killers::Matrix{Move}, history::Matrix{Int32},
                               countermoves::Matrix{Move}, prev_move::Move,
                               ply::Int, cfg::EngineConfig, start_idx::Int=1)
    @inbounds for i in start_idx:length(ml)
        ml.scores[i] = _move_score(ml[i], b, hash_move, killers, history,
                                   countermoves, prev_move, ply, cfg)
    end
end

# Partial selection sort: find the highest-scored move in [idx..n] and swap it
# to position idx.  We sort lazily — only one move per iteration — because a
# beta cutoff may happen on the first or second move, making the rest of the
# sort wasted work.
@inline function _pick_move!(ml::MoveList, idx::Int)::Move
    best_i = idx
    @inbounds best_s = ml.scores[idx]
    @inbounds for i in idx+1:length(ml)
        if ml.scores[i] > best_s
            best_s = ml.scores[i]
            best_i = i
        end
    end
    if best_i != idx
        @inbounds ml.moves[idx],  ml.moves[best_i]  = ml.moves[best_i],  ml.moves[idx]
        @inbounds ml.scores[idx], ml.scores[best_i] = ml.scores[best_i], ml.scores[idx]
    end
    @inbounds ml.moves[idx]
end

# Update the killer table: the most-recent killer bumps the older one out.
# We keep two slots so that two different killers can be remembered simultaneously,
# increasing the chance of an early cutoff when both are tried.
function _update_killers!(killers::Matrix{Move}, ply::Int, m::Move)
    1 <= ply <= MAX_PLY || return
    killers[1, ply] == m && return
    killers[2, ply] = killers[1, ply]
    killers[1, ply] = m
end

# Update the history table when a quiet move causes a beta cutoff.
# The depth² bonus rewards deep cutoffs more: a move that refutes at depth 6
# is far stronger evidence of goodness than one that refutes at depth 1.
# Values are capped at 10_000 to prevent Int32 overflow after many searches.
@inline function _update_history!(history::Matrix{Int32}, m::Move, depth::Int)
    fs = from_sq(m); ts = to_sq(m)
    @inbounds history[fs+1, ts+1] = min(history[fs+1, ts+1] + Int32(depth * depth), Int32(10_000))
end

# History malus: penalise quiet moves that failed to raise alpha.  The penalty
# mirrors the bonus applied to the move that caused the cutoff, so repeatedly
# bad moves sink in the ordering and are tried last or skipped by LMP.
@inline function _update_history_malus!(history::Matrix{Int32}, m::Move, depth::Int)
    fs = from_sq(m); ts = to_sq(m)
    @inbounds history[fs+1, ts+1] = max(history[fs+1, ts+1] - Int32(depth * depth), Int32(-10_000))
end

# Countermove heuristic: record the quiet move that best refuted a specific
# opponent move.  Indexed by the opponent's (from, to) square pair.
@inline function _update_countermove!(cm::Matrix{Move}, prev_move::Move, m::Move)
    prev_move == NULL_MOVE && return
    fs = from_sq(prev_move); ts = to_sq(prev_move)
    @inbounds cm[fs+1, ts+1] = m
end

# ── Search state ──────────────────────────────────────────────────────────────
const MOVE_STACK_SIZE   = MAX_PLY + 64   # regular depth + qsearch budget
const TRICKINESS_WEIGHT = 0.05           # conservative weight; tune up if play feels too timid
const ASPIRATION_DELTA  = 75             # initial aspiration window half-width (centipawns)

# Futility margins (centipawns) indexed by depth.  At depth d, if static eval
# plus this margin is still below alpha, quiet moves cannot improve the position
# and are skipped.  Roughly: 1 pawn at depth 1, 2 pawns at depth 2.
const FUTILITY_MARGIN = (0, 150, 300)

# Pre-computed LMR reduction table: LMR_TABLE[depth, move_index] avoids calling
# log() on every search node.  Capped at 62; actual cap to depth-2 applied inline.
const LMR_TABLE = [clamp(1 + floor(Int, log(max(1,d)) * log(max(1,i)) / 2.5), 0, 62)
                   for d in 1:64, i in 1:256]

# Reverse futility pruning: if static_eval − RFP_MARGIN×depth ≥ beta the node
# is already winning enough that searching it further cannot change the outcome.
const RFP_MARGIN = 90   # centipawns per depth level

# Late move pruning: maximum quiet moves to search at depth 1–3 before giving
# up on the rest.  Positions that are not resolved by the first N quiet moves
# are almost never resolved by later ones at these shallow depths.
# Indexed by depth directly (depth 1 → 6, depth 2 → 12, depth 3 → 18).
const LMP_QUIET_LIMIT = (6, 12, 18)   # depth 1, 2, 3

# Delta pruning margin for quiescence search (centipawns).  A capture whose
# maximum material gain (captured piece value) plus this margin still falls
# below alpha is futile and can be skipped without searching it.
const DELTA_MARGIN = 200

mutable struct SearchInfo
    tt          ::Vector{TTEntry}
    killers     ::Matrix{Move}
    # History heuristic: records how often each (from→to) quiet move caused a beta
    # cutoff, weighted by depth².  High-history moves get tried before low-history
    # ones, improving move ordering beyond what killers alone can achieve.
    # Indexed [from_sq+1, to_sq+1]; values capped at 10_000 to prevent overflow.
    history     ::Matrix{Int32}
    # Countermove heuristic: records the best quiet refutation of each opponent
    # move, indexed by [from_sq+1, to_sq+1] of that opponent move.  Provides a
    # third ordering tier between killers and history.
    countermoves::Matrix{Move}
    move_stack  ::Vector{MoveList}        # pre-allocated, one per ply
    root_moves  ::Vector{Tuple{Int,Move}} # (score, move) from last complete iteration
    nodes       ::Int64
    stop        ::Bool
    time_start  ::Float64
    time_limit  ::Float64
    # Draw detection state:
    #   path         — Zobrist hashes on the current search path (root → parent).
    #                  Maintained via _path_push!/_path_pop! which keep path_counts
    #                  in sync; do not push/pop si.path directly.
    #   path_counts  — hash → count map for O(1) repetition detection; mirrors path.
    #   prior_counts — position counts from the GAME before the search started,
    #                  supplied by the caller (play_lichess tracks these).  A
    #                  position with count 2 is already in its second occurrence;
    #                  one more repeat makes it a draw.
    path         ::Vector{UInt64}
    path_counts  ::Dict{UInt64,Int}
    prior_counts ::Dict{UInt64,Int}
    config       ::EngineConfig
    # Cached count of how many times the root position appeared in the game
    # before this search.  A Dict lookup on si.prior_counts is O(1) but still
    # measurable at ~1M nodes/s; caching it here avoids the lookup on the hot
    # repetition path inside _negamax.
    root_prior_count::Int
    # ── Diagnostic counters (reset each search_move call) ─────────────────────
    # beta_cutoffs / first_move_cutoffs — track move ordering quality.
    #   first_move_cutoffs / beta_cutoffs should be 85–90% for well-ordered search.
    # tt_probes / tt_hits / tt_cutoffs — track transposition table effectiveness.
    # tb_hits — positions answered by the Syzygy endgame tablebase this search.
    beta_cutoffs       ::Int64
    first_move_cutoffs ::Int64
    tt_probes          ::Int64
    tt_hits            ::Int64
    tt_cutoffs         ::Int64
    tb_hits            ::Int64
end

function SearchInfo(cfg::EngineConfig = DEFAULT_CONFIG)
    SearchInfo(
        fill(TT_EMPTY, TT_SIZE),
        fill(NULL_MOVE, 2, MAX_PLY),
        zeros(Int32, 64, 64),
        fill(NULL_MOVE, 64, 64),
        [MoveList() for _ in 1:MOVE_STACK_SIZE],
        Tuple{Int,Move}[],
        Int64(0),
        false,
        0.0,
        0.0,
        UInt64[],
        Dict{UInt64,Int}(),
        Dict{UInt64,Int}(),
        cfg,
        0,
        Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0),
    )
end

# ── Path stack helpers ────────────────────────────────────────────────────────
# path_counts mirrors the path vector as a hash→count map so the repetition
# check in _negamax is O(1) rather than an O(depth) linear scan.
@inline function _path_push!(si::SearchInfo, hash::UInt64)
    push!(si.path, hash)
    si.path_counts[hash] = get(si.path_counts, hash, 0) + 1
end

@inline function _path_pop!(si::SearchInfo)
    h = pop!(si.path)
    cnt = si.path_counts[h] - 1
    if cnt == 0
        delete!(si.path_counts, h)
    else
        si.path_counts[h] = cnt
    end
end

# ── Engine banner ─────────────────────────────────────────────────────────────
"""
    print_engine_banner(si)

Print a one-time summary of the engine configuration: TT size, Syzygy table
coverage, and which search/eval features are currently enabled.  Call once at
the start of each game so the log shows the exact setup used.
"""
function print_engine_banner(si::SearchInfo = SearchInfo())
    cfg   = si.config
    bar   = "─" ^ 62
    println(bar)
    println("Chess Engine")

    # Transposition table
    tt_mb = TT_SIZE * sizeof(TTEntry) ÷ (1024 * 1024)
    @printf("  TT      %dM entries · %d MB\n", TT_SIZE ÷ 1_000_000, tt_mb)

    # Syzygy tables
    if _INITIALIZED[]
        n = length(unique(t -> objectid(t), values(_TABLES)))
        @printf("  Syzygy  %d WDL tables loaded · covers ≤%d pieces\n", n, TB_LARGEST[])
    else
        println("  Syzygy  not loaded  " *
                "(place .rtbw files in Chess/syzygy/ or set SYZYGY_PATH)")
    end

    # Search features (show OFF ones so on is the obvious default)
    search_flags = [("null_move", cfg.null_move), ("aspiration", cfg.aspiration),
                    ("lmr", cfg.lmr), ("pvs", cfg.pvs), ("see", cfg.see),
                    ("rfp", cfg.rfp), ("lmp", cfg.lmp), ("iir", cfg.iir),
                    ("singular_ext", cfg.singular_ext), ("probcut", cfg.probcut),
                    ("syzygy", cfg.syzygy)]
    off = [n for (n, v) in search_flags if !v]
    if isempty(off)
        println("  Search  all heuristics ON")
    else
        println("  Search  OFF: ", join(off, "  "))
    end

    eval_flags = [("mobility", cfg.eval_mobility), ("pins", cfg.eval_pins),
                  ("pawn_storm", cfg.eval_pawn_storm), ("space", cfg.eval_space),
                  ("king_tropism", cfg.eval_king_tropism), ("center", cfg.eval_center),
                  ("rook_passer", cfg.eval_rook_passer), ("complexity", cfg.eval_complexity),
                  ("ocb_discount", cfg.eval_ocb_discount), ("wrong_bishop", cfg.eval_wrong_bishop),
                  ("rook_cutoff", cfg.eval_rook_cutoff), ("pawn_majority", cfg.eval_pawn_majority),
                  ("conn_passers", cfg.eval_connected_passers), ("kn_distance", cfg.eval_knight_distance),
                  ("kbnk", cfg.eval_kbnk), ("mopup", cfg.eval_mopup)]
    off_eval = [n for (n, v) in eval_flags if !v]
    if isempty(off_eval)
        println("  Eval    all terms ON")
    else
        println("  Eval    OFF: ", join(off_eval, "  "))
    end

    println(bar)
end

# ── Result ────────────────────────────────────────────────────────────────────
struct SearchResult
    move ::Move
    score::Int            # from the side-to-move perspective, centipawns
    depth::Int            # depth of completed iteration
    nodes::Int64
    eval ::EvalBreakdown  # static eval of the root position
    pv   ::Vector{Move}   # principal variation extracted from TT
end

# Walk the TT from the root to extract the principal variation.
# Each EXACT entry records the best move at that node; we follow the chain
# until we reach a position not in the TT or a repeat (loop guard).
# b is mutated during traversal but fully restored before returning.
function _extract_pv(b::Board, tt::Vector{TTEntry}, root_move::Move, max_len::Int)::Vector{Move}
    pv    = Move[]
    undos = UndoInfo[]
    seen  = Set{UInt64}()
    m     = root_move
    while m != NULL_MOVE && length(pv) < max_len
        b.hash in seen && break
        push!(seen, b.hash)
        push!(pv, m)
        push!(undos, make_move!(b, m))
        tte = _tt_get(tt, b.hash)
        # Follow EXACT and LOWER entries: both record the best move found at that node.
        # UPPER entries (all moves failed low) have no reliable best move, so stop there.
        m   = (tte.key == b.hash && tte.flag != TT_UPPER) ? tte.move : NULL_MOVE
    end
    for i in length(pv):-1:1
        unmake_move!(b, pv[i], undos[i])
    end
    pv
end

# ── Quiescence search ─────────────────────────────────────────────────────────
# Alpha-beta at depth 0 hands off to quiescence rather than calling the static
# evaluator directly.  Without this, the engine would miss obvious captures
# immediately after the horizon and assign wildly wrong scores to positions where
# a piece has just been sacrificed.
#
# Stand-pat: before searching any capture we evaluate the position statically.
# This score is a lower bound on what the side to move can achieve — they can
# always "stand pat" and decline all captures.  If stand_pat >= beta we prune
# immediately (the opponent already had a better alternative earlier).
# If stand_pat > alpha we raise alpha ( we found a quiet baseline that beats the
# previous best).  Searching captures then looks for something better.
#
# When in check we cannot stand pat (the king may be lost) and must consider
# all evasions, not just captures.
function _quiesce(b::Board, alpha::Int, beta::Int, ply::Int, si::SearchInfo)::Int
    si.nodes += 1
    if (si.nodes & 0x3FF) == 0 && time() >= si.time_limit
        si.stop = true
        return 0
    end
    si.stop && return 0
    ply >= MAX_PLY - 1 && return evaluate_lazy(b, si.config, alpha, beta)

    # A capture might reduce material to a theoretically drawn endgame.
    _is_insufficient_material(b) && return 0

    # TT Probe
    tte = _tt_get(si.tt, b.hash)
    si.tt_probes += 1
    if tte.key == b.hash
        si.tt_hits += 1
        sc = Int(tte.score)
        if sc > MATE_SCORE - MOVE_STACK_SIZE
            sc -= ply
        elseif sc < -(MATE_SCORE - MOVE_STACK_SIZE)
            sc += ply
        end
        if tte.flag == TT_EXACT
            si.tt_cutoffs += 1
            return sc
        elseif tte.flag == TT_LOWER
            alpha = max(alpha, sc)
        else
            beta = min(beta, sc)
        end
        if alpha >= beta
            si.tt_cutoffs += 1
            return sc
        end
    end

    in_check = king_in_check(b, b.side)

    orig_alpha = alpha
    if !in_check
        stand_pat = evaluate_lazy(b, si.config, alpha, beta)
        stand_pat >= beta && return stand_pat
        alpha = max(alpha, stand_pat)
    end

    ml = si.move_stack[min(ply, MOVE_STACK_SIZE)]
    in_check ? generate_moves!(ml, b) : generate_captures!(ml, b)

    # No captures/promos available and not in check: this is a quiet position,
    # return alpha (= stand_pat).  In check with no evasions: checkmate.
    length(ml) == 0 && return in_check ? -(MATE_SCORE - ply) : alpha

    _score_moves!(ml, b, NULL_MOVE, si.killers, si.history, si.countermoves, NULL_MOVE, ply, si.config, 1)

    best      = in_check ? -(MATE_SCORE - ply) : alpha
    best_move = NULL_MOVE
    for i in 1:length(ml)
        m = _pick_move!(ml, i)

        # SEE pruning: a qsearch move list holds only captures and promotions,
        # and _move_score gives SEE-losing captures a negative score.  Picks
        # are in descending score order, so once a losing capture surfaces,
        # everything that remains loses material too — stop searching.
        # Not applied in check (the list holds evasions, all must be tried).
        !in_check && @inbounds(ml.scores[i]) < 0 && break

        # Delta pruning: skip captures that can't raise alpha even in the best case.
        # Guard: only when not in check (stand_pat is defined) and not a promotion
        # (the queen upgrade adds ~800 cp that isn't reflected in the captured piece value).
        if !in_check && !is_promo(m)
            fl_m     = flags(m)
            cap_kind = fl_m == MF_EP ? Pawn : @inbounds b.piece_on[to_sq(m)+1].kind
            @inbounds PIECE_VALUE[Int(cap_kind)+1] + stand_pat + DELTA_MARGIN <= alpha && continue
        end

        undo  = make_move!(b, m)
        score = -_quiesce(b, -beta, -alpha, ply + 1, si)
        unmake_move!(b, m, undo)

        si.stop && break

        if score > best
            best      = score
            best_move = m
        end
        score > alpha && (alpha = score)
        alpha >= beta && break
    end

    # Record the best capture in the TT so _extract_pv can extend the PV
    # through qsearch moves (e.g. show the recapture after a winning capture).
    # Only written when a move actually improved over the initial bound; without
    # this, the PV stops at the last negamax move (a capture) and the material
    # swing calculation overcounts, falsely claiming a piece was won.
    if !si.stop && best_move != NULL_MOVE
        store_score = best
        if best >= MATE_SCORE - MOVE_STACK_SIZE
            store_score = best + ply
        elseif best <= -(MATE_SCORE - MOVE_STACK_SIZE)
            store_score = best - ply
        end
        flag = best >= beta      ? TT_LOWER :
               best > orig_alpha ? TT_EXACT : TT_UPPER
        _tt_put!(si.tt, b.hash, 0, store_score, flag, best_move)
    end

    best
end

# ── Alpha-beta negamax ────────────────────────────────────────────────────────
# Negamax is a clean formulation of minimax where every node maximises its own
# score.  The trick: the score returned by a child node is negated before
# comparison, and the window is flipped (−beta, −alpha) when passed down.
# This works because the child's "best score for me" is the parent's
# "worst score for me" — negation converts between the two perspectives.
#
# Alpha = lower bound: the current player is guaranteed at least this much.
# Beta  = upper bound: the opponent won't allow us to do better than this
#         (they have a refutation elsewhere in the tree).
# A beta cutoff occurs when we find a move that scores >= beta — the opponent
# won't reach this node because they have something better, so we stop searching.
# Singular extension helper: search all moves except `excl_move` to cheaply
# determine whether the hash move is the only good option at this node.
function _negamax_excl(b::Board, depth::Int, alpha::Int, beta::Int,
                       ply::Int, si::SearchInfo, excl_move::Move)::Int
    ml = si.move_stack[min(ply, MOVE_STACK_SIZE)]
    generate_moves!(ml, b)
    best = -(MATE_SCORE + 1)
    for i in 1:length(ml)
        m = ml.moves[i]
        m == excl_move && continue
        _path_push!(si, b.hash)
        undo  = make_move!(b, m)
        score = -_negamax(b, depth - 1, -beta, -alpha, ply + 1, si, false, m)
        unmake_move!(b, m, undo)
        _path_pop!(si)
        si.stop && return 0
        score >= beta && return score
        best = max(best, score)
    end
    best
end

function _negamax(b::Board, depth::Int, alpha::Int, beta::Int,
                  ply::Int, si::SearchInfo, is_null::Bool,
                  prev_move::Move = NULL_MOVE)::Int
    # Periodic time check (every 1024 nodes to keep overhead low).
    si.nodes += 1
    if (si.nodes & 0x3FF) == 0 && time() >= si.time_limit
        si.stop = true
        return 0
    end
    si.stop && return 0

    # ── Draw detection ────────────────────────────────────────────────────────
    # Check these before the TT so a stale non-zero TT entry can't override a draw.

    # 50-move rule: 100 half-moves (plies) without a pawn push or capture.
    b.halfmove >= 100 && return 0

    # Insufficient material: neither side can force checkmate.
    _is_insufficient_material(b) && return 0

    # Repetition detection: sum occurrences in the game (prior_counts) and on the
    # current search path (path_counts — O(1) Dict lookup).  reps >= 2 means this
    # position has been seen at least twice before; one more visit creates a 3-fold
    # repetition draw, so return 0.  We require >= 2 (not >= 1) so the engine
    # cannot manufacture a fake draw by replaying its own last move: prior_counts=1
    # means the position was seen once in the game, but the opponent has no obligation
    # to repeat — only claim draw on the genuine third occurrence.
    # prior_counts is reset after every irreversible move so only genuinely
    # repeatable positions are counted.
    let reps = get(si.prior_counts, b.hash, 0) + get(si.path_counts, b.hash, 0)
        reps >= 2 && return 0
    end

    # TT probe: if we have previously searched this position at sufficient depth,
    # we can reuse the stored result.  "Sufficient depth" means tte.depth >= depth:
    # a stored result from a depth-3 search is not reliable when we need depth-5.
    # The flag tells us whether the stored score is exact, a lower bound, or an
    # upper bound, and we narrow (or cut) the window accordingly.
    tte       = _tt_get(si.tt, b.hash)
    hash_move = NULL_MOVE
    si.tt_probes += 1
    if tte.key == b.hash
        hash_move = tte.move
        si.tt_hits += 1
        # Don't allow TT cutoffs for positions already seen in the game (prior_counts > 0).
        # A TT entry stored before this position entered a repetition cycle would mask
        # the draw: the search would short-circuit before traversing the 3-4 move loop
        # that returns to a position with reps >= 2.  We still use tte.move for ordering.
        if tte.depth >= depth && get(si.prior_counts, b.hash, 0) == 0
            sc = Int(tte.score)
            # Ply-normalize mate scores: stored value is relative to the node that
            # stored it; convert to relative to the current node by undoing the
            # storage adjustment (subtract ply when storing, add back when retrieving
            # — and vice-versa for the losing side).
            # Threshold: MATE_SCORE - MOVE_STACK_SIZE covers the deepest reachable ply
            # (including quiescence), ensuring all mate-distance values are caught.
            if sc > MATE_SCORE - MOVE_STACK_SIZE
                sc -= ply
            elseif sc < -(MATE_SCORE - MOVE_STACK_SIZE)
                sc += ply
            end
            if tte.flag == TT_EXACT
                si.tt_cutoffs += 1
                return sc
            elseif tte.flag == TT_LOWER
                alpha = max(alpha, sc)
            else
                beta = min(beta, sc)
            end
            if alpha >= beta
                si.tt_cutoffs += 1
                return sc
            end
        end
    end

    # ── Tablebase probe ────────────────────────────────────────────────────────
    # If Syzygy tables are loaded and this is a ≤N-piece position with no
    # castling rights, the WDL result is exact — no need to search further.
    # Probe after the TT (cheaper) but before generating moves (expensive).
    if si.config.syzygy && _INITIALIZED[] && b.castling == 0x0
        n_pc = count_bits(all_occ(b))
        if n_pc <= TB_LARGEST[]
            wdl = syzygy_probe_wdl(b)
            if wdl !== nothing
                si.tb_hits += 1
                tb_score = wdl == WDL_WIN          ?  (MATE_SCORE - ply) :
                           wdl == WDL_LOSS         ? -(MATE_SCORE - ply) :
                           wdl == WDL_CURSED_WIN   ?  1 :
                           wdl == WDL_BLESSED_LOSS ? -1 : 0
                flag = tb_score >= beta  ? TT_LOWER :
                       tb_score <= alpha ? TT_UPPER : TT_EXACT
                _tt_put!(si.tt, b.hash, depth, tb_score, flag, NULL_MOVE)
                return tb_score
            end
        end
    end

    # At horizon: drop into quiescence search rather than returning the static
    # eval, to avoid the "horizon effect" of missing captures on the next move.
    depth <= 0 && return _quiesce(b, alpha, beta, ply, si)

    in_check = king_in_check(b, b.side)

    cfg = si.config

    # ── Static evaluation (shared by RFP, futility, and IIR) ─────────────────
    # Compute once and reuse across all pruning tests that follow.  The lazy
    # shortcut means this is cheap whenever the score is far outside the window.
    static_eval = !in_check && depth <= 12 ?
        evaluate_lazy(b, cfg, alpha, beta) : -(MATE_SCORE + 1)

    # ── Reverse futility pruning (static null move) ───────────────────────────
    # If our position is already so good that even after subtracting a generous
    # per-depth margin we still exceed beta, the opponent won't allow this node.
    # Guarded by: not in check (score unreliable), not a null-move child (avoid
    # double-pruning), and the side must have non-pawn material (zugzwang risk).
    if cfg.rfp && !is_null && !in_check && depth >= 1 && depth <= 7 &&
       static_eval != -(MATE_SCORE + 1) &&
       (bb(b, b.side, Knight) | bb(b, b.side, Bishop) |
        bb(b, b.side, Rook)   | bb(b, b.side, Queen)) != BB(0)
        rfp_score = static_eval - RFP_MARGIN * depth
        rfp_score >= beta && return rfp_score
    end

    # ── Null move pruning ─────────────────────────────────────────────────────
    # If we're not in check and we have non-pawn material, try passing our turn.
    # If even then the opponent can't beat beta, the position is good enough to
    # prune: a real move can only do better.  The "zugzwang guard" (non-pawn
    # material check) avoids false pruning in K+P endgames where passing really
    # is catastrophic.
    #
    # We use a null-window around beta (–β, –β+1) and a reduced depth R so
    # the null search is very fast.  R = 3 at depth ≥ 5, R = 2 otherwise.
    if cfg.null_move && !is_null && !in_check && depth >= 3 &&
       (bb(b, b.side, Knight) | bb(b, b.side, Bishop) |
        bb(b, b.side, Rook)   | bb(b, b.side, Queen)) != BB(0)
        R       = depth >= 5 ? 3 : 2
        ep_save = b.ep_square
        _path_push!(si, b.hash)          # record current hash before passing the turn
        b.side  = other(b.side)
        b.hash ⊻= ZOBRIST_SIDE[]
        if ep_save != -1
            b.hash     ⊻= zob_ep(ep_save)
            b.ep_square = -1
        end
        null_score = -_negamax(b, depth - R - 1, -beta, -beta + 1, ply + 1, si, true, NULL_MOVE)
        b.side = other(b.side)
        b.hash ⊻= ZOBRIST_SIDE[]
        if ep_save != -1
            b.ep_square = ep_save
            b.hash     ⊻= zob_ep(ep_save)
        end
        _path_pop!(si)
        !si.stop && null_score >= beta && return beta
    end

    # ── Probcut ───────────────────────────────────────────────────────────────
    # At high depth, if a capture appears so strong that even a shallow search
    # with a raised beta confirms it exceeds beta by a large margin, we can
    # safely prune and return immediately.  This skips expensive subtrees where
    # a clearly winning capture would cause a cutoff anyway.
    if cfg.probcut && !is_null && !in_check && depth >= 5 &&
       abs(beta) < MATE_SCORE - MOVE_STACK_SIZE
        pc_beta  = beta + 200
        pc_depth = depth - 4
        ml_pc    = si.move_stack[min(ply, MOVE_STACK_SIZE)]
        generate_captures!(ml_pc, b)
        for k in 1:length(ml_pc)
            mc  = ml_pc.moves[k]
            _path_push!(si, b.hash)
            undo_pc = make_move!(b, mc)
            pc_score = -_negamax(b, pc_depth, -pc_beta, -pc_beta + 1, ply + 1, si, false, mc)
            unmake_move!(b, mc, undo_pc)
            _path_pop!(si)
            si.stop && break
            pc_score >= pc_beta && return pc_score
        end
    end

    # ── Internal iterative reduction ──────────────────────────────────────────
    # When there is no hash move the move ordering is poor — we're searching
    # blindly.  Reduce depth by 1 so this node is cheap; the TT entry it writes
    # will be used as a hash move when we re-search at the full depth in the
    # next iteration of iterative deepening.
    if cfg.iir && hash_move == NULL_MOVE && depth >= 4 && !in_check
        depth -= 1
    end

    # ── Futility pruning ──────────────────────────────────────────────────────
    # At depth 1 and 2, if static eval + a margin (1–2 pawns) is still below
    # alpha, quiet moves are unlikely to improve alpha — prune them.
    # Captures and promotions bypass this check: they can swing material
    # dramatically and must always be searched.
    #
    # Cache static_eval here so futility-pruned moves can raise the best_score
    # floor to at least this value, preventing the -(MATE_SCORE+1) sentinel
    # from being stored in TT (which causes scores > MATE_SCORE after ply
    # normalization if the sentinel is later retrieved and negated by a parent).
    futility_ok = static_eval > -(MATE_SCORE + 1) && !in_check && depth <= 2 &&
        static_eval + FUTILITY_MARGIN[depth + 1] < alpha

    # ── Singular extension (pre-computed before generate_moves!) ─────────────
    # Must run BEFORE generate_moves! fills si.move_stack[ply], because
    # _negamax_excl also uses si.move_stack[ply] internally and would overwrite it.
    sing_ext = 0
    if cfg.singular_ext && hash_move != NULL_MOVE && depth >= 6 && ply > 0 &&
       tte.key == b.hash && tte.flag == TT_LOWER &&
       tte.depth >= depth - 3 && abs(tte.score) < MATE_SCORE - MOVE_STACK_SIZE
        sing_beta  = tte.score - 2 * depth
        sing_score = _negamax_excl(b, depth ÷ 2, sing_beta - 1, sing_beta, ply, si, hash_move)
        !si.stop && sing_score < sing_beta && ply < MAX_PLY && (sing_ext = 1)
    end

    ml = si.move_stack[min(ply, MOVE_STACK_SIZE)]
    generate_moves!(ml, b)

    # No legal moves: checkmate (king in check) or stalemate (not in check).
    if length(ml) == 0
        return in_check ? -(MATE_SCORE - ply) : 0
    end

    orig_alpha = alpha
    best_score = -(MATE_SCORE + 1)
    best_move  = NULL_MOVE

    # PVS state: true once one move has been searched with the full window.
    # All later moves get a null-window scout search first (see loop below).
    pv_searched = false

    # 1. Try hash move first
    tried_hash = false
    if hash_move != NULL_MOVE
        for i in 1:length(ml)
            if ml.moves[i] == hash_move
                tried_hash = true
                # Swap hash move to front
                ml.moves[i], ml.moves[1] = ml.moves[1], ml.moves[i]

                m  = ml.moves[1]
                fl = flags(m)
                is_capture = (fl & MF_CAPTURE) != 0 || fl == MF_EP
                is_promo   = (fl & MF_PROMO)   != 0

                # Futility pruning on hash move
                if futility_ok && !is_capture && !is_promo
                    best_score = max(best_score, static_eval)
                else
                    _path_push!(si, b.hash)
                    undo = make_move!(b, m)
                    gives_check = king_in_check(b, b.side)
                    extension = (cfg.check_extensions && gives_check && ply < MAX_PLY) ? 1 : sing_ext

                    # Hash move is never reduced (i=1)
                    score = -_negamax(b, depth - 1 + extension, -beta, -alpha, ply + 1, si, false, m)
                    pv_searched = true

                    unmake_move!(b, m, undo)
                    _path_pop!(si)

                    if si.stop; return 0; end

                    if score > best_score
                        best_score = score
                        best_move  = m
                        if score > alpha
                            alpha = score
                            if alpha >= beta
                                si.beta_cutoffs += 1
                                si.first_move_cutoffs += 1  # hash move is always first tried
                                # Write to TT before returning so _extract_pv can
                                # follow the PV through this cut node.
                                store_score = best_score
                                if best_score > MATE_SCORE - MOVE_STACK_SIZE
                                    store_score = best_score + ply
                                elseif best_score < -(MATE_SCORE - MOVE_STACK_SIZE)
                                    store_score = best_score - ply
                                end
                                _tt_put!(si.tt, b.hash, depth, store_score, TT_LOWER, best_move)
                                return best_score
                            end
                        end
                    end
                end
                break
            end
        end
    end

    # 2. Score remaining moves
    _score_moves!(ml, b, hash_move, si.killers, si.history,
                  si.countermoves, prev_move, ply, cfg, tried_hash ? 2 : 1)

    # 3. Search remaining moves
    quiet_count = 0   # number of quiet moves searched so far (for LMP)
    loop_start  = tried_hash ? 2 : 1
    for i in loop_start:length(ml)
        m  = _pick_move!(ml, i)
        fl = flags(m)
        is_capture = (fl & MF_CAPTURE) != 0 || fl == MF_EP
        is_promo   = (fl & MF_PROMO)   != 0

        # Futility: skip quiet moves when we're too far below alpha to recover.
        if futility_ok && !is_capture && !is_promo
            best_score = max(best_score, static_eval)
            continue
        end

        # Late move pruning: at shallow depths, stop searching quiet moves once
        # we've already tried enough of them without raising alpha.
        if !is_capture && !is_promo
            quiet_count += 1
            if cfg.lmp && !in_check && 1 <= depth <= 3 &&
               quiet_count > LMP_QUIET_LIMIT[depth]
                continue
            end
        end
        _path_push!(si, b.hash)
        undo        = make_move!(b, m)
        gives_check = king_in_check(b, b.side)

        # ── Extensions and Late Move Reductions ──────────────────────────────
        extension = (cfg.check_extensions && gives_check && ply < MAX_PLY) ? 1 : 0

        # LMR: after the first 2 moves, reduce quiet non-checking moves.
        # Log-based formula: reduction grows with both depth and move index,
        # giving larger cuts at high depth where re-search cost is highest.
        # Capped at depth-2 so the reduced search is always at least depth 1.
        reduction = 0
        if cfg.lmr && depth >= 3 && i > 2 && !is_capture && !is_promo && !gives_check && !in_check
            reduction = min(LMR_TABLE[min(depth,64), min(i,256)], depth - 2)
            # When already significantly behind, search harder — critical quiet moves
            # (e.g. discovered attacks) are likely ordered late and would otherwise
            # be reduced too much, causing large evaluation swings.
            static_eval < alpha - 200 && (reduction = max(0, reduction - 1))
        end

        # ── Principal variation search ───────────────────────────────────────
        # The first searched move establishes the PV with a full (α, β) window.
        # Later moves only need to prove they are NOT better than α, which the
        # null window (α, α+1) does at a fraction of the cost.  Escalation:
        #   1. scout at reduced depth (LMR) with the null window;
        #   2. if it beats α and was reduced, verify at full depth, still null
        #      window (the cheap check that the reduction wasn't hiding a
        #      better move);
        #   3. if it still beats α inside an open window (α+1 < β), re-search
        #      with the full window to obtain the exact score.  When β = α+1
        #      already (we are inside someone else's scout), step 3 is a no-op.
        if !cfg.pvs || !pv_searched
            score = -_negamax(b, depth - 1 + extension - reduction, -beta, -alpha, ply + 1, si, false, m)
            # Re-search at full depth if the reduced search beat alpha.
            if reduction > 0 && score > alpha && !si.stop
                score = -_negamax(b, depth - 1 + extension, -beta, -alpha, ply + 1, si, false, m)
            end
            pv_searched = true
        else
            score = -_negamax(b, depth - 1 + extension - reduction, -(alpha + 1), -alpha, ply + 1, si, false, m)
            if reduction > 0 && score > alpha && !si.stop
                score = -_negamax(b, depth - 1 + extension, -(alpha + 1), -alpha, ply + 1, si, false, m)
            end
            if score > alpha && score < beta && !si.stop
                score = -_negamax(b, depth - 1 + extension, -beta, -alpha, ply + 1, si, false, m)
            end
        end

        unmake_move!(b, m, undo)
        _path_pop!(si)

        si.stop && break

        if score > best_score
            best_score = score
            best_move  = m
            if score > alpha
                alpha = score
                if alpha >= beta
                    si.beta_cutoffs += 1
                    i == loop_start && (si.first_move_cutoffs += 1)
                    if !is_capture && !is_promo
                        _update_killers!(si.killers, ply, m)
                        _update_history!(si.history, m, depth)
                        cfg.countermove && _update_countermove!(si.countermoves, prev_move, m)
                        # Apply malus to quiet moves searched before this cutoff.
                        if cfg.history_malus
                            for j in loop_start:i-1
                                mj  = ml.moves[j]
                                flj = flags(mj)
                                if (flj & MF_CAPTURE) == 0 && flj != MF_EP && (flj & MF_PROMO) == 0
                                    _update_history_malus!(si.history, mj, depth)
                                end
                            end
                        end
                    end
                    break
                end
            end
        end
    end

    # Store the result in the TT.  The flag reflects what we learned:
    #   best_score >= beta  → lower bound (we stopped early; true score could be higher)
    #   best_score > orig_alpha → exact (alpha was raised; this IS the minimax value)
    #   otherwise           → upper bound (no move improved alpha; true score ≤ best_score)
    if !si.stop
        flag = best_score >= beta      ? TT_LOWER :
               best_score > orig_alpha ? TT_EXACT : TT_UPPER
        # Ply-normalize mate scores before storing so the value is node-relative
        # rather than root-relative.  Retrieving at any ply then gives the correct
        # mate distance by applying the inverse adjustment.
        store_score = best_score
        if best_score > MATE_SCORE - MOVE_STACK_SIZE
            store_score = best_score + ply
        elseif best_score < -(MATE_SCORE - MOVE_STACK_SIZE)
            store_score = best_score - ply
        end
        _tt_put!(si.tt, b.hash, depth, store_score, flag, best_move)
    end

    best_score
end

# ── Trickiness scoring ────────────────────────────────────────────────────────
# "Trickiness" measures how hard it is for the OPPONENT to find the correct
# response to a candidate move.  After playing candidate move m, we score all
# of the opponent's replies with a shallow search and compute:
#
#   gap         = best_reply_score − second_best_score
#               (how much the one correct reply matters; large gap → only one
#                good answer exists, making the position easy to go wrong in)
#
#   naturalness = 1 / rank_of_best_reply_in_MVV-LVA_order
#               (how obvious the best reply is; naturalness=1 if it is the
#                top-scored move by MVV-LVA, lower if it appears further down
#                the list and the opponent must find a non-obvious move)
#
#   trickiness  = gap × (1 − naturalness)
#
# A large gap combined with a non-obvious best reply (low naturalness) gives
# high trickiness: the opponent is likely to play the second-best reply and
# suffer a significant loss.  Among candidate moves that are within 30cp of
# the best objective score, we prefer the trickiest one.
function _trickiness_score(b::Board, m::Move, si::SearchInfo)::Int
    undo = make_move!(b, m)
    ml   = si.move_stack[2]
    generate_moves!(ml, b)
    n    = length(ml)
    if n <= 1
        unmake_move!(b, m, undo)
        return 0
    end

    tte       = _tt_get(si.tt, b.hash)
    hash_move = tte.key == b.hash ? tte.move : NULL_MOVE
    _score_moves!(ml, b, hash_move, si.killers, si.history, si.countermoves, NULL_MOVE, 2, si.config)

    best_score  = -(MATE_SCORE + 1)
    second_best = -(MATE_SCORE + 1)
    best_rank   = n   # default: best reply found last (worst naturalness)

    for i in 1:n
        reply = _pick_move!(ml, i)   # i is the reply's rank in MVV-LVA order
        undo2 = make_move!(b, reply)
        score = -_negamax(b, 2, -MATE_SCORE, MATE_SCORE, 3, si, false)
        unmake_move!(b, reply, undo2)
        si.stop && break
        if score > best_score
            second_best = best_score
            best_score  = score
            best_rank   = i
        elseif score > second_best
            second_best = score
        end
    end

    # If time expired after only one reply was evaluated, second_best is still
    # sentinel — we cannot compute a meaningful gap, so return 0.
    second_best <= -MATE_SCORE && (unmake_move!(b, m, undo); return 0)
    gap         = max(0, min(best_score - second_best, 200))   # cap at 200 cp
    naturalness = 1.0 / best_rank
    trickiness  = round(Int, gap * (1.0 - naturalness))
    unmake_move!(b, m, undo)
    trickiness
end

# ── Root search (tracks best move + all root scores) ──────────────────────────
function _search_root(b::Board, depth::Int, alpha::Int, beta::Int,
                      si::SearchInfo)::Tuple{Int,Move}
    best_score = -MATE_SCORE
    best_move  = NULL_MOVE
    orig_alpha = alpha   # needed to distinguish exact from upper-bound results

    tte       = _tt_get(si.tt, b.hash)
    hash_move = tte.key == b.hash ? tte.move : NULL_MOVE

    ml = si.move_stack[1]
    generate_moves!(ml, b)
    if length(ml) == 0
        return (king_in_check(b, b.side) ? -(MATE_SCORE - 1) : 0, NULL_MOVE)
    end

    empty!(si.root_moves)
    _score_moves!(ml, b, hash_move, si.killers, si.history, si.countermoves, NULL_MOVE, 1, si.config, 1)
    for i in 1:length(ml)
        m = _pick_move!(ml, i)
        _path_push!(si, b.hash)
        undo  = make_move!(b, m)
        # PVS at the root: first move full window, later moves scouted with a
        # null window and re-searched only when the scout beats alpha.
        if i == 1 || !si.config.pvs
            score = -_negamax(b, depth - 1, -beta, -alpha, 2, si, false)
        else
            score = -_negamax(b, depth - 1, -(alpha + 1), -alpha, 2, si, false)
            if score > alpha && score < beta && !si.stop
                score = -_negamax(b, depth - 1, -beta, -alpha, 2, si, false)
            end
        end
        unmake_move!(b, m, undo)
        _path_pop!(si)

        si.stop && break

        if score > best_score
            best_score = score
            best_move  = m
            alpha = max(alpha, score)
            push!(si.root_moves, (score, m))
        end
    end

    # Use the same three-case flag as _negamax so the entry is valid when the
    # position is later encountered as a sub-tree node in future searches:
    #   fail-high (best_score >= beta):  TT_LOWER  — true score ≥ best_score
    #   inside window (> orig_alpha):    TT_EXACT  — this IS the minimax value
    #   fail-low (never beat orig_alpha): TT_UPPER — true score ≤ best_score
    flag = best_score >= beta      ? TT_LOWER :
           best_score > orig_alpha ? TT_EXACT : TT_UPPER
    _tt_put!(si.tt, b.hash, depth, best_score, flag, best_move)
    (best_score, best_move)
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    search_move(b, time_ms; si, prior_counts, verbose) → SearchResult

Find the best move in position `b` within `time_ms` milliseconds.
- `si`: pre-allocated SearchInfo; reuse across moves to keep the TT warm.
- `prior_counts`: Zobrist-hash → occurrence-count map for positions seen in the
  game before this search.  Used for three-fold-repetition detection.
- `verbose`: when false, suppresses the per-depth `info` lines (used for the
  background coaching search that runs after our move is submitted).
"""
function search_move(b::Board, time_ms::Int;
                     si::SearchInfo = SearchInfo(),
                     prior_counts::Dict{UInt64,Int} = Dict{UInt64,Int}(),
                     verbose::Bool = true)::SearchResult
    # Handle checkmate / stalemate before touching the TT or time management.
    ml = si.move_stack[1]
    generate_moves!(ml, b)
    if length(ml) == 0
        score = king_in_check(b, b.side) ? -(MATE_SCORE - 1) : 0
        return SearchResult(NULL_MOVE, score, 0, Int64(0), evaluate(b, si.config), Move[])
    end

    si.stop                = false
    si.nodes               = 0
    si.beta_cutoffs        = 0
    si.first_move_cutoffs  = 0
    si.tt_probes           = 0
    si.tt_hits             = 0
    si.tt_cutoffs          = 0
    si.tb_hits             = 0
    si.time_start   = time()
    si.time_limit   = si.time_start + time_ms / 1000.0
    si.prior_counts      = prior_counts
    si.root_prior_count  = get(prior_counts, b.hash, 0)
    empty!(si.path)
    empty!(si.path_counts)
    fill!(si.killers, NULL_MOVE)
    # Age history at move start (÷2 only — ÷8 was too aggressive and discarded
    # useful ordering signal built up during the engine's own search).
    si.history .÷= 2
    fill!(si.countermoves, NULL_MOVE)

    best_move       = NULL_MOVE
    best_score      = 0
    best_depth      = 0
    best_pv         = Move[]              # PV cached after each *completed* depth
    completed_roots = Tuple{Int,Move}[]   # root_moves from last complete iteration
    pv_candidates   = Set{Move}()         # moves that were AB-best at some iteration

    # Time extension state: when the position is "unstable" (score swings a lot
    # or the best move changes), we grant a one-time extension of up to 1× the
    # original time allocation so the engine can resolve the uncertainty.
    time_extended    = false
    prev_best_move   = NULL_MOVE
    time_hard_limit  = si.time_start + time_ms * 3 / 2 / 1000.0

    prev_score       = 0
    prev_iter_nodes  = Int64(0)   # nodes used by the previous depth iteration (for EBF)
    verbose && println("# depth=ply  score=centipawns(side-to-move)  nps=knodes/s  " *
                       "ord=move-order-quality%  tth=TT-hit%  ttc=TT-cutoff%  " *
                       "tb=tablebase-hits  ebf=branching-factor  pv=best-line")
    for depth in 1:MAX_PLY
        # Age history scores so data from the most-recent iteration carries more
        # weight than data from shallow early iterations.  ÷4 (not ÷2) keeps
        # useful signal from recent depths rather than erasing it too quickly.
        si.history .÷= 4
        nodes_before_depth = si.nodes

        # Aspiration windows: search with a narrow window centred on the previous
        # iteration's score.  If the true score lies outside, we get a fail-low
        # (score ≤ α) or fail-high (score ≥ β) and must re-search with a wider
        # window.  The payoff: when the score is stable, roughly 80% of nodes
        # that would be searched with a full window are pruned.
        #
        # We use a full window for the first four depths or when a mate score
        # is on the board — aspiration only helps when the score is a stable
        # centipawn estimate, not when it may be a mate distance that changes
        # wildly between iterations.
        if !si.config.aspiration || depth <= 4 || abs(prev_score) >= MATE_SCORE - MAX_PLY
            score, move = _search_root(b, depth, -MATE_SCORE, MATE_SCORE, si)
        else
            δ = ASPIRATION_DELTA
            α = max(-MATE_SCORE, prev_score - δ)
            β = min( MATE_SCORE, prev_score + δ)
            for _ in 1:6               # max 6 expansions before falling back to full window
                score, move = _search_root(b, depth, α, β, si)
                si.stop && break
                if score <= α          # fail-low: widen only the lower bound and retry.
                    α  = max(-MATE_SCORE, score - δ)
                    δ *= 3
                elseif score >= β      # fail-high: a move scored much better than expected;
                    # widen the upper side and retry.
                    β  = min(MATE_SCORE, score + δ)
                    δ *= 3
                else
                    break              # score inside window — result is reliable
                end
            end
        end

        si.stop && break   # time ran out mid-search; discard partial result

        best_move  = move
        best_score = score
        best_depth = depth
        push!(pv_candidates, move)
        resize!(completed_roots, length(si.root_moves))
        copyto!(completed_roots, si.root_moves)

        elapsed_ms = round(Int, (time() - si.time_start) * 1_000)
        nps        = elapsed_ms > 0 ? si.nodes * 1_000 ÷ elapsed_ms : 0
        # Extract the PV now, while the TT reflects a *completed* iteration.
        # Storing it here prevents the subsequent partial depth+1 search from
        # overwriting TT_EXACT entries with TT_UPPER entries (due to aspiration
        # fail-low sub-trees), which would shorten the PV to a single move.
        pv_moves   = _extract_pv(b, si.tt, best_move, 8)
        best_pv    = copy(pv_moves)
        pv_str     = join(move_to_uci.(pv_moves), " ")
        if verbose
            this_depth_nodes = si.nodes - nodes_before_depth
            ebf    = prev_iter_nodes > 0 ? this_depth_nodes / prev_iter_nodes : 0.0
            fmc    = si.beta_cutoffs > 0 ? round(Int, 100 * si.first_move_cutoffs / si.beta_cutoffs) : 0
            tth    = si.tt_probes > 0    ? round(Int, 100 * si.tt_hits    / si.tt_probes)            : 0
            ttc    = si.tt_hits > 0      ? round(Int, 100 * si.tt_cutoffs / si.tt_hits)              : 0
            @printf("info depth %2d  score cp %+d  nodes %9d  nps %6dk  time %5dms  fmc %2d%%  tth %2d%%  ttc %2d%%  tb %6d  ebf %4.2f  pv %s\n",
                    depth, score, si.nodes, nps ÷ 1_000, elapsed_ms, fmc, tth, ttc, si.tb_hits, ebf, pv_str)
            prev_iter_nodes = this_depth_nodes
        end

        # Time extension: when the position is genuinely unstable — score swings
        # more than 150 cp from the previous depth, or the best move changes —
        # grant a one-time extension of up to ½ the original allocation (hard
        # cap is 1.5× budget, down from 2×).  Threshold raised from 100 to 150
        # so routine positional fluctuations don't trigger the extension.
        if depth >= 5 && !time_extended && abs(score) < MATE_SCORE - MAX_PLY
            score_swing  = abs(score - prev_score)
            move_changed = (prev_best_move != NULL_MOVE && move != prev_best_move)
            if score_swing > 150 || move_changed
                si.time_limit = min(si.time_limit + time_ms / 2 / 1000.0, time_hard_limit)
                time_extended = true
            end
        end
        prev_score     = score
        prev_best_move = move

        # Only stop early if the mate distance (in half-moves) is strictly less
        # than the current search depth.  Using < instead of <= gives one extra
        # depth of verification beyond the minimum needed to *find* the mate.
        # This prevents a false-mate broadcast when check extensions made the
        # mating line appear forced at depth D but the refutation requires D+1:
        # the extension keeps depth the same at the checked node, so the opponent's
        # evasions are only searched at depth D-1 rather than D, and a quiet king
        # escape requiring full depth can be missed.  The extra iteration is cheap
        # (mate sequences are short) and eliminates spurious "checkmate in N" chat.
        if abs(score) >= MATE_SCORE - MAX_PLY
            mate_dist = MATE_SCORE - abs(score)
            mate_dist < depth && break
        end
    end

    # Trickiness pass: among the top-3 moves within 30cp of the best, prefer
    # the one whose correct reply is hardest for the opponent to find.
    #
    # The pv_candidates filter is critical: we only consider moves that were the
    # AB-best at some depth iteration.  These moves have been the principal
    # variation and therefore have known continuations stored in the TT from deep
    # searches.  A move that was never the PV best (e.g. a speculative sacrifice
    # ranked 5th) was never searched as the main line — we don't know its true
    # value, so selecting it based on shallow trickiness would mean playing an
    # un-analyzed move.
    id_best_move = best_move   # best move after ID; may be overridden by trickiness

    # Skip trickiness on a low time budget: the pass costs up to 10% of the
    # per-move allocation, which is unacceptable when the clock is tight.
    trick_budget_ms = clamp(time_ms ÷ 10, 0, 60)
    if false && best_depth >= 4 && length(completed_roots) >= 2 && !is_capture(best_move) &&
       trick_budget_ms >= 10
        sort!(completed_roots; by = first, rev = true)
        threshold = completed_roots[1][1] - 30
        top_n     = min(3, length(completed_roots))
        si.stop       = false
        si.time_limit = time() + trick_budget_ms / 1000.0
        best_adj   = -MATE_SCORE - 1
        trick_move = best_move
        for (ab_score, m) in completed_roots[1:top_n]
            ab_score < threshold && break
            m ∉ pv_candidates && continue   # skip moves never on the PV
            trick = _trickiness_score(b, m, si)
            adj   = ab_score + round(Int, TRICKINESS_WEIGHT * trick)
            if adj > best_adj
                best_adj   = adj
                trick_move = m
            end
            si.stop && break
        end
        !si.stop && (best_move = trick_move)
    end

    # Use the PV cached from the last *completed* depth when the trickiness pass
    # did not change the best move.  That cache was built while the TT was clean;
    # the subsequent partial depth+1 search and the trickiness pass both write
    # shallow TT_UPPER entries that would shorten a fresh extraction to one move.
    # If trickiness did pick a different move, re-extract — the cached PV no
    # longer matches the selected move and we accept a potentially shorter line.
    pv = best_move == id_best_move ? best_pv : _extract_pv(b, si.tt, best_move, 10)

    # Draw rescue: if the search found a losing score but the game history already
    # contains a position that we can reach in one move (prior_counts >= 2 means
    # it has appeared twice before — playing to it now creates the 3rd occurrence
    # and Lichess auto-enforces the draw), prefer that drawing move.
    # Also check if we are already IN a repeated position (prior_counts[root] >= 2)
    # and don't have a BETTER score elsewhere; in that case any move is fine but
    # we log it so the caller can claim the draw if needed.
    if best_score < 0
        # If the root position itself has appeared >= 2 times before, this IS the
        # 3rd occurrence and Lichess will auto-enforce the draw.  Score it as 0.
        if si.root_prior_count >= 2
            best_score = 0
            pv         = isempty(pv) ? [best_move] : pv
        else
            # Look for a move that reaches a position seen >= 2 times: playing to it
            # creates the 3rd occurrence, Lichess auto-draws.
            ml_rescue = si.move_stack[2]
            generate_moves!(ml_rescue, b)
            for i in 1:length(ml_rescue)
                m = ml_rescue[i]
                undo = make_move!(b, m)
                can_draw = get(prior_counts, b.hash, 0) >= 2
                unmake_move!(b, m, undo)
                if can_draw
                    best_move  = m
                    best_score = 0
                    pv         = [m]
                    break
                end
            end
        end
    end

    SearchResult(best_move, best_score, best_depth, si.nodes, evaluate(b, si.config), pv)
end
