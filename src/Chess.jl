# Chess engine module.  Architectural layers (each include builds on the previous):
#
#   types        — Board, Move, Piece, Color, PieceKind, bitboard aliases
#   attacks      — precomputed sliding/jumping attack tables (magic bitboards)
#   zobrist      — Zobrist hash init; incremental hash used by the TT in search
#   fen          — FEN parsing/serialisation, UCI move conversion
#   movegen      — legal-move generation, make/unmake, check detection
#   eval         — static evaluation (material + PST + structure + king safety)
#   search       — alpha-beta with iterative deepening, TT, move ordering
#   explain      — natural-language move explanations for Lichess chat
#   perft        — move-generation correctness tests
module Chess

using Printf

include("types.jl")
include("attacks.jl")
include("zobrist.jl")
include("fen.jl")
include("movegen.jl")
include("config.jl")
include("syzygy.jl")
include("eval.jl")
include("search.jl")
include("selfplay.jl")
include("explain.jl")
include("perft.jl")

function __init__()
    _init_attacks!()
    _init_castling_masks!()
    _init_zobrist!()
    _init_eval!()
end

export
    # types
    Board, Move, MoveList, Color, PieceKind, Piece,
    White, Black, NoPiece, Pawn, Knight, Bishop, Rook, Queen, King,
    NULL_MOVE,
    # flags
    MF_QUIET, MF_DPUSH, MF_KS_CAST, MF_QS_CAST,
    MF_CAPTURE, MF_EP, MF_PROMO, MF_PROMO_N, MF_PROMO_B, MF_PROMO_R, MF_PROMO_Q,
    MF_PRCAP_N, MF_PRCAP_B, MF_PRCAP_R, MF_PRCAP_Q,
    # square helpers
    sq, file_of, rank_of, sq_bb, sq_name,
    A1, B1, C1, D1, E1, F1, G1, H1,
    A8, B8, C8, D8, E8, F8, G8, H8,
    # bitboard helpers
    BB, bb, lsb, BitIter, count_bits, CR_WK, CR_WQ, CR_BK, CR_BQ,
    # board ops
    all_occ, other,
    # fen
    board_from_fen, board_to_fen, display_board, STARTPOS,
    move_from_uci, move_to_uci, apply_moves!,
    # move query
    from_sq, to_sq, flags, is_capture, is_promo, is_castle, is_ep, promo_kind,
    # movegen
    generate_moves!, generate_captures!, make_move!, unmake_move!, king_in_check, count_legal_moves,
    # attacks
    attackers_to, sq_attacked_by,
    rook_attacks, bishop_attacks, queen_attacks, knight_attacks, king_attacks, pawn_attacks,
    # zobrist
    compute_hash,
    # eval
    EvalBreakdown, evaluate, total, explain, PIECE_VALUE,
    # config
    EngineConfig, DEFAULT_CONFIG,
    # search
    SearchInfo, SearchResult, search_move, MATE_SCORE,
    # selfplay
    MatchResult, selfplay,
    # explain
    explain_move, explain_opponent_move, explain_pv_outcome,
    # syzygy
    syzygy_init!, syzygy_probe_wdl,
    WDL_LOSS, WDL_BLESSED_LOSS, WDL_DRAW, WDL_CURSED_WIN, WDL_WIN, TB_LARGEST,
    # internal syzygy helpers (needed by tests)
    TRIANGLE, LOWER, DIAG, KK_IDX, BINOMIAL, PIVFAC,
    _board_key, _recalc_key, _enc_type_from_name,
    _offdiag, _flipdiag, _load_wdl_table, _INITIALIZED,
    # perft
    perft, perft_divide, run_perft_suite, PERFT_SUITE

end
