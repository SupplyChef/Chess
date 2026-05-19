# Static evaluation. Positive = White is better (centipawns).

# ── Piece values ───────────────────────────────────────────────────────────────
# Indexed by Int(kind)+1: NoPiece=0 Pawn=100 Knight=320 Bishop=330 Rook=500 Queen=900 King=20000
const PIECE_VALUE = (0, 100, 320, 330, 500, 900, 20_000)

# ── Piece-square tables ────────────────────────────────────────────────────────
# 64 entries written rank-8 → rank-1, file-a → file-h (visual board order).
# For White: pst[sq] = table[(7 − rank) × 8 + file + 1]
# For Black: mirror by rank → table[rank × 8 + file + 1]
# The mirror formula ensures both colors use the same geometric preferences
# without storing two tables.

@inline function _pst(table, c::Color, s::Square)::Int
    idx = c == White ? (7 - rank_of(s)) * 8 + file_of(s) + 1 :
                            rank_of(s)  * 8 + file_of(s) + 1
    Int(table[idx])
end

const PST_PAWN = Int16[
     0,  0,  0,  0,  0,  0,  0,  0,
    50, 50, 50, 50, 50, 50, 50, 50,
    10, 10, 20, 30, 30, 20, 10, 10,
     5,  5, 10, 25, 25, 10,  5,  5,
     0,  0,  0, 20, 20,  0,  0,  0,
     5, -5,-10,  0,  0,-10, -5,  5,
     5, 10, 10,-20,-20, 10, 10,  5,
     0,  0,  0,  0,  0,  0,  0,  0,
]

const PST_KNIGHT = Int16[
    -50,-40,-30,-30,-30,-30,-40,-50,
    -40,-20,  0,  0,  0,  0,-20,-40,
    -30,  0, 10, 15, 15, 10,  0,-30,
    -30,  5, 15, 20, 20, 15,  5,-30,
    -30,  0, 15, 20, 20, 15,  0,-30,
    -30,  5, 10, 15, 15, 10,  5,-30,
    -40,-20,  0,  5,  5,  0,-20,-40,
    -50,-40,-30,-30,-30,-30,-40,-50,
]

const PST_BISHOP = Int16[
    -20,-10,-10,-10,-10,-10,-10,-20,
    -10,  0,  0,  0,  0,  0,  0,-10,
    -10,  0,  5, 10, 10,  5,  0,-10,
    -10,  5,  5, 10, 10,  5,  5,-10,
    -10,  0, 10, 10, 10, 10,  0,-10,
    -10, 10, 10, 10, 10, 10, 10,-10,
    -10,  5,  0,  0,  0,  0,  5,-10,
    -20,-10,-10,-10,-10,-10,-10,-20,
]

const PST_ROOK = Int16[
     0,  0,  0,  0,  0,  0,  0,  0,
     5, 10, 10, 10, 10, 10, 10,  5,
    -5,  0,  0,  0,  0,  0,  0, -5,
    -5,  0,  0,  0,  0,  0,  0, -5,
    -5,  0,  0,  0,  0,  0,  0, -5,
    -5,  0,  0,  0,  0,  0,  0, -5,
    -5,  0,  0,  0,  0,  0,  0, -5,
     0,  0,  0,  5,  5,  0,  0,  0,
]

const PST_QUEEN = Int16[
    -20,-10,-10, -5, -5,-10,-10,-20,
    -10,  0,  0,  0,  0,  0,  0,-10,
    -10,  0,  5,  5,  5,  5,  0,-10,
     -5,  0,  5,  5,  5,  5,  0, -5,
      0,  0,  5,  5,  5,  5,  0, -5,
    -10,  5,  5,  5,  5,  5,  0,-10,
    -10,  0,  5,  0,  0,  0,  0,-10,
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

# Bonus in centipawns for a passed pawn based on how far advanced it is.
# Indexed by rank_of(s)+1 (1=rank1 … 8=rank8); ranks 1 and 8 unused for pawns.
# The exponential-ish growth reflects that a pawn on rank 7 is nearly a queen
# while a pawn on rank 3 is only marginally threatening.
const PASSED_BONUS_W = (0, 0, 10, 20, 40, 60, 80, 0)
const PASSED_BONUS_B = (0, 80, 60, 40, 20, 10,  0, 0)

@inline _passed_bonus(s::Square, c::Color)::Int =
    c == White ? PASSED_BONUS_W[rank_of(s)+1] : PASSED_BONUS_B[rank_of(s)+1]

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

function _eval_material(b::Board)::Int
    score = 0
    for k in (Pawn, Knight, Bishop, Rook, Queen)
        v = PIECE_VALUE[Int(k)+1]
        score += (count_bits(bb(b, White, k)) - count_bits(bb(b, Black, k))) * v
    end
    score
end

function _eval_piece_activity(b::Board)::Int
    # Game phase: 24 = full material, 0 = king+pawns only.
    # Used to blend MG and EG king tables; also controls how aggressively
    # king centralisation is incentivised.
    ph = 0
    for c in (White, Black)
        ph += count_bits(bb(b, c, Knight)) + count_bits(bb(b, c, Bishop))
        ph += 2 * count_bits(bb(b, c, Rook))
        ph += 4 * count_bits(bb(b, c, Queen))
    end
    ph = min(ph, 24)

    occ   = all_occ(b)
    score = 0
    for c in (White, Black)
        sign        = c == White ? 1 : -1
        my_pawns    = bb(b, c, Pawn)
        enemy_pawns = bb(b, other(c), Pawn)
        seventh     = c == White ? 6 : 1   # 0-indexed rank of the 7th rank

        for s in BitIter(bb(b, c, Pawn));   score += sign * _pst(PST_PAWN,   c, s); end
        for s in BitIter(bb(b, c, Knight)); score += sign * _pst(PST_KNIGHT, c, s); end
        for s in BitIter(bb(b, c, Bishop)); score += sign * _pst(PST_BISHOP, c, s); end
        for s in BitIter(bb(b, c, Rook));   score += sign * _pst(PST_ROOK,   c, s); end
        for s in BitIter(bb(b, c, Queen));  score += sign * _pst(PST_QUEEN,  c, s); end

        # Tapered king: linear blend between MG and EG scores based on phase.
        ks = lsb(bb(b, c, King))
        king_bonus = (ph * _pst(PST_KING_MG, c, ks) + (24 - ph) * _pst(PST_KING_EG, c, ks)) ÷ 24
        score += sign * king_bonus

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
        # adjacent file at any rank in front of the knight (+20).
        for s in BitIter(bb(b, c, Knight))
            in_opp_half = c == White ? rank_of(s) >= 4 : rank_of(s) <= 3
            in_opp_half || continue
            pmask = (c == White ? _PASSED_W[s+1] : _PASSED_B[s+1]) &
                    ~FILE_MASK[file_of(s)+1]
            (pmask & enemy_pawns) != 0 && continue
            score += sign * 20
        end
    end

    # Bishop pair bonus (+30): two bishops outperform two knights or bishop+knight
    # in open positions because they cover both diagonal colors.
    for c in (White, Black)
        count_bits(bb(b, c, Bishop)) >= 2 && (score += (c == White ? 1 : -1) * 30)
    end

    # Center control: +3cp per piece that attacks any of d4/d5/e4/e5.
    # PSTs reward pieces that occupy the center squares, but a bishop on a2
    # pointing at d5 also exerts meaningful control.  Using the actual attack
    # lookups captures this indirect control that PSTs cannot express.
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
        score += sign * ctrl * 3
    end

    score
end

function _eval_pawn_structure(b::Board)::Int
    score = 0
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
            # because it cannot protect the one ahead of it.
            n > 1 && (score += sign * (n - 1) * (-15))
            # Isolated pawns: no friendly pawn on either adjacent file means
            # this pawn can never be defended by another pawn.
            left  = f > 0 ? pawns & FILE_MASK[f]   : BB(0)
            right = f < 7 ? pawns & FILE_MASK[f+2] : BB(0)
            (left == 0 && right == 0) && (score += sign * n * (-10))
        end

        for s in BitIter(pawns)
            _is_passed(s, c, enemy_pawns) && (score += sign * _passed_bonus(s, c))
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
function _eval_king_safety(b::Board)::Int
    score = 0
    for c in (White, Black)
        sign  = c == White ? 1 : -1
        ks    = lsb(bb(b, c, King))
        kf    = file_of(ks); kr = rank_of(ks)
        pawns = bb(b, c, Pawn)

        # Only evaluate shield for a king that has castled (files a–c or f–h).
        (kf <= 2 || kf >= 5) || continue

        fwd = c == White ? 1 : -1

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

        # Semi-open file penalty: no friendly pawn on a file next to or under
        # the king means that file is a highway for rooks and queens.
        for df in -1:1
            sf = kf + df
            0 <= sf <= 7 || continue
            (pawns & FILE_MASK[sf+1]) == 0 && (score -= sign * 18)
        end
    end
    score
end

# Space and tempo are small corrections; implementing them as stubs keeps
# the first version simple while preserving the EvalBreakdown interface.
_eval_space(::Board)::Int  = 0
_eval_tempo(b::Board)::Int = b.side == White ? 10 : -10

# ── Public API ─────────────────────────────────────────────────────────────────

function evaluate(b::Board)::EvalBreakdown
    EvalBreakdown(
        _eval_material(b),
        _eval_piece_activity(b),
        _eval_pawn_structure(b),
        _eval_king_safety(b),
        _eval_space(b),
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
