# Static evaluation. Positive = White is better (centipawns).

# ── Piece values ───────────────────────────────────────────────────────────────
# Indexed by Int(kind)+1: NoPiece=0 Pawn=100 Knight=320 Bishop=330 Rook=500 Queen=900 King=20000
const PIECE_VALUE = (0, 100, 320, 330, 500, 900, 20_000)

# ── Piece-square tables ────────────────────────────────────────────────────────
# 64 entries written rank-8 → rank-1, file-a → file-h (visual board order).
# For White: pst[sq] = table[(7 − rank) × 8 + file + 1]
# For Black: mirror by rank → table[rank × 8 + file + 1]

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

# King tables blend from MG (hide behind pawns) to EG (centralize).
const PST_KING_MG = Int16[
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -20,-30,-30,-40,-40,-30,-30,-20,
    -10,-20,-20,-25,-25,-20,-20,-10,
    -20,-20,-20,-25,-25,-20,-20,-20,   # rank 2: was +20 for corners — king must NOT walk here in MG
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

# ── Passed-pawn masks ──────────────────────────────────────────────────────────
# _PASSED_W[s+1] = squares that must be free of black pawns for white pawn on s to be passed.
# _PASSED_B[s+1] = same for black.
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
    # Used to taper the king PST between MG and EG.
    ph = 0
    for c in (White, Black)
        ph += count_bits(bb(b, c, Knight)) + count_bits(bb(b, c, Bishop))
        ph += 2 * count_bits(bb(b, c, Rook))
        ph += 4 * count_bits(bb(b, c, Queen))
    end
    ph = min(ph, 24)

    score = 0
    for c in (White, Black)
        sign = c == White ? 1 : -1
        for s in BitIter(bb(b, c, Pawn));   score += sign * _pst(PST_PAWN,   c, s); end
        for s in BitIter(bb(b, c, Knight)); score += sign * _pst(PST_KNIGHT, c, s); end
        for s in BitIter(bb(b, c, Bishop)); score += sign * _pst(PST_BISHOP, c, s); end
        for s in BitIter(bb(b, c, Rook));   score += sign * _pst(PST_ROOK,   c, s); end
        for s in BitIter(bb(b, c, Queen));  score += sign * _pst(PST_QUEEN,  c, s); end

        ks = lsb(bb(b, c, King))
        king_bonus = (ph * _pst(PST_KING_MG, c, ks) + (24 - ph) * _pst(PST_KING_EG, c, ks)) ÷ 24
        score += sign * king_bonus
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
            # Doubled pawns: penalty per extra pawn on the same file
            n > 1 && (score += sign * (n - 1) * (-15))
            # Isolated pawns: no friendly pawn on either adjacent file
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

function _eval_king_safety(b::Board)::Int
    score = 0
    for c in (White, Black)
        sign  = c == White ? 1 : -1
        ks    = lsb(bb(b, c, King))
        kf    = file_of(ks); kr = rank_of(ks)
        pawns = bb(b, c, Pawn)

        # Pawn shield only relevant when king is castled (queenside a-c or kingside f-h)
        (kf <= 2 || kf >= 5) || continue

        fwd = c == White ? 1 : -1

        # Close shield (1 rank ahead): +20 each — pushing g4/h4 costs 20cp per pawn
        r1 = kr + fwd
        if 0 <= r1 <= 7
            for df in -1:1
                sf = kf + df
                0 <= sf <= 7 || continue
                (pawns & sq_bb(sq(sf, r1))) != 0 && (score += sign * 20)
            end
        end

        # Far shield (2 ranks ahead): +8 each — h3 still counts but less than h2
        r2 = kr + 2*fwd
        if 0 <= r2 <= 7
            for df in -1:1
                sf = kf + df
                0 <= sf <= 7 || continue
                (pawns & sq_bb(sq(sf, r2))) != 0 && (score += sign * 8)
            end
        end

        # Semi-open file penalty: no friendly pawn anywhere on a file beside/under king
        # Open files near the castled king are invasion routes for rooks/queens.
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
