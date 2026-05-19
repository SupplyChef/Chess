# Move explanation: tactical (concrete line) vs positional (concept + chess reasoning).
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
# Positive = the side making the first PV move wins material.
# Modifies b temporarily; restored on return.
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

# Plain-English position assessment from the bot's perspective.
function _eval_phrase(cp::Int)::String
    if     cp >=  300; "I have a decisive advantage"
    elseif cp >=  100; "I'm clearly better"
    elseif cp >=   50; "I'm slightly better"
    elseif cp >=  -49; "it's roughly equal"
    elseif cp >= -100; "you're slightly better"
    elseif cp >= -300; "you have a clear advantage"
    else;              "you have a decisive advantage"
    end
end

# After making move m, return the most valuable enemy piece our moved piece now
# attacks (excluding the king). Returns (NoPiece, -1) if nothing is attacked.
# Modifies b temporarily; restored on return.
function _attacked_enemy(b::Board, m::Move)::Tuple{PieceKind, Int}
    undo    = make_move!(b, m)
    us      = other(b.side)   # b.side is now opponent
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

"""
    explain_move(result, b, my_color) → String

Build a Lichess-chat explanation for the bot's move.
- Tactical: shown when AB score confirms a real material change (≥60 cp swing).
- Positional: names the concrete chess objective (open file, outpost, attack, …).
`b` must be the board *before* the move was played.
"""
function explain_move(result::SearchResult, b::Board, my_color::Color)::String
    our_cp  = result.score
    our_san = _approx_san(result.move, b)
    ep      = _eval_phrase(our_cp)
    s(x)    = x >= 0 ? "+$(x)" : "$(x)"
    score_note = "($(s(our_cp))cp, depth $(result.depth))"

    isempty(result.pv) &&
        return "I played $our_san. $(uppercasefirst(ep)) $score_note."

    swing = _pv_material_swing(result.pv, b)

    genuinely_winning = swing >=  90 && our_cp >=  60
    genuinely_losing  = swing <= -90 && our_cp <= -60

    # ── Tactical branch: we win or lose material along the PV ────────────────────
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
        else
            ""
        end
        unmake_move!(b, result.move, undo)

        if winning
            return "I played $our_san, winning $what.$cont $(uppercasefirst(ep)) $score_note."
        else
            return "I played $our_san — losing $what, but it's the best I can do.$cont $(uppercasefirst(ep)) $score_note."
        end
    end

    # ── Positional branch ────────────────────────────────────────────────────────
    fl     = flags(result.move)
    sgn    = my_color == White ? 1 : -1
    e      = result.eval
    our_fr = from_sq(result.move)
    our_k  = b.piece_on[our_fr+1].kind

    # Detect attack on enemy piece (before advancing board).
    atk_k, atk_sq = _attacked_enemy(b, result.move)
    attacking = atk_k != NoPiece

    # First development of a minor piece off the back rank.
    back_rank = my_color == White ? 0 : 7
    is_dev    = (our_k == Knight || our_k == Bishop) && rank_of(our_fr) == back_rank

    # Advance the board to inspect the resulting position.
    undo = make_move!(b, result.move)
    e2   = evaluate(b)
    dst  = to_sq(result.move)

    # Rook on open / semi-open file.
    rook_file_str = ""
    if our_k == Rook
        f         = file_of(dst)
        all_pawns = bb(b, White, Pawn) | bb(b, Black, Pawn)
        my_pawns  = bb(b, my_color, Pawn)
        if (all_pawns & FILE_MASK[f+1]) == 0
            rook_file_str = "takes the open $(Char('a' + f))-file"
        elseif (my_pawns & FILE_MASK[f+1]) == 0
            rook_file_str = "takes the semi-open $(Char('a' + f))-file"
        end
    end

    # Knight outpost: no enemy pawn can ever chase it away from dst.
    # Only label it an outpost when the knight has entered the opponent's half.
    in_opp_half = my_color == White ? rank_of(dst) >= 4 : rank_of(dst) <= 3
    knight_outpost = our_k == Knight && in_opp_half &&
                     (pawn_attacks(dst, my_color) & bb(b, other(my_color), Pawn)) == 0

    # Pawn push that creates a passed pawn.
    creates_passed = our_k == Pawn && !is_capture(result.move) && !is_ep(result.move) &&
                     _is_passed(dst, my_color, bb(b, other(my_color), Pawn))

    # Capture that opens our own file (pawn captures away from its file).
    opens_own_file = false
    open_file_char = ' '
    if our_k == Pawn && (is_capture(result.move) || is_ep(result.move))
        src_f = file_of(our_fr)
        my_pawns_after = bb(b, my_color, Pawn)
        # After the capture our pawn moved to dst_f; check if src_f is now open.
        if (my_pawns_after & FILE_MASK[src_f+1]) == 0
            opens_own_file = true
            open_file_char = Char('a' + src_f)
        end
    end

    # ── Build continuation sentence (board is advanced here) ─────────────────────
    plan = if fl == MF_KS_CAST || fl == MF_QS_CAST
        ""   # self-explanatory, no line needed
    elseif length(result.pv) >= 2
        pv2     = result.pv[2]
        pv2_san = _approx_san(pv2, b)
        if attacking
            if to_sq(pv2) == dst && (is_capture(pv2) || is_ep(pv2))
                # Opponent recaptures our piece.
                if length(result.pv) >= 3
                    undo2    = make_move!(b, pv2)
                    our_next = _approx_san(result.pv[3], b)
                    unmake_move!(b, pv2, undo2)
                    " If you take with $pv2_san, I recapture with $our_next."
                else
                    " If you take with $pv2_san, I recapture."
                end
            elseif from_sq(pv2) == atk_sq
                # Opponent retreats the attacked piece.
                pk_name = _piece_name(atk_k)
                " This forces your $pk_name to $pv2_san."
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

    # ── Pick the most informative concept label ───────────────────────────────────
    concept = if fl == MF_KS_CAST
        "castles kingside — king to safety behind the pawn shield"
    elseif fl == MF_QS_CAST
        "castles queenside — king to safety, rook enters the game"
    elseif attacking
        "attacks your $(_piece_name(atk_k)) on $(sq_name(atk_sq))"
    elseif !isempty(rook_file_str)
        rook_file_str
    elseif knight_outpost
        "plants my knight on $(sq_name(dst)) — your pawns can never drive it away"
    elseif creates_passed
        "creates a passed pawn on the $(Char('a' + file_of(dst)))-file"
    elseif opens_own_file
        "opens the $(open_file_char)-file for my rook"
    elseif is_dev
        "develops my $(_piece_name(our_k))"
    else
        # Eval-delta fallback: translate the largest numerical swing into English.
        parts = Tuple{Int,String}[]
        Δact  >=  8 && push!(parts, (Δact,      "improves my piece activity"))
        Δpawn >=  8 && push!(parts, (Δpawn,      "strengthens my pawn structure"))
        Δpawn <= -8 && push!(parts, (abs(Δpawn), "creates a weakness in your pawns"))
        Δking >= 12 && push!(parts, (Δking,      "improves my king safety"))
        sort!(parts; by = first, rev = true)
        isempty(parts) ? "keeps the position solid" :
        length(parts) == 1 ? parts[1][2] :
        "$(parts[1][2]) and $(parts[2][2])"
    end

    "I played $our_san — $concept.$plan $(uppercasefirst(ep)) $score_note."
end

"""
    explain_opponent_move(b_before, opp_move, engine_result) → String

Coaching mode: compare the opponent's actual move to what the engine would play.
`b_before` is the position *before* the opponent moved.
Returns "" if the move matches the engine choice.
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
