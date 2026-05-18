# Alpha-beta search with iterative deepening, quiescence search,
# transposition table, and killer-move ordering.

# ── Constants ─────────────────────────────────────────────────────────────────
const MATE_SCORE = 30_000   # a forced mate scores MATE_SCORE - ply
const MAX_PLY    = 64
const TT_BITS    = 20
const TT_SIZE    = 1 << TT_BITS   # ~1M entries

const TT_EXACT = 0x00
const TT_LOWER = 0x01   # score is a lower bound (failed high / beta cutoff)
const TT_UPPER = 0x02   # score is an upper bound (failed low)

# ── Transposition table ────────────────────────────────────────────────────────
struct TTEntry
    key::UInt64
    score::Int32
    depth::Int16
    flag::UInt8
    move::Move
end

const TT_EMPTY = TTEntry(UInt64(0), Int32(0), Int16(-1), TT_EXACT, NULL_MOVE)

@inline function _tt_get(tt::Vector{TTEntry}, hash::UInt64)::TTEntry
    tt[(hash & (TT_SIZE - 1)) + 1]
end

@inline function _tt_put!(tt::Vector{TTEntry}, hash::UInt64,
                           depth::Int, score::Int, flag::UInt8, move::Move)
    idx = (hash & (TT_SIZE - 1)) + 1
    e   = tt[idx]
    # Replace if: same position (update), empty slot, or new search is deeper.
    if e.key == hash || e.key == 0 || e.depth <= depth
        tt[idx] = TTEntry(hash, Int32(score), Int16(depth), flag, move)
    end
end

# ── Move ordering ──────────────────────────────────────────────────────────────
# MVV-LVA victim scores: higher = more valuable victim.
const _MVV = (0, 1, 2, 2, 4, 8, 0)  # NoPiece P N B R Q K

@inline function _move_score(m::Move, b::Board,
                              hash_move::Move, killers::Matrix{Move}, ply::Int)::Int
    m == hash_move && return 1_000_000

    fl = flags(m)
    if (fl & MF_CAPTURE) != 0 || fl == MF_EP
        victim  = fl == MF_EP ? Pawn : b.piece_on[to_sq(m)+1].kind
        aggr    = b.piece_on[from_sq(m)+1].kind
        return 100_000 + _MVV[Int(victim)+1] * 10 - _MVV[Int(aggr)+1]
    end

    (fl & MF_PROMO) != 0 && return 90_000

    if 1 <= ply <= MAX_PLY
        killers[1, ply] == m && return 80_000
        killers[2, ply] == m && return 70_000
    end

    0
end

# Returns a sorted (score, move) vector for the given position and ply.
function _order_moves(ml::MoveList, b::Board,
                      hash_move::Move, killers::Matrix{Move}, ply::Int)
    n = length(ml)
    buf = Vector{Tuple{Int,Move}}(undef, n)
    for i in 1:n
        mv = ml[i]
        buf[i] = (_move_score(mv, b, hash_move, killers, ply), mv)
    end
    sort!(buf; by = first, rev = true)
    buf
end

function _update_killers!(killers::Matrix{Move}, ply::Int, m::Move)
    1 <= ply <= MAX_PLY || return
    killers[1, ply] == m && return
    killers[2, ply] = killers[1, ply]
    killers[1, ply] = m
end

# ── Search state ──────────────────────────────────────────────────────────────
mutable struct SearchInfo
    tt         ::Vector{TTEntry}
    killers    ::Matrix{Move}   # killers[1:2, ply]
    nodes      ::Int64
    stop       ::Bool
    time_start ::Float64        # wall-clock start (seconds, from time())
    time_limit ::Float64        # wall-clock cutoff (seconds, from time())
end

function SearchInfo()
    SearchInfo(
        fill(TT_EMPTY, TT_SIZE),
        fill(NULL_MOVE, 2, MAX_PLY),
        Int64(0),
        false,
        0.0,
        0.0,
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
# Applies moves to b and unwinds them — b is restored on return.
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
function _quiesce(b::Board, alpha::Int, beta::Int, ply::Int, si::SearchInfo)::Int
    si.nodes += 1

    in_check = king_in_check(b, b.side)

    if !in_check
        stand_pat = (b.side == White ? 1 : -1) * total(evaluate(b))
        stand_pat >= beta && return stand_pat
        alpha = max(alpha, stand_pat)
    end

    ml = MoveList()
    generate_moves!(ml, b)

    length(ml) == 0 && return in_check ? -(MATE_SCORE - ply) : 0

    best = in_check ? -(MATE_SCORE - ply) : alpha
    for m in ml
        fl = flags(m)
        # When not in check, only search captures, e.p., and promotions.
        if !in_check && (fl & MF_CAPTURE) == 0 && fl != MF_EP && (fl & MF_PROMO) == 0
            continue
        end

        undo  = make_move!(b, m)
        score = -_quiesce(b, -beta, -alpha, ply + 1, si)
        unmake_move!(b, m, undo)

        score > best  && (best  = score)
        score > alpha && (alpha = score)
        alpha >= beta && break
    end
    best
end

# ── Alpha-beta (negamax) ──────────────────────────────────────────────────────
function _negamax(b::Board, depth::Int, alpha::Int, beta::Int,
                  ply::Int, si::SearchInfo)::Int
    # Periodic time check (every 1024 nodes to keep overhead low).
    si.nodes += 1
    if (si.nodes & 0x3FF) == 0 && time() >= si.time_limit
        si.stop = true
        return 0
    end

    # Transposition table probe.
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

    # At horizon: drop into quiescence search.
    depth <= 0 && return _quiesce(b, alpha, beta, ply, si)

    ml = MoveList()
    generate_moves!(ml, b)

    if length(ml) == 0
        return king_in_check(b, b.side) ? -(MATE_SCORE - ply) : 0
    end

    orig_alpha = alpha
    best_score = -(MATE_SCORE + 1)
    best_move  = NULL_MOVE

    for (_, m) in _order_moves(ml, b, hash_move, si.killers, ply)
        undo  = make_move!(b, m)
        score = -_negamax(b, depth - 1, -beta, -alpha, ply + 1, si)
        unmake_move!(b, m, undo)

        si.stop && break

        if score > best_score
            best_score = score
            best_move  = m
            if score > alpha
                alpha = score
                if alpha >= beta
                    fl = flags(m)
                    (fl & MF_CAPTURE) == 0 && fl != MF_EP &&
                        _update_killers!(si.killers, ply, m)
                    break
                end
            end
        end
    end

    if !si.stop
        flag = best_score >= beta      ? TT_LOWER :
               best_score > orig_alpha ? TT_EXACT : TT_UPPER
        _tt_put!(si.tt, b.hash, depth, best_score, flag, best_move)
    end

    best_score
end

# ── Root search (tracks best move separately) ─────────────────────────────────
function _search_root(b::Board, depth::Int, si::SearchInfo)::Tuple{Int,Move}
    alpha      = -MATE_SCORE
    beta       =  MATE_SCORE
    best_score = -MATE_SCORE
    best_move  = NULL_MOVE

    tte       = _tt_get(si.tt, b.hash)
    hash_move = tte.key == b.hash ? tte.move : NULL_MOVE

    ml = MoveList()
    generate_moves!(ml, b)
    if length(ml) == 0
        return (king_in_check(b, b.side) ? -(MATE_SCORE - 1) : 0, NULL_MOVE)
    end

    for (_, m) in _order_moves(ml, b, hash_move, si.killers, 1)
        undo  = make_move!(b, m)
        score = -_negamax(b, depth - 1, -beta, -alpha, 2, si)
        unmake_move!(b, m, undo)

        si.stop && break

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
    search_move(b, time_ms; si) → SearchResult

Find the best move in position `b` within `time_ms` milliseconds.
Pass a pre-allocated `SearchInfo` to reuse the transposition table across moves.
"""
function search_move(b::Board, time_ms::Int; si::SearchInfo = SearchInfo())::SearchResult
    # Handle checkmate / stalemate before touching the TT or time management.
    ml = MoveList()
    generate_moves!(ml, b)
    if length(ml) == 0
        score = king_in_check(b, b.side) ? -(MATE_SCORE - 1) : 0
        return SearchResult(NULL_MOVE, score, 0, Int64(0), evaluate(b), Move[])
    end

    si.stop       = false
    si.nodes      = 0
    si.time_start = time()
    si.time_limit = si.time_start + time_ms / 1000.0
    fill!(si.killers, NULL_MOVE)

    best_move  = NULL_MOVE
    best_score = 0
    best_depth = 0

    for depth in 1:MAX_PLY
        score, move = _search_root(b, depth, si)

        si.stop && break   # time ran out mid-search; discard partial result

        best_move  = move
        best_score = score
        best_depth = depth

        elapsed_ms = round(Int, (time() - si.time_start) * 1_000)
        nps        = elapsed_ms > 0 ? si.nodes * 1_000 ÷ elapsed_ms : 0
        pv_moves   = _extract_pv(b, si.tt, best_move, 8)
        pv_str     = join(move_to_uci.(pv_moves), " ")
        @printf("info depth %2d  score cp %+d  nodes %9d  nps %6dk  time %5dms  pv %s\n",
                depth, score, si.nodes, nps ÷ 1_000, elapsed_ms, pv_str)

        abs(score) >= MATE_SCORE - MAX_PLY && break  # mate found
    end

    pv = _extract_pv(b, si.tt, best_move, 10)
    SearchResult(best_move, best_score, best_depth, si.nodes, evaluate(b), pv)
end
