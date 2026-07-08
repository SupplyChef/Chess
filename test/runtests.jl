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
        @test e.material == 1241
        @test total(e) > 800
    end

    @testset "Evaluation - passed pawn bonus" begin
        # White pawn on e6, no black pawns on d-f files → passed.
        b = board_from_fen("4k3/8/4P3/8/8/8/8/4K3 w - - 0 1")
        e = evaluate(b)
        @test e.pawn_structure > 0      # white passed pawn bonus
    end

    @testset "Evaluation - doubled pawn penalty" begin
        # Doubled pawns on e2/e3: doubled penalty (−12) + isolated penalty (2×−20)
        # outweighs the passed-pawn bonus (+25 for the e3 pawn); the lead pawn
        # gets no free-passer bonus because a friendly pawn trails behind it.
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

    @testset "Knight outpost - challenger blocked direction" begin
        # Regression: the blocked test used to shift occupancy the wrong way,
        # checking the square BEHIND the challenger instead of its advance square.
        e6 = sq_bb(sq(4, 5)); e5 = sq_bb(sq(4, 4)); e7 = sq_bb(sq(4, 6))
        # White's challengers are black pawns: e6 pawn advances to e5.
        @test Chess._challengers_blocked(e6, e5, White) == true    # blocker on advance square
        @test Chess._challengers_blocked(e6, e7, White) == false   # piece behind ≠ blocked
        # Black's challengers are white pawns: e3 pawn advances to e4.
        e3 = sq_bb(sq(4, 2)); e4 = sq_bb(sq(4, 3)); e2 = sq_bb(sq(4, 1))
        @test Chess._challengers_blocked(e3, e4, Black) == true
        @test Chess._challengers_blocked(e3, e2, Black) == false
    end

    @testset "Pawn cache - occupancy-dependent terms not cached" begin
        # Regression: the free-passer bonus reads the full occupancy, but the
        # pawn cache is keyed by the pawn hash only.  Two positions with the
        # same pawn skeleton but different piece placement must still be scored
        # differently when a piece blocks the passer's path.
        cfg = EngineConfig()
        b_clear   = board_from_fen("4k3/8/8/4P3/8/8/8/4K3 w - - 0 1")
        b_blocked = board_from_fen("4k3/4N3/8/4P3/8/8/8/4K3 w - - 0 1")
        @test b_clear.pawn_hash == b_blocked.pawn_hash
        s_clear   = Chess._eval_pawn_structure(b_clear, cfg)    # populates the cache
        s_blocked = Chess._eval_pawn_structure(b_blocked, cfg)  # must not reuse it verbatim
        @test s_clear - s_blocked == 23   # free-passer (20) + tapered passed bonus diff (3) at ph=0 vs ph=1
        # And a repeat lookup (cache hit path) must agree with the first.
        @test Chess._eval_pawn_structure(b_clear, cfg) == s_clear
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

    @testset "Search - expired clock still returns a legal move" begin
        # Regression: when the clock expired during the depth-1 iteration the
        # partial result was discarded and NULL_MOVE returned even though legal
        # moves exist (the Lichess driver then treated the game as over).
        b  = board_from_fen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
        si = SearchInfo()
        ml = MoveList()
        generate_moves!(ml, b)
        legal = Set(ml[i] for i in 1:length(ml))
        for _ in 1:3
            r = search_move(b, 0; si, verbose = false)   # budget already expired
            @test r.move != NULL_MOVE
            @test r.move in legal
        end
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

    @testset "Repetition detection - position seen twice before scores as draw" begin
        # With reps >= 2, a position must have appeared at least twice before
        # (prior_counts >= 2) for the current visit to be the third occurrence (draw).
        # Verify by marking all depth-1 positions as seen twice: every white move then
        # returns 0, and the engine reports score = 0.
        b = board_from_fen("4k3/8/8/8/8/8/Q7/4K3 w - - 0 1")
        ml = MoveList()
        generate_moves!(ml, b)
        pc = Dict{UInt64,Int}()
        for i in 1:length(ml)
            undo = make_move!(b, ml.moves[i])
            pc[b.hash] = 2
            unmake_move!(b, ml.moves[i], undo)
        end
        r = search_move(b, 500; prior_counts=pc)
        @test r.score == 0
    end

    @testset "Regression - path must not double-count the root's own occurrence" begin
        # Bug: si.path[1] is always the root's own hash (pushed by _search_root
        # before its first candidate move, unchanged for the whole search). That
        # single real occurrence is already reflected in prior_counts[root] —
        # apply_moves! counts a position as soon as it is reached, and root is the
        # position we are at right now. Scanning si.path from i=1 counted that same
        # occurrence a second time, so any line transposing back to the root
        # position was declared a draw after only its 2nd real occurrence instead
        # of its 3rd.
        b  = board_from_fen("4k3/8/8/8/8/8/Q7/4K3 w - - 0 1")
        si = Chess.SearchInfo()
        si.prior_counts     = Dict{UInt64,Int}(b.hash => 1)   # root's single real occurrence
        si.root_prior_count = 1
        si.time_limit       = time() + 60.0

        # Simulate a search line that has returned to the root position one ply in
        # (path[1] is always root's hash, pushed before root's first candidate move).
        Chess._path_push!(si, b.hash)
        score = Chess._negamax(b, 2, -100_000, 100_000, 1, si, false)

        # This is only the 2nd real occurrence of the root position — it must not
        # be flagged as an already-drawn repetition, and White (queen vs lone king)
        # must still show a clearly winning score rather than the buggy immediate 0.
        @test !si.rep_draw_flag
        @test score > 100
    end

    @testset "apply_moves! resets prior_counts after a capture" begin
        # After a capture, board.halfmove resets to 0 and apply_moves! must clear
        # prior_counts so pre-capture positions no longer pollute repetition detection.
        # Position: white Ra1 Ke1 vs black Ka8 pawn-a5; white can capture Rxa5.
        b = board_from_fen("k7/8/8/p7/8/8/8/R3K3 w - - 4 1")
        pc = Dict{UInt64,Int}(b.hash => 1)

        # Some quiet moves to grow prior_counts.
        apply_moves!(b, "e1d1", pc)   # Kd1
        apply_moves!(b, "a8b8", pc)   # Kb8
        apply_moves!(b, "d1e1", pc)   # Ke1
        apply_moves!(b, "b8a8", pc)   # Ka8

        @test length(pc) >= 4   # accumulated positions from the quiet sequence

        # Now white captures: Rxa5 (irreversible).
        apply_moves!(b, "a1a5", pc)

        # After the capture, counts must be cleared and contain only the new position.
        @test length(pc) == 1
        @test pc[b.hash] == 1
    end

    @testset "apply_moves! resets prior_counts after a pawn push" begin
        # Same guarantee for pawn pushes (also irreversible).
        b = board_from_fen("4k3/8/8/8/8/8/4P3/4K3 w - - 4 1")
        pc = Dict{UInt64,Int}(b.hash => 1)

        apply_moves!(b, "e1d1", pc)
        apply_moves!(b, "e8f8", pc)
        apply_moves!(b, "d1e1", pc)
        apply_moves!(b, "f8e8", pc)

        @test length(pc) >= 4

        apply_moves!(b, "e2e4", pc)   # pawn push

        @test length(pc) == 1
        @test pc[b.hash] == 1
    end

    @testset "Regression - no phantom queen sacrifice with bounded prior_counts" begin
        # The bug: apply_moves! included pre-capture positions in prior_counts, causing
        # phantom draws for queen continuations and pushing the engine toward sacrificing
        # the queen to reach a K+N+B vs K endgame (a "fresh" position not in prior_counts).
        #
        # The fix: apply_moves! now clears prior_counts after each capture/pawn push.
        # After the game's Kxb5 capture at move 45, prior_counts contains only the
        # single position after that capture.  At move 46 the engine can search all
        # queen continuations freely, finds genuine wins, and does not sacrifice.
        #
        # We model this by supplying only the current position in prior_counts (as
        # apply_moves! would produce immediately after a capture).
        b = board_from_fen("8/Q7/8/1k2B3/8/8/8/2N1K3 w - - 0 46")
        pc = Dict{UInt64,Int}(b.hash => 1)   # only the post-capture position

        r = search_move(b, 2000; prior_counts=pc)

        # Engine must not sacrifice the queen (Qb6+ = "a7b6").
        @test move_to_uci(r.move) != "a7b6"
        # Score must clearly beat K+N+B material (~650 cp).
        @test r.score > 650
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

    @testset "Commentary - protecting a threatened piece" begin
        # Regression: this branch used to crash with a MethodError because
        # _is_defended was called with an unsupported `ignore_sq` keyword.
        # Black's bishop (just arrived on e6) attacks the undefended knight on
        # d5; White replies e2-e4, defending the knight with the pawn.
        b   = board_from_fen("6k1/8/4b3/3N4/8/8/4P3/6K1 w - - 0 1")
        fen = board_to_fen(b)
        opp = Move(sq(2,7), sq(4,5), MF_QUIET)   # ...Bc8-e6, the threatening move
        m   = move_from_uci(b, "e2e4")
        res = SearchResult(m, 10, 6, 100, evaluate(b), Move[m])
        exp = explain_move(res, b, White; last_opp_move = opp)
        @test occursin("protecting my knight", exp)
        # The board must be fully restored (the old crash left it mutated).
        @test board_to_fen(b) == fen
    end

    @testset "Commentary - sacrifice with check suffix" begin
        # Bxh7+!? — the bishop takes a pawn defended only by the king: SEE loses
        # a bishop for a pawn, but the engine's score says the attack is worth it.
        b   = board_from_fen("6k1/5ppp/8/8/8/3B4/8/6K1 w - - 0 1")
        fen = board_to_fen(b)
        m   = move_from_uci(b, "d3h7")
        undo = make_move!(b, m)
        kxh7 = move_from_uci(b, "g8h7")
        unmake_move!(b, m, undo)
        res = SearchResult(m, 120, 8, 100, evaluate(b), Move[m, kxh7])
        exp = explain_move(res, b, White)
        @test occursin("sacrificing my bishop", exp)
        @test occursin("Bxh7+", exp)          # check suffix on the SAN
        @test board_to_fen(b) == fen
    end

    @testset "Commentary - threat announcement" begin
        # Ne5 attacks the undefended bishop on d7 — a concrete threat.
        b   = board_from_fen("6k1/3b4/8/8/8/5N2/8/6K1 w - - 0 1")
        m   = move_from_uci(b, "f3e5")
        res = SearchResult(m, 20, 8, 100, evaluate(b), Move[m])
        exp = explain_move(res, b, White)
        @test occursin("threatening your bishop on d7", exp)
    end

    @testset "Commentary - coaching severity and capture refutation" begin
        # Black plays Qxd4?? into cxd4 — queen for a pawn.
        b        = board_from_fen("3q2k1/8/8/8/3P4/2P5/8/6K1 b - - 0 1")
        best     = move_from_uci(b, "d8d5")
        engine_r = SearchResult(best, 0, 8, 100, evaluate(b), Move[best])
        opp      = move_from_uci(b, "d8d4")
        undo     = make_move!(b, opp)
        reply    = move_from_uci(b, "c3d4")
        after_r  = SearchResult(reply, 900, 8, 100, evaluate(b), Move[reply])
        unmake_move!(b, opp, undo)
        msg = explain_opponent_move(b, opp, engine_r; after = after_r)
        @test occursin("blunder", msg)
        @test occursin("refutes", msg)
        # Without `after` the message falls back to the plain coaching form.
        msg2 = explain_opponent_move(b, opp, engine_r)
        @test occursin("As your coach", msg2)
    end

    @testset "Commentary - chat splitting stays within the Lichess limit" begin
        # Short messages pass through untouched.
        @test Chess._split_chat("I played e4.") == ["I played e4."]
        # Two long sentences split at the sentence boundary.
        s1 = "I played Nf3 — " * join(fill("improving my piece activity", 4), " and ") * "."
        s2 = "After Nf6 I'll Rxe5, then Kd7 — aiming for a passed pawn on the a-file."
        msgs = Chess._split_chat(s1 * " " * s2)
        @test length(msgs) == 2
        @test all(m -> length(m) <= 140, msgs)
        # A single overlong sentence is still delivered within the limit.
        long = "I played Qh5 — " * join(fill("pressure on the kingside", 12), ", ") * "."
        @test all(m -> length(m) <= 140, Chess._split_chat(long))
        # explain_move_messages output always fits.
        b   = board_from_fen(STARTPOS)
        m   = move_from_uci(b, "e2e4")
        res = SearchResult(m, 30, 8, 100, evaluate(b), Move[m])
        @test all(mm -> length(mm) <= 140, explain_move_messages(res, b, White))
    end

    @testset "Commentary - opening names (longest prefix wins)" begin
        @test Chess._opening_name(["e2e4","c7c5","g1f3","d7d6","d2d4","c5d4",
                                   "f3d4","g8f6","b1c3","a7a6"]) == "Sicilian, Najdorf"
        @test Chess._opening_name(["e2e4","c7c5","c2c3"]) == "Sicilian, Alapin"
        @test Chess._opening_name(["e2e4","c7c5"])        == "Sicilian Defense"
        @test Chess._opening_name(["d2d4","f7f5"])        == "Dutch Defense"
        @test Chess._opening_name(["e2e4","e7e5","f2f4"]) == "King's Gambit"
        @test Chess._opening_name(["d2d4","g8f6","c2c4","g7g6","b1c3","d7d5"]) ==
              "Grünfeld Defense"
        @test Chess._opening_name(["h2h4"]) == ""
    end

    @testset "_is_defended with ignore_sq" begin
        # After e2-e4 in the position above, d5 is defended by the e4 pawn and
        # by nothing else: ignoring e4 must flip the answer.
        b = board_from_fen("6k1/8/4b3/3N4/4P3/8/8/6K1 w - - 0 1")
        d5 = sq(3, 4); e4 = sq(4, 3)
        @test Chess._is_defended(b, d5, White) == true
        @test Chess._is_defended(b, d5, White; ignore_sq = e4) == false
        # ignore_sq must also re-open slider lines: rook d1 defends d5 through
        # an empty d-file, and a blocker on d3 cuts that defense unless ignored.
        b2 = board_from_fen("6k1/8/8/3P4/8/3n4/8/3R2K1 w - - 0 1")
        d5 = sq(3, 4); d3 = sq(3, 2)
        @test Chess._is_defended(b2, d5, White) == false               # knight d3 blocks
        @test Chess._is_defended(b2, d5, White; ignore_sq = d3) == true
    end

    # ── Static exchange evaluation ────────────────────────────────────────────

    @testset "SEE - free capture" begin
        # PxP, no recapture: wins exactly one pawn.
        b = board_from_fen("1k6/8/8/3p4/4P3/8/8/1K6 w - - 0 1")
        m = move_from_uci(b, "e4d5")
        @test Chess._see_ge(b, m, 0)   == true
        @test Chess._see_ge(b, m, 133) == true
        @test Chess._see_ge(b, m, 134) == false
    end

    @testset "SEE - even exchange" begin
        # PxP with a pawn recapture: net exactly zero.
        b = board_from_fen("1k6/8/4p3/3p4/4P3/8/8/1K6 w - - 0 1")
        m = move_from_uci(b, "e4d5")
        @test Chess._see_ge(b, m, 0) == true
        @test Chess._see_ge(b, m, 1) == false
    end

    @testset "SEE - losing capture" begin
        # NxP where the pawn is defended by a pawn: 133 − 349 = −216.
        b = board_from_fen("1k6/8/4p3/3p4/8/4N3/8/1K6 w - - 0 1")
        m = move_from_uci(b, "e3d5")
        @test Chess._see_ge(b, m, 0)    == false
        @test Chess._see_ge(b, m, -216) == true
        @test Chess._see_ge(b, m, -215) == false
    end

    @testset "SEE - x-ray battery" begin
        # Doubled rooks on the d-file vs rook d5 defended by knight f6:
        # Rxd5 Nxd5 Rxd5 nets 633 − 633 + 349 = +349.  The second rook only
        # joins the exchange through the square the first rook vacated.
        b = board_from_fen("1k6/8/5n2/3r4/8/8/3R4/1K1R4 w - - 0 1")
        m = move_from_uci(b, "d2d5")
        @test Chess._see_ge(b, m, 0)   == true
        @test Chess._see_ge(b, m, 349) == true
        @test Chess._see_ge(b, m, 350) == false
    end

    @testset "SEE - king recapture legality" begin
        # Nxd5 where the pawn is defended only by the king, but our rook backs
        # the capture up: Kxd5 would be illegal, so we win the pawn cleanly.
        b = board_from_fen("1r6/8/3k4/3p4/8/4N3/8/3R2K1 w - - 0 1")
        m = move_from_uci(b, "e3d5")
        @test Chess._see_ge(b, m, 133) == true
        # Same capture without the backup rook: the king legally recaptures
        # and we lose knight for pawn.
        b2 = board_from_fen("1r6/8/3k4/3p4/8/4N3/8/6K1 w - - 0 1")
        m2 = move_from_uci(b2, "e3d5")
        @test Chess._see_ge(b2, m2, 0) == false
    end

    @testset "Search - avoids SEE-losing capture" begin
        # The only capture available wins a pawn but loses the queen to the
        # recapture; the engine must prefer any quiet move.
        b = board_from_fen("6k1/8/4p3/3p4/8/8/8/3Q2K1 w - - 0 1")
        r = search_move(b, 300)
        @test move_to_uci(r.move) != "d1d5"
    end

    # ── Lazy evaluation ───────────────────────────────────────────────────────

    @testset "Lazy eval - exact inside a wide window" begin
        # With an effectively infinite window the shortcut can never trigger,
        # so evaluate_lazy must agree exactly with the full evaluation.
        for fen in [
            STARTPOS,
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
            "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R b KQ - 1 8",
        ]
            b    = board_from_fen(fen)
            sgn  = b.side == White ? 1 : -1
            full = sgn * total(evaluate(b))
            @test Chess.evaluate_lazy(b, DEFAULT_CONFIG, -32_000, 32_000) == full
        end
    end

    @testset "Lazy eval - shortcut stays on the right side of the bound" begin
        # White is up two queens: with a window near zero the lazy core must
        # fail high, and the full eval must agree that the score is >= beta.
        b    = board_from_fen("4k3/8/8/8/8/8/QQ6/4K3 w - - 0 1")
        lz   = Chess.evaluate_lazy(b, DEFAULT_CONFIG, -50, 50)
        full = total(evaluate(b))
        @test lz >= 50 && full >= 50
        # Same position from Black's perspective: must fail low.
        b2  = board_from_fen("4k3/8/8/8/8/8/QQ6/4K3 b - - 0 1")
        lz2 = Chess.evaluate_lazy(b2, DEFAULT_CONFIG, -50, 50)
        @test lz2 <= -50 && -total(evaluate(b2)) <= -50
    end

    @testset "Lazy eval - disabled flag gives the full value" begin
        cfg = EngineConfig(lazy_eval = false)
        b   = board_from_fen("4k3/8/8/8/8/8/QQ6/4K3 w - - 0 1")
        @test Chess.evaluate_lazy(b, cfg, -50, 50) == total(evaluate(b, cfg))
    end

    # ── Principal variation search ────────────────────────────────────────────

    @testset "PVS - finds mate in 2" begin
        # Rook ladder: both rooks on rank 5, neither can immediately reach rank 8.
        # 1.Rg8+ Kd7 2.Rh7# (or symmetric). Score = MATE_SCORE - 4. No mate in 1.
        b = board_from_fen("3k4/8/8/6RR/8/8/8/6K1 w - - 0 1")
        r = search_move(b, 1000)
        @test r.score == MATE_SCORE - 4
    end

    @testset "PVS - agrees with full-window search" begin
        # On clear tactical positions PVS must select the same move as the
        # plain full-window alpha-beta (it only changes how fast non-PV moves
        # are refuted, never the final result).
        for fen in [
            "7k/8/8/3q4/8/8/8/3R3K w - - 0 1",     # free queen: Rxd5
            "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4",  # Qxf7#
        ]
            b1 = board_from_fen(fen)
            b2 = board_from_fen(fen)
            r_pvs  = search_move(b1, 400; si = SearchInfo(DEFAULT_CONFIG))
            r_full = search_move(b2, 400; si = SearchInfo(EngineConfig(pvs = false)))
            @test r_pvs.move == r_full.move
        end
    end

    @testset "Feature flags - new toggles exist and default on" begin
        @test DEFAULT_CONFIG.pvs       == true
        @test DEFAULT_CONFIG.see       == true
        @test DEFAULT_CONFIG.lazy_eval == true
        cfg = EngineConfig(pvs = false, see = false, lazy_eval = false)
        @test !cfg.pvs && !cfg.see && !cfg.lazy_eval
    end

    # ── Transposition table ───────────────────────────────────────────────────

    @testset "TT — PV length >= 2 for positions with clear continuations" begin
        # Rxd5 wins a free queen; the opponent must reply with a king move.
        # The hash-move TT fix (writing TT_LOWER on cut-node beta cutoff) is
        # required for _extract_pv to follow the opponent's reply.
        b = board_from_fen("7k/8/8/3q4/8/8/8/3R3K w - - 0 1")
        r = search_move(b, 1000)
        @test move_to_uci(r.move) == "d1d5"
        @test length(r.pv) >= 2
    end

    @testset "TT — PV captures opponent reply in forced mate sequence" begin
        # Rook ladder mate in 2 (4 half-moves). The PV must include at least our
        # first move and the opponent's forced reply. The final mating move may not
        # appear because it is a quiet (non-capture) checkmate reached at qsearch
        # depth, which cannot store a TT entry for it — that is expected behaviour.
        # The key invariant is >= 2 (not 1): the cut-node TT write allows
        # _extract_pv to follow through the opponent's reply.
        b = board_from_fen("3k4/8/8/6RR/8/8/8/6K1 w - - 0 1")
        r = search_move(b, 1000)
        @test r.score == MATE_SCORE - 4
        @test length(r.pv) >= 2
    end

    @testset "TT — replacement: deeper entry is preserved" begin
        si = SearchInfo()
        h  = UInt64(0xDEADBEEFCAFE1234)
        b  = board_from_fen(STARTPOS)
        m1 = move_from_uci(b, "e2e4")
        m2 = move_from_uci(b, "d2d4")
        # Write a deep entry (depth 10).
        Chess._tt_put!(si.tt, h, 10, 50, Chess.TT_EXACT, m1)
        e1 = Chess._tt_get(si.tt, h)
        @test e1.key == h && Int(e1.depth) == 10 && e1.move == m1
        # Attempt to overwrite with a shallower entry (depth 9) — must not replace.
        Chess._tt_put!(si.tt, h, 9, 99, Chess.TT_EXACT, m2)
        e2 = Chess._tt_get(si.tt, h)
        @test Int(e2.depth) == 10
        @test e2.move == m1
    end

    @testset "TT — replacement: same-depth entry is overwritten (aspiration support)" begin
        si = SearchInfo()
        h  = UInt64(0xABCDEF0123456789)
        b  = board_from_fen(STARTPOS)
        m1 = move_from_uci(b, "e2e4")
        m2 = move_from_uci(b, "d2d4")
        Chess._tt_put!(si.tt, h, 5, 30, Chess.TT_UPPER, m1)
        # Same depth must replace (aspiration re-search updates a stale UPPER entry).
        Chess._tt_put!(si.tt, h, 5, 45, Chess.TT_EXACT, m2)
        e = Chess._tt_get(si.tt, h)
        @test e.score == Int32(45)
        @test e.flag  == Chess.TT_EXACT
        @test e.move  == m2
    end

    @testset "TT — entry stays within 24 bytes after eval/gen fields" begin
        # key(8) + score(4) + depth(2) + flag(1) + move(4) + eval(2) + gen(1)
        # fits the pre-existing 24-byte padded footprint, so the 8M-entry table
        # size is unchanged.
        @test sizeof(Chess.TTEntry) == 24
    end

    @testset "TT — static eval survives an overwrite that has no eval" begin
        si = SearchInfo()
        h  = UInt64(0x1122334455667788)
        b  = board_from_fen(STARTPOS)
        m1 = move_from_uci(b, "e2e4")
        Chess._tt_put!(si.tt, h, 3, 40, Chess.TT_EXACT, m1, 123, UInt8(1))
        @test Int(Chess._tt_get(si.tt, h).eval) == 123
        # Deeper write for the same position without a known eval must keep
        # the cached eval — it is position-exact and never goes stale.
        Chess._tt_put!(si.tt, h, 5, 60, Chess.TT_EXACT, m1, Int(Chess.TT_EVAL_NONE), UInt8(1))
        e = Chess._tt_get(si.tt, h)
        @test Int(e.depth) == 5 && Int(e.eval) == 123
    end

    @testset "TT — stale generation is replaced regardless of depth" begin
        si = SearchInfo()
        h  = UInt64(0x8877665544332211)
        b  = board_from_fen(STARTPOS)
        m1 = move_from_uci(b, "e2e4")
        m2 = move_from_uci(b, "d2d4")
        Chess._tt_put!(si.tt, h, 12, 50, Chess.TT_EXACT, m1, Int(Chess.TT_EVAL_NONE), UInt8(1))
        # A shallower entry from a NEWER generation replaces the deep stale one.
        Chess._tt_put!(si.tt, h, 2, -10, Chess.TT_UPPER, m2, Int(Chess.TT_EVAL_NONE), UInt8(2))
        e = Chess._tt_get(si.tt, h)
        @test Int(e.depth) == 2 && e.move == m2 && e.gen == UInt8(2)
    end

    @testset "TT — mate score ply normalization is consistent across searches" begin
        # Searching the same mate-in-2 twice with a warm TT must return the
        # same mate distance both times (normalization roundtrip is correct).
        b  = board_from_fen("3k4/8/6R1/7R/8/8/8/6K1 w - - 0 1")
        si = SearchInfo()
        r1 = search_move(b, 500; si)
        r2 = search_move(b, 500; si)
        @test r1.score == r2.score
        @test abs(r2.score) >= MATE_SCORE - Chess.MAX_PLY
    end

    @testset "TT — prior_counts guard: warm TT does not override draw by repetition" begin
        # Search normally first to populate the TT with a positive score.
        b  = board_from_fen("4k3/8/8/8/8/8/Q7/4K3 w - - 0 1")
        si = SearchInfo()
        r1 = search_move(b, 500; si)
        @test r1.score > 0

        # Mark every position reachable in one white move as seen twice.
        # Each such position has prior_counts = 2, so any move there is a draw.
        # The prior_counts guard in _negamax must block the TT's positive score.
        ml = MoveList()
        generate_moves!(ml, b)
        pc = Dict{UInt64,Int}()
        for i in 1:length(ml)
            undo = make_move!(b, ml.moves[i])
            pc[b.hash] = 2
            unmake_move!(b, ml.moves[i], undo)
        end
        r2 = search_move(b, 500; si, prior_counts = pc)
        @test r2.score == 0
    end

    @testset "TT — _extract_pv stops at TT_UPPER entry" begin
        b  = board_from_fen("7k/8/8/3q4/8/8/8/3R3K w - - 0 1")
        si = SearchInfo()
        r  = search_move(b, 500; si)
        # Overwrite the position after the best move with a TT_UPPER entry.
        # _extract_pv must stop there and return a length-1 PV.
        undo = make_move!(b, r.move)
        Chess._tt_put!(si.tt, b.hash, 20, 0, Chess.TT_UPPER, NULL_MOVE)
        unmake_move!(b, r.move, undo)
        pv = Chess._extract_pv(b, si.tt, r.move, 8)
        @test length(pv) == 1
    end

    @testset "TT — _extract_pv terminates on hash cycle" begin
        # Inject a TT chain that loops: position after pv[2] points back to pv[1].
        # _extract_pv must terminate cleanly via the seen-hash guard.
        b  = board_from_fen(STARTPOS)
        si = SearchInfo()
        r  = search_move(b, 300; si)
        @test length(r.pv) >= 1
        if length(r.pv) >= 2
            undo1 = make_move!(b, r.pv[1])
            undo2 = make_move!(b, r.pv[2])
            Chess._tt_put!(si.tt, b.hash, 1, 0, Chess.TT_EXACT, r.pv[1])
            unmake_move!(b, r.pv[2], undo2)
            unmake_move!(b, r.pv[1], undo1)
        end
        pv = Chess._extract_pv(b, si.tt, r.move, 20)
        @test length(pv) >= 1
        @test length(pv) <= 20
    end

    # ── Draw rescue ───────────────────────────────────────────────────────────

    @testset "SEE - quiet move to a square defended by a stronger piece is SEE-losing" begin
        # The draw rescue uses _see_ge to avoid offering a draw by moving a piece
        # that immediately hangs.  These cases exercise _see_ge on QUIET moves
        # (no captured piece on the destination square).
        #
        # Ka1+Rc4 vs Ka8+Qf7: Qf7 diagonally attacks c4 (f7→e6→d5→c4).
        # Rc4→c7: queen on f7 recaptures along rank 7 (c7 and f7 share rank 7,
        #          no piece between them) — rook hangs, SEE < 0.
        # Rc4→c8: no attacker on c8 (queen can't reach it, Ka8 is 2 files away) — SEE = 0.
        b  = board_from_fen("k7/5q2/8/8/2R5/8/8/K7 w - - 0 1")
        m7 = move_from_uci(b, "c4c7")
        m8 = move_from_uci(b, "c4c8")
        @test Chess._see_ge(b, m7, 0)   == false   # rook hangs to Qf7xRc7
        @test Chess._see_ge(b, m7, -633) == true    # threshold at full rook loss
        @test Chess._see_ge(b, m8, 0)   == true     # c8 is undefended: SEE = 0
    end

    @testset "Draw rescue — root already at its 3rd occurrence scores as draw" begin
        # root_prior_count already includes the CURRENT occurrence (apply_moves!
        # increments a position's count as soon as it is reached, and root is the
        # position we are at right now). So root_prior_count == 3 means this exact
        # position has already recurred for the 3rd time, right now — a draw
        # claimable regardless of which move is played next.
        #
        # Ka1 vs Ka8+Qb6: white king only, clearly losing (queen dominates).
        # Only legal white move is Ka2 (b1 and b2 are covered by Qb6 along the b-file).
        # After Ka2 the position is still losing (black queen wins), so best_score < 0.
        # When root_prior_count = 3, the draw rescue must override best_score to 0.
        b  = board_from_fen("k7/8/1q6/8/8/8/8/K7 w - - 0 1")
        si = SearchInfo()
        # Prime the TT so the engine has established a negative best_score.
        _ = search_move(b, 200; si)

        # Claim the root has already occurred 3 times, counting now.
        pc = Dict{UInt64,Int}(b.hash => 3)
        r  = search_move(b, 500; si, prior_counts = pc)
        @test r.score == 0
    end

    @testset "Regression - root seen only twice must not be scored as a draw" begin
        # Bug: the draw-rescue fallback used to trigger on root_prior_count >= 2,
        # but that count already includes the CURRENT occurrence, so 2 means the
        # position has only happened twice so far (this being the 2nd time) — one
        # more genuine recurrence is required for an actual 3-fold draw, and it is
        # NOT guaranteed by an arbitrary losing move. Overriding to 0 here falsely
        # reports a draw for a move that plainly loses (e.g. hangs a queen).
        b  = board_from_fen("k7/8/1q6/8/8/8/8/K7 w - - 0 1")
        si = SearchInfo()
        _  = search_move(b, 200; si)

        pc = Dict{UInt64,Int}(b.hash => 2)   # 2nd occurrence, not yet a draw
        r  = search_move(b, 500; si, prior_counts = pc)
        @test r.score < 0
    end

    include("syzygy_test.jl")

end
