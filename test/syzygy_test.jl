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

@testset "Syzygy — enc_type from filename" begin
    @test _enc_type_from_name("KRvK")   == 0   # j=3 → enc_type=0
    @test _enc_type_from_name("KQvK")   == 0
    @test _enc_type_from_name("KNvK")   == 0
    @test _enc_type_from_name("KBvK")   == 0
    @test _enc_type_from_name("KvK")    == 2   # j=2 → enc_type=2
    @test _enc_type_from_name("KNNvK")  == 2   # N appears twice → j=2
    @test _enc_type_from_name("KRRvK")  == 2
    @test _enc_type_from_name("KBBvK")  == 2
    @test _enc_type_from_name("KRBvK")  == 0   # K,R,B,K each once → j=4
    @test _enc_type_from_name("KQvKR")  == 0   # all four once → j=4
    @test _enc_type_from_name("KQvKQ")  == 0   # Q appears on both sides once each → j=4
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
const SYZYGY_PATH = get(ENV, "SYZYGY_PATH", "")

@testset "Syzygy — WDL integration (requires SYZYGY_PATH)" begin
    if isempty(SYZYGY_PATH) || !isdir(SYZYGY_PATH)
        @test_skip "Set SYZYGY_PATH to a directory containing .rtbw files"
    else
        @test syzygy_init!(SYZYGY_PATH) == true
        @test TB_LARGEST[] >= 3

        # KvK is always a draw
        b = board_from_fen("8/8/8/8/8/8/8/K6k w - - 0 1")
        @test syzygy_probe_wdl(b) == WDL_DRAW

        # K+R vs K: side with rook wins
        b = board_from_fen("8/8/8/8/8/8/8/KR5k w - - 0 1")
        @test syzygy_probe_wdl(b) == WDL_WIN

        # From losing side's perspective
        b = board_from_fen("8/8/8/8/8/8/8/kr5K b - - 0 1")
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

        if TB_LARGEST[] >= 5
            # K+Q vs K+R: queen wins
            b = board_from_fen("8/8/8/8/3k4/8/8/KQ6 w - - 0 1")
            @test syzygy_probe_wdl(b) == WDL_WIN
        end
    end
end
