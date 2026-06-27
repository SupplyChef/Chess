# tune_eval.jl — Position feature extraction for weight tuning.
#
# extract_features(b) computes a length-N_WEIGHTS vector φ such that
#     evaluate_from_weights(b, θ) ≈ dot(θ, φ(b))
# for any weight vector θ.  The eval is linear in θ for all terms except the
# pawn-majority max(0,…) gate (handled by clamping at zero in feature space).
#
# This file deliberately does NOT use the pawn-structure cache (_PAWN_TT) or
# the lazy-eval shortcut, because both assume the current hard-coded weights.

function extract_features(b::Board)::Vector{Float64}
    φ = zeros(Float64, N_WEIGHTS)
    _feat_material!(φ, b)
    ph = Int(clamp(b.phase, 0, 24))
    ph_mg = ph / 24.0
    ph_eg = 1.0 - ph_mg
    _feat_pst!(φ, b, ph_mg, ph_eg)
    _feat_piece_activity!(φ, b, ph)
    _feat_pawn_structure!(φ, b)
    _feat_king_safety!(φ, b, ph)
    _feat_space!(φ, b)
    _feat_tempo!(φ, b)
    _feat_complexity!(φ, b)
    φ
end

# Score a position with an arbitrary weight vector (for validation / reporting).
@inline function score_from_weights(φ::Vector{Float64}, θ::Vector{Float64})::Float64
    dot(φ, θ)
end

# ── Material ───────────────────────────────────────────────────────────────────
function _feat_material!(φ, b)
    for c in (White, Black)
        s = c == White ? 1.0 : -1.0
        φ[1] += s * count_bits(bb(b, c, Pawn))
        φ[2] += s * count_bits(bb(b, c, Knight))
        φ[3] += s * count_bits(bb(b, c, Bishop))
        φ[4] += s * count_bits(bb(b, c, Rook))
        φ[5] += s * count_bits(bb(b, c, Queen))
    end
end

# ── PSTs (tapered) ─────────────────────────────────────────────────────────────
function _feat_pst!(φ, b, ph_mg::Float64, ph_eg::Float64)
    piece_kinds = (Pawn, Knight, Bishop, Rook, Queen, King)
    for (pidx, kind) in enumerate(piece_kinds)
        mg_base = _pst_mg_base(pidx)
        eg_base = _pst_eg_base(pidx)
        for c in (White, Black)
            s = c == White ? 1.0 : -1.0
            for sq in BitIter(bb(b, c, kind))
                pst_j = c == White ? (7 - rank_of(sq)) * 8 + file_of(sq) + 1 :
                                          rank_of(sq)  * 8 + file_of(sq) + 1
                φ[mg_base + pst_j] += s * ph_mg
                φ[eg_base + pst_j] += s * ph_eg
            end
        end
    end
end

# ── Piece activity ─────────────────────────────────────────────────────────────
function _feat_piece_activity!(φ, b, ph::Int)
    occ   = all_occ(b)
    wp    = bb(b, White, Pawn)
    bp    = bb(b, Black, Pawn)
    w_atk = ((wp << 7) & ~FILE_MASK[8]) | ((wp << 9) & ~FILE_MASK[1])
    b_atk = ((bp >> 9) & ~FILE_MASK[8]) | ((bp >> 7) & ~FILE_MASK[1])

    for c in (White, Black)
        s           = c == White ? 1.0 : -1.0
        my_pawns    = bb(b, c, Pawn)
        enemy_pawns = bb(b, other(c), Pawn)
        seventh     = c == White ? 6 : 1

        # Rooks: open file, semi-open, 7th rank
        for sq in BitIter(bb(b, c, Rook))
            f = file_of(sq)
            if ((my_pawns | enemy_pawns) & FILE_MASK[f+1]) == 0
                φ[FEAT_ROOK_OPEN] += s
            elseif (my_pawns & FILE_MASK[f+1]) == 0
                φ[FEAT_ROOK_SEMI] += s
            end
            rank_of(sq) == seventh && (φ[FEAT_ROOK_7TH] += s)
        end

        # Connected rooks
        my_rooks = bb(b, c, Rook)
        if count_bits(my_rooks) >= 2
            seen = BB(0)
            for s1 in BitIter(my_rooks)
                (rook_attacks(s1, occ) & my_rooks & ~seen) != 0 && (φ[FEAT_CONNECTED_ROOKS] += s)
                seen |= sq_bb(s1)
            end
        end

        # Knight outposts
        for sq in BitIter(bb(b, c, Knight))
            in_opp = c == White ? rank_of(sq) >= 4 : rank_of(sq) <= 3
            in_opp || continue
            pawn_sup = (pawn_attacks(sq, other(c)) & bb(b, c, Pawn)) != BB(0)
            pmask    = (c == White ? _PASSED_W[sq+1] : _PASSED_B[sq+1]) & ~FILE_MASK[file_of(sq)+1]
            challenger = pmask & enemy_pawns
            if challenger == 0
                φ[pawn_sup ? FEAT_OUTPOST_FULL_SUP : FEAT_OUTPOST_FULL_FREE] += s
            else
                blocked = c == White ? (challenger & (occ >> 8)) : (challenger & (occ << 8))
                blocked == challenger && (φ[pawn_sup ? FEAT_OUTPOST_SEMI_SUP : FEAT_OUTPOST_SEMI_FREE] += s)
            end
        end

        # Safe invasion (minor pieces in opponent's half, not attacked by enemy pawns)
        for sq in BitIter(bb(b, c, Knight) | bb(b, c, Bishop))
            in_opp = c == White ? rank_of(sq) >= 4 : rank_of(sq) <= 3
            in_opp || continue
            (pawn_attacks(sq, c) & enemy_pawns) == 0 && (φ[FEAT_SAFE_INVASION] += s)
        end
    end

    # Bishop pair (tapered)
    ph_eg_frac = (24 - ph) / 24.0
    for c in (White, Black)
        s = c == White ? 1.0 : -1.0
        if count_bits(bb(b, c, Bishop)) >= 2
            φ[FEAT_BISHOP_PAIR_BASE] += s
            φ[FEAT_BISHOP_PAIR_EG]   += s * ph_eg_frac
        end
    end

    # Mobility + trapped pieces
    for c in (White, Black)
        s        = c == White ? 1.0 : -1.0
        our_occ  = b.occ[Int(c)+1]
        their_atk = c == White ? b_atk : w_atk

        for sq in BitIter(bb(b, c, Knight))
            atk  = knight_attacks(sq) & ~our_occ
            safe = count_bits(atk & ~their_atk)
            φ[FEAT_KNIGHT_MOB] += s * safe
            if safe == 0;     φ[FEAT_KNIGHT_TRAP0] -= s
            elseif safe == 1; φ[FEAT_KNIGHT_TRAP1] -= s
            end
        end
        for sq in BitIter(bb(b, c, Bishop))
            atk  = bishop_attacks(sq, occ) & ~our_occ
            safe = count_bits(atk & ~their_atk)
            φ[FEAT_BISHOP_MOB] += s * safe
            if safe == 0;     φ[FEAT_BISHOP_TRAP0] -= s
            elseif safe == 1; φ[FEAT_BISHOP_TRAP1] -= s
            elseif safe == 2; φ[FEAT_BISHOP_TRAP2] -= s
            elseif safe == 3; φ[FEAT_BISHOP_TRAP3] -= s
            end
        end
        for sq in BitIter(bb(b, c, Rook))
            atk  = rook_attacks(sq, occ) & ~our_occ
            safe = count_bits(atk & ~their_atk)
            φ[FEAT_ROOK_MOB] += s * safe
            if safe == 0;     φ[FEAT_ROOK_TRAP0] -= s
            elseif safe == 1; φ[FEAT_ROOK_TRAP1] -= s
            elseif safe == 2; φ[FEAT_ROOK_TRAP2] -= s
            end
        end
        for sq in BitIter(bb(b, c, Queen))
            atk  = queen_attacks(sq, occ) & ~our_occ
            safe = count_bits(atk & ~their_atk)
            φ[FEAT_QUEEN_MOB] += s * safe
            if safe == 0;                   φ[FEAT_QUEEN_TRAP0]  -= s
            elseif 1 <= safe <= 2;          φ[FEAT_QUEEN_TRAP12] -= s
            end
        end
    end

    # Center control (d4/d5/e4/e5)
    for c in (White, Black)
        s    = c == White ? 1.0 : -1.0
        ctrl = 0
        for cs in (sq(3,3), sq(4,3), sq(3,4), sq(4,4))
            (pawn_attacks(cs, other(c)) & bb(b, c, Pawn))                        != 0 && (ctrl += 1)
            (knight_attacks(cs)         & bb(b, c, Knight))                       != 0 && (ctrl += 1)
            (bishop_attacks(cs, occ)    & (bb(b,c,Bishop)|bb(b,c,Queen)))        != 0 && (ctrl += 1)
            (rook_attacks(cs, occ)      & (bb(b,c,Rook)|bb(b,c,Queen)))          != 0 && (ctrl += 1)
            (king_attacks(cs)           & bb(b, c, King))                         != 0 && (ctrl += 1)
        end
        φ[FEAT_CENTER_CTRL] += s * ctrl
    end

    # Pins: feature = signed sum of pinned-piece-value÷8 (using default piece values)
    for c in (White, Black)
        s        = c == White ? 1.0 : -1.0
        their_k  = lsb(bb(b, other(c), King))
        their_occ = b.occ[Int(other(c))+1]
        for sq in BitIter(bb(b, c, Rook) | bb(b, c, Queen))
            sf = file_of(sq); sr = rank_of(sq)
            kf = file_of(their_k); kr = rank_of(their_k)
            ray = if sf == kf; FILE_MASK[sf+1]
                  elseif sr == kr; RANK_MASK[sr+1]
                  else; continue
                  end
            between = _slider_attacks(sq, sq_bb(their_k), ray) &
                      _slider_attacks(their_k, sq_bb(sq), ray)
            pieces  = between & occ
            if count_bits(pieces) == 1 && (pieces & their_occ) != 0
                kind = b.piece_on[lsb(pieces)+1].kind
                φ[FEAT_PIN_SCALE] += s * PIECE_VALUE[Int(kind)+1] / 8.0
            end
        end
        for sq in BitIter(bb(b, c, Bishop) | bb(b, c, Queen))
            ray = if (DIAG_MASK[sq+1] & sq_bb(their_k)) != 0;  DIAG_MASK[sq+1]
                  elseif (ADIAG_MASK[sq+1] & sq_bb(their_k)) != 0; ADIAG_MASK[sq+1]
                  else; continue
                  end
            between = _slider_attacks(sq, sq_bb(their_k), ray) &
                      _slider_attacks(their_k, sq_bb(sq), ray)
            pieces  = between & occ
            if count_bits(pieces) == 1 && (pieces & their_occ) != 0
                kind = b.piece_on[lsb(pieces)+1].kind
                φ[FEAT_PIN_SCALE] += s * PIECE_VALUE[Int(kind)+1] / 8.0
            end
        end
    end

    # King tropism (endgame only)
    if ph < 20
        eg_weight = Float64(24 - ph)

        # King proximity (asymmetric: bonus for the material-superior side)
        let wk = lsb(bb(b, White, King)), bk = lsb(bb(b, Black, King))
            dist      = _chebyshev(wk, bk)
            prox_feat = (7 - dist) * eg_weight / 12.0
            w_pieces  = count_bits(bb(b, White, Knight) | bb(b, White, Bishop) |
                                   bb(b, White, Rook)   | bb(b, White, Queen))
            b_pieces  = count_bits(bb(b, Black, Knight) | bb(b, Black, Bishop) |
                                   bb(b, Black, Rook)   | bb(b, Black, Queen))
            if w_pieces > b_pieces
                φ[FEAT_TROPISM_KING_PROX] += prox_feat
            elseif b_pieces > w_pieces
                φ[FEAT_TROPISM_KING_PROX] -= prox_feat
            end
        end

        for c in (White, Black)
            s           = c == White ? 1.0 : -1.0
            our_k       = lsb(bb(b, c, King))
            their_k     = lsb(bb(b, other(c), King))
            their_pawns = bb(b, other(c), Pawn)
            our_pawns   = bb(b, c, Pawn)

            for psq in BitIter(our_pawns)
                _is_passed(psq, c, their_pawns) || continue
                φ[FEAT_TROPISM_OWN_PASS] += s * (7 - _chebyshev(our_k, psq)) * eg_weight / 12.0
            end
            for psq in BitIter(their_pawns)
                _is_passed(psq, other(c), our_pawns) || continue
                φ[FEAT_TROPISM_ENE_PASS] += s * (7 - _chebyshev(our_k, psq)) * eg_weight / 12.0
            end

            tkf = file_of(their_k); tkr = rank_of(their_k)
            corner_dist = min(tkf, 7 - tkf, tkr, 7 - tkr)
            φ[FEAT_TROPISM_CORNER] += s * (7 - corner_dist) * eg_weight / 12.0
        end
    end

    # Rook-passer features
    for c in (White, Black)
        s           = c == White ? 1.0 : -1.0
        their_pawns = bb(b, other(c), Pawn)
        my_rooks    = bb(b, c, Rook)
        enemy_rooks = bb(b, other(c), Rook)
        their_k     = lsb(bb(b, other(c), King))

        for psq in BitIter(bb(b, c, Pawn))
            _is_passed(psq, c, their_pawns) || continue
            f = file_of(psq); r = rank_of(psq)
            for rs in BitIter(my_rooks & FILE_MASK[f+1])
                behind = c == White ? rank_of(rs) < r : rank_of(rs) > r
                if behind; φ[FEAT_ROOK_BEHIND_PASS] += s; break; end
            end
            for rs in BitIter(enemy_rooks & FILE_MASK[f+1])
                blocking = c == White ? rank_of(rs) > r : rank_of(rs) < r
                if blocking; φ[FEAT_ROOK_BLOCK_PASS] -= s; break; end
            end
            enemy_kr = rank_of(their_k)
            for rs in BitIter(my_rooks)
                rr = rank_of(rs)
                cut = c == White ? (rr > enemy_kr && rr <= r) : (rr < enemy_kr && rr >= r)
                if cut; φ[FEAT_ROOK_CUTOFF] += s; break; end
            end
        end
    end

    # Wrong-color bishop: K+B+rook-pawn vs bare K → large penalty
    for c in (White, Black)
        s = c == White ? 1.0 : -1.0
        (bb(b, c, Rook) | bb(b, c, Queen) | bb(b, c, Knight)) != BB(0) && continue
        count_bits(bb(b, c, Bishop)) == 1 || continue
        my_pawns = bb(b, c, Pawn)
        count_bits(my_pawns) == 1 || continue
        psq = lsb(my_pawns); pf = file_of(psq)
        (pf == 0 || pf == 7) || continue
        promo_rank  = c == White ? 7 : 0
        bish_sq     = lsb(bb(b, c, Bishop))
        bish_color  = (file_of(bish_sq) + rank_of(bish_sq)) & 1
        promo_color = (pf + promo_rank) & 1
        bish_color != promo_color && (φ[FEAT_WRONG_BISHOP] -= s)
    end

    # K+B+N vs bare K
    for c in (White, Black)
        s = c == White ? 1.0 : -1.0
        tc = other(c)
        (bb(b,c,Rook)|bb(b,c,Queen)|bb(b,c,Pawn)) != BB(0) && continue
        count_bits(bb(b, c, Knight)) == 1 || continue
        count_bits(bb(b, c, Bishop)) == 1 || continue
        (bb(b,tc,Rook)|bb(b,tc,Queen)|bb(b,tc,Bishop)|bb(b,tc,Knight)|bb(b,tc,Pawn)) != BB(0) && continue

        bish_sq    = lsb(bb(b, c, Bishop))
        bish_color = (file_of(bish_sq) + rank_of(bish_sq)) & 1
        their_k    = lsb(bb(b, tc, King))
        kf = file_of(their_k); kr = rank_of(their_k)
        corner_dist = if bish_color == 0
            min(kf + kr, (7 - kf) + (7 - kr))
        else
            min(kf + (7 - kr), (7 - kf) + kr)
        end
        φ[FEAT_KBNK_CORNER] += s * (14 - corner_dist)
        our_k = lsb(bb(b, c, King))
        φ[FEAT_KBNK_PROX]   += s * (7 - _chebyshev(our_k, their_k))
    end

    # Mopup (phase < 6, decisive material advantage)
    if ph < 6
        for c in (White, Black)
            s = c == White ? 1.0 : -1.0
            tc = other(c)
            (bb(b,tc,Rook)|bb(b,tc,Queen)|bb(b,tc,Bishop)|bb(b,tc,Knight)|bb(b,tc,Pawn)) != BB(0) && continue
            Int(b.material) * (c == White ? 1 : -1) < 400 && continue
            their_k    = lsb(bb(b, tc, King))
            tkf = file_of(their_k); tkr = rank_of(their_k)
            corner_dist = min(tkf, 7-tkf, tkr, 7-tkr)
            our_k = lsb(bb(b, c, King))
            φ[FEAT_MOPUP_CORNER] += s * (7 - corner_dist)
            φ[FEAT_MOPUP_PROX]   += s * (7 - _chebyshev(our_k, their_k))
        end
    end
end

# ── Pawn structure ─────────────────────────────────────────────────────────────
function _feat_pawn_structure!(φ, b)
    # Opposite-colored bishops discount: halve passed-pawn bonuses
    ocb_only = false
    no_heavy = (bb(b,White,Rook)|bb(b,Black,Rook)|bb(b,White,Queen)|bb(b,Black,Queen)|
                bb(b,White,Knight)|bb(b,Black,Knight)) == BB(0)
    if no_heavy && count_bits(bb(b,White,Bishop)) == 1 && count_bits(bb(b,Black,Bishop)) == 1
        ws = lsb(bb(b,White,Bishop)); bs = lsb(bb(b,Black,Bishop))
        ocb_only = ((file_of(ws)+rank_of(ws)) & 1) != ((file_of(bs)+rank_of(bs)) & 1)
    end
    discount = ocb_only ? 0.5 : 1.0

    for c in (White, Black)
        s           = c == White ? 1.0 : -1.0
        pawns       = bb(b, c, Pawn)
        enemy_pawns = bb(b, other(c), Pawn)

        # Doubled and isolated pawns (per file)
        for f in 0:7
            fp = pawns & FILE_MASK[f+1]
            fp == 0 && continue
            n = count_bits(fp)
            n > 1 && (φ[FEAT_DOUBLED_PAWN]  -= s * (n - 1))
            left  = f > 0 ? pawns & FILE_MASK[f]   : BB(0)
            right = f < 7 ? pawns & FILE_MASK[f+2] : BB(0)
            (left == 0 && right == 0) && (φ[FEAT_ISOLATED_PAWN] -= s * n)
        end

        passed_bb = BB(0)
        for psq in BitIter(pawns)
            if _is_passed(psq, c, enemy_pawns)
                r = rank_of(psq)
                # rank_bonus_idx mirrors PASSED_BONUS_W indexing (rank_of+1 for white,
                # 8-rank_of for black). Active bonuses are at ranks 3-7 (indices 3-7).
                rbi = c == White ? r + 1 : 8 - r
                feat_idx = if rbi == 3; FEAT_PASSED_R3
                           elseif rbi == 4; FEAT_PASSED_R4
                           elseif rbi == 5; FEAT_PASSED_R5
                           elseif rbi == 6; FEAT_PASSED_R6
                           elseif rbi == 7; FEAT_PASSED_R7
                           else; 0
                           end
                feat_idx > 0 && (φ[feat_idx] += s * discount)
                passed_bb |= sq_bb(psq)

                # Free passer bonus
                pf = file_of(psq)
                if c == White
                    fwd_mask    = _PASSED_W[psq+1] & FILE_MASK[pf+1] & ~RANK_MASK[8]
                    behind_mask = _PASSED_B[psq+1] & FILE_MASK[pf+1]
                else
                    fwd_mask    = _PASSED_B[psq+1] & FILE_MASK[pf+1] & ~RANK_MASK[1]
                    behind_mask = _PASSED_W[psq+1] & FILE_MASK[pf+1]
                end
                if (all_occ(b) & fwd_mask) == 0 && (bb(b, c, Pawn) & behind_mask) == 0
                    φ[FEAT_FREE_PASSER] += s   # no OCB discount (mirrors eval.jl)
                end
            else
                # Backward pawn
                supp = c == White ? _BACKWARD_W[psq+1] : _BACKWARD_B[psq+1]
                if (pawns & supp) == 0
                    fwd = c == White ? psq + 8 : psq - 8
                    if 0 <= fwd <= 63 && (pawn_attacks(fwd, c) & enemy_pawns) != 0
                        φ[FEAT_BACKWARD_PAWN] -= s
                    end
                end
            end
        end

        # Connected passers
        for psq in BitIter(passed_bb)
            f = file_of(psq)
            nb = (f > 0 ? FILE_MASK[f]   : BB(0)) |
                 (f < 7 ? FILE_MASK[f+2] : BB(0))
            (passed_bb & nb) != 0 && (φ[FEAT_CONNECTED_PASS] += s)  # +1 per passer in pair, no OCB
        end

        # Pawn majority (queenside / kingside)
        our_qs = count(f -> (pawns & FILE_MASK[f]) != BB(0), 1:4)
        opp_qs = count(f -> (enemy_pawns & FILE_MASK[f]) != BB(0), 1:4)
        our_ks = count(f -> (pawns & FILE_MASK[f]) != BB(0), 5:8)
        opp_ks = count(f -> (enemy_pawns & FILE_MASK[f]) != BB(0), 5:8)
        start_rank = c == White ? 1 : 6

        for (our_cnt, opp_cnt, files) in ((our_qs, opp_qs, 1:4), (our_ks, opp_ks, 5:8))
            opp_cnt > 0 && our_cnt > opp_cnt || continue
            maj_bb = reduce(|, (pawns & FILE_MASK[f] for f in files), init=BB(0))
            min_rank = Int(trailing_zeros(maj_bb)) >> 3
            max_rank = (63 - Int(leading_zeros(maj_bb))) >> 3
            trailing_rank = c == White ? min_rank : max_rank
            adv = max(0, c == White ? trailing_rank - start_rank : start_rank - trailing_rank)
            φ[FEAT_PM_BASE] += s
            φ[FEAT_PM_ADV]  += s * adv
        end
    end
end

# ── King safety ────────────────────────────────────────────────────────────────
function _feat_king_safety!(φ, b, ph::Int)
    occ = all_occ(b)

    for c in (White, Black)
        s     = c == White ? 1.0 : -1.0
        ks    = lsb(bb(b, c, King))
        kf    = file_of(ks); kr = rank_of(ks)
        pawns = bb(b, c, Pawn)
        them  = other(c)
        fwd   = c == White ? 1 : -1

        # King zone attacks (only meaningful with pieces on board)
        if ph >= 8
            zone = king_attacks(ks) | sq_bb(ks)
            n_atk = 0; n_k = 0; n_b = 0; n_r = 0; n_q = 0
            q_atk = false
            for sq in BitIter(bb(b, them, Knight))
                (knight_attacks(sq) & zone) != 0 && (n_atk += 1; n_k += 1)
            end
            for sq in BitIter(bb(b, them, Bishop))
                (bishop_attacks(sq, occ) & zone) != 0 && (n_atk += 1; n_b += 1)
            end
            for sq in BitIter(bb(b, them, Rook))
                (rook_attacks(sq, occ) & zone) != 0 && (n_atk += 1; n_r += 1)
            end
            for sq in BitIter(bb(b, them, Queen))
                if (queen_attacks(sq, occ) & zone) != 0
                    n_atk += 1; n_q += 1; q_atk = true
                end
            end

            if n_atk >= 2
                them_pieces = count_bits(bb(b,them,Knight)|bb(b,them,Bishop)|
                                         bb(b,them,Rook)|bb(b,them,Queen))
                sus_num = 4; sus_den = 4
                q_atk           || (sus_den *= 2)
                them_pieces <= 2 && (sus_num *= 2; sus_den *= 5)
                factor = ph * sus_num / (24.0 * sus_den)
                # Penalty goes against the victim (color c), so subtract from c's perspective
                φ[FEAT_KING_ATK_N] -= s * n_k * factor
                φ[FEAT_KING_ATK_B] -= s * n_b * factor
                φ[FEAT_KING_ATK_R] -= s * n_r * factor
                φ[FEAT_KING_ATK_Q] -= s * n_q * factor
            end
        end

        # Castling rights (scaled by phase above 6)
        if ph >= 6
            wt = (ph - 6) / 2.0
            has_ks = c == White ? (b.castling & CR_WK) != 0 : (b.castling & CR_BK) != 0
            has_qs = c == White ? (b.castling & CR_WQ) != 0 : (b.castling & CR_BQ) != 0
            has_ks && (φ[FEAT_CASTLING_KS] += s * wt)
            has_qs && (φ[FEAT_CASTLING_QS] += s * wt)
        end

        # Uncastled king in center (files d–e)
        if ph >= 8 && kf >= 3 && kf <= 4
            φ[FEAT_CENTER_KING] -= s * ph
        end

        # Pawn shield and open-file penalties (castled king only)
        if kf <= 2 || kf >= 5
            r1 = kr + fwd
            if 0 <= r1 <= 7
                for df in -1:1
                    sf = kf + df
                    0 <= sf <= 7 || continue
                    (pawns & sq_bb(sq(sf, r1))) != 0 && (φ[FEAT_SHIELD_CLOSE] += s)
                end
            end
            r2 = kr + 2 * fwd
            if 0 <= r2 <= 7
                for df in -1:1
                    sf = kf + df
                    0 <= sf <= 7 || continue
                    (pawns & sq_bb(sq(sf, r2))) != 0 && (φ[FEAT_SHIELD_FAR] += s)
                end
            end
            # Semi-open file adjacent to king
            for df in -1:1
                sf = kf + df
                0 <= sf <= 7 || continue
                has_shld = (0 <= r1 <= 7 && (pawns & sq_bb(sq(sf, r1))) != 0) ||
                           (0 <= r2 <= 7 && (pawns & sq_bb(sq(sf, r2))) != 0)
                has_shld || (φ[FEAT_SEMIOPEN_KING] -= s)
            end
            # h-pawn hook penalty
            hook_rank = c == White ? 2 : 5
            (pawns & sq_bb(sq(7, hook_rank))) != 0 && (φ[FEAT_HPAWN_HOOK] -= s)
        end

        # Pawn storm (opposite-flank castling)
        their_ks  = lsb(bb(b, other(c), King))
        their_kf  = file_of(their_ks)
        if abs(kf - their_kf) >= 3
            for psq in BitIter(pawns)
                abs(file_of(psq) - their_kf) <= 2 || continue
                advance = c == White ? rank_of(psq) - 2 : 5 - rank_of(psq)
                advance > 0 && (φ[FEAT_PAWN_STORM] += s * advance)
            end
        end
    end
end

# ── Space ──────────────────────────────────────────────────────────────────────
function _feat_space!(φ, b)
    zone = (RANK_MASK[4]|RANK_MASK[5]|RANK_MASK[6]) &
           (FILE_MASK[3]|FILE_MASK[4]|FILE_MASK[5]|FILE_MASK[6])
    for c in (White, Black)
        s           = c == White ? 1.0 : -1.0
        pawns       = bb(b, c, Pawn)
        enemy_pawns = bb(b, other(c), Pawn)
        our_atk = c == White ?
            ((pawns << 7) & ~FILE_MASK[8]) | ((pawns << 9) & ~FILE_MASK[1]) :
            ((pawns >> 9) & ~FILE_MASK[8]) | ((pawns >> 7) & ~FILE_MASK[1])
        enemy_atk = c == White ?
            ((enemy_pawns >> 9) & ~FILE_MASK[8]) | ((enemy_pawns >> 7) & ~FILE_MASK[1]) :
            ((enemy_pawns << 7) & ~FILE_MASK[8]) | ((enemy_pawns << 9) & ~FILE_MASK[1])
        φ[FEAT_SPACE] += s * count_bits(our_atk & zone & ~enemy_atk)
    end
end

# ── Tempo + complexity ─────────────────────────────────────────────────────────
function _feat_tempo!(φ, b)
    φ[FEAT_TEMPO] += b.side == White ? 1.0 : -1.0
end

function _feat_complexity!(φ, b)
    mat = Int(b.material)
    if abs(mat) >= 60 && (bb(b, White, Queen) | bb(b, Black, Queen)) != BB(0)
        φ[FEAT_COMPLEXITY] += mat < 0 ? 1.0 : -1.0
    end
end
