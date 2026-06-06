using Chess
using Printf
using Dates

function benchmark_pos(name, fen, depth)
    b = board_from_fen(fen)
    println("Benchmarking: $name at depth $depth")

    # Warmup
    search_move(b, 200; verbose=false)

    start_time = now()
    # We use a fixed depth search for benchmarking NPS and efficiency
    # But search_move is time-based. We will simulate a deep search by giving it plenty of time
    # but we will look at the nodes reported for the last completed depth.

    si = SearchInfo()
    r = search_move(b, 5000; si=si, verbose=true) # This will print info lines

    elapsed = (now() - start_time).value / 1000.0
    nps = r.nodes / elapsed

    @printf("\nSummary for %s:\n", name)
    @printf("  Nodes: %d\n", r.nodes)
    @printf("  Time:  %.3f s\n", elapsed)
    @printf("  NPS:   %d\n", round(Int, nps))
    println("-"^40)
    return nps
end

function run_benchmarks()
    positions = [
        ("Startpos", STARTPOS, 8),
        ("Kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 6),
        ("Talkchess", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 6)
    ]

    total_nps = 0.0
    for (name, fen, depth) in positions
        total_nps += benchmark_pos(name, fen, depth)
    end

    @printf("\nAverage NPS: %d\n", round(Int, total_nps / length(positions)))
end

run_benchmarks()
