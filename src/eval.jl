# Static evaluation. Positive = White is better (centipawns).

# ── Piece values ───────────────────────────────────────────────────────────────
# Indexed by Int(kind)+1: NoPiece=0 Pawn=100 Knight=320 Bishop=330 Rook=500 Queen=1000 King=20000
const PIECE_VALUE = (0, 100, 320, 330, 500, 1000, 20_000)

# ── Piece-square tables ────────────────────────────────────────────────────────
# 64 entries written rank-8 → rank-1, file-a → file-h (visual board order).
# We pre-compute these into MG_TABLE and EG_TABLE for both colors.
# These tables store ONLY PST values (no base piece values).

const MG_TABLE = zeros(Int32, 2, 7, 64)
const EG_TABLE = zeros(Int32, 2, 7, 64)

function _init_eval!()
    for c in (White, Black)
        for k in (Pawn, Knight, Bishop, Rook, Queen, King)
            mg_pst = if k == Pawn; PST_PAWN_MG
                elseif k == Knight; PST_KNIGHT_MG
                elseif k == Bishop; PST_BISHOP_MG
                elseif k == Rook;   PST_ROOK_MG
                elseif k == Queen;  PST_QUEEN_MG
                else                PST_KING_MG
                end
            eg_pst = if k == Pawn; PST_PAWN_EG
                elseif k == Knight; PST_KNIGHT_EG
                elseif k == Bishop; PST_BISHOP_EG
                elseif k == Rook;   PST_ROOK_EG
                elseif k == Queen;  PST_QUEEN_EG
                else                PST_KING_EG
                end

            for s in 0:63
                # Mirroring logic from original _pst
                idx = c == White ? (7 - rank_of(s)) * 8 + file_of(s) + 1 :
                                        rank_of(s)  * 8 + file_of(s) + 1
                MG_TABLE[Int(c)+1, Int(k)+1, s+1] = Int32(mg_pst[idx])
                EG_TABLE[Int(c)+1, Int(k)+1, s+1] = Int32(eg_pst[idx])
            end
        end
    end
end

# Chebyshev (chessboard) distance: the number of king moves between two squares.
# Equal to max(|Δfile|, |Δrank|) because the king can move diagonally.
@inline _chebyshev(s1::Square, s2::Square)::Int =
    max(abs(file_of(s1) - file_of(s2)), abs(rank_of(s1) - rank_of(s2)))

# All piece types now have separate MG and EG tables, blended by the same
# phase taper used for the king: value = (ph×MG + (24−ph)×EG) ÷ 24.
# MG tables (Michniewski "Simplified Evaluation Function" baseline, unchanged)
# reward development, central control, and formation.  EG tables reward
# advancement, long-range activity, and centralisation, which matter more
# once most pieces have been traded.

const PST_PAWN_MG = Int16[
     0,  0,  0,  0,  0,  0,  0,  0,
    50, 50, 50, 50, 50, 50, 50, 50,
    10, 10, 20, 30, 30, 20, 10, 10,
     5,  5, 10, 25, 25, 10,  5,  5,
     0,  0,  0, 20, 20,  0,  0,  0,
     5, -5,-10,  0,  0,-10, -5,  5,
     5, 10, 10,-20,-20, 10, 10,  5,
     0,  0,  0,  0,  0,  0,  0,  0,
]

# In the endgame, advancement toward promotion is the dominant concern.
# Formation bonuses/penalties from the MG table are dropped; central files
# get only a small premium because connected/passed pawn bonuses are handled
# separately by PASSED_BONUS and the pawn-structure evaluator.
const PST_PAWN_EG = Int16[
     0,  0,  0,  0,  0,  0,  0,  0,
    25, 25, 25, 25, 25, 25, 25, 25,
    15, 15, 15, 15, 15, 15, 15, 15,
     8,  8, 10, 12, 12, 10,  8,  8,
     3,  3,  5,  7,  7,  5,  3,  3,
     1,  1,  2,  3,  3,  2,  1,  1,
     0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,
]

const PST_KNIGHT_MG = Int16[
    -50,-40,-30,-30,-30,-30,-40,-50,
    -40,-20,  0,  0,  0,  0,-20,-40,
    -30,  0, 10, 15, 15, 10,  0,-30,
    -30,  5, 15, 20, 20, 15,  5,-30,
    -30,  0, 15, 20, 20, 15,  0,-30,
    -30,  5, 10, 15, 15, 10,  5,-30,
    -40,-20,  0,  5,  5,  0,-20,-40,
    -50,-40,-30,-30,-30,-30,-40,-50,
]

# Knights are slightly weaker in open endgames (fewer pieces to work with).
# Corner/edge penalties are preserved; near-centre values are softened a touch
# since the knight's relative value drops as the board opens.
const PST_KNIGHT_EG = Int16[
    -50,-40,-30,-30,-30,-30,-40,-50,
    -40,-20, -5, -5, -5, -5,-20,-40,
    -30, -5, 10, 15, 15, 10, -5,-30,
    -30,  0, 15, 20, 20, 15,  0,-30,
    -30,  0, 15, 20, 20, 15,  0,-30,
    -30, -5, 10, 15, 15, 10, -5,-30,
    -40,-20, -5, -5, -5, -5,-20,-40,
    -50,-40,-30,-30,-30,-30,-40,-50,
]

const PST_BISHOP_MG = Int16[
    -20,-10,-10,-10,-10,-10,-10,-20,
    -10,  0,  0,  0,  0,  0,  0,-10,
    -10,  0,  5, 10, 10,  5,  0,-10,
    -10,  5,  5, 10, 10,  5,  5,-10,
    -10,  0, 10, 10, 10, 10,  0,-10,
    -10, 10, 10, 10, 10, 10, 10,-10,
    -10,  5,  0,  0,  0,  0,  5,-10,
    -20,-10,-10,-10,-10,-10,-10,-20,
]

# Bishops are strong in open endgames.  The EG table is more symmetric than MG
# and rewards the central diagonals where the bishop controls the most squares.
const PST_BISHOP_EG = Int16[
    -20,-10,-10,-10,-10,-10,-10,-20,
    -10,  5,  0,  0,  0,  0,  5,-10,
    -10,  5, 10, 10, 10, 10,  5,-10,
    -10,  0, 10, 15, 15, 10,  0,-10,
    -10,  0, 10, 15, 15, 10,  0,-10,
    -10,  5, 10, 10, 10, 10,  5,-10,
    -10,  5,  0,  0,  0,  0,  5,-10,
    -20,-10,-10,-10,-10,-10,-10,-20,
]

const PST_ROOK_MG = Int16[
     0,  0,  0,  0,  0,  0,  0,  0,
     5, 10, 10, 10, 10, 10, 10,  5,
    -5,  0,  0,  0,  0,  0,  0, -5,
    -5,  0,  0,  0,  0,  0,  0, -5,
    -5,  0,  0,  0,  0,  0,  0, -5,
    -5,  0,  0,  0,  0,  0,  0, -5,
    -5,  0,  0,  0,  0,  0,  0, -5,
     0,  0,  0,  5,  5,  0,  0,  0,
]

# In the endgame rooks want centralized, active files.  The 7th-rank bonus is
# handled separately (+15) so this table only adjusts file/rank preference.
const PST_ROOK_EG = Int16[
     0,  0,  0,  0,  0,  0,  0,  0,
     5, 10, 10, 10, 10, 10, 10,  5,
     0,  0,  5,  5,  5,  5,  0,  0,
     0,  0,  5,  5,  5,  5,  0,  0,
     0,  0,  5,  5,  5,  5,  0,  0,
     0,  0,  5,  5,  5,  5,  0,  0,
    -5,  0,  0,  0,  0,  0,  0, -5,
     0,  0,  0,  3,  3,  0,  0,  0,
]

const PST_QUEEN_MG = Int16[
    -20,-10,-10, -5, -5,-10,-10,-20,
    -10,  0,  0,  0,  0,  0,  0,-10,
    -10,  0,  5,  5,  5,  5,  0,-10,
     -5,  0,  5,  5,  5,  5,  0, -5,
      0,  0,  5,  5,  5,  5,  0, -5,
    -10,  5,  5,  5,  5,  5,  0,-10,
    -10,  0,  5,  0,  0,  0,  0,-10,
    -20,-10,-10, -5, -5,-10,-10,-20,
]

# In the endgame the queen wants to be centralized and aggressive.
# The MG table discourages early queen development; the EG table has no such bias.
const PST_QUEEN_EG = Int16[
    -20,-10,-10, -5, -5,-10,-10,-20,
    -10,  0,  5,  5,  5,  5,  0,-10,
    -10,  5, 10, 10, 10, 10,  5,-10,
     -5,  5, 10, 15, 15, 10,  5, -5,
     -5,  5, 10, 15, 15, 10,  5, -5,
    -10,  5, 10, 10, 10, 10,  5,-10,
    -10,  0,  5,  5,  5,  5,  0,-10,
    -20,-10,-10, -5, -5,-10,-10,-20,
]

# ── Tapered king evaluation ────────────────────────────────────────────────────
# The king's ideal location changes completely between the middlegame (MG) and
# endgame (EG): in the MG it should hide behind pawns in a corner; in the EG
# all pawns may be gone so the king must centralise to support its own pawns.
#
# We blend MG and EG tables by a "phase" value that counts remaining material:
#   phase = knights + bishops + 2×rooks + 4×queens, clamped to [0, 24].
# At full material (phase=24) the result is the pure MG score; at phase=0 it
# is the pure EG score.  The linear interpolation king_bonus = (ph×MG + (24-ph)×EG) / 24
# continuously adjusts the king's positional incentive as pieces come off the board.
const PST_KING_MG = Int16[
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -20,-30,-30,-40,-40,-30,-30,-20,
    -10,-20,-20,-25,-25,-20,-20,-10,
    -20,-20,-20,-25,-25,-20,-20,-20,   # rank 2: corners penalised to prevent premature king walks
     20, 30, 10,  0,  0, 10, 30, 20,
]

const PST_KING_EG = Int16[
    -50,-40,-30,-20,-20,-30,-40,-50,
    -30,-20,-10,  0,  0,-10,-20,-30,
    -30,-10, 20, 30, 30, 20,-10,-30,
    -30,-10, 30, 40, 40, 30,-10,-30,
    -30,-10, 30, 40, 40, 30,-10,-30,
    -30,-10, 20, 30, 30, 20,-10,-30,
    -30,-30,  0,  0,  0,  0,-30,-30,
    -50,-30,-30,-30,-30,-30,-30,-50,
]

# ── Passed-pawn corridor masks ─────────────────────────────────────────────────
# A pawn is "passed" when no enemy pawn can ever block or capture it — i.e.,
# there is no enemy pawn in the three-file corridor (own file + adjacent files)
# in front of it.
#
# _PASSED_W[s+1] covers all squares on files f-1, f, f+1 with rank > r (for white).
# _PASSED_B[s+1] covers the same files with rank < r (for black).
# If the intersection with enemy pawns is empty, the pawn is passed.
# These masks are also reused for the knight-outpost test, which checks that no
# enemy pawn can advance to challenge the outpost square.
function _build_passed_masks()
    wm = zeros(BB, 64)
    bm = zeros(BB, 64)
    for s in 0:63
        f = file_of(s); r = rank_of(s)
        for rank in (r+1):7
            f > 0 && (wm[s+1] |= sq_bb(sq(f-1, rank)))
                      wm[s+1] |= sq_bb(sq(f,   rank))
            f < 7 && (wm[s+1] |= sq_bb(sq(f+1, rank)))
        end
        for rank in 0:(r-1)
            f > 0 && (bm[s+1] |= sq_bb(sq(f-1, rank)))
                      bm[s+1] |= sq_bb(sq(f,   rank))
            f < 7 && (bm[s+1] |= sq_bb(sq(f+1, rank)))
        end
    end
    wm, bm
end
const (_PASSED_W, _PASSED_B) = _build_passed_masks()

@inline _is_passed(s::Square, c::Color, enemy_pawns::BB)::Bool =
    (c == White ? _PASSED_W[s+1] : _PASSED_B[s+1]) & enemy_pawns == 0

# ── Backward pawn masks ────────────────────────────────────────────────────────
# A pawn is "backward" if it has no friendly pawns on adjacent files at the same
# or earlier ranks, and its advance square is controlled by an enemy pawn.
# These masks cover the "support zone": adjacent files at the same or earlier ranks.
function _build_backward_masks()
    wm = zeros(BB, 64)
    bm = zeros(BB, 64)
    for s in 0:63
        f = file_of(s); r = rank_of(s)
        adj_files = (f > 0 ? FILE_MASK[f] : BB(0)) | (f < 7 ? FILE_MASK[f+2] : BB(0))
        for rank in 0:r
            wm[s+1] |= (adj_files & RANK_MASK[rank+1])
        end
        for rank in r:7
            bm[s+1] |= (adj_files & RANK_MASK[rank+1])
        end
    end
    wm, bm
end
const (_BACKWARD_W, _BACKWARD_B) = _build_backward_masks()

# Bonus in centipawns for a passed pawn based on how far advanced it is.
# Indexed by rank_of(s)+1 (1=rank1 … 8=rank8); ranks 1 and 8 unused for pawns.
# The curve is intentionally steep to create urgency: each rank gain must look
# more attractive than the defensive alternative, otherwise the engine sits on
# a "winning" eval without converting.  A rank-7 pawn is essentially a free queen.
# The rank-2→3 jump (+25 cp) ensures even newly-passed pawns are pushed promptly.
const PASSED_BONUS_W = (0, 0, 15, 35, 60,  90, 130, 0)
const PASSED_BONUS_B = (0, 130,  90, 60, 35, 15,   0, 0)

@inline _passed_bonus(s::Square, c::Color)::Int =
    c == White ? PASSED_BONUS_W[rank_of(s)+1] : PASSED_BONUS_B[rank_of(s)+1]

# ── Insufficient-material draw detection ──────────────────────────────────────
# FIDE rules: the game is drawn when neither side has enough material to force
# checkmate by any sequence of legal moves.  The recognised cases are:
#   K vs K
#   K+N vs K  (a lone knight cannot force mate)
#   K+B vs K  (a lone bishop cannot force mate)
#   K+B vs K+B with both bishops on the same colour
# We do NOT declare K+N+N vs K a draw even though it is theoretically drawn:
# it can deliver checkmate with a badly-placed opponent king, so the engine
# should still try rather than accept a "free" draw.
function _is_insufficient_material(b::Board)::Bool
    # Any pawn, rook, or queen means checkmate is always potentially forceable.
    (bb(b, White, Pawn)  | bb(b, Black, Pawn)  |
     bb(b, White, Rook)  | bb(b, Black, Rook)  |
     bb(b, White, Queen) | bb(b, Black, Queen)) != 0 && return false

    wn = count_bits(bb(b, White, Knight))
    bn = count_bits(bb(b, Black, Knight))
    wb = count_bits(bb(b, White, Bishop))
    bb_ = count_bits(bb(b, Black, Bishop))
    total_minor = wn + bn + wb + bb_

    total_minor == 0 && return true   # K vs K
    total_minor == 1 && return true   # K+minor vs K

    # K+B vs K+B: draw only when both bishops travel on the same colour.
    # A bishop's square colour is (file+rank) mod 2.
    if wn == 0 && bn == 0 && wb == 1 && bb_ == 1
        ws = lsb(bb(b, White, Bishop))
        bs = lsb(bb(b, Black, Bishop))
        return (file_of(ws) + rank_of(ws)) & 1 == (file_of(bs) + rank_of(bs)) & 1
    end
    false
end

# ── EvalBreakdown ──────────────────────────────────────────────────────────────
struct EvalBreakdown
    material::Int
    piece_activity::Int
    pawn_structure::Int
    king_safety::Int
    space::Int
    tempo::Int
end

total(e::EvalBreakdown)::Int =
    e.material + e.piece_activity + e.pawn_structure + e.king_safety + e.space + e.tempo

# ── Component functions ────────────────────────────────────────────────────────

function _eval_piece_activity(b::Board, cfg::EngineConfig = DEFAULT_CONFIG)::Int
    ph = Int(clamp(b.phase, 0, 24))
    # Tapered PST score
    score = (ph * Int(b.mg_score) + (24 - ph) * Int(b.eg_score)) ÷ 24
    occ   = all_occ(b)

    # Pawn attack bitboards for mobility safety checks
    wp = bb(b, White, Pawn)
    bp = bb(b, Black, Pawn)
    w_pawn_atk = ((wp << 7) & ~FILE_MASK[8]) | ((wp << 9) & ~FILE_MASK[1])
    b_pawn_atk = ((bp >> 9) & ~FILE_MASK[8]) | ((bp >> 7) & ~FILE_MASK[1])

    for c in (White, Black)
        sign        = c == White ? 1 : -1
        my_pawns    = bb(b, c, Pawn)
        enemy_pawns = bb(b, other(c), Pawn)
        seventh     = c == White ? 6 : 1   # 0-indexed rank of the 7th rank

        # Rook on open file (+20) or semi-open file (+10).
        # Open = no pawn of either color on the file; semi-open = no friendly pawn.
        # Rook on the 7th rank (+15, stacks with file bonus).
        for s in BitIter(bb(b, c, Rook))
            f = file_of(s)
            if ((my_pawns | enemy_pawns) & FILE_MASK[f+1]) == 0
                score += sign * 20
            elseif (my_pawns & FILE_MASK[f+1]) == 0
                score += sign * 10
            end
            rank_of(s) == seventh && (score += sign * 15)
        end

        # Connected rooks: two rooks with a clear line of sight (+15 per pair).
        # The `seen` mask ensures each pair is counted once even if three rooks
        # are somehow on the board (promoted rook).
        my_rooks = bb(b, c, Rook)
        if count_bits(my_rooks) >= 2
            seen = BB(0)
            for s1 in BitIter(my_rooks)
                (rook_attacks(s1, occ) & my_rooks & ~seen) != 0 && (score += sign * 15)
                seen |= sq_bb(s1)
            end
        end

        # Knight outpost: a knight in the opponent's half that cannot be chased
        # by an enemy pawn.  We reuse the passed-pawn corridor mask (minus the
        # knight's own file) to test whether any enemy pawn can advance to an
        # adjacent file at any rank in front of the knight.
        # Full outpost: +32 if pawn-supported (hard to dislodge), +20 otherwise.
        # Semi-outpost: +14 if pawn-supported, +8 otherwise.
        for s in BitIter(bb(b, c, Knight))
            in_opp_half = c == White ? rank_of(s) >= 4 : rank_of(s) <= 3
            in_opp_half || continue
            # Pawn-supported: a friendly pawn defends the knight's square.
            # Equivalently: pawn_attacks(s, other(c)) gives the squares that
            # could host a pawn of color c to defend s diagonally.
            pawn_supported = (pawn_attacks(s, other(c)) & bb(b, c, Pawn)) != BB(0)
            pmask = (c == White ? _PASSED_W[s+1] : _PASSED_B[s+1]) &
                    ~FILE_MASK[file_of(s)+1]
            challenger = pmask & enemy_pawns
            if challenger == 0
                score += sign * (pawn_supported ? 32 : 20)
            else
                # Semi-outpost: all challenger pawns are immediately blocked.
                # Enemy pawn advances toward our side (decreasing rank for Black
                # challengers, increasing rank for White challengers).
                all_blocked = true
                for ep in BitIter(challenger)
                    fwd_sq = c == White ? ep - 8 : ep + 8
                    if 0 <= fwd_sq <= 63 && (occ & sq_bb(fwd_sq)) != 0
                        # this challenger pawn is blocked — OK
                    else
                        all_blocked = false; break
                    end
                end
                all_blocked && (score += sign * (pawn_supported ? 14 : 8))
            end
        end

        # Safe invasion: any minor piece in the opponent's half not immediately
        # attacked by an enemy pawn earns a small bonus for controlling space
        # inside the enemy camp. Applies to both knights and bishops.
        for s in BitIter(bb(b, c, Knight) | bb(b, c, Bishop))
            in_opp_half = c == White ? rank_of(s) >= 4 : rank_of(s) <= 3
            in_opp_half || continue
            (pawn_attacks(s, c) & enemy_pawns) == 0 && (score += sign * 4)
        end
    end

    # Bishop pair bonus: scales with board openness (inverse of phase).
    # 20 cp at full material (closed positions) → 30 cp at bare endgame (open).
    for c in (White, Black)
        count_bits(bb(b, c, Bishop)) >= 2 && (score += (c == White ? 1 : -1) * (20 + (24 - ph) * 10 ÷ 24))
    end

    if cfg.eval_mobility
        for c in (White, Black)
            sign      = c == White ? 1 : -1
            our_occ   = b.occ[Int(c)+1]
            their_atk = c == White ? b_pawn_atk : w_pawn_atk

            for s in BitIter(bb(b, c, Knight))
                atk  = knight_attacks(s) & ~our_occ
                safe = count_bits(atk & ~their_atk)
                unsf = count_bits(atk &  their_atk)
                score += sign * (safe * 2 + unsf * 1)
                # Trapped knight penalty
                safe == 0 && (score -= sign * 100)
                safe == 1 && (score -= sign * 50)
            end
            for s in BitIter(bb(b, c, Bishop))
                atk  = bishop_attacks(s, occ) & ~our_occ
                safe = count_bits(atk & ~their_atk)
                unsf = count_bits(atk &  their_atk)
                score += sign * (safe * 2 + unsf * 1)
                # Trapped bishop penalty
                safe == 0 && (score -= sign * 100)
                safe == 1 && (score -= sign * 50)
            end
            for s in BitIter(bb(b, c, Rook))
                atk  = rook_attacks(s, occ) & ~our_occ
                safe = count_bits(atk & ~their_atk)
                unsf = count_bits(atk &  their_atk)
                score += sign * (safe * 2 + unsf * 1)
                # Trapped rook penalty (e.g. cornered by pawns)
                safe == 0 && (score -= sign * 100)
            end
            for s in BitIter(bb(b, c, Queen))
                atk  = queen_attacks(s, occ) & ~our_occ
                safe = count_bits(atk & ~their_atk)
                unsf = count_bits(atk &  their_atk)
                score += sign * (safe * 1 + unsf * 0)
                # A trapped queen is catastrophic — far worse than a trapped minor piece.
                safe == 0 && (score -= sign * 150)
                safe <= 2 && safe > 0 && (score -= sign * 60)
            end
        end
    end

    if cfg.eval_center
        for c in (White, Black)
            sign = c == White ? 1 : -1
            ctrl = 0
            for cs in (sq(3,3), sq(4,3), sq(3,4), sq(4,4))
                (pawn_attacks(cs, other(c)) & bb(b, c, Pawn))                              != 0 && (ctrl += 1)
                (knight_attacks(cs)          & bb(b, c, Knight))                            != 0 && (ctrl += 1)
                (bishop_attacks(cs, occ)     & (bb(b, c, Bishop) | bb(b, c, Queen)))       != 0 && (ctrl += 1)
                (rook_attacks(cs, occ)       & (bb(b, c, Rook)   | bb(b, c, Queen)))       != 0 && (ctrl += 1)
                (king_attacks(cs)            & bb(b, c, King))                              != 0 && (ctrl += 1)
            end
            score += sign * ctrl * 2
        end
    end

    if cfg.eval_pins
    for c in (White, Black)
        sign     = c == White ? 1 : -1
        their_k  = lsb(bb(b, other(c), King))
        their_occ = b.occ[Int(other(c))+1]

        for s in BitIter(bb(b, c, Rook) | bb(b, c, Queen))
            sf = file_of(s); sr = rank_of(s)
            kf = file_of(their_k); kr = rank_of(their_k)
            if sf == kf
                ray_mask = @inbounds FILE_MASK[sf+1]
            elseif sr == kr
                ray_mask = @inbounds RANK_MASK[sr+1]
            else
                continue
            end
            between = _slider_attacks(s, sq_bb(their_k), ray_mask) &
                      _slider_attacks(their_k, sq_bb(s), ray_mask)
            pieces_between = between & occ
            if count_bits(pieces_between) == 1 && (pieces_between & their_occ) != 0
                pinned_sq   = lsb(pieces_between)
                pinned_kind = b.piece_on[pinned_sq+1].kind
                score += sign * PIECE_VALUE[Int(pinned_kind)+1] ÷ 8
            end
        end

        for s in BitIter(bb(b, c, Bishop) | bb(b, c, Queen))
            if (@inbounds DIAG_MASK[s+1]) & sq_bb(their_k) != 0
                ray_mask = @inbounds DIAG_MASK[s+1]
            elseif (@inbounds ADIAG_MASK[s+1]) & sq_bb(their_k) != 0
                ray_mask = @inbounds ADIAG_MASK[s+1]
            else
                continue
            end
            between = _slider_attacks(s, sq_bb(their_k), ray_mask) &
                      _slider_attacks(their_k, sq_bb(s), ray_mask)
            pieces_between = between & occ
            if count_bits(pieces_between) == 1 && (pieces_between & their_occ) != 0
                pinned_sq   = lsb(pieces_between)
                pinned_kind = b.piece_on[pinned_sq+1].kind
                score += sign * PIECE_VALUE[Int(pinned_kind)+1] ÷ 8
            end
        end
    end   # for c
    end   # cfg.eval_pins

    # ── Endgame king tropism ──────────────────────────────────────────────────────
    # In the endgame the king is an active fighting piece.  Beyond what the tapered
    # PSTs already reward (king centralisation), four additional incentives apply:
    #
    #   (a) Own king → own passed pawns: escort them to promotion.
    #       Bonus = (7 − dist) × eg_weight × 2 ÷ 12
    #       At bare-king endgame (eg_weight=24): up to +28 cp per pawn.
    #
    #   (b) Own king → enemy passed pawns: blockade or capture them.
    #       Bonus = (7 − dist) × eg_weight × 3 ÷ 12
    #       At bare-king endgame: up to +42 cp per pawn.
    #
    #   (c) Enemy king near the edge/corner: mating patterns require the losing
    #       king to be confined.  corner_dist = min(file, 7−file, rank, 7−rank).
    #       Bonus = (7 − corner_dist) × eg_weight × 5 ÷ 12  (increased from 3)
    #       At bare-king endgame: up to +70 cp for an edge-confined king.
    #
    #   (d) Own king close to enemy king (K+R vs K / K+R+B vs K technique):
    #       The king-proximity bonus is computed once outside the per-color loop
    #       because the Chebyshev distance is symmetric — adding it inside the
    #       loop for both sides would cancel to zero.  We award it only to the
    #       material-superior side so the winning king is incentivised to approach
    #       while the losing king is implicitly penalised by the opponent's bonus.
    #       Bonus = (7 − dist) × eg_weight × 4 ÷ 12
    #       At bare-king endgame: up to +56 cp.
    #
    # All terms are weighted by (24 − ph) / 12 so they vanish at full material
    # and reach full strength at bare-king endings.
    if cfg.eval_king_tropism && ph < 20
        eg_weight = 24 - ph   # 4..24

        # (d) King proximity — asymmetric, computed once.
        let wk = lsb(bb(b, White, King))
            bk = lsb(bb(b, Black, King))
            king_dist  = _chebyshev(wk, bk)
            prox_bonus = (7 - king_dist) * eg_weight * 4 ÷ 12
            w_pieces = count_bits(bb(b, White, Knight) | bb(b, White, Bishop) |
                                  bb(b, White, Rook)   | bb(b, White, Queen))
            b_pieces = count_bits(bb(b, Black, Knight) | bb(b, Black, Bishop) |
                                  bb(b, Black, Rook)   | bb(b, Black, Queen))
            if w_pieces > b_pieces
                score += prox_bonus
            elseif b_pieces > w_pieces
                score -= prox_bonus
            end
        end

        for c in (White, Black)
            sign        = c == White ? 1 : -1
            our_k       = lsb(bb(b, c, King))
            their_k     = lsb(bb(b, other(c), King))
            our_pawns   = bb(b, c, Pawn)
            their_pawns = bb(b, other(c), Pawn)

            for s in BitIter(our_pawns)
                _is_passed(s, c, their_pawns) || continue
                score += sign * (7 - _chebyshev(our_k, s)) * eg_weight * 2 ÷ 12
            end
            for s in BitIter(their_pawns)
                _is_passed(s, other(c), our_pawns) || continue
                score += sign * (7 - _chebyshev(our_k, s)) * eg_weight * 3 ÷ 12
            end

            their_kf    = file_of(their_k)
            their_kr    = rank_of(their_k)
            corner_dist = min(their_kf, 7 - their_kf, their_kr, 7 - their_kr)
            score += sign * (7 - corner_dist) * eg_weight * 5 ÷ 12
        end
    end

    if cfg.eval_rook_passer
        for c in (White, Black)
            sign        = c == White ? 1 : -1
            their_pawns = bb(b, other(c), Pawn)
            my_rooks    = bb(b, c, Rook)
            enemy_rooks = bb(b, other(c), Rook)
            their_k     = lsb(bb(b, other(c), King))
            for s in BitIter(bb(b, c, Pawn))
                _is_passed(s, c, their_pawns) || continue
                f = file_of(s); r = rank_of(s)
                # Our rook behind our passed pawn — the classic battery.
                for rs in BitIter(my_rooks & FILE_MASK[f+1])
                    behind = c == White ? rank_of(rs) < r : rank_of(rs) > r
                    if behind; score += sign * 25; break; end
                end
                # Enemy rook in front of our passed pawn — blockading it.
                # We reward the rook's OWNER (the blocking side) via sign flip.
                for rs in BitIter(enemy_rooks & FILE_MASK[f+1])
                    blocking = c == White ? rank_of(rs) > r : rank_of(rs) < r
                    if blocking; score -= sign * 20; break; end
                end
                # Rook rank cut-off: our rook sits on a rank that separates the
                # enemy king from the pawn's promotion side.  The king cannot
                # cross that rank to catch the pawn, winning decisive time.
                if cfg.eval_rook_cutoff
                    enemy_kr = rank_of(their_k)
                    for rs in BitIter(my_rooks)
                        rr = rank_of(rs)
                        # White pawn runs toward rank 7; cut off king below rook rank.
                        # Black pawn runs toward rank 0; cut off king above rook rank.
                        cut_off = c == White ? (rr > enemy_kr && rr <= r) :
                                               (rr < enemy_kr && rr >= r)
                        if cut_off; score += sign * 30; break; end
                    end
                end
            end
        end
    end

    # Wrong-color bishop: K+B+rook-pawn vs lone K where bishop cannot control
    # the promotion square is a theoretical draw regardless of pawn advancement.
    if cfg.eval_wrong_bishop
        for c in (White, Black)
            sign = c == White ? 1 : -1
            # Only applies when the "winning" side has bishop+pawn(s) only.
            (bb(b, c, Rook) | bb(b, c, Queen) | bb(b, c, Knight)) != BB(0) && continue
            count_bits(bb(b, c, Bishop)) == 1 || continue
            my_pawns = bb(b, c, Pawn)
            count_bits(my_pawns) == 1 || continue
            ps = lsb(my_pawns)
            pf = file_of(ps)
            (pf == 0 || pf == 7) || continue   # must be a rook pawn
            promo_rank = c == White ? 7 : 0
            bish_sq    = lsb(bb(b, c, Bishop))
            # Bishop and promotion square on different square colors → draw.
            bish_color  = (file_of(bish_sq) + rank_of(bish_sq)) & 1
            promo_color = (pf + promo_rank) & 1
            if bish_color != promo_color
                score -= sign * 150
            end
        end
    end

    # Knight distance penalty in deep endgames (phase < 10): a knight stranded
    # far from all pawns contributes almost nothing.
    if cfg.eval_knight_distance && ph < 10
        eg_wt = 10 - ph   # 1..10
        all_pawns = bb(b, White, Pawn) | bb(b, Black, Pawn)
        for c in (White, Black)
            sign = c == White ? 1 : -1
            for ns in BitIter(bb(b, c, Knight))
                min_dist = 14
                for ps in BitIter(all_pawns)
                    d = _chebyshev(ns, ps)
                    d < min_dist && (min_dist = d)
                end
                # No pawns on the board — knight distance is irrelevant.
                min_dist == 14 && continue
                penalty = min(min_dist * eg_wt ÷ 5, 20)
                score -= sign * penalty
            end
        end
    end

    # ── K+B+N vs lone K ───────────────────────────────────────────────────────
    # B+N mate requires driving the bare king to a corner of the bishop's colour.
    # The existing king-tropism terms are insufficient for this rare but important
    # technique.  We add a large bonus that scales with how close the bare king
    # is to the correct corner and how close the winning king is to the bare king.
    if cfg.eval_kbnk
        for c in (White, Black)
            sign = c == White ? 1 : -1
            their_c = other(c)
            # Winning side must have exactly K+B+N.
            (bb(b, c, Rook)   | bb(b, c, Queen)  | bb(b, c, Pawn)) != BB(0) && continue
            count_bits(bb(b, c, Knight)) == 1     || continue
            count_bits(bb(b, c, Bishop)) == 1     || continue
            # Losing side must be a bare king.
            (bb(b, their_c, Rook)   | bb(b, their_c, Queen)  |
             bb(b, their_c, Bishop) | bb(b, their_c, Knight) |
             bb(b, their_c, Pawn)) != BB(0)       && continue

            bish_sq    = lsb(bb(b, c, Bishop))
            bish_color = (file_of(bish_sq) + rank_of(bish_sq)) & 1
            their_k    = lsb(bb(b, their_c, King))
            kf = file_of(their_k); kr = rank_of(their_k)
            # Correct corners: a1=(0,0) and h8=(7,7) are light (sum even),
            #                  a8=(0,7) and h1=(7,0) are dark (sum odd).
            corner_dist = if bish_color == 0   # light bishop → a1 or h8
                min(kf + kr, (7 - kf) + (7 - kr))
            else                               # dark bishop → a8 or h1
                min(kf + (7 - kr), (7 - kf) + kr)
            end
            score += sign * (14 - corner_dist) * 12   # up to +168 cp
            our_k  = lsb(bb(b, c, King))
            score += sign * (7 - _chebyshev(our_k, their_k)) * 8   # up to +56 cp
        end
    end

    # ── Mopup evaluation ──────────────────────────────────────────────────────
    # When one side has a decisive material advantage and the opponent is down
    # to a bare (or near-bare) king, the winning side earns bonuses for
    # (a) pushing the losing king to a corner and (b) bringing its own king
    # close.  This is additive to the existing king-tropism terms but activates
    # more aggressively when the material gap is large.
    if cfg.eval_mopup && ph < 6
        for c in (White, Black)
            sign    = c == White ? 1 : -1
            their_c = other(c)
            # Losing side: no pieces except the king (bare king).
            (bb(b, their_c, Rook)   | bb(b, their_c, Queen)  |
             bb(b, their_c, Bishop) | bb(b, their_c, Knight) |
             bb(b, their_c, Pawn)) != BB(0)       && continue
            # Winning side must have a significant material edge.
            Int(b.material) * sign < 400           && continue

            their_k    = lsb(bb(b, their_c, King))
            their_kf   = file_of(their_k)
            their_kr   = rank_of(their_k)
            corner_dist = min(their_kf, 7 - their_kf, their_kr, 7 - their_kr)
            our_k       = lsb(bb(b, c, King))
            score += sign * (7 - corner_dist) * 15           # up to +105 cp
            score += sign * (7 - _chebyshev(our_k, their_k)) * 12   # up to +84 cp
        end
    end

    score
end

function _eval_pawn_structure(b::Board, cfg::EngineConfig = DEFAULT_CONFIG)::Int
    score = 0

    # Opposite-colored bishops with no other pieces: passed pawn bonuses halved.
    ocb_only = false
    if cfg.eval_ocb_discount
        no_heavy = (bb(b, White, Rook)   | bb(b, Black, Rook)   |
                    bb(b, White, Queen)  | bb(b, Black, Queen)  |
                    bb(b, White, Knight) | bb(b, Black, Knight)) == BB(0)
        if no_heavy &&
           count_bits(bb(b, White, Bishop)) == 1 &&
           count_bits(bb(b, Black, Bishop)) == 1
            ws = lsb(bb(b, White, Bishop))
            bs = lsb(bb(b, Black, Bishop))
            ocb_only = ((file_of(ws) + rank_of(ws)) & 1) != ((file_of(bs) + rank_of(bs)) & 1)
        end
    end

    for c in (White, Black)
        sign = c == White ? 1 : -1
        pawns       = bb(b, c, Pawn)
        enemy_pawns = bb(b, other(c), Pawn)

        for f in 0:7
            fp = pawns & FILE_MASK[f+1]
            fp == 0 && continue
            n = count_bits(fp)
            # Doubled pawns: penalty per extra pawn on the same file.
            # The lead pawn is neutral; each additional pawn is a liability
            # because it cannot protect the one ahead of it.  −12 cp reflects
            # that doubled pawns also create weaknesses on the adjacent files
            # that the opponent can target with a rook or majority.
            n > 1 && (score += sign * (n - 1) * (-12))
            # Isolated pawns: no friendly pawn on either adjacent file means
            # this pawn can never be defended by another pawn.  −20 cp is larger
            # than the doubled penalty because an isolated pawn is a permanent
            # structural weakness, not just a mobility issue.
            left  = f > 0 ? pawns & FILE_MASK[f]   : BB(0)
            right = f < 7 ? pawns & FILE_MASK[f+2] : BB(0)
            (left == 0 && right == 0) && (score += sign * n * (-20))
        end

        passed_bb = BB(0)
        for s in BitIter(pawns)
            if _is_passed(s, c, enemy_pawns)
                bonus = _passed_bonus(s, c)
                ocb_only && (bonus = bonus ÷ 2)
                score += sign * bonus
                passed_bb |= sq_bb(s)
                # Free passer: no piece of either colour stands between the
                # pawn and its promotion square, AND no friendly pawn trails
                # behind it on the same file (doubled pawns are not truly free).
                promo_rank = c == White ? 7 : 0
                pawn_rank  = rank_of(s)
                pawn_file  = file_of(s)
                path_clear = true
                if c == White
                    for r in (pawn_rank + 1):(promo_rank - 1)
                        (all_occ(b) & sq_bb(sq(pawn_file, r))) != 0 && (path_clear = false; break)
                    end
                    # disqualify if a friendly pawn sits behind on the same file
                    for r in 1:(pawn_rank - 1)
                        (bb(b, c, Pawn) & sq_bb(sq(pawn_file, r))) != 0 && (path_clear = false; break)
                    end
                else
                    for r in (promo_rank + 1):(pawn_rank - 1)
                        (all_occ(b) & sq_bb(sq(pawn_file, r))) != 0 && (path_clear = false; break)
                    end
                    for r in (pawn_rank + 1):6
                        (bb(b, c, Pawn) & sq_bb(sq(pawn_file, r))) != 0 && (path_clear = false; break)
                    end
                end
                path_clear && (score += sign * 15)
            else
                # Backward pawn detection: no friendly pawns in the support zone,
                # and the square in front is attacked by an enemy pawn.
                support_mask = c == White ? _BACKWARD_W[s+1] : _BACKWARD_B[s+1]
                if (pawns & support_mask) == 0
                    fwd_sq = c == White ? s + 8 : s - 8
                    if 0 <= fwd_sq <= 63
                        if (pawn_attacks(fwd_sq, c) & enemy_pawns) != 0
                            score += sign * (-15)
                        end
                    end
                end
            end
        end

        # Connected passed pawns: adjacent passers support each other and are
        # very difficult to stop together — a lone piece cannot handle both
        # simultaneously.  The bonus is large enough to clearly outweigh the
        # cost of pushing versus making defensive moves.
        if cfg.eval_connected_passers
            for s in BitIter(passed_bb)
                f = file_of(s)
                neighbor = (f > 0 ? FILE_MASK[f]   : BB(0)) |
                           (f < 7 ? FILE_MASK[f+2] : BB(0))
                (passed_bb & neighbor) != 0 && (score += sign * 30)
            end
        end

        # Flank pawn majority: more pawns on one flank creates a potential
        # passed pawn by advancing — a long-term structural advantage.
        if cfg.eval_pawn_majority
            # Count files with at least one pawn (not total pawns), and only
            # award the bonus when the opponent actually has pawns on that flank
            # — an uncontested flank with no enemy pawns doesn't create a
            # meaningful majority (the doubled-pawn test case has 2 white pawns
            # on e but zero black pawns; that's not a structural advantage).
            our_qs = count(f -> (pawns & FILE_MASK[f]) != BB(0), 1:4)
            opp_qs = count(f -> (enemy_pawns & FILE_MASK[f]) != BB(0), 1:4)
            our_ks = count(f -> (pawns & FILE_MASK[f]) != BB(0), 5:8)
            opp_ks = count(f -> (enemy_pawns & FILE_MASK[f]) != BB(0), 5:8)
            (opp_qs > 0 && our_qs > opp_qs) && (score += sign * 15)
            (opp_ks > 0 && our_ks > opp_ks) && (score += sign * 15)
        end
    end
    score
end

# ── King-safety pawn shield ────────────────────────────────────────────────────
# After castling the king typically sits on g1/h1 (kingside) or b1/c1 (queenside).
# The pawns on the two ranks directly in front of it form a "shield" that
# blocks enemy queens and rooks from approaching on open files.
#
# We award +20 per pawn in the rank directly in front of the king (close shield)
# and +8 per pawn two ranks ahead (far shield).  The smaller far-shield bonus
# acknowledges that a pawn on h3 still provides some cover but leaves the king
# more exposed than one on h2.
#
# We also penalise open files adjacent to the king (-18 each): an open file is
# an invasion route for heavy pieces even if the immediate pawn shield is intact.
#
# The whole block is skipped when the king is in the centre (files c–e), because
# a centralised king in the middlegame is already penalised by PST_KING_MG and
# the shield geometry doesn't apply.
function _eval_king_safety(b::Board, cfg::EngineConfig = DEFAULT_CONFIG)::Int
    # Game phase: 24 = full material, 0 = king+pawns only.
    ph = 0
    for c in (White, Black)
        ph += count_bits(bb(b, c, Knight)) + count_bits(bb(b, c, Bishop))
        ph += 2 * count_bits(bb(b, c, Rook))
        ph += 4 * count_bits(bb(b, c, Queen))
    end
    ph = min(ph, 24)

    score = 0
    occ   = all_occ(b)
    for c in (White, Black)
        sign     = c == White ? 1 : -1
        ks       = lsb(bb(b, c, King))
        kf       = file_of(ks); kr = rank_of(ks)
        their_ks = lsb(bb(b, other(c), King))
        their_kf = file_of(their_ks)
        pawns    = bb(b, c, Pawn)
        them     = other(c)
        fwd      = c == White ? 1 : -1

        # ── 1. King Zone attacks ──────────────────────────────────────────────
        # Penalise the side whose king's surrounding squares are heavily
        # attacked by enemy pieces.  This is a proxy for attacking pressure.
        # We count how many enemy pieces (excluding pawns/king) attack any
        # square in the 3x3 zone around our king.
        if ph >= 8
            king_zone = king_attacks(ks) | sq_bb(ks)
            enemy_atk_count  = 0
            enemy_atk_weight = 0

            for s in BitIter(bb(b, them, Knight))
                if (knight_attacks(s) & king_zone) != 0
                    enemy_atk_count += 1; enemy_atk_weight += 5
                end
            end
            for s in BitIter(bb(b, them, Bishop))
                if (bishop_attacks(s, occ) & king_zone) != 0
                    enemy_atk_count += 1; enemy_atk_weight += 5
                end
            end
            for s in BitIter(bb(b, them, Rook))
                if (rook_attacks(s, occ) & king_zone) != 0
                    enemy_atk_count += 1; enemy_atk_weight += 8
                end
            end
            for s in BitIter(bb(b, them, Queen))
                if (queen_attacks(s, occ) & king_zone) != 0
                    enemy_atk_count += 1; enemy_atk_weight += 20
                end
            end

            if enemy_atk_count >= 1
                # Scale by phase: full strength at ph=24, vanishes at ph=0.
                # Penalty is weighted by (count * weight) to reflect pressure.
                penalty = (enemy_atk_weight * enemy_atk_count * ph) ÷ 24
                score -= sign * penalty
            end
        end

        if kf <= 2 || kf >= 5
            # King has castled — evaluate pawn shield and open-file penalties.

            # Close shield (1 rank ahead): +20 each
            r1 = kr + fwd
            if 0 <= r1 <= 7
                for df in -1:1
                    sf = kf + df
                    0 <= sf <= 7 || continue
                    (pawns & sq_bb(sq(sf, r1))) != 0 && (score += sign * 20)
                end
            end

            # Far shield (2 ranks ahead): +8 each
            r2 = kr + 2*fwd
            if 0 <= r2 <= 7
                for df in -1:1
                    sf = kf + df
                    0 <= sf <= 7 || continue
                    (pawns & sq_bb(sq(sf, r2))) != 0 && (score += sign * 8)
                end
            end

            # Semi-open file penalty: a pawn on g4 with the king on g1 provides
            # no protection — only pawns at the close (r1) or far (r2) shield
            # ranks count.  Using the full file mask would miss the case where
            # the pawn has advanced past the shield zone, leaving the king
            # exposed to rooks and queens on what is effectively an open file.
            for df in -1:1
                sf = kf + df
                0 <= sf <= 7 || continue
                has_shield = (0 <= r1 <= 7 && (pawns & sq_bb(sq(sf, r1))) != 0) ||
                             (0 <= r2 <= 7 && (pawns & sq_bb(sq(sf, r2))) != 0)
                has_shield || (score -= sign * 22)
            end

            # h-pawn hook penalty: when the h-pawn has advanced to the 6th rank
            # (h6 for Black, h3 for White) it creates a "hook" for the opponent —
            # Rxh6 sacrifices, Qh5-g6, and g7# mating patterns all become viable.
            # The far-shield code rewards h6 as +8; this penalty overrides that
            # incentive and makes the engine actively avoid pushing the h-pawn.
            hook_rank = c == White ? 2 : 5
            if (pawns & sq_bb(sq(7, hook_rank))) != 0
                score -= sign * 20
            end
        end

        # Pawn storm bonus (gated by cfg.eval_pawn_storm):
        # when the kings are on opposite flanks (file distance
        # >= 3) we gain by advancing pawns toward the enemy king — this is the
        # classical "pawn storm" attacking motif.  We award +6cp per rank
        # advanced beyond rank 3 (0-indexed) for any of our pawns within two
        # files of the enemy king, reflecting that advanced pawns on the enemy
        # king's flank create real mating threats.
        if cfg.eval_pawn_storm && abs(kf - their_kf) >= 3
            for s in BitIter(pawns)
                abs(file_of(s) - their_kf) <= 2 || continue
                advance = c == White ? rank_of(s) - 2 : 5 - rank_of(s)
                advance > 0 && (score += sign * advance * 6)
            end
        end
    end
    score
end

# Space advantage: count safe center squares that our pawns attack but enemy
# pawns do not.  "Safe" means the enemy cannot immediately retake with a pawn.
# The evaluation zone is ranks 4–6 (0-indexed 3–5), files c–f (0-indexed 2–5),
# i.e. the extended center on both sides of the board.
#
# We use bulk pawn-attack bitboards to stay branchless (no square iteration).
# File-wrap masking is critical: a pawn on file h shifted left by 7 appears on
# file a of the next rank — the mask corrects this artifact.
#
#   White left attacks:  (pawns << 7) & ~FILE_MASK[8]   (a-file would wrap → exclude h)
#   White right attacks: (pawns << 9) & ~FILE_MASK[1]   (h-file would wrap → exclude a)
#   Black left attacks:  (pawns >> 9) & ~FILE_MASK[8]
#   Black right attacks: (pawns >> 7) & ~FILE_MASK[1]
function _eval_space(b::Board)::Int
    score = 0
    space_zone = (RANK_MASK[4] | RANK_MASK[5] | RANK_MASK[6]) &
                 (FILE_MASK[3] | FILE_MASK[4] | FILE_MASK[5] | FILE_MASK[6])
    for c in (White, Black)
        sign        = c == White ? 1 : -1
        pawns       = bb(b, c, Pawn)
        enemy_pawns = bb(b, other(c), Pawn)
        if c == White
            our_atk   = ((pawns << 7) & ~FILE_MASK[8]) | ((pawns << 9) & ~FILE_MASK[1])
            enemy_atk = ((enemy_pawns >> 9) & ~FILE_MASK[8]) | ((enemy_pawns >> 7) & ~FILE_MASK[1])
        else
            our_atk   = ((pawns >> 9) & ~FILE_MASK[8]) | ((pawns >> 7) & ~FILE_MASK[1])
            enemy_atk = ((enemy_pawns << 7) & ~FILE_MASK[8]) | ((enemy_pawns << 9) & ~FILE_MASK[1])
        end
        safe_space = our_atk & space_zone & ~enemy_atk
        score += sign * count_bits(safe_space) * 4
    end
    score
end
_eval_tempo(b::Board)::Int = b.side == White ? 10 : -10

# ── Public API ─────────────────────────────────────────────────────────────────

# How far (in centipawns) the slow eval terms (mobility, king safety, pawn
# structure, space, …) can realistically move the score away from the
# material + PST core.  Chosen as a conservative bound: trapped-piece
# penalties (−100), king-zone attack penalties, and stacked passer bonuses
# rarely sum past ~400 cp in one direction.
const LAZY_EVAL_MARGIN = 450

"""
    evaluate_lazy(b, cfg, alpha, beta) → Int

Static evaluation from the **side-to-move** perspective, with a lazy shortcut:
when the cheap core (material + tapered PST + tempo) already lies more than
`LAZY_EVAL_MARGIN` outside the `(alpha, beta)` window, the core is returned
directly — the remaining slow terms cannot bring the score back inside the
window, so any bound-relative decision (stand-pat cutoff, futility test) is
unaffected.  Otherwise falls through to the full `evaluate`.
"""
@inline function evaluate_lazy(b::Board, cfg::EngineConfig, alpha::Int, beta::Int)::Int
    if cfg.lazy_eval
        ph   = Int(clamp(b.phase, 0, 24))
        core = Int(b.material) + (ph * Int(b.mg_score) + (24 - ph) * Int(b.eg_score)) ÷ 24
        sc   = (b.side == White ? core : -core) + 10   # +10 tempo for the side to move
        (sc - LAZY_EVAL_MARGIN >= beta || sc + LAZY_EVAL_MARGIN <= alpha) && return sc
    end
    (b.side == White ? 1 : -1) * total(evaluate(b, cfg))
end

function evaluate(b::Board, cfg::EngineConfig = DEFAULT_CONFIG)::EvalBreakdown
    ph = Int(clamp(b.phase, 0, 24))
    material = b.material

    # Material balance (without PST) for complexity and other terms
    # (Note: b.material already tracks this incrementally)
    # A queen gives the weaker side mating threats and tactical counterplay that
    # pure rook endings deny.  Discourages the losing side from swapping queens
    # and the winning side from forcing simplification.
    complexity = 0
    if cfg.eval_complexity && abs(material) >= 60 &&
       (bb(b, White, Queen) | bb(b, Black, Queen)) != BB(0)
        complexity = material < 0 ? 20 : -20   # bonus for the side that is behind
    end

    EvalBreakdown(
        Int(material),
        _eval_piece_activity(b, cfg),
        _eval_pawn_structure(b, cfg),
        _eval_king_safety(b, cfg),
        (cfg.eval_space ? _eval_space(b) : 0) + complexity,
        _eval_tempo(b),
    )
end

function explain(e::EvalBreakdown; io::IO = stdout)
    t = total(e)
    println(io, "Evaluation: $(t > 0 ? "+" : "")$t cp  ($(t > 0 ? "White" : t < 0 ? "Black" : "equal"))")
    println(io, "  Material:       $(e.material > 0 ? "+" : "")$(e.material)")
    println(io, "  Piece activity: $(e.piece_activity > 0 ? "+" : "")$(e.piece_activity)")
    println(io, "  Pawn structure: $(e.pawn_structure > 0 ? "+" : "")$(e.pawn_structure)")
    println(io, "  King safety:    $(e.king_safety > 0 ? "+" : "")$(e.king_safety)")
    println(io, "  Space:          $(e.space > 0 ? "+" : "")$(e.space)")
    println(io, "  Tempo:          $(e.tempo > 0 ? "+" : "")$(e.tempo)")
end
