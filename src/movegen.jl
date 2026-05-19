# Legal move generator.
#
# Strategy: generate pseudo-legal moves first (fast, no legality check), then
# filter by making each move and testing whether the king is left in check.
# The make/unmake approach is simpler than the alternative (pinned-piece
# analysis + check-evasion logic) and correct for all edge cases including
# discovered checks and en-passant pins.

# ── Make / Unmake ──────────────────────────────────────────────────────────────

struct UndoInfo
    captured_kind::PieceKind
    ep_square::Int
    castling::UInt8
    halfmove::Int
    captured_sq::Int    # differs from to_sq for en-passant
    hash::UInt64
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
    hash_save     = b.hash

    # XOR out the parts of the Zobrist hash that are about to change.
    # Castling rights and en-passant square each have their own Zobrist key
    # because they affect position identity: the same pieces in the same places
    # can be a different position if castling rights differ.
    b.hash ⊻= ZOBRIST_CAST[b.castling + 1]
    ep_sq_save != -1 && (b.hash ⊻= zob_ep(ep_sq_save))

    _remove_piece!(b, us, moving_kind, fr)
    b.hash ⊻= zob_piece(us, moving_kind, fr)

    if fl == MF_EP
        # The captured pawn is NOT on the to-square; it's on the same rank as
        # the moving pawn, one square behind the landing square.
        captured_sq   = to + (us == White ? -8 : 8)
        captured_kind = Pawn
        _remove_piece!(b, them, Pawn, captured_sq)
        b.hash ⊻= zob_piece(them, Pawn, captured_sq)
    elseif (fl & MF_CAPTURE) != 0
        captured_kind = b.piece_on[to+1].kind
        _remove_piece!(b, them, captured_kind, to)
        b.hash ⊻= zob_piece(them, captured_kind, to)
    end

    # On promotion the piece that lands differs from the piece that left.
    place_kind = (fl & MF_PROMO) != 0 ? promo_kind(m) : moving_kind
    _add_piece!(b, us, place_kind, to)
    b.hash ⊻= zob_piece(us, place_kind, to)

    # Castling moves the rook as well; the king's move was handled above.
    if fl == MF_KS_CAST
        rf, rt = us == White ? (H1, F1) : (H8, F8)
        _remove_piece!(b, us, Rook, rf); _add_piece!(b, us, Rook, rt)
        b.hash ⊻= zob_piece(us, Rook, rf) ⊻ zob_piece(us, Rook, rt)
    elseif fl == MF_QS_CAST
        rf, rt = us == White ? (A1, D1) : (A8, D8)
        _remove_piece!(b, us, Rook, rf); _add_piece!(b, us, Rook, rt)
        b.hash ⊻= zob_piece(us, Rook, rf) ⊻ zob_piece(us, Rook, rt)
    end

    # Castling rights are lost when a rook or king moves from its home square.
    # ANDing the pre-computed mask for both from- and to-squares handles rook
    # captures (opponent captures our rook → our right on that side is gone).
    b.castling  &= _castling_mask(fr) & _castling_mask(to)

    # En-passant is only valid immediately after a double pawn push; we record
    # the skipped square so the next position knows which EP capture is legal.
    b.ep_square  = fl == MF_DPUSH ? fr + (us == White ? 8 : -8) : -1
    b.halfmove   = (moving_kind == Pawn || captured_kind != NoPiece) ? 0 : b.halfmove + 1

    # XOR in updated mutable state and flip the side-to-move key.
    b.hash ⊻= ZOBRIST_CAST[b.castling + 1]
    b.ep_square != -1 && (b.hash ⊻= zob_ep(b.ep_square))
    b.hash ⊻= ZOBRIST_SIDE[]

    if us == Black; b.fullmove += 1; end
    b.side = them

    UndoInfo(captured_kind, ep_sq_save, cast_save, hm_save, captured_sq, hash_save)
end

function unmake_move!(b::Board, m::Move, undo::UndoInfo)
    # Restoring the saved hash is safer than re-deriving it — avoids any
    # risk of hash drift from floating-point or ordering differences.
    b.hash      = undo.hash
    b.side      = other(b.side)
    us = b.side; them = other(us)
    fr = from_sq(m); to = to_sq(m); fl = flags(m)

    b.ep_square = undo.ep_square
    b.castling  = undo.castling
    b.halfmove  = undo.halfmove

    moved_kind = b.piece_on[to+1].kind
    _remove_piece!(b, us, moved_kind, to)

    # On promotion the piece on `to` is the promoted piece, not the pawn —
    # restore a pawn, not the promoted piece.
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

# Castling-right loss mask per square: ANDed into b.castling after each move.
# Moving from/to a rook's home square clears that rook's castling right;
# moving from/to a king's home square clears both rights for that color.
# Using a lookup table avoids four conditional branches on every make_move!.
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
# We generate all moves that are structurally valid (correct piece movement,
# no landing on own pieces) but may leave the king in check.  The subsequent
# _filter_legal! pass removes those.  This split is faster than checking
# legality during generation because most positions have no pins or checks.

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
#
# Pawn pushes are computed with bulk bitboard shifts:
#   single push: all pawns shifted one rank forward, masked to empty squares.
#   double push: the single-push result filtered to rank 3 (for white), then
#     shifted one more rank.  Filtering to rank 3 first ensures we only push
#     from the starting rank AND the intermediate square was empty.
# Captures use diagonal shifts masked against opponent pieces, with file-edge
# guards to stop wrap-around (a-file pawns cannot capture to the left).

function _add_promos!(ml, fr, to, capture::Bool)
    # Always generate queen first so it scores highest under MVV-LVA ordering;
    # underpromotions are included because knight promotions sometimes save material.
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

        # Captures: left diagonal = file decreases = shift <<7 from pawn square.
        # ~FILE_MASK[1] masks out the a-file so an a-file pawn cannot "wrap"
        # a left-shift of 7 bits onto the h-file of the rank below.
        cap_l = (pawns & ~FILE_MASK[1]) << 7 & their_occ
        cap_r = (pawns & ~FILE_MASK[8]) << 9 & their_occ
        for to in BitIter(cap_l & ~RANK_MASK[8]); push!(ml, Move(to - 7, to, MF_CAPTURE)); end
        for to in BitIter(cap_r & ~RANK_MASK[8]); push!(ml, Move(to - 9, to, MF_CAPTURE)); end
        for to in BitIter(cap_l &  RANK_MASK[8]); _add_promos!(ml, to - 7, to, true); end
        for to in BitIter(cap_r &  RANK_MASK[8]); _add_promos!(ml, to - 9, to, true); end

        # En-passant: the ep_square is the square the pawn LANDS on (behind the
        # captured pawn), not the captured pawn's square.
        if ep != -1
            ep_bb = sq_bb(ep)
            (pawns & ~FILE_MASK[1]) << 7 & ep_bb != 0 && push!(ml, Move(ep - 7, ep, MF_EP))
            (pawns & ~FILE_MASK[8]) << 9 & ep_bb != 0 && push!(ml, Move(ep - 9, ep, MF_EP))
        end

    else  # Black — all directions are mirrored
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

        # For black: right-shift 7 = lower-right diagonal (file+1, rank-1);
        # guard with ~FILE_MASK[8] (not h-file) to prevent wrap to file-a.
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

    # Castling legality requires three conditions simultaneously:
    #   1. The castling right flag is still set (neither king nor rook has moved).
    #   2. All squares between king and rook are empty (the rook cannot jump).
    #   3. The king does not pass through or land on an attacked square
    #      (the king cannot castle out of, through, or into check).
    # We do NOT check whether the rook is still present — the castling right
    # flag is cleared whenever a rook moves from its home square, which covers
    # the case of a rook being captured as well as moving.
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
# In-place compaction: overwrite illegal moves with the next legal move using
# a write pointer.  Avoids a second allocation and keeps the MoveList self-
# contained.
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

# ─── Capture + promotion generator (for quiescence search) ────────────────────
# Quiescence search only needs captures, en-passant, and promotions — quiet
# moves are ignored because they don't change material and the stand-pat score
# already accounts for them.  Generating only these moves avoids running the
# legality filter over ~25 quiet moves per node that would be discarded anyway.

function _gen_pawn_captures_promos!(ml, b, us, their_occ, empty)
    pawns = bb(b, us, Pawn)
    ep    = b.ep_square

    if us == White
        for to in BitIter((pawns << 8) & empty & RANK_MASK[8])
            _add_promos!(ml, to - 8, to, false)
        end
        cap_l = (pawns & ~FILE_MASK[1]) << 7 & their_occ
        cap_r = (pawns & ~FILE_MASK[8]) << 9 & their_occ
        for to in BitIter(cap_l & ~RANK_MASK[8]); push!(ml, Move(to - 7, to, MF_CAPTURE)); end
        for to in BitIter(cap_r & ~RANK_MASK[8]); push!(ml, Move(to - 9, to, MF_CAPTURE)); end
        for to in BitIter(cap_l &  RANK_MASK[8]); _add_promos!(ml, to - 7, to, true); end
        for to in BitIter(cap_r &  RANK_MASK[8]); _add_promos!(ml, to - 9, to, true); end
        if ep != -1
            ep_bb = sq_bb(ep)
            (pawns & ~FILE_MASK[1]) << 7 & ep_bb != 0 && push!(ml, Move(ep - 7, ep, MF_EP))
            (pawns & ~FILE_MASK[8]) << 9 & ep_bb != 0 && push!(ml, Move(ep - 9, ep, MF_EP))
        end
    else
        for to in BitIter((pawns >> 8) & empty & RANK_MASK[1])
            _add_promos!(ml, to + 8, to, false)
        end
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

function generate_captures!(ml::MoveList, b::Board)
    us = b.side; them = other(us)
    occ       = all_occ(b)
    our_occ   = b.occ[Int(us)+1]
    their_occ = b.occ[Int(them)+1]

    reset!(ml)

    _gen_pawn_captures_promos!(ml, b, us, their_occ, ~occ)

    for fr in BitIter(bb(b, us, Knight))
        for to in BitIter(knight_attacks(fr) & their_occ); push!(ml, Move(fr, to, MF_CAPTURE)); end
    end
    for fr in BitIter(bb(b, us, Bishop))
        for to in BitIter(bishop_attacks(fr, occ) & their_occ); push!(ml, Move(fr, to, MF_CAPTURE)); end
    end
    for fr in BitIter(bb(b, us, Rook))
        for to in BitIter(rook_attacks(fr, occ) & their_occ); push!(ml, Move(fr, to, MF_CAPTURE)); end
    end
    for fr in BitIter(bb(b, us, Queen))
        for to in BitIter(queen_attacks(fr, occ) & their_occ); push!(ml, Move(fr, to, MF_CAPTURE)); end
    end
    ks = lsb(bb(b, us, King))
    for to in BitIter(king_attacks(ks) & their_occ); push!(ml, Move(ks, to, MF_CAPTURE)); end

    _filter_legal!(ml, b)
end
