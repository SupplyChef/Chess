# weights.jl — All tunable evaluation parameters in a single flat vector.
#
# Design: every scalar constant and every PST entry in eval.jl is represented
# here.  During normal play the engine uses the hard-coded defaults in eval.jl
# for maximum speed.  During tuning, extract_features() linearises the eval so
# that the score = dot(θ, φ(pos)), and Optim.jl L-BFGS minimises the sigmoid
# MSE loss against Stockfish-16 labels from ChessBench.
#
# Vector layout (total N_WEIGHTS = 840 entries):
#   [1..5]     material: pawn, knight, bishop, rook, queen
#   [6..389]   PST MG: 6 piece types × 64 squares (pawn, knight, bishop, rook, queen, king)
#   [390..773] PST EG: same ordering
#   [774..840] 67 scalar bonuses (see FEAT_* constants below)

# ── Dimension constants ────────────────────────────────────────────────────────
const N_MAT      = 5
const N_PST_HALF = 6 * 64    # 384  (one phase)
const N_PST      = 2 * N_PST_HALF  # 768
const N_SCALAR   = 67
const N_WEIGHTS  = N_MAT + N_PST + N_SCALAR  # 840

# ── PST offset helpers ─────────────────────────────────────────────────────────
# piece_idx: 1=Pawn 2=Knight 3=Bishop 4=Rook 5=Queen 6=King
@inline _pst_mg_base(piece_idx::Int) = N_MAT + (piece_idx - 1) * 64
@inline _pst_eg_base(piece_idx::Int) = N_MAT + N_PST_HALF + (piece_idx - 1) * 64

# ── Scalar feature index constants ────────────────────────────────────────────
const _S = N_MAT + N_PST  # = 773; scalar features start at _S + 1

const FEAT_ROOK_OPEN        = _S + 1
const FEAT_ROOK_SEMI        = _S + 2
const FEAT_ROOK_7TH         = _S + 3
const FEAT_CONNECTED_ROOKS  = _S + 4
const FEAT_OUTPOST_FULL_SUP = _S + 5
const FEAT_OUTPOST_FULL_FREE= _S + 6
const FEAT_OUTPOST_SEMI_SUP = _S + 7
const FEAT_OUTPOST_SEMI_FREE= _S + 8
const FEAT_SAFE_INVASION    = _S + 9
const FEAT_BISHOP_PAIR_BASE = _S + 10  # ±has_pair
const FEAT_BISHOP_PAIR_EG   = _S + 11  # ±has_pair × (24−ph)/24
const FEAT_KNIGHT_MOB       = _S + 12  # signed safe-move count
const FEAT_BISHOP_MOB       = _S + 13
const FEAT_ROOK_MOB         = _S + 14
const FEAT_QUEEN_MOB        = _S + 15
const FEAT_KNIGHT_TRAP0     = _S + 16  # knights with 0 safe moves
const FEAT_KNIGHT_TRAP1     = _S + 17
const FEAT_BISHOP_TRAP0     = _S + 18
const FEAT_BISHOP_TRAP1     = _S + 19
const FEAT_BISHOP_TRAP2     = _S + 20
const FEAT_BISHOP_TRAP3     = _S + 21
const FEAT_ROOK_TRAP0       = _S + 22
const FEAT_ROOK_TRAP1       = _S + 23
const FEAT_ROOK_TRAP2       = _S + 24
const FEAT_QUEEN_TRAP0      = _S + 25
const FEAT_QUEEN_TRAP12     = _S + 26
const FEAT_CENTER_CTRL      = _S + 27  # pieces controlling d4/e4/d5/e5
const FEAT_PIN_SCALE        = _S + 28  # signed Σ piece_value÷8 for pinned pieces
const FEAT_TROPISM_OWN_PASS = _S + 29
const FEAT_TROPISM_ENE_PASS = _S + 30
const FEAT_TROPISM_CORNER   = _S + 31
const FEAT_TROPISM_KING_PROX= _S + 32
const FEAT_ROOK_BEHIND_PASS = _S + 33
const FEAT_ROOK_BLOCK_PASS  = _S + 34
const FEAT_ROOK_CUTOFF      = _S + 35
const FEAT_WRONG_BISHOP     = _S + 36
const FEAT_KBNK_CORNER      = _S + 37
const FEAT_KBNK_PROX        = _S + 38
const FEAT_MOPUP_CORNER     = _S + 39
const FEAT_MOPUP_PROX       = _S + 40
const FEAT_PASSED_R3        = _S + 41   # rank 3 bonus (15 cp)
const FEAT_PASSED_R4        = _S + 42   # rank 4 bonus (35 cp)
const FEAT_PASSED_R5        = _S + 43   # rank 5 bonus (60 cp)
const FEAT_PASSED_R6        = _S + 44   # rank 6 bonus (90 cp)
const FEAT_PASSED_R7        = _S + 45   # rank 7 bonus (130 cp, near promotion)
const FEAT_DOUBLED_PAWN     = _S + 46
const FEAT_ISOLATED_PAWN    = _S + 47
const FEAT_BACKWARD_PAWN    = _S + 48
const FEAT_FREE_PASSER      = _S + 49
const FEAT_CONNECTED_PASS   = _S + 50
const FEAT_PM_BASE          = _S + 51  # pawn majority: majority count
const FEAT_PM_ADV           = _S + 52  # pawn majority: advancement bonus
const FEAT_KING_ATK_N       = _S + 53
const FEAT_KING_ATK_B       = _S + 54
const FEAT_KING_ATK_R       = _S + 55
const FEAT_KING_ATK_Q       = _S + 56
const FEAT_CASTLING_KS      = _S + 57
const FEAT_CASTLING_QS      = _S + 58
const FEAT_CENTER_KING      = _S + 59  # ×phase → penalty
const FEAT_SHIELD_CLOSE     = _S + 60
const FEAT_SHIELD_FAR       = _S + 61
const FEAT_SEMIOPEN_KING    = _S + 62
const FEAT_HPAWN_HOOK       = _S + 63
const FEAT_PAWN_STORM       = _S + 64
const FEAT_SPACE            = _S + 65
const FEAT_TEMPO            = _S + 66
const FEAT_COMPLEXITY       = _S + 67

# ── Default weight vector ──────────────────────────────────────────────────────
# Initialised from the hard-coded constants in eval.jl.  Called once after
# _init_eval!() so that the PST arrays are already populated.
function default_weights()::Vector{Float64}
    w = zeros(Float64, N_WEIGHTS)

    # Material
    w[1] = 100.0   # pawn
    w[2] = 320.0   # knight
    w[3] = 335.0   # bishop
    w[4] = 500.0   # rook
    w[5] = 1000.0  # queen

    # PST MG (white's visual orientation, rank-8→rank-1 in each 64-entry block)
    for (i, pst) in enumerate((PST_PAWN_MG, PST_KNIGHT_MG, PST_BISHOP_MG,
                                PST_ROOK_MG, PST_QUEEN_MG, PST_KING_MG))
        base = _pst_mg_base(i)
        for j in 1:64
            w[base + j] = Float64(pst[j])
        end
    end
    # PST EG
    for (i, pst) in enumerate((PST_PAWN_EG, PST_KNIGHT_EG, PST_BISHOP_EG,
                                PST_ROOK_EG, PST_QUEEN_EG, PST_KING_EG))
        base = _pst_eg_base(i)
        for j in 1:64
            w[base + j] = Float64(pst[j])
        end
    end

    # Scalar defaults matching eval.jl
    w[FEAT_ROOK_OPEN]         =  20.0
    w[FEAT_ROOK_SEMI]         =  10.0
    w[FEAT_ROOK_7TH]          =  15.0
    w[FEAT_CONNECTED_ROOKS]   =  15.0
    w[FEAT_OUTPOST_FULL_SUP]  =  32.0
    w[FEAT_OUTPOST_FULL_FREE] =  20.0
    w[FEAT_OUTPOST_SEMI_SUP]  =  14.0
    w[FEAT_OUTPOST_SEMI_FREE] =   8.0
    w[FEAT_SAFE_INVASION]     =   4.0
    w[FEAT_BISHOP_PAIR_BASE]  =  20.0
    w[FEAT_BISHOP_PAIR_EG]    =  10.0   # extra bonus at bare endgame (MG=20, EG=30)
    w[FEAT_KNIGHT_MOB]        =   1.0
    w[FEAT_BISHOP_MOB]        =   0.5
    w[FEAT_ROOK_MOB]          =   0.5
    w[FEAT_QUEEN_MOB]         =   1.0/3.0
    w[FEAT_KNIGHT_TRAP0]      = 100.0
    w[FEAT_KNIGHT_TRAP1]      =  25.0
    w[FEAT_BISHOP_TRAP0]      = 100.0
    w[FEAT_BISHOP_TRAP1]      =  25.0
    w[FEAT_BISHOP_TRAP2]      =  10.0
    w[FEAT_BISHOP_TRAP3]      =   4.0
    w[FEAT_ROOK_TRAP0]        = 100.0
    w[FEAT_ROOK_TRAP1]        =  18.0
    w[FEAT_ROOK_TRAP2]        =   6.0
    w[FEAT_QUEEN_TRAP0]       = 150.0
    w[FEAT_QUEEN_TRAP12]      =  30.0
    w[FEAT_CENTER_CTRL]       =   1.0
    w[FEAT_PIN_SCALE]         =   1.0   # multiplied by piece_value÷8 in feature
    w[FEAT_TROPISM_OWN_PASS]  =   2.0
    w[FEAT_TROPISM_ENE_PASS]  =   3.0
    w[FEAT_TROPISM_CORNER]    =   5.0
    w[FEAT_TROPISM_KING_PROX] =   4.0
    w[FEAT_ROOK_BEHIND_PASS]  =  25.0
    w[FEAT_ROOK_BLOCK_PASS]   =  20.0
    w[FEAT_ROOK_CUTOFF]       =  30.0
    w[FEAT_WRONG_BISHOP]      = 150.0
    w[FEAT_KBNK_CORNER]       =  12.0
    w[FEAT_KBNK_PROX]         =   8.0
    w[FEAT_MOPUP_CORNER]      =  15.0
    w[FEAT_MOPUP_PROX]        =  12.0
    w[FEAT_PASSED_R3]         =  15.0
    w[FEAT_PASSED_R4]         =  35.0
    w[FEAT_PASSED_R5]         =  60.0
    w[FEAT_PASSED_R6]         =  90.0
    w[FEAT_PASSED_R7]         = 130.0
    w[FEAT_DOUBLED_PAWN]      =  20.0
    w[FEAT_ISOLATED_PAWN]     =  20.0
    w[FEAT_BACKWARD_PAWN]     =  15.0
    w[FEAT_FREE_PASSER]       =  15.0
    w[FEAT_CONNECTED_PASS]    =  30.0
    w[FEAT_PM_BASE]           =  20.0
    w[FEAT_PM_ADV]            =   5.0
    w[FEAT_KING_ATK_N]        =   5.0
    w[FEAT_KING_ATK_B]        =   5.0
    w[FEAT_KING_ATK_R]        =   8.0
    w[FEAT_KING_ATK_Q]        =  20.0
    w[FEAT_CASTLING_KS]       =   5.0
    w[FEAT_CASTLING_QS]       =   4.0
    w[FEAT_CENTER_KING]       =   3.0   # × phase
    w[FEAT_SHIELD_CLOSE]      =  20.0
    w[FEAT_SHIELD_FAR]        =   8.0
    w[FEAT_SEMIOPEN_KING]     =  22.0
    w[FEAT_HPAWN_HOOK]        =  20.0
    w[FEAT_PAWN_STORM]        =   6.0
    w[FEAT_SPACE]             =   4.0
    w[FEAT_TEMPO]             =  10.0
    w[FEAT_COMPLEXITY]        =  20.0

    w
end

# ── Apply weights → updated eval.jl constants ─────────────────────────────────
# After training, call this to write the new weights back into the source file.
# Returns a string of Julia code that replaces the constant definitions.
function weights_to_source(w::Vector{Float64})::String
    io = IOBuffer()
    println(io, "# Tuned by ChessBench training — replace constants in eval.jl")
    println(io, "")
    println(io, "const PIECE_VALUE = (0, $(round(Int,w[1])), $(round(Int,w[2])), $(round(Int,w[3])), $(round(Int,w[4])), $(round(Int,w[5])), 20_000)")
    for (name, pidx) in (("PST_PAWN_MG",1),("PST_KNIGHT_MG",2),("PST_BISHOP_MG",3),
                          ("PST_ROOK_MG",4),("PST_QUEEN_MG",5),("PST_KING_MG",6))
        base = _pst_mg_base(pidx)
        vals = [round(Int, w[base+j]) for j in 1:64]
        println(io, "const $name = Int16$(vals)")
    end
    for (name, pidx) in (("PST_PAWN_EG",1),("PST_KNIGHT_EG",2),("PST_BISHOP_EG",3),
                          ("PST_ROOK_EG",4),("PST_QUEEN_EG",5),("PST_KING_EG",6))
        base = _pst_eg_base(pidx)
        vals = [round(Int, w[base+j]) for j in 1:64]
        println(io, "const $name = Int16$(vals)")
    end
    String(take!(io))
end
