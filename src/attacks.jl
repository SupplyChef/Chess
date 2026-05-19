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
# PAWN_ATTACKS[sq+1, color+1]: which squares does a pawn on `sq` of `color`
# attack?  Stored by square so we can look up "which pawns attack square X?"
# by using the opposite color's index — the key insight behind sq_attacked_by.
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
        # attack to the left, but a naive shift would wrap to file-h.
        pw = BB(0); pb = BB(0)
        if r < 7
            r < 7 && f > 0 && (pw |= sq_bb(sq(f-1, r+1)))
            r < 7 && f < 7 && (pw |= sq_bb(sq(f+1, r+1)))
        end
        if r > 0
            r > 0 && f > 0 && (pb |= sq_bb(sq(f-1, r-1)))
            r > 0 && f < 7 && (pb |= sq_bb(sq(f+1, r-1)))
        end
        PAWN_ATTACKS[s+1, 1] = pw   # White attacks (upward)
        PAWN_ATTACKS[s+1, 2] = pb   # Black attacks (downward)
    end
end

# ── Ray/mask tables ────────────────────────────────────────────────────────────
# Each mask covers all squares on a given line through a given square.
# The hyperbola quintessence formula needs to know which bits to mask in/out
# so that carry propagation stays confined to the relevant ray.

const FILE_MASK  = Vector{BB}(undef, 8)
const RANK_MASK  = Vector{BB}(undef, 8)
# DIAG_MASK[s+1]  = all squares on the NE diagonal (/) through s.
# ADIAG_MASK[s+1] = all squares on the NW diagonal (\) through s.
# Two separate masks are needed because a bishop on d4 sits on both diagonals
# and the formula must be applied to each independently.
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
# The classic o^(o-2r) formula computes attacks for a slider on square r given
# occupancy o, along a single ray direction:
#
#   forward ray:  (o - 2r) ^ o  (masked to the line)
#
# The subtraction propagates a carry through all bits between r and the first
# blocker, setting exactly the squares the slider can reach in the forward
# direction.  To also cover the reverse direction (lower bits), we bit-reverse
# the board, apply the same formula, then bit-reverse back:
#
#   reverse ray:  bitreverse((bitreverse(o) - 2*bitreverse(r)) ^ bitreverse(o))
#
# XOR-ing the two rays gives the full attack set.  Masking with the line mask
# discards carry bits that leaked into other files or ranks.
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
    # Apply the formula separately for each diagonal: the DIAG_MASK covers the
    # NE (/) direction and ADIAG_MASK covers the NW (\) direction.
    @inbounds _slider_attacks(s, occ, DIAG_MASK[s+1]) |
              _slider_attacks(s, occ, ADIAG_MASK[s+1])
end

@inline queen_attacks(s::Square, occ::BB)::BB = rook_attacks(s, occ) | bishop_attacks(s, occ)

@inline knight_attacks(s::Square)::BB = @inbounds KNIGHT_ATTACKS[s+1]
@inline king_attacks(s::Square)::BB   = @inbounds KING_ATTACKS[s+1]
@inline pawn_attacks(s::Square, c::Color)::BB = @inbounds PAWN_ATTACKS[s+1, Int(c)+1]

# ── Attackers-to-square (used for legality + check detection) ─────────────────
# To find all pieces attacking square `sq`, we ask the reverse question: which
# attack patterns originating AT `sq` would reach a piece of each type?
# A knight on sq attacks the same squares as any knight that could attack sq,
# so "knight on sq attacks knight BB" finds all knights that threaten sq.
function attackers_to(b::Board, sq::Square, occ::BB)::BB
    result = BB(0)
    result |= knight_attacks(sq) & (bb(b, White, Knight) | bb(b, Black, Knight))
    result |= king_attacks(sq)   & (bb(b, White, King)   | bb(b, Black, King))
    result |= rook_attacks(sq, occ)   & (bb(b, White, Rook) | bb(b, Black, Rook) |
                                          bb(b, White, Queen) | bb(b, Black, Queen))
    result |= bishop_attacks(sq, occ) & (bb(b, White, Bishop) | bb(b, Black, Bishop) |
                                          bb(b, White, Queen)  | bb(b, Black, Queen))
    # Pawn attack direction is reversed: to find black pawns that attack sq,
    # use the white pawn attack table (which direction a white pawn would attack
    # FROM sq), then intersect with black pawns.
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
        # Use the OTHER color's pawn table so we look in the attacker's direction.
        PAWN_ATTACKS[sq+1, Int(other(a))+1] & bb(b, a, Pawn)
    ) != 0
end

function _init_attacks!()
    _init_masks!()
    _init_nonsliding_attacks!()
end
