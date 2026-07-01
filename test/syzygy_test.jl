@testset "Syzygy — precomputed tables" begin
    # BINOMIAL[k, n+1] = C(n,k)
    @test BINOMIAL[1, 1+1] == 1    # C(1,1)=1
    @test BINOMIAL[1, 5+1] == 5    # C(5,1)=5
    @test BINOMIAL[2, 5+1] == 10   # C(5,2)=10
    @test BINOMIAL[3, 6+1] == 20   # C(6,3)=20
    @test BINOMIAL[1, 0+1] == 0    # C(0,1)=0
    @test BINOMIAL[2, 2+1] == 1    # C(2,2)=1
    @test BINOMIAL[6,63+1] == binomial(Int64(63),Int64(6))

    # TRIANGLE: 64 entries, values 0–9, symmetric board
    @test length(TRIANGLE) == 64
    @test all(x -> 0 <= x <= 9, TRIANGLE)
    @test TRIANGLE[sq(0,0)+1] == 6   # a1 → class 6 (corner)
    @test TRIANGLE[sq(1,0)+1] == 0   # b1
    @test TRIANGLE[sq(0,1)+1] == 0   # a2
    @test TRIANGLE[sq(3,3)+1] == 9   # d4 (inner center)
    @test TRIANGLE[sq(7,7)+1] == 6   # h8 (corner, same class as a1)
    # 8-fold symmetry: a1,h1,a8,h8 all class 6
    for s in [sq(0,0), sq(7,0), sq(0,7), sq(7,7)]
        @test TRIANGLE[s+1] == 6
    end

    # LOWER: 64 entries, 36 distinct non-negative values
    @test length(LOWER) == 64
    @test LOWER[sq(0,0)+1] == 28   # a1 (diagonal element)
    @test LOWER[sq(1,0)+1] == 0    # b1
    @test LOWER[sq(0,1)+1] == 0    # a2

    # DIAG: only diagonal squares are non-zero
    @test length(DIAG) == 64
    @test DIAG[sq(0,0)+1] == 0    # a1 main diagonal
    @test DIAG[sq(1,1)+1] == 1    # b2 main diagonal
    @test DIAG[sq(7,0)+1] == 8    # h1 anti-diagonal
    @test DIAG[sq(0,7)+1] == 15   # a8 anti-diagonal
    @test DIAG[sq(1,0)+1] == 0    # b1: not on either diagonal → 0

    # KK_IDX: 10 arrays of 64 entries each, values -1 or 0..461
    @test length(KK_IDX) == 10
    for arr in KK_IDX
        @test length(arr) == 64
        @test all(x -> x == -1 || (0 <= x <= 461), arr)
    end
    # Maximum index = 461
    @test maximum(maximum, KK_IDX) == 461
    # Kings adjacent or overlapping → -1
    @test KK_IDX[1][sq(0,0)+1] == -1   # tri=0 → wK at b1; bK at a1 adjacent
end

@testset "Syzygy — geometry helpers" begin
    @test _offdiag(sq(0,0)) == 0    # a1 on diagonal
    @test _offdiag(sq(1,0)) == -1   # b1: rank(0)-file(1) = -1
    @test _offdiag(sq(0,1)) == 1    # a2: rank(1)-file(0) = 1
    @test _offdiag(sq(3,3)) == 0    # d4 on diagonal

    @test _flipdiag(sq(2,0)) == sq(0,2)   # c1 → a3
    @test _flipdiag(sq(0,2)) == sq(2,0)   # a3 → c1
    @test _flipdiag(sq(3,5)) == sq(5,3)   # involution
    @test _flipdiag(_flipdiag(sq(4,6))) == sq(4,6)  # double flip = identity

    # Flip helpers via XOR
    @test (sq(0,0) ⊻ 0x07) == sq(7,0)   # a1→h1 (flip file)
    @test (sq(0,0) ⊻ 0x38) == sq(0,7)   # a1→a8 (flip rank)
end

@testset "Syzygy — enc_type detection from piece codes (Bug 2 regression)" begin
    # Piece codes: bits 0-2 = piece kind (King=6, Queen=5, Rook=4, Bishop=3, Knight=2, Pawn=1)
    #              bit  3   = color (0=white, 1=black → 8 added)
    # KRvK: [wK=6, wR=4, bK=14]  — no consecutive equal → KK encoding (enc_type=2)
    @test _detect_enc_type([6, 4, 14]) == 2
    # KQvK: [wK=6, wQ=5, bK=14]  — no consecutive equal → KK encoding
    @test _detect_enc_type([6, 5, 14]) == 2
    # KBvK / KNvK — same shape
    @test _detect_enc_type([6, 3, 14]) == 2   # KBvK
    @test _detect_enc_type([6, 2, 14]) == 2   # KNvK

    # KNNvK: [wK=6, wN=2, wN=2, bK=14] — positions 2 & 3 are equal → 3-leader (enc_type=0)
    @test _detect_enc_type([6, 2, 2, 14]) == 0
    # KRRvK, KBBvK, KQQvK — same pattern: two identical pieces in a row
    @test _detect_enc_type([6, 4, 4, 14]) == 0   # KRRvK
    @test _detect_enc_type([6, 3, 3, 14]) == 0   # KBBvK
    @test _detect_enc_type([6, 5, 5, 14]) == 0   # KQQvK

    # KRBvK: [wK=6, wR=4, wB=3, bK=14] — all distinct → KK encoding
    @test _detect_enc_type([6, 4, 3, 14]) == 2

    # Edge: two-piece array (KvK) — no consecutive-equal check runs → KK
    @test _detect_enc_type([6, 14]) == 2
end

@testset "Syzygy — material key" begin
    b1 = board_from_fen("8/8/8/8/8/8/8/K6k w - - 0 1")
    b2 = board_from_fen("8/8/8/8/8/8/8/k6K b - - 0 1")
    @test _board_key(b1) == "KvK"
    @test _board_key(b2) == "KvK"   # same material regardless of side

    b3 = board_from_fen("8/8/8/8/8/8/8/KR5k w - - 0 1")
    @test _board_key(b3)       == "KRvK"
    @test _board_key(b3, true) == "KvKR"

    # Mirrored position has swapped key
    b4 = board_from_fen("8/8/8/8/8/8/8/kr5K b - - 0 1")
    @test _board_key(b4) == "KvKR"

    # 5-piece
    b5 = board_from_fen("8/8/8/8/8/8/8/KQRBNk w - - 0 1")
    @test _board_key(b5) == "KQRBNvK"
end

@testset "Syzygy — magic validation" begin
    tmp = tempname()
    write(tmp, UInt8[0x00, 0x00, 0x00, 0x00, 0x00])
    @test _load_wdl_table(tmp, "KRvK") === nothing
    rm(tmp)

    # Correct magic but file too short → nothing
    tmp2 = tempname()
    write(tmp2, UInt8[0x71, 0xE8, 0x23, 0x5D])
    @test _load_wdl_table(tmp2, "KRvK") === nothing
    rm(tmp2)
end

@testset "Syzygy — probe guards" begin
    # Not initialised → nothing
    _INITIALIZED[] = false
    b = board_from_fen("8/8/8/8/8/8/8/KR5k w - - 0 1")
    @test syzygy_probe_wdl(b) === nothing

    # Castling rights → nothing
    _INITIALIZED[] = true
    b2 = board_from_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
    @test syzygy_probe_wdl(b2) === nothing
    _INITIALIZED[] = false   # restore for subsequent tests
end

# ── Integration tests (require real tablebase files) ──────────────────────────
const _DEFAULT_SYZYGY = joinpath(@__DIR__, "..", "syzygy")
const SYZYGY_PATH = let p = get(ENV, "SYZYGY_PATH", "")
    isempty(p) ? _DEFAULT_SYZYGY : p
end

@testset "Syzygy — WDL integration (requires SYZYGY_PATH)" begin
    if !isdir(SYZYGY_PATH)
        @test_skip "No tablebase files found (place .rtbw files in Chess/syzygy/ or set SYZYGY_PATH)"
    else
        @test syzygy_init!(SYZYGY_PATH) == true
        @test TB_LARGEST[] >= 3

        # KvK is always a draw
        b = board_from_fen("8/8/8/8/8/8/8/K6k w - - 0 1")
        @test syzygy_probe_wdl(b) == WDL_DRAW

        # K+R vs K: side with rook wins
        b = board_from_fen("8/8/8/8/8/8/8/KR5k w - - 0 1")
        @test syzygy_probe_wdl(b) == WDL_WIN

        # From losing side's perspective (White has rook, Black to move → Black loses)
        b = board_from_fen("8/8/8/8/8/8/8/KR5k b - - 0 1")
        @test syzygy_probe_wdl(b) == WDL_LOSS

        # K+N+N vs K: theoretical draw (knights cannot force mate)
        b = board_from_fen("8/8/8/8/8/8/8/KNN4k w - - 0 1")
        @test syzygy_probe_wdl(b) == WDL_DRAW

        # Castling rights present → cannot probe
        b = board_from_fen("8/8/8/8/8/8/8/KR5k w K - 0 1")
        @test syzygy_probe_wdl(b) === nothing

        # Symmetry: probe from both sides
        b_w = board_from_fen("8/8/8/8/8/8/8/KR5k w - - 0 1")
        b_b = board_from_fen("8/8/8/8/8/8/8/KR5k b - - 0 1")
        r_w = syzygy_probe_wdl(b_w)
        r_b = syzygy_probe_wdl(b_b)
        @test r_w !== nothing
        @test r_b !== nothing
        # White wins with rook, black (without rook) loses
        @test r_w == WDL_WIN
        @test r_b == WDL_LOSS

        # ── Asymmetric table: probe from the weaker-side perspective ─────────────
        # This exercises the key != t.key path (cmirror=8, bside flipped).
        # KRvK: board key matches table key when White has rook; to hit key!=t.key
        # we need Black to hold the stronger material (Black has KR, White has K).
        #
        # KvKR: board key = "KvKR", table key = "KRvK", mirrored key = "KvKR".
        # Black has the rook and wins; White (no rook) loses.
        # Position: WK h1, BK h8, BR a8.
        b_asym_w = board_from_fen("r6k/8/8/8/8/8/8/7K w - - 0 1")   # White to move, white loses
        b_asym_b = board_from_fen("r6k/8/8/8/8/8/8/7K b - - 0 1")   # Black to move, black wins
        @test syzygy_probe_wdl(b_asym_w) == WDL_LOSS   # white has no rook → loses
        @test syzygy_probe_wdl(b_asym_b) == WDL_WIN    # black has rook → wins

        # Probe the same asymmetric position from multiple square layouts to ensure
        # the index computation is not sensitive to the rank at which pieces sit
        # (regression for the sq ⊻ mirror bug).
        for fen in [
            "r6k/8/8/8/8/8/8/7K w - - 0 1",   # BK h8, BR a8, WK h1
            "8/r4k1K/8/8/8/8/8/8 w - - 0 1",   # BK f7, BR a7, WK h7 (all rank 7)
            "r3k3/8/8/8/8/8/8/7K w - - 0 1",   # BK e8, BR a8, WK h1
        ]
            b_l = board_from_fen(fen)
            @test syzygy_probe_wdl(b_l) == WDL_LOSS
        end

        # ── KBvKR endgame: turn-awareness regression ─────────────────────────────
        # KBvKR is theoretically DRAWN with best play (bishop side can hold a
        # fortress), so WDL_DRAW is the expected result for most positions.
        # However, when the bishop is en prise (capturable without recapture),
        # the position is WDL_WIN for the rook side regardless of whose turn it is
        # to move: if it is the rook side's turn they take immediately; if it is the
        # bishop side's turn the bishop is about to be lost.
        #
        # This is the pattern that caused the move-58 blunder in the bug report:
        # engine played Bc1 (bishop to hanging square), probe returned WDL_DRAW
        # instead of WDL_LOSS (from White's perspective), so the blunder scored 0.
        #
        # Position: WK c4, WB c1, BK e5, BR h1.
        # Black (rook side) to move: Rh1xc1+ wins the bishop outright → KvKR.
        # White (bishop side) to move: bishop is hanging, only way to avoid loss
        # is to move it; a correctly-placed bishop draws, but from THIS square (c1)
        # with the rook controlling the first rank, the bishop side is already lost.
        #
        # The probe must return WDL_WIN for the rook side and WDL_LOSS for the
        # bishop side, correctly reflecting whose turn it is.
        let b_hang_b = board_from_fen("8/8/8/4k3/2K5/8/8/2B4r b - - 0 1"),
            b_hang_w = board_from_fen("8/8/8/4k3/2K5/8/8/2B4r w - - 0 1")
            @test syzygy_probe_wdl(b_hang_b) == WDL_WIN    # Black (rook side) to move: bishop is free
            @test syzygy_probe_wdl(b_hang_w) == WDL_LOSS   # White (bishop side) to move: can't save it
        end

        # Non-hanging KBvKR: bishop safely placed → draw from both sides.
        # WK b1, WB f4, BK e6, BR a8: rook cannot immediately take the bishop.
        let b_safe_w = board_from_fen("r7/8/4k3/8/5B2/8/8/1K6 w - - 0 1"),
            b_safe_b = board_from_fen("r7/8/4k3/8/5B2/8/8/1K6 b - - 0 1")
            @test syzygy_probe_wdl(b_safe_w) == WDL_DRAW
            @test syzygy_probe_wdl(b_safe_b) == WDL_DRAW
        end

        if TB_LARGEST[] >= 5
            # K+Q vs K+R: queen wins
            b = board_from_fen("8/8/8/8/3k4/8/8/KQ6 w - - 0 1")
            @test syzygy_probe_wdl(b) == WDL_WIN

            # K+R vs K+R: theoretical draw (symmetric position)
            b = board_from_fen("8/8/8/8/3k1r2/8/8/3K1R2 w - - 0 1")
            @test syzygy_probe_wdl(b) == WDL_DRAW

            # KRR vs KR: the two-rook side wins (asymmetric, exercises key!=t.key for rook side)
            # Black has two rooks, White has one — probe from White's (losing) perspective.
            b_krr_w = board_from_fen("8/8/8/8/3k1rr1/8/8/3K1R2 w - - 0 1")
            b_krr_b = board_from_fen("8/8/8/8/3k1rr1/8/8/3K1R2 b - - 0 1")
            @test syzygy_probe_wdl(b_krr_w) == WDL_LOSS   # White (KR) loses to KRR
            @test syzygy_probe_wdl(b_krr_b) == WDL_WIN    # Black (KRR) wins
        end
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# Tests ported from the official python-chess Syzygy test suite
# (https://github.com/niklasf/python-chess, SyzygyTestCase).
#
# python-chess WDL scale: -2=loss, -1=blessed_loss, 0=draw, +1=cursed_win, +2=win
# Our WDL constants:  WDL_LOSS=0, WDL_BLESSED_LOSS=1, WDL_DRAW=2,
#                     WDL_CURSED_WIN=3, WDL_WIN=4   (= python_wdl + 2)
# ──────────────────────────────────────────────────────────────────────────────
@testset "Syzygy — python-chess ported tests" begin
    if !_INITIALIZED[]
        @warn "Syzygy tablebases not initialised — skipping python-chess ported tests"
    else
        if TB_LARGEST[] >= 4
            # ── KBNvK pawnless table (test_probe_pawnless_wdl_table) ─────────────
            # python: probe_wdl_table returns raw table value for the side stored in
            # the file (always "White = strong side").  Our syzygy_probe_wdl returns
            # from the perspective of the side to move, so we use that throughout.

            # "8/8/8/5N2/5K2/2kB4/8/8 b - - 0 1"  python → -2 (Black to move, Black loses)
            let b = board_from_fen("8/8/8/5N2/5K2/2kB4/8/8 b - - 0 1")
                @test syzygy_probe_wdl(b) == WDL_LOSS
            end

            # "7B/5kNK/8/8/8/8/8/8 w - - 0 1"  python → 2 (White to move, White wins)
            let b = board_from_fen("7B/5kNK/8/8/8/8/8/8 w - - 0 1")
                @test syzygy_probe_wdl(b) == WDL_WIN
            end

            # "N7/8/2k5/8/7K/8/8/B7 w - - 0 1"  python → 2 (White to move, White wins)
            let b = board_from_fen("N7/8/2k5/8/7K/8/8/B7 w - - 0 1")
                @test syzygy_probe_wdl(b) == WDL_WIN
            end

            # "8/8/1NkB4/8/7K/8/8/8 w - - 1 1"  python → 0 (draw)
            let b = board_from_fen("8/8/1NkB4/8/7K/8/8/8 w - - 1 1")
                @test syzygy_probe_wdl(b) == WDL_DRAW
            end

            # "8/8/8/2n5/2b1K3/2k5/8/8 w - - 0 1"  python → -2 (White to move, White loses — KvKBN)
            let b = board_from_fen("8/8/8/2n5/2b1K3/2k5/8/8 w - - 0 1")
                @test syzygy_probe_wdl(b) == WDL_LOSS
            end

            # ── KRvKP table (test_probe_wdl_table) ───────────────────────────────
            # "8/8/2K5/4P3/8/8/8/3r3k b - - 1 1"  python → 0 (draw; pawn can queen)
            let b = board_from_fen("8/8/2K5/4P3/8/8/8/3r3k b - - 1 1")
                @test syzygy_probe_wdl(b) == WDL_DRAW
            end

            # "8/8/2K5/8/4P3/8/8/3r3k b - - 1 1"  python → 2 — but from Black's POV
            # Black to move with rook vs KP: python returns +2 meaning White wins.
            # From Black's perspective (side to move) this is WDL_LOSS.
            let b = board_from_fen("8/8/2K5/8/4P3/8/8/3r3k b - - 1 1")
                @test syzygy_probe_wdl(b) == WDL_LOSS
            end

            # ── KRvKB tablebase (test_probe_wdl_tablebase) ───────────────────────
            # Winning KRvKB: Black to move, Black has bishop, loses.
            # "7k/6b1/6K1/8/8/8/8/3R4 b - - 12 7"  python → -2
            let b = board_from_fen("7k/6b1/6K1/8/8/8/8/3R4 b - - 12 7")
                @test syzygy_probe_wdl(b) == WDL_LOSS
            end

            # Drawn KBBvK: Black to move, Black has only king, but KBBvK with same-color
            # bishops cannot force mate.
            # "7k/8/8/4K3/3B4/4B3/8/8 b - - 12 7"  python → 0
            let b = board_from_fen("7k/8/8/4K3/3B4/4B3/8/8 b - - 12 7")
                @test syzygy_probe_wdl(b) == WDL_DRAW
            end

            # Winning KBBvK (opposite-color bishops): White to move, White wins.
            # "7k/8/8/4K2B/8/4B3/8/8 w - - 12 7"  python → 2
            let b = board_from_fen("7k/8/8/4K2B/8/4B3/8/8 w - - 12 7")
                @test syzygy_probe_wdl(b) == WDL_WIN
            end
        else
            @test_skip "4-piece python-chess tests require TB_LARGEST >= 4 (have $(TB_LARGEST[]))"
        end

        # ── issue #93 regression (5-piece, needs TB_LARGEST >= 5) ────────────────
        # "4r1K1/6PP/3k4/8/8/8/8/8 w - - 1 64"  python → wdl=2, dtz=4
        if TB_LARGEST[] >= 5
            let b = board_from_fen("4r1K1/6PP/3k4/8/8/8/8/8 w - - 1 64")
                @test syzygy_probe_wdl(b) == WDL_WIN
            end
        else
            @test_skip "5-piece python-chess test requires TB_LARGEST >= 5 (have $(TB_LARGEST[]))"
        end
    end
end
