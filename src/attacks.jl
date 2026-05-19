# Pre-computed attack tables for all piece types.
#
# Non-sliding pieces (knight, king, pawn) have fixed attack sets that depend
# only on the source square, so we compute them once at startup and store them
# in plain lookup tables.
#
# Sliding pieces (bishop, rook, queen) have attacks that depend on which
# squares are occupied — a rook on e1 is blocked by a piece on e4.  We use
# the "hyperbola quintessence" technique (see below) rather than magic
# bitboards; it costs two extra arithmetic ops per ray but needs no large
# magic table, keeping memory usage small.

# ── Non-sliding attack tables (generated at module load) ─────────────────────

const KNIGHT_ATTACKS = Vector{BB}(undef, 64)
const KING_ATTACKS   = Vector{BB}(undef, 64)

# PAWN_ATTACKS[sq+1, color+1]: which squares does a pawn of the given color
# attack FROM sq?  Storing by source square lets us answer "which pawns attack
# target X?" by looking up the OPPOSITE color's entry at X — since A attacks B
# iff B would attack A from the same table.  This symmetry is why
# sq_attacked_by uses the opponent's pawn table index.
const PAWN_ATTACKS   = Matrix{BB}(undef, 64, 2)   # [sq, color+1]

function _init_nonsliding_attacks!()
    for s in 0:63
        b = sq_bb(s)
        f, r = file_of(s), rank_of(s)

        # Knight
        ka = BB(0)
        for (df, dr) in ((-2,-1),(-2,1),(-1,-2),(-1,2),(1,-2),(1,2),(2,-1),(2,1))
            ff, rr = f+df, r+dr
            if 0 <= ff <= 7 && 0 <= rr <= 7
                ka |= sq_bb(sq(ff, rr))
            end
        end
        KNIGHT_ATTACKS[s+1] = ka

        # King
        kg = BB(0)
        for (df, dr) in ((-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1))
            ff, rr = f+df, r+dr
            if 0 <= ff <= 7 && 0 <= rr <= 7
                kg |= sq_bb(sq(ff, rr))
            end
        end
        KING_ATTACKS[s+1] = kg

        # Pawn attacks: white pawns attack diagonally forward (rank+1),
        # black pawns attack diagonally backward (rank-1).
        # File-edge guards prevent wrap-around: a pawn on file-a cannot
        # attack to the left, but a naive bit shift would wrap to file-h.
        pw = BB(0); pb = BB(0)
        if r < 7
            r < 7 && f > 0 && (pw |= sq_bb(sq(f-1, r+1)))
            r < 7 && f < 7 && (pw |= sq_bb(sq(f+1, r+1)))
        end
        if r > 0
            r > 0 && f > 0 && (pb |= sq_bb(sq(f-1, r-1)))
            r > 0 && f < 7 && (pb |= sq_bb(sq(f+1, r-1)))
        end
        PAWN_ATTACKS[s+1, 1] = pw   # White attacks upward (toward rank 8)
        PAWN_ATTACKS[s+1, 2] = pb   # Black attacks downward (toward rank 1)
    end
end

# ── Ray/mask tables ────────────────────────────────────────────────────────────
# Each mask isolates all squares on a given line (file, rank, or diagonal)
# through a given square.  The hyperbola quintessence formula relies on carry
# propagation staying within the line; the mask discards any bits that leaked
# into neighboring files or ranks during the subtract step.

const FILE_MASK  = Vector{BB}(undef, 8)
const RANK_MASK  = Vector{BB}(undef, 8)

# DIAG_MASK[s+1]  = all squares on the NE (/) diagonal through s.
# ADIAG_MASK[s+1] = all squares on the NW (\) anti-diagonal through s.
# Two separate masks are needed because a bishop sits on both diagonals
# simultaneously and the formula must be applied to each independently;
# mixing both diagonals in one mask would let carries jump between them.
const DIAG_MASK  = Vector{BB}(undef, 64)
const ADIAG_MASK = Vector{BB}(undef, 64)

function _init_masks!()
    for f in 0:7
        m = BB(0)
        for r in 0:7; m |= sq_bb(sq(f,r)); end
        FILE_MASK[f+1] = m
    end
    for r in 0:7
        m = BB(0)
        for f in 0:7; m |= sq_bb(sq(f,r)); end
        RANK_MASK[r+1] = m
    end
    for s in 0:63
        f, r = file_of(s), rank_of(s)
        dm = BB(0); adm = BB(0)
        for d in -7:7
            ff = f+d; rr = r+d
            0 <= ff <= 7 && 0 <= rr <= 7 && (dm |= sq_bb(sq(ff,rr)))
            ff2 = f-d; rr2 = r+d
            0 <= ff2 <= 7 && 0 <= rr2 <= 7 && (adm |= sq_bb(sq(ff2,rr2)))
        end
        DIAG_MASK[s+1]  = dm
        ADIAG_MASK[s+1] = adm
    end
end

# ── Hyperbola quintessence for sliding attacks ─────────────────────────────────
# The classic o^(o-2r) trick computes the set of squares a slider on square r
# can reach along a single ray, given occupancy bitboard o.
#
# Forward ray (higher-indexed squares):
#   (o & mask) - 2*r   subtracts r from the masked occupancy.  The borrow
#   propagates upward through all empty squares until it hits the first blocker,
#   setting exactly the squares the slider can reach (the blocker itself
#   included — captures are legal).
#   XOR with o then isolates just those newly-flipped bits.
#
# Reverse ray (lower-indexed squares):
#   Bits below the slider are handled by bit-reversing the board, applying the
#   same formula, then bit-reversing the result back.  Bit-reversal maps the
#   lower ray to the upper half of the integer so the subtraction propagates in
#   the right direction.
#
# XOR of forward and reverse gives the full attack set on that line.
# The mask clamp ensures bits that leaked into adjacent files/ranks are removed.
@inline function _slider_attacks(s::Square, occ::BB, mask::BB)::BB
    o = occ & mask
    r = sq_bb(s)
    fwd = (o - (r << 1)) & mask
    rev_o = bitreverse(o)
    rev_r = bitreverse(r)
    rev = bitreverse((rev_o - (rev_r << 1)) & bitreverse(mask))
    fwd ⊻ rev
end

@inline function rook_attacks(s::Square, occ::BB)::BB
    @inbounds _slider_attacks(s, occ, FILE_MASK[file_of(s)+1]) |
              _slider_attacks(s, occ, RANK_MASK[rank_of(s)+1])
end

@inline function bishop_attacks(s::Square, occ::BB)::BB
    # Apply the formula to each diagonal independently: DIAG_MASK (NE, /)
    # and ADIAG_MASK (NW, \).  A queen is just the union of both.
    @inbounds _slider_attacks(s, occ, DIAG_MASK[s+1]) |
              _slider_attacks(s, occ, ADIAG_MASK[s+1])
end

@inline queen_attacks(s::Square, occ::BB)::BB = rook_attacks(s, occ) | bishop_attacks(s, occ)

@inline knight_attacks(s::Square)::BB = @inbounds KNIGHT_ATTACKS[s+1]
@inline king_attacks(s::Square)::BB   = @inbounds KING_ATTACKS[s+1]
@inline pawn_attacks(s::Square, c::Color)::BB = @inbounds PAWN_ATTACKS[s+1, Int(c)+1]

# ── Attackers-to-square (used for legality + check detection) ─────────────────
# To find all pieces attacking square `sq`, we exploit the symmetry of attack
# geometry: X attacks sq  iff  sq would attack X with the same piece type.
# So we "stand on sq" with each piece type and look for pieces of that type
# in the resulting attack set.  One pass covers all piece types at once.
function attackers_to(b::Board, sq::Square, occ::BB)::BB
    result = BB(0)
    result |= knight_attacks(sq) & (bb(b, White, Knight) | bb(b, Black, Knight))
    result |= king_attacks(sq)   & (bb(b, White, King)   | bb(b, Black, King))
    result |= rook_attacks(sq, occ)   & (bb(b, White, Rook) | bb(b, Black, Rook) |
                                          bb(b, White, Queen) | bb(b, Black, Queen))
    result |= bishop_attacks(sq, occ) & (bb(b, White, Bishop) | bb(b, Black, Bishop) |
                                          bb(b, White, Queen)  | bb(b, Black, Queen))
    # Pawn symmetry is directional: to find black pawns that attack sq, we look
    # at which squares a WHITE pawn on sq would attack, then intersect with the
    # black pawn bitboard.  A white pawn on sq attacks upward; the black pawns
    # that attack sq also point downward toward sq — same squares, opposite color.
    result |= PAWN_ATTACKS[sq+1, 1] & bb(b, Black, Pawn)
    result |= PAWN_ATTACKS[sq+1, 2] & bb(b, White, Pawn)
    result
end

@inline function sq_attacked_by(b::Board, sq::Square, attacker::Color, occ::BB)::Bool
    a = attacker
    (
        knight_attacks(sq) & bb(b, a, Knight) |
        king_attacks(sq)   & bb(b, a, King)   |
        rook_attacks(sq, occ)   & (bb(b, a, Rook)   | bb(b, a, Queen)) |
        bishop_attacks(sq, occ) & (bb(b, a, Bishop) | bb(b, a, Queen)) |
        # Use the OTHER color's pawn-attack index so we look in the attacker's
        # forward direction: e.g. to find white pawns attacking sq, use the black
        # pawn table (which looks downward, the direction white pawns come FROM).
        PAWN_ATTACKS[sq+1, Int(other(a))+1] & bb(b, a, Pawn)
    ) != 0
end

function _init_attacks!()
    _init_masks!()
    _init_nonsliding_attacks!()
end
