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

"""
    explain_move(result, b, my_color) → String

Build a Lichess-chat explanation for the bot's move.
- Tactical (PV swings ≥1 pawn of material): shows concrete line.
- Positional (quiet PV): shows concept deltas from EvalBreakdown.
`b` must be the board *before* the move was played.
"""
function explain_move(result::SearchResult, b::Board, my_color::Color)::String
    e      = result.eval
    sgn    = my_color == White ? 1 : -1
    bot_cp = sgn * total(e)
    s(x)   = x >= 0 ? "+$x" : "$x"
    outlook = bot_cp > 50 ? "I'm better" : bot_cp < -50 ? "you're better" : "roughly equal"

    isempty(result.pv) &&
        return "$(s(bot_cp))cp ($outlook) [d=$(result.depth)]"

    swing  = _pv_material_swing(result.pv, b)
    pv_str = _format_pv_line(result.pv, b)

    if abs(swing) >= 90
        winning = sgn * swing > 0
        verb    = winning ? "winning" : "losing"
        what    = abs(swing) >= 800 ? "a queen" : abs(swing) >= 450 ? "a rook" :
                  abs(swing) >= 270 ? "a piece" : "a pawn"
        return "$(s(bot_cp))cp ($verb $what): $pv_str [d=$(result.depth)]"
    else
        # Positional: compute eval delta after our move.
        undo = make_move!(b, result.move)
        e2   = evaluate(b)
        unmake_move!(b, result.move, undo)

        Δact  = sgn * (e2.piece_activity - e.piece_activity)
        Δpawn = sgn * (e2.pawn_structure - e.pawn_structure)
        Δking = sgn * (e2.king_safety    - e.king_safety)

        parts = String[]
        abs(Δact)  >= 5 && push!(parts, "activity $(s(Δact))")
        abs(Δpawn) >= 5 && push!(parts, "pawns $(s(Δpawn))")
        abs(Δking) >= 5 && push!(parts, "king $(s(Δking))")

        desc = isempty(parts) ? outlook : join(parts, ", ")
        return "$(s(bot_cp))cp ($desc): $pv_str [d=$(result.depth)]"
    end
end

"""
    explain_opponent_move(b_before, opp_move, engine_result) → String

Coaching mode: compare opponent's actual move to what the engine would play.
`b_before` is the position *before* the opponent moved.
Returns "" if there's nothing useful to say.
"""
function explain_opponent_move(b_before::Board, opp_move::Move,
                               engine_result::SearchResult)::String
    engine_result.move == NULL_MOVE && return ""
    opp_uci    = move_to_uci(opp_move)
    engine_uci = move_to_uci(engine_result.move)

    opp_move == engine_result.move &&
        return "Good move! $opp_uci is what I'd play here."

    pv_str = isempty(engine_result.pv) ? engine_uci :
             _format_pv_line(engine_result.pv, b_before)
    "I expected $pv_str here. Watching how $opp_uci goes… [d=$(engine_result.depth)]"
end
