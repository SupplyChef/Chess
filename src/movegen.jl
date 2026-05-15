# Legal move generator.
# Strategy: generate pseudo-legal moves, then filter by checking that the king
# is not left in check. Make/unmake is used for the legality test.

# ── Make / Unmake ──────────────────────────────────────────────────────────────

struct UndoInfo
    captured_kind::PieceKind
    ep_square::Int
    castling::UInt8
    halfmove::Int
    captured_sq::Int    # differs from to_sq for en-passant
end

function make_move!(b::Board, m::Move)::UndoInfo
    fr = from_sq(m); to = to_sq(m); fl = flags(m)
    us = b.side; them = other(us)
    moving_kind = b.piece_on[fr+1].kind

    captured_kind = NoPiece
    captured_sq   = to
    ep_sq_save    = b.ep_square
    cast_save     = b.castling
    hm_save       = b.halfmove

    _remove_piece!(b, us, moving_kind, fr)

    if fl == MF_EP
        captured_sq   = to + (us == White ? -8 : 8)
        captured_kind = Pawn
        _remove_piece!(b, them, Pawn, captured_sq)
    elseif (fl & MF_CAPTURE) != 0
        captured_kind = b.piece_on[to+1].kind
        _remove_piece!(b, them, captured_kind, to)
    end

    place_kind = (fl & MF_PROMO) != 0 ? promo_kind(m) : moving_kind
    _add_piece!(b, us, place_kind, to)

    if fl == MF_KS_CAST
        rf, rt = us == White ? (H1, F1) : (H8, F8)
        _remove_piece!(b, us, Rook, rf); _add_piece!(b, us, Rook, rt)
    elseif fl == MF_QS_CAST
        rf, rt = us == White ? (A1, D1) : (A8, D8)
        _remove_piece!(b, us, Rook, rf); _add_piece!(b, us, Rook, rt)
    end

    b.castling  &= _castling_mask(fr) & _castling_mask(to)
    b.ep_square  = fl == MF_DPUSH ? fr + (us == White ? 8 : -8) : -1
    b.halfmove   = (moving_kind == Pawn || captured_kind != NoPiece) ? 0 : b.halfmove + 1

    if us == Black; b.fullmove += 1; end
    b.side = them

    UndoInfo(captured_kind, ep_sq_save, cast_save, hm_save, captured_sq)
end

function unmake_move!(b::Board, m::Move, undo::UndoInfo)
    b.side      = other(b.side)
    us = b.side; them = other(us)
    fr = from_sq(m); to = to_sq(m); fl = flags(m)

    b.ep_square = undo.ep_square
    b.castling  = undo.castling
    b.halfmove  = undo.halfmove

    moved_kind = b.piece_on[to+1].kind
    _remove_piece!(b, us, moved_kind, to)

    restore_kind = (fl & MF_PROMO) != 0 ? Pawn : moved_kind
    _add_piece!(b, us, restore_kind, fr)

    if undo.captured_kind != NoPiece
        _add_piece!(b, them, undo.captured_kind, undo.captured_sq)
    end

    if fl == MF_KS_CAST
        rf, rt = us == White ? (H1, F1) : (H8, F8)
        _remove_piece!(b, us, Rook, rt); _add_piece!(b, us, Rook, rf)
    elseif fl == MF_QS_CAST
        rf, rt = us == White ? (A1, D1) : (A8, D8)
        _remove_piece!(b, us, Rook, rt); _add_piece!(b, us, Rook, rf)
    end

    if us == Black; b.fullmove -= 1; end
end

@inline function _remove_piece!(b::Board, c::Color, k::PieceKind, s::Square)
    mask = sq_bb(s)
    b.bb[Int(c)+1, Int(k)] &= ~mask
    b.occ[Int(c)+1]        &= ~mask
    b.piece_on[s+1]         = NO_PIECE
end

@inline function _add_piece!(b::Board, c::Color, k::PieceKind, s::Square)
    mask = sq_bb(s)
    b.bb[Int(c)+1, Int(k)] |= mask
    b.occ[Int(c)+1]        |= mask
    b.piece_on[s+1]         = Piece(c, k)
end

# Castling-right loss mask per square (ANDed into castling after each move).
const _CAST_MASK = fill(UInt8(0xFF), 64)
function _init_castling_masks!()
    _CAST_MASK[A1+1] = ~CR_WQ
    _CAST_MASK[E1+1] = ~(CR_WK | CR_WQ)
    _CAST_MASK[H1+1] = ~CR_WK
    _CAST_MASK[A8+1] = ~CR_BQ
    _CAST_MASK[E8+1] = ~(CR_BK | CR_BQ)
    _CAST_MASK[H8+1] = ~CR_BK
end
@inline _castling_mask(s::Square) = _CAST_MASK[s+1]

# ── Check test ────────────────────────────────────────────────────────────────
@inline function king_in_check(b::Board, c::Color)::Bool
    ks = lsb(bb(b, c, King))
    sq_attacked_by(b, ks, other(c), all_occ(b))
end

# ── Pseudo-legal move generation ───────────────────────────────────────────────

function generate_moves!(ml::MoveList, b::Board)
    us = b.side; them = other(us)
    occ      = all_occ(b)
    our_occ  = b.occ[Int(us)+1]
    their_occ = b.occ[Int(them)+1]
    empty    = ~occ

    reset!(ml)

    _gen_pawn_moves!(ml, b, us, them, their_occ, empty)
    _gen_knight_moves!(ml, b, us, our_occ, their_occ)
    _gen_bishop_moves!(ml, b, us, our_occ, their_occ, occ)
    _gen_rook_moves!(ml, b, us, our_occ, their_occ, occ)
    _gen_queen_moves!(ml, b, us, our_occ, their_occ, occ)
    _gen_king_moves!(ml, b, us, our_occ, their_occ, occ)

    _filter_legal!(ml, b)
end

# ─── Pawn moves ───────────────────────────────────────────────────────────────
# FILE_MASK indices are 1-based: FILE_MASK[1]=file-a, FILE_MASK[8]=file-h.
# RANK_MASK indices are 1-based: RANK_MASK[1]=rank-1 … RANK_MASK[8]=rank-8.

function _add_promos!(ml, fr, to, capture::Bool)
    base = capture ? MF_PRCAP_Q : MF_PROMO_Q
    push!(ml, Move(fr, to, base))
    push!(ml, Move(fr, to, base - 1))   # R
    push!(ml, Move(fr, to, base - 2))   # B
    push!(ml, Move(fr, to, base - 3))   # N
end

function _gen_pawn_moves!(ml, b, us, them, their_occ, empty)
    pawns = bb(b, us, Pawn)
    ep    = b.ep_square

    if us == White
        # Pushes
        single = (pawns << 8) & empty
        double = ((single & RANK_MASK[3]) << 8) & empty

        for to in BitIter(single & ~RANK_MASK[8])
            push!(ml, Move(to - 8, to, MF_QUIET))
        end
        for to in BitIter(double)
            push!(ml, Move(to - 16, to, MF_DPUSH))
        end
        for to in BitIter(single & RANK_MASK[8])
            _add_promos!(ml, to - 8, to, false)
        end

        # Captures (left = file decreases = shift <<7 from pawn square)
        cap_l = (pawns & ~FILE_MASK[1]) << 7 & their_occ
        cap_r = (pawns & ~FILE_MASK[8]) << 9 & their_occ
        for to in BitIter(cap_l & ~RANK_MASK[8]); push!(ml, Move(to - 7, to, MF_CAPTURE)); end
        for to in BitIter(cap_r & ~RANK_MASK[8]); push!(ml, Move(to - 9, to, MF_CAPTURE)); end
        for to in BitIter(cap_l &  RANK_MASK[8]); _add_promos!(ml, to - 7, to, true); end
        for to in BitIter(cap_r &  RANK_MASK[8]); _add_promos!(ml, to - 9, to, true); end

        # En-passant
        if ep != -1
            ep_bb = sq_bb(ep)
            (pawns & ~FILE_MASK[1]) << 7 & ep_bb != 0 && push!(ml, Move(ep - 7, ep, MF_EP))
            (pawns & ~FILE_MASK[8]) << 9 & ep_bb != 0 && push!(ml, Move(ep - 9, ep, MF_EP))
        end

    else  # Black
        single = (pawns >> 8) & empty
        double = ((single & RANK_MASK[6]) >> 8) & empty

        for to in BitIter(single & ~RANK_MASK[1])
            push!(ml, Move(to + 8, to, MF_QUIET))
        end
        for to in BitIter(double)
            push!(ml, Move(to + 16, to, MF_DPUSH))
        end
        for to in BitIter(single & RANK_MASK[1])
            _add_promos!(ml, to + 8, to, false)
        end

        # For black: shifting right 7 = lower-right diagonal (file+1, rank-1)
        # guard: not file-h to avoid wrap when going right
        cap_l = (pawns & ~FILE_MASK[8]) >> 7 & their_occ
        cap_r = (pawns & ~FILE_MASK[1]) >> 9 & their_occ
        for to in BitIter(cap_l & ~RANK_MASK[1]); push!(ml, Move(to + 7, to, MF_CAPTURE)); end
        for to in BitIter(cap_r & ~RANK_MASK[1]); push!(ml, Move(to + 9, to, MF_CAPTURE)); end
        for to in BitIter(cap_l &  RANK_MASK[1]); _add_promos!(ml, to + 7, to, true); end
        for to in BitIter(cap_r &  RANK_MASK[1]); _add_promos!(ml, to + 9, to, true); end

        if ep != -1
            ep_bb = sq_bb(ep)
            (pawns & ~FILE_MASK[8]) >> 7 & ep_bb != 0 && push!(ml, Move(ep + 7, ep, MF_EP))
            (pawns & ~FILE_MASK[1]) >> 9 & ep_bb != 0 && push!(ml, Move(ep + 9, ep, MF_EP))
        end
    end
end

# ─── Piece moves ──────────────────────────────────────────────────────────────

function _gen_knight_moves!(ml, b, us, our_occ, their_occ)
    for fr in BitIter(bb(b, us, Knight))
        atk = knight_attacks(fr) & ~our_occ
        for to in BitIter(atk & their_occ);  push!(ml, Move(fr, to, MF_CAPTURE)); end
        for to in BitIter(atk & ~their_occ); push!(ml, Move(fr, to, MF_QUIET));   end
    end
end

function _gen_bishop_moves!(ml, b, us, our_occ, their_occ, occ)
    for fr in BitIter(bb(b, us, Bishop))
        atk = bishop_attacks(fr, occ) & ~our_occ
        for to in BitIter(atk & their_occ);  push!(ml, Move(fr, to, MF_CAPTURE)); end
        for to in BitIter(atk & ~their_occ); push!(ml, Move(fr, to, MF_QUIET));   end
    end
end

function _gen_rook_moves!(ml, b, us, our_occ, their_occ, occ)
    for fr in BitIter(bb(b, us, Rook))
        atk = rook_attacks(fr, occ) & ~our_occ
        for to in BitIter(atk & their_occ);  push!(ml, Move(fr, to, MF_CAPTURE)); end
        for to in BitIter(atk & ~their_occ); push!(ml, Move(fr, to, MF_QUIET));   end
    end
end

function _gen_queen_moves!(ml, b, us, our_occ, their_occ, occ)
    for fr in BitIter(bb(b, us, Queen))
        atk = queen_attacks(fr, occ) & ~our_occ
        for to in BitIter(atk & their_occ);  push!(ml, Move(fr, to, MF_CAPTURE)); end
        for to in BitIter(atk & ~their_occ); push!(ml, Move(fr, to, MF_QUIET));   end
    end
end

function _gen_king_moves!(ml, b, us, our_occ, their_occ, occ)
    them = other(us)
    ks   = lsb(bb(b, us, King))
    atk  = king_attacks(ks) & ~our_occ
    for to in BitIter(atk & their_occ);  push!(ml, Move(ks, to, MF_CAPTURE)); end
    for to in BitIter(atk & ~their_occ); push!(ml, Move(ks, to, MF_QUIET));   end

    # Castling — squares between king and rook must be empty, king must not pass through check.
    if us == White
        if (b.castling & CR_WK) != 0 &&
           (occ & BB(0x0000000000000060)) == 0 &&
           !sq_attacked_by(b, E1, them, occ) &&
           !sq_attacked_by(b, F1, them, occ) &&
           !sq_attacked_by(b, G1, them, occ)
            push!(ml, Move(E1, G1, MF_KS_CAST))
        end
        if (b.castling & CR_WQ) != 0 &&
           (occ & BB(0x000000000000000E)) == 0 &&
           !sq_attacked_by(b, E1, them, occ) &&
           !sq_attacked_by(b, D1, them, occ) &&
           !sq_attacked_by(b, C1, them, occ)
            push!(ml, Move(E1, C1, MF_QS_CAST))
        end
    else
        if (b.castling & CR_BK) != 0 &&
           (occ & BB(0x6000000000000000)) == 0 &&
           !sq_attacked_by(b, E8, them, occ) &&
           !sq_attacked_by(b, F8, them, occ) &&
           !sq_attacked_by(b, G8, them, occ)
            push!(ml, Move(E8, G8, MF_KS_CAST))
        end
        if (b.castling & CR_BQ) != 0 &&
           (occ & BB(0x0E00000000000000)) == 0 &&
           !sq_attacked_by(b, E8, them, occ) &&
           !sq_attacked_by(b, D8, them, occ) &&
           !sq_attacked_by(b, C8, them, occ)
            push!(ml, Move(E8, C8, MF_QS_CAST))
        end
    end
end

# ─── Legality filter ──────────────────────────────────────────────────────────

function _filter_legal!(ml::MoveList, b::Board)
    us = b.side
    write_idx = 0
    for i in 1:ml.count[]
        m = ml.moves[i]
        undo = make_move!(b, m)
        legal = !king_in_check(b, us)
        unmake_move!(b, m, undo)
        if legal
            write_idx += 1
            ml.moves[write_idx] = m
        end
    end
    ml.count[] = write_idx
end

function count_legal_moves(b::Board)::Int
    ml = MoveList()
    generate_moves!(ml, b)
    length(ml)
end
