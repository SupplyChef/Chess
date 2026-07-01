# kpk.jl — King + Pawn vs King endgame bitbase.
#
# A perfect (retrograde-analysis) tablebase for the 3-man KPK ending: every
# legal (white-king, black-king, white-pawn, side-to-move) tuple is classified
# as WIN (the pawn side can force promotion with best play) or DRAW/INVALID.
# Built once at module init time and queried in O(1) thereafter.
#
# Encoding always assumes White holds the pawn; callers with Black holding the
# pawn must vertically mirror the position before probing (see kpk.jl callers
# in search.jl).
#
#   stm ∈ {0,1}   0 = White to move, 1 = Black to move
#   wk  ∈ 0..63   white king square
#   bk  ∈ 0..63   black king square
#   ps  ∈ 8..55   white pawn square (ranks 2..7, 0-indexed ranks 1..6)
#
# index = stm·(64·64·48) + bk·(64·48) + wk·48 + (ps − 8)
# Total positions: 2 × 64 × 64 × 48 = 393 216.  Stored as 1 bit per position
# (set ⇔ WIN), i.e. 6 144 UInt64 words ≈ 48 KiB.

const KPK_TOTAL  = 2 * 64 * 64 * 48
const KPK_WORDS  = (KPK_TOTAL + 63) >> 6
const _KPK_BITS  = zeros(UInt64, KPK_WORDS)

@inline kpk_index(stm::Int, wk::Int, bk::Int, ps::Int)::Int =
    stm * (64 * 64 * 48) + bk * (64 * 48) + wk * 48 + (ps - 8)

"""
    kpk_is_win(stm, wk, bk, ps) -> Bool

Look up whether the side with the pawn (always encoded as White) wins the
position with best play, given `stm` (0=White,1=Black to move), white king
square `wk`, black king square `bk`, and white pawn square `ps` (8..55).
"""
@inline function kpk_is_win(stm::Int, wk::Int, bk::Int, ps::Int)::Bool
    i = kpk_index(stm, wk, bk, ps)
    (@inbounds _KPK_BITS[(i >> 6) + 1] >> (i & 63)) & 0x1 != 0
end

# ── Construction (retrograde analysis) ────────────────────────────────────────
# Classification values used only during the build pass (not stored long-term).
const _KPK_INVALID = 0x0   # illegal position (never reached by legal play)
const _KPK_UNKNOWN = 0x1   # not yet classified
const _KPK_DRAW    = 0x2
const _KPK_WIN     = 0x4

const _KING_DXDY = ((-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1))

@inline _kpk_cdist(f1::Int, r1::Int, f2::Int, r2::Int)::Int =
    max(abs(f1 - f2), abs(r1 - r2))

# White pawn on `ps` attacks `ps+7` (left diag, needs file>0) and `ps+9`
# (right diag, needs file<7) — i.e. the squares one rank ahead, diagonally.
@inline function _kpk_pawn_attacks(ps::Int, psf::Int, target::Int)::Bool
    (psf > 0 && ps + 7 == target) || (psf < 7 && ps + 9 == target)
end

function _kpk_seed!(db::Vector{UInt8})
    for stm in 0:1, wk in 0:63, bk in 0:63, ps in 8:55
        idx = kpk_index(stm, wk, bk, ps) + 1
        wkf = wk & 7;  wkr = wk >> 3
        bkf = bk & 7;  bkr = bk >> 3
        psf = ps & 7;  psr = ps >> 3

        if wk == bk || wk == ps || bk == ps
            db[idx] = _KPK_INVALID; continue
        end
        # Kings can never be adjacent in any legal position (whoever just
        # moved would have left their own king in check).
        if _kpk_cdist(wkf, wkr, bkf, bkr) <= 1
            db[idx] = _KPK_INVALID; continue
        end

        if stm == 0   # White to move: Black king must not be in check
            if _kpk_pawn_attacks(ps, psf, bk)
                db[idx] = _KPK_INVALID; continue
            end
            # Immediate win: pawn on rank 7 can push to rank 8 safely.
            if psr == 6
                promo = ps + 8
                if promo != wk && promo != bk
                    pf = promo & 7; pr = promo >> 3
                    bk_adj = _kpk_cdist(bkf, bkr, pf, pr) <= 1
                    wk_adj = _kpk_cdist(wkf, wkr, pf, pr) <= 1
                    # Safe to promote unless Black king can capture the new
                    # queen and White's king isn't there to defend it.
                    if !bk_adj || wk_adj
                        db[idx] = _KPK_WIN
                    end
                end
            end
        else          # Black to move: stalemate or forced pawn capture → draw
            has_move = false
            can_capture = false
            for (df, dr) in _KING_DXDY
                nf = bkf + df; nr = bkr + dr
                (0 <= nf <= 7 && 0 <= nr <= 7) || continue
                ns = nr * 8 + nf
                ns == wk && continue
                _kpk_cdist(wkf, wkr, nf, nr) <= 1 && continue   # into check
                if ns == ps
                    if !(_kpk_cdist(wkf, wkr, psf, psr) <= 1)   # wk defends ps?
                        can_capture = true
                        has_move = true
                    end
                    continue
                end
                _kpk_pawn_attacks(ps, psf, ns) && continue       # into check
                has_move = true
            end
            (!has_move || can_capture) && (db[idx] = _KPK_DRAW)
        end
    end
end

function _kpk_iterate!(db::Vector{UInt8})
    changed = true
    while changed
        changed = false
        for stm in 0:1, wk in 0:63, bk in 0:63, ps in 8:55
            idx = kpk_index(stm, wk, bk, ps) + 1
            db[idx] != _KPK_UNKNOWN && continue

            wkf = wk & 7;  wkr = wk >> 3
            bkf = bk & 7;  bkr = bk >> 3
            psf = ps & 7;  psr = ps >> 3
            r = UInt8(0)

            if stm == 0   # White to move: wins if any move wins
                for (df, dr) in _KING_DXDY
                    nf = wkf + df; nr = wkr + dr
                    (0 <= nf <= 7 && 0 <= nr <= 7) || continue
                    ns = nr * 8 + nf
                    ns == ps && continue
                    _kpk_cdist(bkf, bkr, nf, nr) <= 1 && continue
                    r |= @inbounds db[kpk_index(1, ns, bk, ps) + 1]
                end
                if psr < 6
                    push1 = ps + 8
                    if push1 != wk && push1 != bk
                        r |= @inbounds db[kpk_index(1, wk, bk, push1) + 1]
                        if psr == 1
                            push2 = ps + 16
                            if push2 != wk && push2 != bk
                                r |= @inbounds db[kpk_index(1, wk, bk, push2) + 1]
                            end
                        end
                    end
                end
                # psr == 6 is fully resolved during seeding (WIN or UNKNOWN);
                # no further push is possible (rank 8 is outside the table).

                if r & _KPK_WIN != 0
                    db[idx] = _KPK_WIN; changed = true
                elseif r & _KPK_UNKNOWN == 0
                    db[idx] = _KPK_DRAW; changed = true   # incl. stalemate (r==0)
                end

            else          # Black to move: draws if any move draws
                for (df, dr) in _KING_DXDY
                    nf = bkf + df; nr = bkr + dr
                    (0 <= nf <= 7 && 0 <= nr <= 7) || continue
                    ns = nr * 8 + nf
                    ns == wk && continue
                    _kpk_cdist(wkf, wkr, nf, nr) <= 1 && continue
                    ns == ps && continue                   # capture: resolved in seeding
                    _kpk_pawn_attacks(ps, psf, ns) && continue
                    r |= @inbounds db[kpk_index(0, wk, ns, ps) + 1]
                end

                if r & _KPK_DRAW != 0
                    db[idx] = _KPK_DRAW; changed = true
                elseif r & _KPK_UNKNOWN == 0 && r != 0
                    db[idx] = _KPK_WIN; changed = true
                end
            end
        end
    end
end

function _init_kpk!()
    db = fill(_KPK_UNKNOWN, KPK_TOTAL)
    _kpk_seed!(db)
    _kpk_iterate!(db)

    fill!(_KPK_BITS, UInt64(0))
    @inbounds for i in 0:(KPK_TOTAL - 1)
        if db[i + 1] == _KPK_WIN
            _KPK_BITS[(i >> 6) + 1] |= UInt64(1) << (i & 63)
        end
    end
end

# ── Board-level probe ──────────────────────────────────────────────────────────
"""
    kpk_probe_wdl(b::Board) -> Union{Int, Nothing}

If `b` is a 3-man King+Pawn vs King position, returns `WDL_WIN`, `WDL_DRAW`,
or `WDL_LOSS` from the side-to-move's perspective using the KPK bitbase.
Returns `nothing` for any other material configuration.
"""
function kpk_probe_wdl(b::Board)::Union{Int, Nothing}
    count_bits(all_occ(b)) == 3 || return nothing
    (bb(b, White, Knight) | bb(b, White, Bishop) | bb(b, White, Rook) | bb(b, White, Queen) |
     bb(b, Black, Knight) | bb(b, Black, Bishop) | bb(b, Black, Rook) | bb(b, Black, Queen)) != 0 &&
        return nothing

    wp = bb(b, White, Pawn)
    bp = bb(b, Black, Pawn)
    count_bits(wp) + count_bits(bp) == 1 || return nothing

    if wp != BB(0)
        wk  = lsb(bb(b, White, King))
        bk  = lsb(bb(b, Black, King))
        ps  = lsb(wp)
        stm = b.side == White ? 0 : 1
        win = kpk_is_win(stm, wk, bk, ps)
        stm_has_pawn = b.side == White
        return win ? (stm_has_pawn ? WDL_WIN : WDL_LOSS) :
                     (stm_has_pawn ? WDL_DRAW : WDL_DRAW)
    else
        # Black holds the pawn: mirror vertically (rank r -> 7-r, file fixed)
        # so the pawn side becomes "White" in the bitbase's encoding.
        flip(s::Int) = (7 - (s >> 3)) * 8 + (s & 7)
        wk  = flip(lsb(bb(b, Black, King)))
        bk  = flip(lsb(bb(b, White, King)))
        ps  = flip(lsb(bp))
        stm = b.side == Black ? 0 : 1
        win = kpk_is_win(stm, wk, bk, ps)
        stm_has_pawn = b.side == Black
        return win ? (stm_has_pawn ? WDL_WIN : WDL_LOSS) :
                     (stm_has_pawn ? WDL_DRAW : WDL_DRAW)
    end
end
