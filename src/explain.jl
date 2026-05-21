# Move explanation: produce natural-language commentary for Lichess chat.
#
# Two public entry points:
#   explain_move          — narrates the bot's own move to the opponent.
#   explain_opponent_move — coaching mode: compares the opponent's move to what the
#                           engine would have played in their position.
#
# Explanation priority inside explain_move (first matching branch wins):
#   1. Forced mate (us)    — we're mating in N moves; show the key idea.
#   2. Being mated (them)  — we're delaying checkmate; acknowledge and fight on.
#   3. Material gain       — we win material over the PV.  Not triggered for a
#                            recapture: taking back on the same square the opponent
#                            just moved to restores balance, not a new gain.
#      3a. Fork            — we simultaneously attack 2+ profitable targets.
#   4. Positional          — driven by the static-eval breakdown comparing the
#                            position before and after the move.  Named structural
#                            patterns (open file, outpost, passed pawn, …) are
#                            reported only when the relevant eval term confirms the
#                            improvement; the largest gaining term leads.

# ── Piece / square helpers ─────────────────────────────────────────────────────

function _san_sym(k::PieceKind)::String
    k == Knight ? "N" : k == Bishop ? "B" : k == Rook ? "R" :
    k == Queen  ? "Q" : k == King   ? "K" : ""
end

function _approx_san(m::Move, b::Board)::String
    fl = flags(m)
    fl == MF_KS_CAST && return "O-O"
    fl == MF_QS_CAST && return "O-O-O"
    k   = b.piece_on[from_sq(m)+1].kind
    cap = is_capture(m) || is_ep(m)
    dst = sq_name(to_sq(m))
    if k == Pawn
        pfx = cap ? string(Char('a' + file_of(from_sq(m)))) : ""
        sfx = is_promo(m) ? ("=" * _san_sym(promo_kind(m))) : ""
        return pfx * (cap ? "x" : "") * dst * sfx
    end
    _san_sym(k) * (cap ? "x" : "") * dst
end

function _piece_name(k::PieceKind)::String
    k == Pawn   ? "pawn"   : k == Knight ? "knight" : k == Bishop ? "bishop" :
    k == Rook   ? "rook"   : k == Queen  ? "queen"  : "piece"
end

# ── Material swing over the PV ────────────────────────────────────────────────
# Net material gained (in centipawns) by the side making pv[1] over the PV.
# Positive = we gain; negative = we lose.
function _pv_material_swing(pv::Vector{Move}, b::Board)::Int
    isempty(pv) && return 0
    us    = b.side
    net   = 0
    undos = UndoInfo[]
    for m in pv
        fl   = flags(m)
        sign = b.side == us ? 1 : -1
        if fl == MF_EP
            net += sign * PIECE_VALUE[Int(Pawn)+1]
        elseif (fl & MF_CAPTURE) != 0
            net += sign * PIECE_VALUE[Int(b.piece_on[to_sq(m)+1].kind)+1]
        end
        if (fl & MF_PROMO) != 0
            net += sign * (PIECE_VALUE[Int(promo_kind(m))+1] - PIECE_VALUE[Int(Pawn)+1])
        end
        push!(undos, make_move!(b, m))
    end
    for i in length(pv):-1:1; unmake_move!(b, pv[i], undos[i]); end
    net
end

# ── Attack / fork helpers ──────────────────────────────────────────────────────

# Reverse-lookup: does any piece of `defender` attack `sq`?
# Uses the symmetry of attack sets: a square S attacked by a knight iff a
# knight on S attacks a real knight of the defender, etc.
function _is_defended(b::Board, sq::Int, defender::Color)::Bool
    occ = all_occ(b)
    (pawn_attacks(sq, other(defender))  & bb(b, defender, Pawn))                              != 0 && return true
    (knight_attacks(sq)                 & bb(b, defender, Knight))                             != 0 && return true
    (bishop_attacks(sq, occ)            & (bb(b, defender, Bishop) | bb(b, defender, Queen))) != 0 && return true
    (rook_attacks(sq, occ)              & (bb(b, defender, Rook)   | bb(b, defender, Queen))) != 0 && return true
    (king_attacks(sq)                   & bb(b, defender, King))                               != 0 && return true
    false
end

# Enemy pieces attacked from the destination square after making move m,
# filtered to those that are "profitable to capture": either undefended,
# worth more than the mover, or the king (giving check always threatens).
# Returns them sorted most-valuable-first.  Board is restored afterward.
function _fork_targets(b::Board, m::Move, mover_val::Int)::Vector{Tuple{PieceKind,Int}}
    undo   = make_move!(b, m)
    us     = other(b.side)      # side that just moved
    them   = b.side
    dst    = to_sq(m)
    occ    = all_occ(b)
    theirs = b.occ[Int(them)+1]
    atk    = let k = b.piece_on[dst+1].kind
        k == Pawn   ? pawn_attacks(dst, us)   :
        k == Knight ? knight_attacks(dst)      :
        k == Bishop ? bishop_attacks(dst, occ) :
        k == Rook   ? rook_attacks(dst, occ)   :
        k == Queen  ? queen_attacks(dst, occ)  : BB(0)
    end
    targets = Tuple{PieceKind,Int}[]
    for s in BitIter(atk & theirs)
        pk = b.piece_on[s+1].kind
        if pk == King
            push!(targets, (King, s))
        else
            v = PIECE_VALUE[Int(pk)+1]
            if v > mover_val || !_is_defended(b, s, them)
                push!(targets, (pk, s))
            end
        end
    end
    unmake_move!(b, m, undo)
    sort!(targets; by = p -> p[1] == King ? 10_000 : -PIECE_VALUE[Int(p[1])+1])
    targets
end

# ── Endgame / structural helpers ───────────────────────────────────────────────

# Endgame: non-pawn/king material ≤ 2800 cp (≈ one queen + one rook total).
function _is_endgame(b::Board)::Bool
    mat = 0
    for c in (White, Black)
        mat += PIECE_VALUE[Int(Knight)+1] * count_bits(bb(b, c, Knight))
        mat += PIECE_VALUE[Int(Bishop)+1] * count_bits(bb(b, c, Bishop))
        mat += PIECE_VALUE[Int(Rook)+1]   * count_bits(bb(b, c, Rook))
        mat += PIECE_VALUE[Int(Queen)+1]  * count_bits(bb(b, c, Queen))
    end
    mat <= 2800
end

# ── PV continuation sentence ───────────────────────────────────────────────────
# Produces " After Xe4, I plan Rxf7." style text from the PV.
# Board must be advanced by pv[1] before calling; restored by caller afterward.
function _pv_continuation(pv::Vector{Move}, b_after::Board)::String
    length(pv) < 2 && return ""
    opp = _approx_san(pv[2], b_after)
    if length(pv) >= 3
        undo2 = make_move!(b_after, pv[2])
        ours  = _approx_san(pv[3], b_after)
        unmake_move!(b_after, pv[2], undo2)
        return " After $opp, I plan $ours."
    end
    " I expect $opp from you next."
end

# ── explain_move ──────────────────────────────────────────────────────────────

"""
    explain_move(result, b, my_color; last_opp_move) → String

Build a Lichess-chat explanation for the bot's move.
`b` must be the board *before* the move.
`last_opp_move` is the opponent's immediately preceding move (used to detect
recaptures, where we are restoring material balance rather than gaining it).
"""
function explain_move(result::SearchResult, b::Board, my_color::Color;
                      last_opp_move::Union{Move,Nothing} = nothing)::String
    our_san  = _approx_san(result.move, b)
    scorestr = result.score >= 0 ? "+$(result.score)" : "$(result.score)"
    note     = "($(scorestr)cp, depth $(result.depth))"

    isempty(result.pv) && return "I played $our_san. $note"

    sgn     = my_color == White ? 1 : -1
    our_fr  = from_sq(result.move)
    our_k   = b.piece_on[our_fr+1].kind
    our_val = PIECE_VALUE[Int(our_k)+1]
    fl      = flags(result.move)

    # ── 1. Forced-mate sequences ───────────────────────────────────────────────
    abs_score = abs(result.score)
    if abs_score >= MATE_SCORE - MAX_PLY
        # (MATE_SCORE - abs_score) = half-moves to checkmate; +1 so integer division
        # rounds toward "mate in N" rather than N-1 for odd half-move counts.
        mate_in = (MATE_SCORE - abs_score + 1) ÷ 2

        if result.score > 0
            # We are mating.
            undo    = make_move!(b, result.move)
            cont    = _pv_continuation(result.pv, b)
            unmake_move!(b, result.move, undo)
            label   = mate_in == 1 ? "Checkmate!" :
                      "I'm playing for checkmate in $mate_in.$cont"
            return "I played $our_san — $label $note"
        else
            # We are being mated; we delay as long as possible.
            label = mate_in == 1 ? "It's checkmate — game over." :
                    "I'm being mated in $mate_in moves, but I'll keep fighting. $note"
            return "I played $our_san — $label"
        end
    end

    # ── 2. Material gain ────────────────────────────────────────────────────────
    swing = _pv_material_swing(result.pv, b)

    # A recapture (landing on the same square the opponent just vacated) restores
    # balance; we are not winning new material, so suppress the material branch.
    is_recap = last_opp_move !== nothing &&
               (is_capture(result.move) || is_ep(result.move)) &&
               to_sq(result.move) == to_sq(last_opp_move)

    genuinely_winning = swing >=  90 && result.score >=  60 && !is_recap
    genuinely_losing  = swing <= -90 && result.score <= -60 && !is_recap

    if genuinely_winning || genuinely_losing
        # 2a. Fork check: do we simultaneously threaten 2+ profitable targets?
        forks = _fork_targets(b, result.move, our_val)
        if length(forks) >= 2
            n1 = _piece_name(forks[1][1])
            n2 = _piece_name(forks[2][1])
            what = swing >= 800 ? "the queen" : swing >= 450 ? "the rook" :
                   swing >= 270 ? "a piece"   : "a pawn"
            return "I played $our_san — forking your $n1 and $n2, winning $what. $note"
        end

        # 2b. Non-fork material gain / loss.
        what = abs(swing) >= 800 ? "the queen" : abs(swing) >= 450 ? "the rook" :
               abs(swing) >= 270 ? "a piece"   : "a pawn"
        undo = make_move!(b, result.move)
        cont = if length(result.pv) >= 3
            opp  = _approx_san(result.pv[2], b)
            undo2 = make_move!(b, result.pv[2])
            ours  = _approx_san(result.pv[3], b)
            unmake_move!(b, result.pv[2], undo2)
            " After $opp, I continue with $ours."
        elseif length(result.pv) >= 2
            " Your best reply is $(_approx_san(result.pv[2], b))."
        else ""
        end
        unmake_move!(b, result.move, undo)
        if genuinely_winning
            return "I played $our_san — winning $what.$cont $note"
        else
            return "I played $our_san — losing $what, but it's the best I can do.$cont $note"
        end
    end

    # ── 3. Positional improvements ─────────────────────────────────────────────
    # Compare the static eval breakdown before and after the move to identify
    # what specifically improved.  Named structural patterns are reported only
    # when the relevant eval term confirms the gain; the largest term leads.

    # Pre-move context (needed before make_move!).
    back_rank       = my_color == White ? 0 : 7
    in_check_before = king_in_check(b, my_color)
    is_dev          = (our_k == Knight || our_k == Bishop) && rank_of(our_fr) == back_rank

    undo = make_move!(b, result.move)
    e2   = evaluate(b)
    dst  = to_sq(result.move)
    e    = result.eval   # static eval of the position BEFORE the move

    # Deltas from our side's perspective (positive = we improved).
    Δact  = sgn * (e2.piece_activity - e.piece_activity)
    Δpawn = sgn * (e2.pawn_structure - e.pawn_structure)
    Δking = sgn * (e2.king_safety    - e.king_safety)

    # Structural patterns — checked only for the relevant piece type,
    # and only when the corresponding eval term shows improvement.
    rook_concept = ""
    if our_k == Rook
        seventh   = my_color == White ? 6 : 1
        f         = file_of(dst)
        my_rooks  = bb(b, my_color, Rook)
        all_pawns = bb(b, White, Pawn) | bb(b, Black, Pawn)
        my_pawns  = bb(b, my_color, Pawn)
        occ_ex    = all_occ(b)
        visible     = rook_attacks(dst, occ_ex) & my_rooks & ~sq_bb(dst)
        file_conn   = (visible & FILE_MASK[f+1]) != 0
        rank_conn   = (visible & RANK_MASK[rank_of(dst)+1]) != 0
        if file_conn
            rook_concept = "connects my rooks on the $(Char('a'+f))-file"
        elseif rank_conn
            rook_concept = "doubles my rooks"
        elseif rank_of(dst) == seventh
            rook_concept = "invades the 7th rank"
        elseif (all_pawns & FILE_MASK[f+1]) == 0
            rook_concept = "occupies the open $(Char('a'+f))-file"
        elseif (my_pawns & FILE_MASK[f+1]) == 0
            rook_concept = "takes the semi-open $(Char('a'+f))-file"
        end
    end

    in_opp_half    = my_color == White ? rank_of(dst) >= 4 : rank_of(dst) <= 3
    knight_outpost = our_k == Knight && in_opp_half && let
        ep    = bb(b, other(my_color), Pawn)
        pmask = (my_color == White ? _PASSED_W[dst+1] : _PASSED_B[dst+1]) &
                ~FILE_MASK[file_of(dst)+1]
        (pmask & ep) == 0
    end

    creates_passed = our_k == Pawn && !is_capture(result.move) && !is_ep(result.move) &&
                     _is_passed(dst, my_color, bb(b, other(my_color), Pawn))

    opens_own_file = false; open_file_char = ' '
    if our_k == Pawn && (is_capture(result.move) || is_ep(result.move))
        src_f = file_of(our_fr)
        if (bb(b, my_color, Pawn) & FILE_MASK[src_f+1]) == 0
            opens_own_file = true; open_file_char = Char('a' + src_f)
        end
    end

    pawn_center = our_k == Pawn && !is_capture(result.move) && !is_ep(result.move) &&
                  file_of(dst) in (3, 4) && rank_of(dst) in (3, 4)

    endgame = _is_endgame(b)

    # PV continuation.
    plan = _pv_continuation(result.pv, b)

    unmake_move!(b, result.move, undo)

    # Build the concept label.  Castling and king moves get explicit labels.
    # Structural patterns take priority when the relevant eval term confirms them.
    # The eval-delta breakdown is the final arbiter for everything else.
    concept = if fl == MF_KS_CAST
        "king to safety behind the pawn shield"
    elseif fl == MF_QS_CAST
        "king to safety, rook enters the game"
    elseif our_k == King
        if in_check_before;  "escaping check"
        elseif endgame;      "activating the king for the endgame"
        elseif Δking >= 8;   "improving king safety"
        else;                "repositioning the king"
        end
    elseif !isempty(rook_concept) && Δact >= 5
        rook_concept
    elseif knight_outpost && Δact >= 5
        "establishing a permanent outpost on $(sq_name(dst)) — your pawns can never chase it away"
    elseif creates_passed && Δpawn >= 5
        "creating a passed pawn on the $(Char('a' + file_of(dst)))-file"
    elseif opens_own_file && Δact >= 5
        "opening the $(open_file_char)-file for my rook"
    elseif pawn_center
        "fighting for the center"
    elseif is_dev && Δact >= 5
        "developing my $(_piece_name(our_k))"
    else
        # Eval-delta fallback: name the largest improving term.
        parts = Tuple{Int,String}[]
        Δact  >=  8 && push!(parts, (Δact,       "improving my piece activity"))
        Δpawn >=  8 && push!(parts, (Δpawn,       "strengthening my pawn structure"))
        Δpawn <= -8 && push!(parts, (abs(Δpawn),  "weakening your pawn structure"))
        Δking >=  8 && push!(parts, (Δking,       "improving my king safety"))
        sort!(parts; by = first, rev = true)
        isempty(parts) ? "keeping the position solid" :
        length(parts) == 1 ? parts[1][2] :
        "$(parts[1][2]) and $(parts[2][2])"
    end

    "I played $our_san — $concept.$plan $note"
end

# ── explain_opponent_move ──────────────────────────────────────────────────────

"""
    explain_opponent_move(b_before, opp_move, engine_result) → String

Coaching mode: compare the opponent's actual move to what the engine would play.
`b_before` is the position *before* the opponent moved.
"""
function explain_opponent_move(b_before::Board, opp_move::Move,
                               engine_result::SearchResult)::String
    engine_result.move == NULL_MOVE && return ""
    opp_san    = _approx_san(opp_move, b_before)
    engine_san = _approx_san(engine_result.move, b_before)
    opp_move == engine_result.move &&
        return "Good move! $opp_san is exactly what I'd play in your position."
    undo      = make_move!(b_before, engine_result.move)
    reply_str = length(engine_result.pv) >= 2 ?
                ", after which I'd play $(_approx_san(engine_result.pv[2], b_before))" : ""
    unmake_move!(b_before, engine_result.move, undo)
    "As your coach: I'd have played $engine_san there$reply_str. " *
    "Let's see how $opp_san works out. [depth $(engine_result.depth)]"
end
