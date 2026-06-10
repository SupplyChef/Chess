using Random
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

# Magic Bitboards
const ROOK_MASKS   = zeros(BB, 64)
const ROOK_MAGICS  = zeros(UInt64, 64)
const ROOK_TABLE   = zeros(BB, 4096, 64)
const ROOK_SHIFT   = 52

const BISHOP_MASKS  = zeros(BB, 64)
const BISHOP_MAGICS = zeros(UInt64, 64)
const BISHOP_TABLE  = zeros(BB, 512, 64)
const BISHOP_SHIFT  = 55

@inline function rook_attacks(s::Square, occ::UInt64)::UInt64
    @inbounds m = ROOK_MASKS[s+1]
    @inbounds magic = ROOK_MAGICS[s+1]
    idx = (UInt64(occ & m) * magic) >> ROOK_SHIFT
    @inbounds ROOK_TABLE[Int(idx) + 1, s+1]
end

@inline function bishop_attacks(s::Square, occ::UInt64)::UInt64
    @inbounds m = BISHOP_MASKS[s+1]
    @inbounds magic = BISHOP_MAGICS[s+1]
    idx = (UInt64(occ & m) * magic) >> BISHOP_SHIFT
    @inbounds BISHOP_TABLE[Int(idx) + 1, s+1]
end

# Flexible integer versions to avoid MethodErrors
@inline rook_attacks(s::Integer, occ::Integer)   = rook_attacks(Int(s), UInt64(occ))
@inline bishop_attacks(s::Integer, occ::Integer) = bishop_attacks(Int(s), UInt64(occ))
@inline queen_attacks(s::Integer, occ::Integer)  = rook_attacks(s, occ) | bishop_attacks(s, occ)

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
    # Use the OTHER color's pawn-attack index so we look in the attacker's
    # forward direction: e.g. to find white pawns attacking sq, use the black
    # pawn table (which looks downward, the direction white pawns come FROM).
    (PAWN_ATTACKS[sq+1, Int(other(a))+1] & bb(b, a, Pawn)) != 0 && return true
    (knight_attacks(sq) & bb(b, a, Knight)) != 0 && return true
    (king_attacks(sq)   & bb(b, a, King))   != 0 && return true

    # Sliders are more expensive (magic bitboard lookups)
    (bishop_attacks(sq, occ) & (bb(b, a, Bishop) | bb(b, a, Queen))) != 0 && return true
    (rook_attacks(sq, occ)   & (bb(b, a, Rook)   | bb(b, a, Queen))) != 0 && return true

    false
end

function _rook_attacks_slow(s::Square, occ::BB)
    f, r = file_of(s), rank_of(s)
    atk = BB(0)
    for (df, dr) in ((0,1), (0,-1), (1,0), (-1,0))
        ff, rr = f+df, r+dr
        while 0 <= ff <= 7 && 0 <= rr <= 7
            target = sq_bb(sq(ff, rr))
            atk |= target
            (occ & target) != 0 && break
            ff += df; rr += dr
        end
    end
    atk
end

function _bishop_attacks_slow(s::Square, occ::BB)
    f, r = file_of(s), rank_of(s)
    atk = BB(0)
    for (df, dr) in ((1,1), (1,-1), (-1,1), (-1,-1))
        ff, rr = f+df, r+dr
        while 0 <= ff <= 7 && 0 <= rr <= 7
            target = sq_bb(sq(ff, rr))
            atk |= target
            (occ & target) != 0 && break
            ff += df; rr += dr
        end
    end
    atk
end

function _rook_mask(s::Square)
    f, r = file_of(s), rank_of(s)
    mask = BB(0)
    for rr in (r+1):6; mask |= sq_bb(sq(f, rr)); end
    for rr in (r-1):-1:1; mask |= sq_bb(sq(f, rr)); end
    for ff in (f+1):6; mask |= sq_bb(sq(ff, r)); end
    for ff in (f-1):-1:1; mask |= sq_bb(sq(ff, r)); end
    mask
end

function _bishop_mask(s::Square)
    f, r = file_of(s), rank_of(s)
    mask = BB(0)
    for d in 1:7
        ff, rr = f+d, r+d
        (ff >= 7 || rr >= 7) && break
        mask |= sq_bb(sq(ff, rr))
    end
    for d in 1:7
        ff, rr = f-d, r+d
        (ff <= 0 || rr >= 7) && break
        mask |= sq_bb(sq(ff, rr))
    end
    for d in 1:7
        ff, rr = f+d, r-d
        (ff >= 7 || rr <= 0) && break
        mask |= sq_bb(sq(ff, rr))
    end
    for d in 1:7
        ff, rr = f-d, r-d
        (ff <= 0 || rr <= 0) && break
        mask |= sq_bb(sq(ff, rr))
    end
    mask
end

function _init_sliding_attacks!()
    Random.seed!(42)
    for s in 0:63
        # Rook
        mask = _rook_mask(s)
        ROOK_MASKS[s+1] = mask
        subsets = BB[]; attacks = BB[]; curr = BB(0)
        while true
            push!(subsets, curr); push!(attacks, _rook_attacks_slow(s, curr))
            curr = (curr - 1) & mask
            curr == 0 && break
        end
        found = false
        for _ in 1:100000
            magic = rand(UInt64) & rand(UInt64) & rand(UInt64)
            fill!(view(ROOK_TABLE, :, s+1), 0)
            fail = false
            for i in 1:length(subsets)
                idx = ((subsets[i] * magic) >> ROOK_SHIFT) + 1
                if ROOK_TABLE[idx, s+1] == 0
                    ROOK_TABLE[idx, s+1] = attacks[i]
                elseif ROOK_TABLE[idx, s+1] != attacks[i]
                    fail = true; break
                end
            end
            if !fail
                ROOK_MAGICS[s+1] = magic
                found = true; break
            end
        end
        !found && error("Failed to find rook magic for square $s")

        # Bishop
        mask = _bishop_mask(s)
        BISHOP_MASKS[s+1] = mask
        subsets = BB[]; attacks = BB[]; curr = BB(0)
        while true
            push!(subsets, curr); push!(attacks, _bishop_attacks_slow(s, curr))
            curr = (curr - 1) & mask
            curr == 0 && break
        end
        found = false
        for _ in 1:100000
            magic = rand(UInt64) & rand(UInt64) & rand(UInt64)
            fill!(view(BISHOP_TABLE, :, s+1), 0)
            fail = false
            for i in 1:length(subsets)
                idx = ((subsets[i] * magic) >> BISHOP_SHIFT) + 1
                if BISHOP_TABLE[idx, s+1] == 0
                    BISHOP_TABLE[idx, s+1] = attacks[i]
                elseif BISHOP_TABLE[idx, s+1] != attacks[i]
                    fail = true; break
                end
            end
            if !fail
                BISHOP_MAGICS[s+1] = magic
                found = true; break
            end
        end
        !found && error("Failed to find bishop magic for square $s")
    end
end

function _init_attacks!()
    _init_masks!()
    _init_nonsliding_attacks!()
    _init_sliding_attacks!()
end
