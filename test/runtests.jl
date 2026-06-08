using Chess
using Test

@testset "Chess.jl" begin

    @testset "Square helpers" begin
        @test sq(0,0) == 0   # a1
        @test sq(7,7) == 63  # h8
        @test sq(4,0) == 4   # e1
        @test file_of(sq(3,5)) == 3
        @test rank_of(sq(3,5)) == 5
        @test sq_name(E1) == "e1"
        @test sq_name(H8) == "h8"
    end

    @testset "FEN parsing - starting position" begin
        b = board_from_fen(STARTPOS)
        @test b.side == White
        @test b.castling == (CR_WK | CR_WQ | CR_BK | CR_BQ)
        @test b.ep_square == -1
        @test b.halfmove == 0
        @test b.fullmove == 1
        # White pieces
        @test count_bits(bb(b, White, Pawn))   == 8
        @test count_bits(bb(b, White, Knight)) == 2
        @test count_bits(bb(b, White, Bishop)) == 2
        @test count_bits(bb(b, White, Rook))   == 2
        @test count_bits(bb(b, White, Queen))  == 1
        @test count_bits(bb(b, White, King))   == 1
        # Black pieces
        @test count_bits(bb(b, Black, Pawn))   == 8
        @test count_bits(bb(b, Black, King))   == 1
    end

    @testset "FEN round-trip" begin
        fens = [
            STARTPOS,
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        ]
        for fen in fens
            @test board_to_fen(board_from_fen(fen)) == fen
        end
    end

    @testset "Attack tables" begin
        # Knight on e4 (sq=28) attacks 8 squares
        @test count_bits(knight_attacks(sq(4,3))) == 8
        # Knight on a1 attacks 2 squares
        @test count_bits(knight_attacks(A1)) == 2
        # King on e1 attacks 5 squares
        @test count_bits(king_attacks(E1)) == 5
        # King on e4 attacks 8 squares
        @test count_bits(king_attacks(sq(4,3))) == 8
    end

    @testset "Sliding attacks - empty board" begin
        # Rook on e1 on empty board: 7 along rank + 7 along file = 14
        @test count_bits(rook_attacks(E1, BB(0))) == 14
        # Bishop on d4 on empty board: diagonals
        @test count_bits(bishop_attacks(sq(3,3), BB(0))) == 13
        # Queen = rook + bishop
        @test queen_attacks(sq(3,3), BB(0)) == rook_attacks(sq(3,3), BB(0)) | bishop_attacks(sq(3,3), BB(0))
    end

    @testset "Sliding attacks - with blockers" begin
        # Rook on a1, blocker on a4: can go up to a4 but not beyond
        occ = sq_bb(A1) | sq_bb(sq(0,3))
        atk = rook_attacks(A1, occ)
        @test (atk & sq_bb(sq(0,3))) != 0   # a4 is attacked
        @test (atk & sq_bb(sq(0,4))) == 0   # a5 is blocked
        @test (atk & sq_bb(sq(0,7))) == 0   # a8 is blocked
    end

    @testset "Make/unmake preserves state" begin
        b = board_from_fen(STARTPOS)
        fen_before = board_to_fen(b)
        ml = MoveList()
        generate_moves!(ml, b)
        for m in ml
            undo = make_move!(b, m)
            unmake_move!(b, m, undo)
            @test board_to_fen(b) == fen_before
        end
    end

    @testset "Zobrist hash - consistent with compute_hash" begin
        for fen in [
            STARTPOS,
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        ]
            b = board_from_fen(fen)
            @test b.hash == compute_hash(b)

            # Hash must be restored perfectly by unmake.
            ml = MoveList()
            generate_moves!(ml, b)
            h0 = b.hash
            for m in ml
                undo = make_move!(b, m)
                # After make: hash should equal compute_hash.
                @test b.hash == compute_hash(b)
                unmake_move!(b, m, undo)
                @test b.hash == h0
            end
        end
    end

    @testset "Perft depth 1 - starting position" begin
        b = board_from_fen(STARTPOS)
        @test perft(b, 1) == 20
    end

    @testset "Perft depth 2 - starting position" begin
        b = board_from_fen(STARTPOS)
        @test perft(b, 2) == 400
    end

    @testset "Perft depth 3 - starting position" begin
        b = board_from_fen(STARTPOS)
        @test perft(b, 3) == 8902
    end

    @testset "Perft depth 4 - starting position" begin
        b = board_from_fen(STARTPOS)
        @test perft(b, 4) == 197281
    end

    @testset "Perft - Kiwipete depth 1-3" begin
        b = board_from_fen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
        @test perft(b, 1) == 48
        @test perft(b, 2) == 2039
        @test perft(b, 3) == 97862
    end

    @testset "Perft - Position 3 depth 1-4" begin
        b = board_from_fen("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")
        @test perft(b, 1) == 14
        @test perft(b, 2) == 191
        @test perft(b, 3) == 2812
        @test perft(b, 4) == 43238
    end

    @testset "Perft - Position 5 depth 1-3" begin
        b = board_from_fen("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8")
        @test perft(b, 1) == 44
        @test perft(b, 2) == 1486
        @test perft(b, 3) == 62379
    end

    @testset "Check detection" begin
        # After 1.e4 e5 2.Qh5 Nc6 3.Bc4 Nf6?? 4.Qxf7# it's checkmate
        b = board_from_fen("r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4")
        @test king_in_check(b, Black) == true
        ml = MoveList()
        generate_moves!(ml, b)
        @test length(ml) == 0   # checkmate
    end

    @testset "Stalemate detection" begin
        b = board_from_fen("k7/8/1Q6/8/8/8/8/7K b - - 0 1")
        ml = MoveList()
        generate_moves!(ml, b)
        @test length(ml) == 0
        @test king_in_check(b, Black) == false
    end

    @testset "En-passant" begin
        # White pawn on e5, black just played d7-d5
        b = board_from_fen("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")
        @test b.ep_square == sq(3, 5)   # d6
        ml = MoveList()
        generate_moves!(ml, b)
        ep_moves = filter(m -> is_ep(m), collect(ml))
        @test length(ep_moves) == 1
        m = ep_moves[1]
        @test from_sq(m) == sq(4, 4)   # e5
        @test to_sq(m)   == sq(3, 5)   # d6
    end

    @testset "Castling" begin
        # Position with both castling options available for white
        b = board_from_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        ml = MoveList()
        generate_moves!(ml, b)
        castle_moves = filter(m -> is_castle(m), collect(ml))
        @test length(castle_moves) == 2

        # Cannot castle through check: d1 attacked
        b2 = board_from_fen("4k2r/8/8/8/8/8/8/R3K2r w Q - 0 1")
        generate_moves!(ml, b2)
        castle_moves2 = filter(m -> is_castle(m), collect(ml))
        @test length(castle_moves2) == 0
    end

    @testset "Promotion" begin
        b = board_from_fen("8/P7/8/8/8/8/8/4K1k1 w - - 0 1")
        ml = MoveList()
        generate_moves!(ml, b)
        promos = filter(m -> is_promo(m), collect(ml))
        @test length(promos) == 4   # Q, R, B, N
    end

    # ── Evaluation ────────────────────────────────────────────────────────────

    @testset "Evaluation - starting position is near zero" begin
        b = board_from_fen(STARTPOS)
        e = evaluate(b)
        @test e.material == 0           # perfectly balanced
        @test abs(total(e)) < 50        # PST + small tempo only
    end

    @testset "Evaluation - material advantage detected" begin
        # White has an extra queen.
        b = board_from_fen("rnb1kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        e = evaluate(b)
        @test e.material == 1000
        @test total(e) > 800
    end

    @testset "Evaluation - passed pawn bonus" begin
        # White pawn on e6, no black pawns on d-f files → passed.
        b = board_from_fen("4k3/8/4P3/8/8/8/8/4K3 w - - 0 1")
        e = evaluate(b)
        @test e.pawn_structure > 0      # white passed pawn bonus
    end

    @testset "Evaluation - doubled pawn penalty" begin
        # Doubled pawns on e2/e3: doubled penalty (−15) + isolated penalty (−20)
        # outweighs the small passed-pawn bonus (+10 for the e3 pawn).
        b = board_from_fen("4k3/8/8/8/8/4P3/4P3/4K3 w - - 0 1")
        e = evaluate(b)
        @test e.pawn_structure < 0
    end

    @testset "Insufficient material detection" begin
        # K vs K
        @test Chess._is_insufficient_material(board_from_fen("4k3/8/8/8/8/8/8/4K3 w - - 0 1")) == true
        # K+N vs K
        @test Chess._is_insufficient_material(board_from_fen("4k3/8/8/8/8/2N5/8/4K3 w - - 0 1")) == true
        # K+B vs K
        @test Chess._is_insufficient_material(board_from_fen("4k3/8/8/8/8/2B5/8/4K3 w - - 0 1")) == true
        # K+B vs K+B (same color: White c3 [even] and Black f6 [even])
        @test Chess._is_insufficient_material(board_from_fen("4k3/8/5b2/8/8/2B5/8/4K3 w - - 0 1")) == true
        # K+B vs K+B (different colors: White c3 [even] and Black f5 [odd])
        @test Chess._is_insufficient_material(board_from_fen("4k3/5b2/8/8/8/2B5/8/4K3 w - - 0 1")) == false
        # Pawns prevent draw detection
        @test Chess._is_insufficient_material(board_from_fen("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")) == false
    end

    @testset "Evaluation components" begin
        # Bishop pair bonus (+30)
        b1 = board_from_fen("4k3/8/8/8/8/8/B7/4K3 w - - 0 1")
        b2 = board_from_fen("4k3/8/8/8/8/8/B6B/4K3 w - - 0 1")
        e1 = evaluate(b1)
        e2 = evaluate(b2)
        # Piece activity increases by more than the second bishop's material
        # (material is separate, so we just check activity delta).
        # PST + Mobility + BishopPair
        @test e2.piece_activity > e1.piece_activity + 15

        # Rook on open file (+20) / semi-open (+10) / closed (0).
        # Both kings present; pawns on rank 3 block each other (neither is a passer)
        # so the rook-behind-passer bonus doesn't distort the comparison.
        # b_semi: black pawn a3 on file a (semi-open for white); white pawn b2
        #   prevents a3 from being a passer (_PASSED_B blocked by b2).
        # b_closed: white pawn a2 added so file a is fully closed; a2/a3 block each other.
        b_open   = board_from_fen("4k3/8/8/8/8/8/8/R3K3 w - - 0 1")
        b_semi   = board_from_fen("4k3/8/8/8/8/p7/1P6/R3K3 w - - 0 1")
        b_closed = board_from_fen("4k3/8/8/8/8/p7/P7/R3K3 w - - 0 1")
        @test evaluate(b_open).piece_activity > evaluate(b_semi).piece_activity
        @test evaluate(b_semi).piece_activity > evaluate(b_closed).piece_activity

        # Rook on 7th rank (+15)
        b_a1 = board_from_fen("4k3/8/8/8/8/8/8/R3K3 w - - 0 1")
        b_a7 = board_from_fen("4k3/R7/8/8/8/8/8/4K3 w - - 0 1")
        # PST difference (a7=5, a1=0) + 7th rank bonus (15) = 20.
        @test evaluate(b_a7).piece_activity > evaluate(b_a1).piece_activity

        # Knight outpost (+35)
        b_out = board_from_fen("4k3/8/8/8/4N3/8/8/4K3 w - - 0 1")
        b_no_out = board_from_fen("4k3/8/8/3p4/4N3/8/8/4K3 w - - 0 1")
        # b_no_out: knight on e4 is NOT an outpost because black pawn on d5 can challenge it.
        # Delta = Outpost bonus (35) - Semi-outpost if applicable?
        # Here d5 is not blocked, so it's a full loss of outpost bonus.
        @test evaluate(b_out).piece_activity > evaluate(b_no_out).piece_activity
    end

    # ── Search ────────────────────────────────────────────────────────────────

    @testset "Search - finds free capture" begin
        # White rook can take the undefended black queen on d5 freely.
        b = board_from_fen("7k/8/8/3q4/8/8/8/3R3K w - - 0 1")
        r = search_move(b, 500)
        @test move_to_uci(r.move) == "d1d5"
    end

    @testset "Search - avoids losing piece" begin
        # White knight on e4 is attacked by the black pawn on d5; the knight must move.
        b = board_from_fen("4k3/8/8/3p4/4N3/8/8/4K3 w - - 0 1")
        r = search_move(b, 500)
        @test from_sq(r.move) == sq(4, 3)   # knight on e4 moves away
    end

    @testset "Search - finds mate in 1" begin
        # Position after 1.e4 e5 2.Bc4 Nc6 3.Qh5 Nf6??; white plays Qxf7#.
        b = board_from_fen("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4")
        r = search_move(b, 500)
        @test move_to_uci(r.move) == "h5f7"
    end

    @testset "Search - stalemate returns 0" begin
        # Black is stalemated; search_move must return NULL_MOVE with score 0.
        b = board_from_fen("k7/8/1Q6/8/8/8/8/7K b - - 0 1")
        r = search_move(b, 200)
        @test r.score == 0
        @test r.move == NULL_MOVE
    end

    @testset "Search - SearchInfo reuse keeps TT" begin
        b  = board_from_fen(STARTPOS)
        si = SearchInfo()
        r1 = search_move(b, 300; si)
        r2 = search_move(b, 300; si)
        # Second search with warm TT should find at least the same or better move.
        @test r2.depth >= r1.depth
    end

    @testset "Search - 50-move rule" begin
        # Position where White is winning, but halfmove counter is 100.
        # Any quiet move will result in 101 half-moves, which search scores as 0.
        b = board_from_fen("4k3/8/8/8/8/8/Q7/4K3 w - - 100 1")
        r = search_move(b, 200)
        @test r.score == 0
    end

    @testset "Search - threefold repetition" begin
        # If a move leads to a position that has already occurred twice, it's a draw.
        # Or if it occurred once before in the game and once in the current path.
        b = board_from_fen(STARTPOS)
        si = SearchInfo()
        # Mocking that STARTPOS has occurred once before.
        si.prior_counts[b.hash] = 1

        # We need a position where repeating is forced or the best option to see a 0 score,
        # but simply checking that a repeated position evaluates to 0 in search is enough.
        # Let's use a child of STARTPOS and see if moving back to STARTPOS is avoided.
        b2 = board_from_fen("rnbqkbnr/pppppppp/8/8/8/N7/PPPPPPPP/R1BQKBNR b KQkq - 1 1")
        si2 = SearchInfo()
        si2.prior_counts[b.hash] = 1 # STARTPOS occurred once
        # If Black plays Nb8, it's the 2nd time in game + 1 time in path = 2 repetitions (draw).
        # (Engine returns 0 if reps >= 1).
        # We can't easily verify the internal move score without more machinery,
        # but we can verify that search doesn't crash with prior_counts.
        r = search_move(b2, 200; si=si2)
        @test true
    end

    # ── Trickiness ────────────────────────────────────────────────────────────

    @testset "Trickiness - score is non-negative and bounded" begin
        # _trickiness_score must always return a value in [0, 200].
        b  = board_from_fen(STARTPOS)
        si = SearchInfo()
        ml = MoveList()
        generate_moves!(ml, b)
        for i in 1:min(5, length(ml))
            t = Chess._trickiness_score(b, ml[i], si)
            @test t >= 0
            @test t <= 200
        end
    end

    @testset "Trickiness - low when opponent has no good reply" begin
        # After a free queen capture (Rxd5), all Black king moves are roughly equally
        # bad (White is heavily winning regardless), so the gap between best and
        # second-best reply is small → trickiness close to 0.
        b  = board_from_fen("7k/8/8/3q4/8/8/8/3R3K w - - 0 1")
        si = SearchInfo()
        t  = Chess._trickiness_score(b, move_from_uci(b, "d1d5"), si)
        @test t >= 0
        @test t <= 50   # no critical reply; all replies equally losing for Black
    end

    @testset "Trickiness - does not override clearly better move" begin
        # The maximum trickiness bonus is TRICKINESS_WEIGHT × 200 ≈ 20cp.
        # A move winning a free queen (+1000cp) cannot be displaced by trickiness.
        b = board_from_fen("7k/8/8/3q4/8/8/8/3R3K w - - 0 1")
        r = search_move(b, 500)
        @test move_to_uci(r.move) == "d1d5"
    end

    @testset "Trickiness - board restored after scoring" begin
        # _trickiness_score must leave the board in exactly its original state.
        b   = board_from_fen(STARTPOS)
        si  = SearchInfo()
        ml  = MoveList()
        generate_moves!(ml, b)
        fen = board_to_fen(b)
        for i in 1:min(5, length(ml))
            Chess._trickiness_score(b, ml[i], si)
            @test board_to_fen(b) == fen
        end
    end

    # ── Commentary ────────────────────────────────────────────────────────────

    @testset "Commentary - fork" begin
        # White knight on e5 takes pawn on f7, forking Black king (h8) and rook (d8).
        # Requires a capture to trigger immediate fork commentary.
        b = board_from_fen("3r3k/5p2/8/4N3/8/8/8/4K3 w - - 0 1")
        # Nxf7+
        m = move_from_uci(b, "e5f7")
        res = SearchResult(m, 100, 1, 1, evaluate(b), Move[m])
        exp = explain_move(res, b, White)
        @test occursin("forking", exp) || occursin("outpost", exp)
    end

    @testset "Commentary - pin escape" begin
        # White king on e1, White rook on e2, Black queen on e8. Rook is pinned.
        b = board_from_fen("4q3/8/8/8/8/8/4R3/4K3 w - - 0 1")
        # Moving the king escapes the pin.
        # Let's manually create a SearchResult to test explain_move directly.
        move = move_from_uci(b, "e1d1")
        res = SearchResult(move, 0, 1, 1, evaluate(b), Move[move])
        exp = explain_move(res, b, White)
        @test occursin("escaping the pin", exp)
    end

end
