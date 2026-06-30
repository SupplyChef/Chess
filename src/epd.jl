# epd.jl — EPD (Extended Position Description) test suite runner.
#
# Supports WAC (Win at Chess), STS (Strategic Test Suite), and any
# standard EPD file.  Best moves in the file are in SAN; this module
# converts them to UCI for comparison with the engine's output.
#
# Usage:
#   results = run_epd_suite("test/wac.epd"; time_ms=1000)
#   results = run_epd_suite("test/sts.epd"; time_ms=5000, cfg=DEFAULT_CONFIG)

struct EPDEntry
    fen        ::String
    best_moves ::Vector{String}   # UCI notation (converted from SAN at load time)
    id         ::String
end

struct EPDResult
    id          ::String
    found       ::Bool
    engine_move ::String
    best_moves  ::Vector{String}
    score_cp    ::Int
    depth       ::Int
    nodes       ::Int64
    time_ms     ::Int
end

# ── SAN → UCI conversion ──────────────────────────────────────────────────────

function _san_piece(c::Char)::PieceKind
    c == 'N' && return Knight
    c == 'B' && return Bishop
    c == 'R' && return Rook
    c == 'Q' && return Queen
    c == 'K' && return King
    Pawn
end

# Convert file/rank characters to 0-based index; returns -1 on failure.
_san_file(c::Char) = ('a' <= c <= 'h') ? Int(c) - Int('a') : -1
_san_rank(c::Char) = ('1' <= c <= '8') ? Int(c) - Int('1') : -1

# 0-based square from two-char string like "e4"; returns -1 on failure.
function _san_sq(s::AbstractString)::Int
    length(s) < 2 && return -1
    f = _san_file(s[1])
    r = _san_rank(s[2])
    (f < 0 || r < 0) && return -1
    r * 8 + f
end

# Convert a SAN move string to UCI given the current board.
# Returns "" if the move cannot be matched to any legal move.
function _san_to_uci(b::Board, san::String)::String
    # Strip check/checkmate suffixes and annotation glyphs
    s = replace(san, r"[+#!?]+" => "")

    # Castling
    if s == "O-O" || s == "0-0"
        ml = MoveList()
        generate_moves!(ml, b)
        for m in ml
            is_castle(m) && flags(m) == MF_KS_CAST && return move_to_uci(m)
        end
        return ""
    end
    if s == "O-O-O" || s == "0-0-0"
        ml = MoveList()
        generate_moves!(ml, b)
        for m in ml
            is_castle(m) && flags(m) == MF_QS_CAST && return move_to_uci(m)
        end
        return ""
    end

    # Promotion: strip "=X" suffix, record promo piece
    promo_pc = NoPiece
    promo_m = match(r"=([NBRQ])$", s)
    if promo_m !== nothing
        promo_pc = _san_piece(promo_m[1][1])
        s = s[1:end-2]
    end

    # Determine piece kind, disambiguation, and destination square
    piece_kind = Pawn
    dis_file   = -1   # disambiguation file (0-based); -1 = unspecified
    dis_rank   = -1   # disambiguation rank (0-based)
    dst_sq     = -1   # destination square (0-based)

    # Upper-case first letter → non-pawn piece
    if !isempty(s) && isuppercase(s[1]) && s[1] != 'O'
        piece_kind = _san_piece(s[1])
        s = s[2:end]
    end

    # Strip capture marker
    s = replace(s, "x" => "")

    # Remaining string is [dis][dst] where dis is optional 1-char disambiguation
    # and dst is the 2-char destination square.
    n = length(s)
    if n == 2
        dst_sq = _san_sq(s)
    elseif n == 3
        c1 = s[1]
        if _san_file(c1) >= 0
            dis_file = _san_file(c1)
        elseif _san_rank(c1) >= 0
            dis_rank = _san_rank(c1)
        end
        dst_sq = _san_sq(s[2:3])
    elseif n == 4
        # Full from+to (rare in SAN, but handle it)
        dis_file = _san_file(s[1])
        dis_rank = _san_rank(s[2])
        dst_sq   = _san_sq(s[3:4])
    end

    dst_sq == -1 && return ""

    ml = MoveList()
    generate_moves!(ml, b)
    for m in ml
        to_sq(m) != dst_sq && continue
        b.piece_on[from_sq(m)+1].kind != piece_kind && continue
        if dis_file >= 0 && from_sq(m) % 8 != dis_file; continue; end
        if dis_rank >= 0 && from_sq(m) ÷ 8 != dis_rank; continue; end
        if promo_pc != NoPiece
            is_promo(m) || continue
            promo_kind(m) != promo_pc && continue
        else
            is_promo(m) && continue   # don't match promotions when none expected
        end
        return move_to_uci(m)
    end
    ""
end

# ── EPD parser ────────────────────────────────────────────────────────────────

function _parse_epd_line(line::String)::Union{EPDEntry, Nothing}
    stripped = strip(line)
    (isempty(stripped) || startswith(stripped, '#')) && return nothing

    parts = split(stripped)
    length(parts) < 4 && return nothing

    # EPD has 4 mandatory FEN fields (no move clocks).  If parts[5]/[6] look
    # like integers, they're optional halfmove/fullmove counters.
    op_start = 5
    if length(parts) >= 5 && match(r"^\d+$", parts[5]) !== nothing
        op_start = 6
        if length(parts) >= 6 && match(r"^\d+$", parts[6]) !== nothing
            op_start = 7
        end
    end

    fen_parts = String.(parts[1:op_start-1])
    # Pad to 6 fields so board_from_fen is happy
    while length(fen_parts) < 6
        push!(fen_parts, length(fen_parts) == 4 ? "0" : "1")
    end
    fen = join(fen_parts, " ")

    ops_str = length(parts) >= op_start ? join(parts[op_start:end], " ") : ""

    # Extract "bm" opcode — one or more SAN moves (terminated by ";")
    bm_san = String[]
    bm_m = match(r"\bbm\s+([^;]+)", ops_str)
    if bm_m !== nothing
        for tok in split(strip(String(bm_m[1])))
            push!(bm_san, String(tok))
        end
    end
    isempty(bm_san) && return nothing

    # Extract "id" opcode
    id = ""
    id_m = match(r"\bid\s+\"([^\"]+)\"", ops_str)
    id_m !== nothing && (id = String(id_m[1]))

    # Convert SAN best moves to UCI using the position
    b = try
        board_from_fen(fen)
    catch
        return nothing
    end
    best_uci = String[]
    for san in bm_san
        uci = _san_to_uci(b, san)
        !isempty(uci) && push!(best_uci, uci)
    end
    isempty(best_uci) && return nothing

    EPDEntry(fen, best_uci, id)
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    run_epd_suite(epd_file; time_ms=1000, cfg=DEFAULT_CONFIG, verbose=true)

Run the engine on every position in an EPD file and report the score.

- `time_ms`: search time per position (milliseconds).
- `cfg`: engine configuration.
- `verbose`: print pass/fail for each position.

Returns a `Vector{EPDResult}`.  Use `epd_failures(results)` to inspect wrong answers.
"""
function run_epd_suite(epd_file::String;
                        time_ms ::Int         = 1_000,
                        cfg     ::EngineConfig = DEFAULT_CONFIG,
                        verbose ::Bool        = true)::Vector{EPDResult}

    entries = EPDEntry[]
    open(epd_file) do f
        for line in eachline(f)
            e = _parse_epd_line(line)
            e !== nothing && push!(entries, e)
        end
    end
    isempty(entries) && (@warn "No valid EPD entries in $epd_file"; return EPDResult[])

    results = EPDResult[]
    # Reuse SearchInfo so TT stays warm across positions — correct because
    # TT entries have full 64-bit key validation and won't cross-contaminate.
    si      = SearchInfo(cfg)
    correct = 0
    t_total = 0.0

    if verbose
        @printf("%-6s  %-8s  %-18s  %-6s  %-5s  %-9s  %s\n",
                "result", "engine", "best", "cp", "depth", "nodes", "id")
        println(repeat('-', 72))
    end

    for (idx, entry) in enumerate(entries)
        b = board_from_fen(entry.fen)
        # Reset per-position state; TT is intentionally kept warm.
        si.path_ptr = 0
        fill!(si.killers, NULL_MOVE)
        si.prior_counts = Dict{UInt64,Int}()

        t0 = time()
        r  = search_move(b, time_ms; si=si, verbose=false)
        t1 = time()
        elapsed = round(Int, (t1 - t0) * 1_000)
        t_total += t1 - t0

        uci   = r.move == NULL_MOVE ? "none" : move_to_uci(r.move)
        found = uci in entry.best_moves
        correct += found

        push!(results, EPDResult(
            entry.id, found, uci, entry.best_moves,
            r.score, r.depth, r.nodes, elapsed,
        ))

        if verbose
            mark = found ? "OK" : "FAIL"
            bm   = join(entry.best_moves, "/")
            bm_display = length(bm) > 18 ? bm[1:15] * "..." : bm
            @printf("%-6s  %-8s  %-18s  %+6d  %5d  %9d  %s\n",
                    mark, uci, bm_display, r.score, r.depth, r.nodes, entry.id)
        end
    end

    pct = length(entries) > 0 ? round(Int, 100 * correct / length(entries)) : 0
    verbose && println()
    @printf("Score: %d / %d  (%d%%)  total time %.1fs\n",
            correct, length(entries), pct, t_total)
    results
end

"""
    epd_failures(results) → Vector{EPDResult}

Return only the positions the engine answered incorrectly.
"""
epd_failures(results::Vector{EPDResult}) = filter(r -> !r.found, results)
