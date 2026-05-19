# Perft (performance test): counts the total number of leaf nodes reachable from a
# position at exactly depth N by legal play.  It has nothing to do with engine
# strength — it is purely a correctness test for move generation.
#
# The canonical node counts for standard positions are published on the Chess
# Programming Wiki.  Any deviation means a bug in generate_moves!, make_move!, or
# unmake_move!.  perft(b, 1) therefore equals the number of legal moves from b.

function perft(b::Board, depth::Int)::Int
    depth == 0 && return 1

    ml = MoveList()
    generate_moves!(ml, b)

    # At depth 1, every legal move is a leaf — skip make/unmake overhead.
    depth == 1 && return length(ml)

    total = 0
    for m in ml
        undo = make_move!(b, m)
        total += perft(b, depth - 1)
        unmake_move!(b, m, undo)
    end
    total
end

# perft_divide: shows the contribution of each root move (helpful for debugging)
function perft_divide(b::Board, depth::Int)
    ml = MoveList()
    generate_moves!(ml, b)
    total = 0
    results = Pair{String,Int}[]
    for m in ml
        undo = make_move!(b, m)
        n = perft(b, depth - 1)
        unmake_move!(b, m, undo)
        push!(results, move_to_uci(m) => n)
        total += n
    end
    sort!(results, by = x -> x.first)
    for (mv, n) in results
        println(mv, ": ", n)
    end
    println("\nTotal: ", total)
    total
end

# Standard perft positions with known correct node counts.
# Source: https://www.chessprogramming.org/Perft_Results
const PERFT_SUITE = [
    (
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "Starting position",
        [20, 400, 8902, 197281, 4865609],
    ),
    (
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "Position 2 (Kiwipete)",
        [48, 2039, 97862, 4085603],
    ),
    (
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "Position 3",
        [14, 191, 2812, 43238, 674624],
    ),
    (
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "Position 4 (mirrored)",
        [6, 264, 9467, 422333],
    ),
    (
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        "Position 5",
        [44, 1486, 62379, 2103487],
    ),
    (
        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        "Position 6",
        [46, 2079, 89890, 3894594],
    ),
]

function run_perft_suite(; max_depth::Int = 4, verbose::Bool = true)
    all_passed = true
    for (fen, name, expected) in PERFT_SUITE
        b = board_from_fen(fen)
        verbose && println("\n── ", name, " ──")
        verbose && println("FEN: ", fen)
        for d in 1:min(max_depth, length(expected))
            t = @elapsed n = perft(b, d)
            ok = n == expected[d]
            all_passed &= ok
            status = ok ? "✓" : "✗ (expected $(expected[d]))"
            if verbose
                @printf("  depth %d: %10d  %.3fs  %s\n", d, n, t, status)
            end
        end
    end
    verbose && println(all_passed ? "\nAll perft tests passed!" : "\nSome perft tests FAILED.")
    all_passed
end
