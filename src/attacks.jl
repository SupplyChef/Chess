# Pre-computed attack tables.
# Sliding piece attacks use the classical "hyperbola quintessence" o^(o-2r) trick
# for rank/file and the same reflected for diagonals. This avoids magic bitboards
# while still being reasonably fast.

# ── Non-sliding attack tables (generated at module load) ─────────────────────

const KNIGHT_ATTACKS = Vector{BB}(undef, 64)
const KING_ATTACKS   = Vector{BB}(undef, 64)
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

        # Pawn attacks
        pw = BB(0); pb = BB(0)
        if r < 7
            r < 7 && f > 0 && (pw |= sq_bb(sq(f-1, r+1)))
            r < 7 && f < 7 && (pw |= sq_bb(sq(f+1, r+1)))
        end
        if r > 0
            r > 0 && f > 0 && (pb |= sq_bb(sq(f-1, r-1)))
            r > 0 && f < 7 && (pb |= sq_bb(sq(f+1, r-1)))
        end
        PAWN_ATTACKS[s+1, 1] = pw   # White attacks
        PAWN_ATTACKS[s+1, 2] = pb   # Black attacks
    end
end

# ── Ray/mask tables ────────────────────────────────────────────────────────────

const FILE_MASK = Vector{BB}(undef, 8)
const RANK_MASK = Vector{BB}(undef, 8)
const DIAG_MASK  = Vector{BB}(undef, 64)   # NE diagonal (/)
const ADIAG_MASK = Vector{BB}(undef, 64)   # NW diagonal (\)

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
# Computes attacks along a ray (mask) for a slider on square s with occupancy o.
@inline function _slider_attacks(s::Square, occ::BB, mask::BB)::BB
    o = occ & mask
    r = sq_bb(s)
    # forward rays (o^(o-2r) masked to the ray)
    fwd = (o - (r << 1)) & mask
    # reverse rays via bit-reversal
    rev_o = bitreverse(o)
    rev_r = bitreverse(r)
    rev = bitreverse((rev_o - (rev_r << 1)) & bitreverse(mask))
    fwd ⊻ rev
end

@inline function rook_attacks(s::Square, occ::BB)::BB
    _slider_attacks(s, occ, FILE_MASK[file_of(s)+1]) |
    _slider_attacks(s, occ, RANK_MASK[rank_of(s)+1])
end

@inline function bishop_attacks(s::Square, occ::BB)::BB
    _slider_attacks(s, occ, DIAG_MASK[s+1]) |
    _slider_attacks(s, occ, ADIAG_MASK[s+1])
end

@inline queen_attacks(s::Square, occ::BB)::BB = rook_attacks(s, occ) | bishop_attacks(s, occ)

@inline knight_attacks(s::Square)::BB = KNIGHT_ATTACKS[s+1]
@inline king_attacks(s::Square)::BB   = KING_ATTACKS[s+1]
@inline pawn_attacks(s::Square, c::Color)::BB = PAWN_ATTACKS[s+1, Int(c)+1]

# ── Attackers-to-square (used for legality + check detection) ─────────────────
function attackers_to(b::Board, sq::Square, occ::BB)::BB
    result = BB(0)
    result |= knight_attacks(sq) & (bb(b, White, Knight) | bb(b, Black, Knight))
    result |= king_attacks(sq)   & (bb(b, White, King)   | bb(b, Black, King))
    result |= rook_attacks(sq, occ)   & (bb(b, White, Rook) | bb(b, Black, Rook) |
                                          bb(b, White, Queen) | bb(b, Black, Queen))
    result |= bishop_attacks(sq, occ) & (bb(b, White, Bishop) | bb(b, Black, Bishop) |
                                          bb(b, White, Queen)  | bb(b, Black, Queen))
    result |= PAWN_ATTACKS[sq+1, 1] & bb(b, Black, Pawn)   # white-direction attacks → black pawn
    result |= PAWN_ATTACKS[sq+1, 2] & bb(b, White, Pawn)   # black-direction attacks → white pawn
    result
end

@inline function sq_attacked_by(b::Board, sq::Square, attacker::Color, occ::BB)::Bool
    a = attacker
    sq_bb(sq) & (
        knight_attacks(sq) & bb(b, a, Knight) |
        king_attacks(sq)   & bb(b, a, King)   |
        rook_attacks(sq, occ)   & (bb(b, a, Rook)   | bb(b, a, Queen)) |
        bishop_attacks(sq, occ) & (bb(b, a, Bishop) | bb(b, a, Queen)) |
        PAWN_ATTACKS[sq+1, Int(other(a))+1] & bb(b, a, Pawn)
    ) != 0
end

function _init_attacks!()
    _init_masks!()
    _init_nonsliding_attacks!()
end
