# Move explanation: tactical (concrete line) vs positional (concrete objective).
# Coaching mode compares the opponent's actual move to the engine's choice.

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

# Net material gained by the side making pv[1] over the course of the PV.
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

# Most valuable enemy piece attacked by our moved piece (excluding the king).
# Returns (NoPiece, -1) if nothing is attacked.  Modifies b temporarily.
function _attacked_enemy(b::Board, m::Move)::Tuple{PieceKind, Int}
    undo    = make_move!(b, m)
    us      = other(b.side)
    them    = b.side
    dst     = to_sq(m)
    occ     = all_occ(b)
    theirs  = b.occ[Int(them)+1]
    atk = let k = b.piece_on[dst+1].kind
        k == Pawn   ? pawn_attacks(dst, us)      :
        k == Knight ? knight_attacks(dst)         :
        k == Bishop ? bishop_attacks(dst, occ)    :
        k == Rook   ? rook_attacks(dst, occ)      :
        k == Queen  ? queen_attacks(dst, occ)     : BB(0)
    end
    best_k = NoPiece; best_sq = -1; best_val = 0
    for s in BitIter(atk & theirs)
        pk = b.piece_on[s+1].kind
        v  = PIECE_VALUE[Int(pk)+1]
        if pk != King && v > best_val
            best_val = v; best_k = pk; best_sq = s
        end
    end
    unmake_move!(b, m, undo)
    (best_k, best_sq)
end

# True if any piece of `defender` attacks `sq`.  Call with board already advanced.
function _is_defended(b::Board, sq::Int, defender::Color)::Bool
    occ = all_occ(b)
    (pawn_attacks(sq, other(defender))  & bb(b, defender, Pawn))                              != 0 && return true
    (knight_attacks(sq)                 & bb(b, defender, Knight))                             != 0 && return true
    (bishop_attacks(sq, occ)            & (bb(b, defender, Bishop) | bb(b, defender, Queen))) != 0 && return true
    (rook_attacks(sq, occ)              & (bb(b, defender, Rook)   | bb(b, defender, Queen))) != 0 && return true
    (king_attacks(sq)                   & bb(b, defender, King))                               != 0 && return true
    false
end

# True when few heavy pieces remain — king should become active.
function _is_endgame(b::Board)::Bool
    mat = 0
    for c in (White, Black)
        mat += PIECE_VALUE[Int(Knight)+1] * count_bits(bb(b, c, Knight))
        mat += PIECE_VALUE[Int(Bishop)+1] * count_bits(bb(b, c, Bishop))
        mat += PIECE_VALUE[Int(Rook)+1]   * count_bits(bb(b, c, Rook))
        mat += PIECE_VALUE[Int(Queen)+1]  * count_bits(bb(b, c, Queen))
    end
    mat <= 2800   # roughly: both sides have ≤ queen + rook combined
end

"""
    explain_move(result, b, my_color) → String

Build a Lichess-chat explanation for the bot's move.
`b` must be the board *before* the move was played.
"""
function explain_move(result::SearchResult, b::Board, my_color::Color)::String
    our_cp  = result.score
    our_san = _approx_san(result.move, b)
    s(x)    = x >= 0 ? "+$(x)" : "$(x)"
    score_note = "($(s(our_cp))cp, depth $(result.depth))"

    isempty(result.pv) &&
        return "I played $our_san. $score_note."

    swing = _pv_material_swing(result.pv, b)

    genuinely_winning = swing >=  90 && our_cp >=  60
    genuinely_losing  = swing <= -90 && our_cp <= -60

    # ── Tactical branch ───────────────────────────────────────────────────────────
    if genuinely_winning || genuinely_losing
        winning = genuinely_winning
        what    = abs(swing) >= 800 ? "the queen" : abs(swing) >= 450 ? "the rook" :
                  abs(swing) >= 270 ? "a piece"   : "a pawn"
        undo = make_move!(b, result.move)
        cont = if length(result.pv) >= 3
            opp_san  = _approx_san(result.pv[2], b)
            undo2    = make_move!(b, result.pv[2])
            our_next = _approx_san(result.pv[3], b)
            unmake_move!(b, result.pv[2], undo2)
            " After $opp_san, I continue with $our_next."
        elseif length(result.pv) >= 2
            " Your best reply is $(_approx_san(result.pv[2], b))."
        else; ""
        end
        unmake_move!(b, result.move, undo)
        if winning
            return "I played $our_san, winning $what.$cont $score_note."
        else
            return "I played $our_san — losing $what, but it's the best I can do.$cont $score_note."
        end
    end

    # ── Positional branch ─────────────────────────────────────────────────────────
    fl     = flags(result.move)
    sgn    = my_color == White ? 1 : -1
    e      = result.eval
    our_fr = from_sq(result.move)
    our_k  = b.piece_on[our_fr+1].kind

    # Compute these before advancing the board.
    atk_k, atk_sq  = _attacked_enemy(b, result.move)
    attacking       = atk_k != NoPiece
    back_rank       = my_color == White ? 0 : 7
    is_dev          = (our_k == Knight || our_k == Bishop) && rank_of(our_fr) == back_rank
    in_check_before = king_in_check(b, my_color)

    # Advance the board.
    undo = make_move!(b, result.move)
    e2   = evaluate(b)
    dst  = to_sq(result.move)

    # ── Position-based detectors (board is advanced here) ─────────────────────────

    # Attack significance: only worth noting when we'd win material (target > attacker)
    # or the target is genuinely undefended.
    attack_worth_noting = false
    if attacking
        our_val = PIECE_VALUE[Int(our_k)+1]
        atk_val = PIECE_VALUE[Int(atk_k)+1]
        attack_worth_noting = atk_val > our_val || !_is_defended(b, atk_sq, other(my_color))
    end

    # Rook: 7th-rank invasion, doubling, open/semi-open file.
    rook_concept = ""
    if our_k == Rook
        seventh = my_color == White ? 6 : 1   # 0-indexed rank of the 7th rank
        f       = file_of(dst)
        my_rooks     = bb(b, my_color, Rook)
        all_pawns    = bb(b, White, Pawn) | bb(b, Black, Pawn)
        my_pawns     = bb(b, my_color, Pawn)
        if count_bits(my_rooks & FILE_MASK[f+1]) >= 2
            rook_concept = "doubles rooks on the $(Char('a'+f))-file"
        elseif count_bits(my_rooks & RANK_MASK[rank_of(dst)+1]) >= 2
            rook_concept = "doubles rooks on the $(rank_of(dst)+1)th rank"
        elseif rank_of(dst) == seventh
            rook_concept = "invades the 7th rank"
        elseif (all_pawns & FILE_MASK[f+1]) == 0
            rook_concept = "takes the open $(Char('a'+f))-file"
        elseif (my_pawns & FILE_MASK[f+1]) == 0
            rook_concept = "takes the semi-open $(Char('a'+f))-file"
        end
    end

    # True outpost: in opponent's half AND no enemy pawn exists on adjacent files
    # at or above the knight's rank (from the enemy's direction) — meaning no pawn
    # can ever advance into a square that attacks the knight.
    # Uses the passed-pawn corridor mask (same file excluded) rather than just
    # checking current pawn attacks, which would miss e.g. c7 threatening c6→d5.
    in_opp_half    = my_color == White ? rank_of(dst) >= 4 : rank_of(dst) <= 3
    knight_outpost = our_k == Knight && in_opp_half && let
        ep    = bb(b, other(my_color), Pawn)
        pmask = (my_color == White ? _PASSED_W[dst+1] : _PASSED_B[dst+1]) &
                ~FILE_MASK[file_of(dst)+1]
        (pmask & ep) == 0
    end

    # Passed pawn creation.
    creates_passed = our_k == Pawn && !is_capture(result.move) && !is_ep(result.move) &&
                     _is_passed(dst, my_color, bb(b, other(my_color), Pawn))

    # Pawn capture opening our own file.
    opens_own_file = false; open_file_char = ' '
    if our_k == Pawn && (is_capture(result.move) || is_ep(result.move))
        src_f = file_of(our_fr)
        if (bb(b, my_color, Pawn) & FILE_MASK[src_f+1]) == 0
            opens_own_file = true; open_file_char = Char('a' + src_f)
        end
    end

    # Central pawn advance (d4/d5/e4/e5).
    pawn_center = our_k == Pawn && !is_capture(result.move) && !is_ep(result.move) &&
                  file_of(dst) in (3, 4) && rank_of(dst) in (3, 4)

    # Endgame flag for king-move labelling.
    endgame = _is_endgame(b)

    # ── Continuation sentence (board is advanced) ─────────────────────────────────
    plan = if fl == MF_KS_CAST || fl == MF_QS_CAST
        ""
    elseif length(result.pv) >= 2
        pv2     = result.pv[2]
        pv2_san = _approx_san(pv2, b)
        if attack_worth_noting
            if to_sq(pv2) == dst && (is_capture(pv2) || is_ep(pv2))
                if length(result.pv) >= 3
                    undo2    = make_move!(b, pv2)
                    our_next = _approx_san(result.pv[3], b)
                    unmake_move!(b, pv2, undo2)
                    " If you take with $pv2_san, I recapture with $our_next."
                else
                    " If you take with $pv2_san, I recapture."
                end
            elseif from_sq(pv2) == atk_sq
                " This forces your $(_piece_name(atk_k)) to $pv2_san."
            else
                if length(result.pv) >= 3
                    undo2    = make_move!(b, pv2)
                    our_next = _approx_san(result.pv[3], b)
                    unmake_move!(b, pv2, undo2)
                    " After $pv2_san, I continue with $our_next."
                else
                    " I expect $pv2_san from you next."
                end
            end
        else
            if length(result.pv) >= 3
                undo2    = make_move!(b, pv2)
                our_next = _approx_san(result.pv[3], b)
                unmake_move!(b, pv2, undo2)
                " After $pv2_san, I plan $our_next."
            else
                " I expect $pv2_san from you next."
            end
        end
    else
        ""
    end

    unmake_move!(b, result.move, undo)

    Δact  = sgn * (e2.piece_activity - e.piece_activity)
    Δpawn = sgn * (e2.pawn_structure - e.pawn_structure)
    Δking = sgn * (e2.king_safety    - e.king_safety)

    # ── Concept label ─────────────────────────────────────────────────────────────
    concept = if fl == MF_KS_CAST
        "castles kingside — king to safety behind the pawn shield"
    elseif fl == MF_QS_CAST
        "castles queenside — king to safety, rook enters the game"
    elseif attack_worth_noting
        "attacks your $(_piece_name(atk_k)) on $(sq_name(atk_sq))"
    elseif !isempty(rook_concept)
        rook_concept
    elseif knight_outpost
        "plants my knight on $(sq_name(dst)) — your pawns can never drive it away"
    elseif creates_passed
        "creates a passed pawn on the $(Char('a' + file_of(dst)))-file"
    elseif opens_own_file
        "opens the $(open_file_char)-file for my rook"
    elseif pawn_center
        "fights for the center"
    elseif is_dev
        "develops my $(_piece_name(our_k))"
    elseif our_k == King
        # King moves must never fall into the generic eval-delta bucket —
        # Δact just reflects PST changes, which is meaningless to say out loud.
        if in_check_before
            "escapes check"
        elseif endgame
            "activates the king for the endgame"
        elseif Δking >= 8
            "improves king safety"
        else
            "repositions the king"
        end
    else
        parts = Tuple{Int,String}[]
        Δact  >=  8 && push!(parts, (Δact,      "improves my piece activity"))
        Δpawn >=  8 && push!(parts, (Δpawn,      "strengthens my pawn structure"))
        Δpawn <= -8 && push!(parts, (abs(Δpawn), "creates a weakness in your pawns"))
        Δking >= 12 && push!(parts, (Δking,      "improves king safety"))
        sort!(parts; by = first, rev = true)
        isempty(parts) ? "keeps the position solid" :
        length(parts) == 1 ? parts[1][2] :
        "$(parts[1][2]) and $(parts[2][2])"
    end

    "I played $our_san — $concept.$plan $score_note."
end

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
