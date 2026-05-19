# Move explanation: tactical (concrete line) vs positional (concept deltas).
# Coaching mode compares the opponent's actual move to the engine's choice.

function _san_sym(k::PieceKind)::String
    k == Knight ? "N" : k == Bishop ? "B" : k == Rook ? "R" :
    k == Queen  ? "Q" : k == King   ? "K" : ""
end

function _approx_san(m::Move, b::Board)::String
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

# Format up to max_moves PV moves in approximate SAN. Modifies b temporarily.
function _format_pv_line(pv::Vector{Move}, b::Board; max_moves::Int = 6)::String
    isempty(pv) && return ""
    parts = String[]
    undos = UndoInfo[]
    for m in pv[1:min(length(pv), max_moves)]
        push!(parts, _approx_san(m, b))
        push!(undos, make_move!(b, m))
    end
    for i in length(undos):-1:1; unmake_move!(b, pv[i], undos[i]); end
    join(parts, " ")
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
function _eval_phrase(bot_cp::Int)::String
    if     bot_cp >=  300; "I have a decisive advantage"
    elseif bot_cp >=  100; "I'm clearly better"
    elseif bot_cp >=   50; "I'm slightly better"
    elseif bot_cp >=  -49; "it's roughly equal"
    elseif bot_cp >= -100; "you're slightly better"
    elseif bot_cp >= -300; "you have a clear advantage"
    else;                  "you have a decisive advantage"
    end
end

"""
    explain_move(result, b, my_color) → String

Build a Lichess-chat explanation for the bot's move.
- Tactical (PV swings ≥1 pawn): names the gain/loss and shows the key follow-up.
- Positional (quiet PV): describes the main concept and the planned continuation.
`b` must be the board *before* the move was played.
"""
function explain_move(result::SearchResult, b::Board, my_color::Color)::String
    e       = result.eval
    sgn     = my_color == White ? 1 : -1
    bot_cp  = sgn * total(e)
    our_san = _approx_san(result.move, b)
    ep      = _eval_phrase(bot_cp)
    score_note = "($(bot_cp)cp, depth $(result.depth))"

    isempty(result.pv) &&
        return "I played $our_san. $(uppercasefirst(ep)) $score_note."

    swing = _pv_material_swing(result.pv, b)

    if abs(swing) >= 90
        winning = swing > 0
        what    = abs(swing) >= 800 ? "the queen" : abs(swing) >= 450 ? "the rook" :
                  abs(swing) >= 270 ? "a piece" : "a pawn"

        # Build a continuation sentence: "After Nxe5, I recapture with Bxe5."
        undo = make_move!(b, result.move)
        cont = if length(result.pv) >= 3
            opp_san  = _approx_san(result.pv[2], b)
            undo2    = make_move!(b, result.pv[2])
            our_next = _approx_san(result.pv[3], b)
            unmake_move!(b, result.pv[2], undo2)
            " After $opp_san, I continue with $our_next."
        elseif length(result.pv) >= 2
            opp_san = _approx_san(result.pv[2], b)
            " Your best reply is $opp_san."
        else
            ""
        end
        unmake_move!(b, result.move, undo)

        if winning
            return "I played $our_san, winning $what.$cont $(uppercasefirst(ep)) $score_note."
        else
            return "I played $our_san — losing $what, but it's the best I can do.$cont $(uppercasefirst(ep)) $score_note."
        end
    else
        # Positional: describe the main concept, then give the planned line.
        undo = make_move!(b, result.move)
        e2   = evaluate(b)

        # Show opponent's expected reply and our follow-up (pv[2] and pv[3]).
        plan = if length(result.pv) >= 3
            opp_san  = _approx_san(result.pv[2], b)
            undo2    = make_move!(b, result.pv[2])
            our_next = _approx_san(result.pv[3], b)
            unmake_move!(b, result.pv[2], undo2)
            " If you play $opp_san, I'm planning $our_next."
        elseif length(result.pv) >= 2
            opp_san = _approx_san(result.pv[2], b)
            " I expect $opp_san from you next."
        else
            ""
        end
        unmake_move!(b, result.move, undo)

        Δact  = sgn * (e2.piece_activity - e.piece_activity)
        Δpawn = sgn * (e2.pawn_structure - e.pawn_structure)
        Δking = sgn * (e2.king_safety    - e.king_safety)

        # Pick the two most significant concepts, largest first.
        concepts = Tuple{Int,String}[]
        abs(Δact)  >= 5 && push!(concepts, (abs(Δact),
            Δact  > 0 ? "activates my pieces"     : "concedes some activity"))
        abs(Δpawn) >= 5 && push!(concepts, (abs(Δpawn),
            Δpawn > 0 ? "strengthens my pawns"     : "weakens my pawn structure"))
        abs(Δking) >= 5 && push!(concepts, (abs(Δking),
            Δking > 0 ? "improves my king safety"  : "targets your king"))
        sort!(concepts; by = first, rev = true)

        concept = isempty(concepts) ? "a solid developing move" :
                  length(concepts) == 1 ? concepts[1][2] :
                  "$(concepts[1][2]) and $(concepts[2][2])"

        return "I played $our_san — $concept.$plan $(uppercasefirst(ep)) $score_note."
    end
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

    # Show the engine's preferred move and, if available, the follow-up reply.
    undo      = make_move!(b_before, engine_result.move)
    reply_str = length(engine_result.pv) >= 2 ?
                ", after which I'd play $(_approx_san(engine_result.pv[2], b_before))" : ""
    unmake_move!(b_before, engine_result.move, undo)

    "As your coach: I'd have played $engine_san there$reply_str. " *
    "Let's see how $opp_san works out. [depth $(engine_result.depth)]"
end
