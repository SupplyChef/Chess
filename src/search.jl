# Alpha-beta search with iterative deepening, quiescence search,
# transposition table, and killer-move ordering.

# ── Constants ─────────────────────────────────────────────────────────────────
const MATE_SCORE = 30_000   # a forced mate scores MATE_SCORE - ply
const MAX_PLY    = 64
const TT_BITS    = 20
const TT_SIZE    = 1 << TT_BITS   # ~1M entries

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

# TT replacement policy: always replace if the stored entry is from a shallower
# search.  A deeper entry contains more information (more nodes were searched to
# produce it) and is therefore more valuable to keep.  Same-position updates
# (same key) always replace to capture the latest, deeper result.  Empty slots
# are always filled.
@inline function _tt_put!(tt::Vector{TTEntry}, hash::UInt64,
                           depth::Int, score::Int, flag::UInt8, move::Move)
    idx = (hash & (TT_SIZE - 1)) + 1
    @inbounds e = tt[idx]
    if e.key == hash || e.key == 0 || e.depth <= depth
        @inbounds tt[idx] = TTEntry(hash, Int32(score), Int16(depth), flag, move)
    end
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
                              ply::Int)::Int
    m == hash_move && return 1_000_000

    fl = flags(m)
    if (fl & MF_CAPTURE) != 0 || fl == MF_EP
        victim  = fl == MF_EP ? Pawn : b.piece_on[to_sq(m)+1].kind
        aggr    = b.piece_on[from_sq(m)+1].kind
        # Victim weight dominates (×10) so any more-valuable capture outranks
        # any less-valuable capture regardless of the aggressor.
        return 100_000 + _MVV[Int(victim)+1] * 10 - _MVV[Int(aggr)+1]
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

    # History heuristic: quiet moves that previously caused cutoffs score
    # between 1 and 60_000 — above generic quiet moves but below killers.
    fs = from_sq(m); ts = to_sq(m)
    @inbounds h = Int(history[fs+1, ts+1])
    h > 0 && return min(h, 60_000)

    0
end

# Fill ml.scores with move ordering scores (parallel to ml.moves).
function _score_moves!(ml::MoveList, b::Board, hash_move::Move,
                       killers::Matrix{Move}, history::Matrix{Int32}, ply::Int)
    @inbounds for i in 1:length(ml)
        ml.scores[i] = _move_score(ml[i], b, hash_move, killers, history, ply)
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

# ── Search state ──────────────────────────────────────────────────────────────
const MOVE_STACK_SIZE   = MAX_PLY + 64   # regular depth + qsearch budget
const TRICKINESS_WEIGHT = 0.10           # conservative weight; tune up if play feels too timid
const ASPIRATION_DELTA  = 75             # initial aspiration window half-width (centipawns)

# Futility margins (centipawns) indexed by depth.  At depth d, if static eval
# plus this margin is still below alpha, quiet moves cannot improve the position
# and are skipped.  Roughly: 1 pawn at depth 1, 2 pawns at depth 2.
const FUTILITY_MARGIN = (0, 150, 300)

mutable struct SearchInfo
    tt          ::Vector{TTEntry}
    killers     ::Matrix{Move}
    # History heuristic: records how often each (from→to) quiet move caused a beta
    # cutoff, weighted by depth².  High-history moves get tried before low-history
    # ones, improving move ordering beyond what killers alone can achieve.
    # Indexed [from_sq+1, to_sq+1]; values capped at 10_000 to prevent overflow.
    history     ::Matrix{Int32}
    move_stack  ::Vector{MoveList}        # pre-allocated, one per ply
    root_moves  ::Vector{Tuple{Int,Move}} # (score, move) from last complete iteration
    nodes       ::Int64
    stop        ::Bool
    time_start  ::Float64
    time_limit  ::Float64
    # Draw detection state:
    #   path         — Zobrist hashes of every position on the current search path,
    #                  from the root down to the current node's parent.  Used to
    #                  detect repetitions that occur within the search tree.
    #   prior_counts — position counts from the GAME before the search started,
    #                  supplied by the caller (play_lichess tracks these).  A
    #                  position with count 2 is already in its second occurrence;
    #                  one more repeat makes it a draw.
    path         ::Vector{UInt64}
    prior_counts ::Dict{UInt64,Int}
    config       ::EngineConfig
end

function SearchInfo(cfg::EngineConfig = DEFAULT_CONFIG)
    SearchInfo(
        fill(TT_EMPTY, TT_SIZE),
        fill(NULL_MOVE, 2, MAX_PLY),
        zeros(Int32, 64, 64),
        [MoveList() for _ in 1:MOVE_STACK_SIZE],
        Tuple{Int,Move}[],
        Int64(0),
        false,
        0.0,
        0.0,
        UInt64[],
        Dict{UInt64,Int}(),
        cfg,
    )
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
        m   = (tte.key == b.hash && tte.flag == TT_EXACT) ? tte.move : NULL_MOVE
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
# If stand_pat > alpha we raise alpha (we found a quiet baseline that beats the
# previous best).  Searching captures then looks for something better.
#
# When in check we cannot stand pat (the king may be lost) and must consider
# all evasions, not just captures.
function _quiesce(b::Board, alpha::Int, beta::Int, ply::Int, si::SearchInfo)::Int
    si.nodes += 1

    # A capture might reduce material to a theoretically drawn endgame.
    _is_insufficient_material(b) && return 0

    in_check = king_in_check(b, b.side)

    if !in_check
        stand_pat = (b.side == White ? 1 : -1) * total(evaluate(b, si.config))
        stand_pat >= beta && return stand_pat
        alpha = max(alpha, stand_pat)
    end

    ml = si.move_stack[min(ply, MOVE_STACK_SIZE)]
    in_check ? generate_moves!(ml, b) : generate_captures!(ml, b)

    # No captures/promos available and not in check: this is a quiet position,
    # return alpha (= stand_pat).  In check with no evasions: checkmate.
    length(ml) == 0 && return in_check ? -(MATE_SCORE - ply) : alpha

    _score_moves!(ml, b, NULL_MOVE, si.killers, si.history, ply)

    best = in_check ? -(MATE_SCORE - ply) : alpha
    for i in 1:length(ml)
        m = _pick_move!(ml, i)

        undo  = make_move!(b, m)
        score = -_quiesce(b, -beta, -alpha, ply + 1, si)
        unmake_move!(b, m, undo)

        score > best  && (best  = score)
        score > alpha && (alpha = score)
        alpha >= beta && break
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
function _negamax(b::Board, depth::Int, alpha::Int, beta::Int,
                  ply::Int, si::SearchInfo, is_null::Bool)::Int
    # Periodic time check (every 1024 nodes to keep overhead low).
    si.nodes += 1
    if (si.nodes & 0x3FF) == 0 && time() >= si.time_limit
        si.stop = true
        return 0
    end

    # ── Draw detection ────────────────────────────────────────────────────────
    # Check these before the TT so a stale non-zero TT entry can't override a draw.

    # 50-move rule: 100 half-moves (plies) without a pawn push or capture.
    b.halfmove >= 100 && return 0

    # Insufficient material: neither side can force checkmate.
    _is_insufficient_material(b) && return 0

    # Repetition: count how many times this position has been seen before —
    # both in the game (prior_counts) and on the current search path.
    # Two prior occurrences means this would be the third → draw.
    # One prior occurrence means this is the second: we return 0 (draw value)
    # so the engine avoids the repetition when winning and embraces it when losing.
    let reps = get(si.prior_counts, b.hash, 0)
        for h in si.path; h == b.hash && (reps += 1); end
        reps >= 2 && return 0
    end

    # TT probe: if we have previously searched this position at sufficient depth,
    # we can reuse the stored result.  "Sufficient depth" means tte.depth >= depth:
    # a stored result from a depth-3 search is not reliable when we need depth-5.
    # The flag tells us whether the stored score is exact, a lower bound, or an
    # upper bound, and we narrow (or cut) the window accordingly.
    tte       = _tt_get(si.tt, b.hash)
    hash_move = NULL_MOVE
    if tte.key == b.hash
        hash_move = tte.move
        if tte.depth >= depth
            sc = Int(tte.score)
            if tte.flag == TT_EXACT
                return sc
            elseif tte.flag == TT_LOWER
                alpha = max(alpha, sc)
            else
                beta = min(beta, sc)
            end
            alpha >= beta && return sc
        end
    end

    # At horizon: drop into quiescence search rather than returning the static
    # eval, to avoid the "horizon effect" of missing captures on the next move.
    depth <= 0 && return _quiesce(b, alpha, beta, ply, si)

    in_check = king_in_check(b, b.side)

    # ── Null move pruning ─────────────────────────────────────────────────────
    # If we're not in check and we have non-pawn material, try passing our turn.
    # If even then the opponent can't beat beta, the position is good enough to
    # prune: a real move can only do better.  The "zugzwang guard" (non-pawn
    # material check) avoids false pruning in K+P endgames where passing really
    # is catastrophic.
    #
    # We use a null-window around beta (–β, –β+1) and a reduced depth R so
    # the null search is very fast.  R = 3 at depth ≥ 6, R = 2 otherwise.
    cfg = si.config
    if cfg.null_move && !is_null && !in_check && depth >= 3 &&
       (bb(b, b.side, Knight) | bb(b, b.side, Bishop) |
        bb(b, b.side, Rook)   | bb(b, b.side, Queen)) != BB(0)
        R       = depth >= 6 ? 3 : 2
        ep_save = b.ep_square
        push!(si.path, b.hash)          # record current hash before passing the turn
        b.side  = other(b.side)
        b.hash ⊻= ZOBRIST_SIDE[]
        if ep_save != -1
            b.hash     ⊻= zob_ep(ep_save)
            b.ep_square = -1
        end
        null_score = -_negamax(b, depth - R - 1, -beta, -beta + 1, ply + 1, si, true)
        b.side = other(b.side)
        b.hash ⊻= ZOBRIST_SIDE[]
        if ep_save != -1
            b.ep_square = ep_save
            b.hash     ⊻= zob_ep(ep_save)
        end
        pop!(si.path)
        !si.stop && null_score >= beta && return beta
    end

    # ── Futility pruning ──────────────────────────────────────────────────────
    # At depth 1 and 2, if static eval + a margin (1–2 pawns) is still below
    # alpha, quiet moves are unlikely to improve alpha — prune them.
    # Captures and promotions bypass this check: they can swing material
    # dramatically and must always be searched.
    futility_ok = cfg.futility && !in_check && depth <= 2 &&
        (b.side == White ? 1 : -1) * total(evaluate(b, cfg)) +
        FUTILITY_MARGIN[depth + 1] < alpha

    ml = si.move_stack[min(ply, MOVE_STACK_SIZE)]
    generate_moves!(ml, b)

    # No legal moves: checkmate (king in check) or stalemate (not in check).
    if length(ml) == 0
        return in_check ? -(MATE_SCORE - ply) : 0
    end

    _score_moves!(ml, b, hash_move, si.killers, si.history, ply)

    orig_alpha = alpha
    best_score = -(MATE_SCORE + 1)
    best_move  = NULL_MOVE

    for i in 1:length(ml)
        m  = _pick_move!(ml, i)
        fl = flags(m)
        is_capture = (fl & MF_CAPTURE) != 0 || fl == MF_EP
        is_promo   = (fl & MF_PROMO)   != 0

        # Futility: skip quiet moves when we're too far below alpha to recover.
        if futility_ok && !is_capture && !is_promo
            continue
        end

        push!(si.path, b.hash)
        undo        = make_move!(b, m)
        gives_check = king_in_check(b, b.side)   # did this move give check?

        # ── Extensions and Late Move Reductions ──────────────────────────────
        # Check extension: moves that give check are searched one ply deeper.
        # Checking moves lead to forced sequences (the opponent must evade), so
        # the resulting subtree is narrow and cheap to explore.  Extending ensures
        # we don't miss a forced mate that LMR would otherwise reduce away.
        extension = (cfg.check_extensions && gives_check) ? 1 : 0

        # LMR: after the first 3 moves, reduce quiet non-checking moves.
        # Good moves appear early in the sorted list; late moves are usually
        # noise and tolerate reduced depth.  If the reduced search beats alpha
        # we re-search at full depth — LMR only saves work on unsound moves.
        # Extra reduction for very late moves (index > 8).
        reduction = 0
        if cfg.lmr && depth >= 3 && i > 3 && !is_capture && !is_promo && !gives_check && !in_check
            reduction = i > 8 ? 2 : 1
        end

        score = -_negamax(b, depth - 1 + extension - reduction, -beta, -alpha, ply + 1, si, false)

        # Re-search at full (+ extension) depth if the reduced search beat alpha.
        if reduction > 0 && score > alpha && !si.stop
            score = -_negamax(b, depth - 1 + extension, -beta, -alpha, ply + 1, si, false)
        end

        unmake_move!(b, m, undo)
        pop!(si.path)

        si.stop && break

        if score > best_score
            best_score = score
            best_move  = m
            if score > alpha
                alpha = score
                if alpha >= beta
                    # Beta cutoff: record this quiet move in killers and history
                    # so it gets tried early in sibling and future nodes.
                    if !is_capture && !is_promo
                        _update_killers!(si.killers, ply, m)
                        _update_history!(si.history, m, depth)
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
        _tt_put!(si.tt, b.hash, depth, best_score, flag, best_move)
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
    _score_moves!(ml, b, hash_move, si.killers, si.history, 2)

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

    tte       = _tt_get(si.tt, b.hash)
    hash_move = tte.key == b.hash ? tte.move : NULL_MOVE

    ml = si.move_stack[1]
    generate_moves!(ml, b)
    if length(ml) == 0
        return (king_in_check(b, b.side) ? -(MATE_SCORE - 1) : 0, NULL_MOVE)
    end

    empty!(si.root_moves)
    _score_moves!(ml, b, hash_move, si.killers, si.history, 1)
    for i in 1:length(ml)
        m = _pick_move!(ml, i)
        push!(si.path, b.hash)
        undo  = make_move!(b, m)
        score = -_negamax(b, depth - 1, -beta, -alpha, 2, si, false)
        unmake_move!(b, m, undo)
        pop!(si.path)

        si.stop && break

        push!(si.root_moves, (score, m))
        if score > best_score
            best_score = score
            best_move  = m
            alpha = max(alpha, score)
        end
    end

    _tt_put!(si.tt, b.hash, depth, best_score, TT_EXACT, best_move)
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

    si.stop         = false
    si.nodes        = 0
    si.time_start   = time()
    si.time_limit   = si.time_start + time_ms / 1000.0
    si.prior_counts = prior_counts
    empty!(si.path)
    fill!(si.killers, NULL_MOVE)
    fill!(si.history, Int32(0))

    best_move       = NULL_MOVE
    best_score      = 0
    best_depth      = 0
    completed_roots = Tuple{Int,Move}[]   # root_moves from last complete iteration
    pv_candidates   = Set{Move}()         # moves that were AB-best at some iteration

    prev_score = 0
    for depth in 1:MAX_PLY
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
            while true
                score, move = _search_root(b, depth, α, β, si)
                si.stop && break
                if score <= α          # fail-low: the position is worse than expected;
                    # keep β close to the old α (the score won't be much higher)
                    # and widen the lower side only.
                    β  = (α + β) ÷ 2
                    α  = max(-MATE_SCORE, score - δ)
                    δ *= 3
                elseif score >= β      # fail-high: a move scored much better than expected;
                    # widen the upper side and retry.
                    β  = min(MATE_SCORE, score + δ)
                    δ *= 3
                else
                    break              # score inside window — result is reliable
                end
                δ > 2 * MATE_SCORE && break  # fallback: give up and accept the result
            end
        end

        si.stop && break   # time ran out mid-search; discard partial result

        best_move  = move
        best_score = score
        best_depth = depth
        prev_score = score
        push!(pv_candidates, move)
        resize!(completed_roots, length(si.root_moves))
        copyto!(completed_roots, si.root_moves)

        elapsed_ms = round(Int, (time() - si.time_start) * 1_000)
        nps        = elapsed_ms > 0 ? si.nodes * 1_000 ÷ elapsed_ms : 0
        pv_moves   = _extract_pv(b, si.tt, best_move, 8)
        pv_str     = join(move_to_uci.(pv_moves), " ")
        verbose && @printf("info depth %2d  score cp %+d  nodes %9d  nps %6dk  time %5dms  pv %s\n",
                           depth, score, si.nodes, nps ÷ 1_000, elapsed_ms, pv_str)

        abs(score) >= MATE_SCORE - MAX_PLY && break  # mate found; no need to search deeper
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
    if best_depth >= 4 && length(completed_roots) >= 2 && !is_capture(best_move)
        sort!(completed_roots; by = first, rev = true)
        threshold = completed_roots[1][1] - 30
        top_n     = min(3, length(completed_roots))
        si.stop       = false
        si.time_limit = time() + 0.060   # 60 ms budget for trickiness pass
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

    pv = _extract_pv(b, si.tt, best_move, 10)
    SearchResult(best_move, best_score, best_depth, si.nodes, evaluate(b, si.config), pv)
end
