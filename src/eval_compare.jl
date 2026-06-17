# eval_compare.jl — Compare this engine's evaluations vs Stockfish for each position in a PGN game.
#
# Usage:
#   julia --project src/eval_compare.jl <game.pgn> <stockfish_path> [depth=12]
#
# For each half-move the script reports:
#   - Our static eval  (evaluate(), White's perspective, centipawns)
#   - Our search eval  (search_move() at depth D, White's perspective)
#   - Stockfish static eval (via UCI "eval" command, White's perspective)
#   - Stockfish search eval (via "go depth D", White's perspective)
#   - Lichess cloud eval if present in PGN comments (%eval annotations)
#
# Results are sorted by |our_search − sf_search| so the biggest
# discrepancies appear first — these are the positions most worth studying.

using Chess
using Printf

# ── Result row ────────────────────────────────────────────────────────────────
struct EvalRow
    ply       ::Int
    san       ::String
    fen       ::String
    our_static::Int          # cp, White's perspective
    our_search::Int          # cp, White's perspective
    sf_static ::Union{Int,Nothing}  # nothing if unavailable (e.g. checkmate pos)
    sf_search ::Int          # cp, White's perspective
    lc_eval   ::Union{Int,Nothing}  # Lichess cloud eval, or nothing
end

delta_search(r::EvalRow) = r.our_search - r.sf_search
delta_static(r::EvalRow) = r.our_static - (r.sf_static !== nothing ? r.sf_static : r.our_static)

# ── Stockfish subprocess wrapper ──────────────────────────────────────────────
mutable struct SF
    proc::Base.Process
end

function sf_start(path::String)::SF
    proc = open(Cmd([path]), "r+")
    println(proc.in, "uci")
    _sf_wait(proc.out, "uciok")
    println(proc.in, "isready")
    _sf_wait(proc.out, "readyok")
    SF(proc)
end

function _sf_wait(io::IO, token::String)
    while true
        startswith(readline(io), token) && return
    end
end

sf_quit(sf::SF) = println(sf.proc.in, "quit")

# Stockfish static eval via the "eval" UCI command.
# Returns centipawns from White's perspective, or nothing if unavailable.
function sf_eval_static(sf::SF, fen::String)::Union{Int,Nothing}
    println(sf.proc.in, "position fen $fen")
    println(sf.proc.in, "eval")
    println(sf.proc.in, "isready")
    result = nothing
    while true
        l = readline(sf.proc.out)
        startswith(l, "readyok") && break
        # Matches both "Final evaluation: +0.52 (white side)" and
        # "Final evaluation  0.52 (white side)" across Stockfish versions.
        m = match(r"[Ff]inal evaluation[^0-9+\-]*([+\-]?\d+\.?\d+)\s*\(white side\)", l)
        m !== nothing && (result = round(Int, parse(Float64, m[1]) * 100))
    end
    result
end

# Stockfish search eval at a fixed depth.
# Returns centipawns from White's perspective.
function sf_eval_search(sf::SF, fen::String, depth::Int)::Int
    side_white = split(fen)[2] == "w"
    println(sf.proc.in, "position fen $fen")
    println(sf.proc.in, "go depth $depth")
    score = 0
    while true
        l = readline(sf.proc.out)
        m_cp = match(r"\bscore cp ([+\-]?\d+)", l)
        if m_cp !== nothing
            cp = parse(Int, m_cp[1])
            score = side_white ? cp : -cp
        end
        m_mate = match(r"\bscore mate ([+\-]?\d+)", l)
        if m_mate !== nothing
            ply = parse(Int, m_mate[1])
            # side-to-move wins if ply > 0, loses if ply < 0
            stm = ply > 0 ? (30_000 - abs(ply)) : -(30_000 - abs(ply))
            score = side_white ? stm : -stm
        end
        startswith(l, "bestmove") && break
    end
    score
end

# ── SAN → Move ────────────────────────────────────────────────────────────────
# Parses a single Standard Algebraic Notation token and returns the
# corresponding legal Move in position b.  Raises an error if not found.
function move_from_san(b::Board, san::AbstractString)::Move
    s = replace(san, r"[\+#!?]+" => "")   # strip check / annotation suffixes

    if s in ("O-O", "0-0")
        ml = MoveList(); generate_moves!(ml, b)
        for m in ml; flags(m) == MF_KS_CAST && return m; end
        error("Kingside castle not legal: $san")
    end
    if s in ("O-O-O", "0-0-0")
        ml = MoveList(); generate_moves!(ml, b)
        for m in ml; flags(m) == MF_QS_CAST && return m; end
        error("Queenside castle not legal: $san")
    end

    # Pattern: [PIECE][file_disambig][rank_disambig][x][dest_file][dest_rank][=PROMO]
    pat = match(r"^([NBRQK]?)([a-h]?)([1-8]?)(x?)([a-h][1-8])(=[NBRQ])?$", s)
    pat === nothing && error("Cannot parse SAN token: '$san'")

    piece_sym, dis_f, dis_r, _, dest_str, promo_str = pat.captures
    dest_sq  = sq(Int(dest_str[1] - 'a'), Int(dest_str[2] - '1'))
    kind = isempty(piece_sym) ? Pawn :
           piece_sym == "N" ? Knight : piece_sym == "B" ? Bishop :
           piece_sym == "R" ? Rook   : piece_sym == "Q" ? Queen : King
    pk   = isempty(promo_str) ? NoPiece :
           promo_str[2] == 'N' ? Knight : promo_str[2] == 'B' ? Bishop :
           promo_str[2] == 'R' ? Rook   : Queen

    ml = MoveList(); generate_moves!(ml, b)
    for mv in ml
        to_sq(mv) == dest_sq                               || continue
        b.piece_on[from_sq(mv)+1].kind == kind             || continue
        !isempty(dis_f) && file_of(from_sq(mv)) != Int(dis_f[1]-'a') && continue
        !isempty(dis_r) && rank_of(from_sq(mv)) != Int(dis_r[1]-'1') && continue
        if pk != NoPiece
            (is_promo(mv) && promo_kind(mv) == pk)         || continue
        else
            is_promo(mv) && continue
        end
        return mv
    end
    error("SAN '$san' not found among legal moves in: $(board_to_fen(b))")
end

# ── PGN parser ────────────────────────────────────────────────────────────────
# Returns (san_moves, start_fen, lichess_cp_by_halfmove_index)
function parse_pgn(pgn::String)
    # Starting FEN from headers (only for non-standard starts)
    fen_m = match(r"\[FEN \"([^\"]+)\"\]", pgn)
    start_fen = fen_m !== nothing ? fen_m[1] : STARTPOS

    # Lichess %eval annotations — one per half-move in comment order.
    # Format: [%eval 0.17]  or  [%eval #3]  (forced mate in 3)
    lc_cp = Int[]
    for m in eachmatch(r"\[%eval\s+(?:#([+\-]?\d+)|([+\-]?\d+\.?\d*))\]", pgn)
        if m[1] !== nothing           # mate score
            push!(lc_cp, parse(Int, m[1]) > 0 ? 30_000 : -30_000)
        else
            push!(lc_cp, round(Int, parse(Float64, m[2]) * 100))
        end
    end

    # Strip PGN headers (lines starting with '[')
    movetext = replace(pgn, r"^\[[^\]]*\]\s*"m => "")

    # Strip {comments} — these contain %eval, %clk etc.
    movetext = replace(movetext, r"\{[^}]*\}" => " ")

    # Strip (variations) iteratively to handle nesting
    while occursin('(', movetext)
        movetext = replace(movetext, r"\([^()]*\)" => " ")
    end

    # Strip NAGs ($N), result tokens
    movetext = replace(movetext, r"\$\d+" => " ")
    movetext = replace(movetext, r"\b(1-0|0-1|1/2-1/2|\*)\b" => " ")

    # Strip move numbers (e.g. "1.", "1...", "12.")
    movetext = replace(movetext, r"\d+\.+\s*" => " ")

    # Tokenize — keep only tokens that look like moves (start with piece letter,
    # file letter, or 'O' for castling)
    tokens = split(strip(movetext))
    moves  = filter(t -> !isnothing(match(r"^[a-hNBRQKO]", t)) &&
                         t ∉ ("1-0","0-1","1/2-1/2","*"), tokens)

    moves, start_fen, lc_cp
end

# ── Formatting helpers ─────────────────────────────────────────────────────────
_cp(x::Int)     = @sprintf("%+d", x)
_cp(::Nothing)  = "  N/A"

# ── Main ──────────────────────────────────────────────────────────────────────
function main()
    if length(ARGS) < 2
        println(stderr, "Usage: julia --project src/eval_compare.jl <game.pgn> <stockfish_path> [depth=12]")
        exit(1)
    end
    pgn_file = ARGS[1]
    sf_path  = ARGS[2]
    depth    = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 12

    isfile(pgn_file) || error("PGN file not found: $pgn_file")
    isfile(sf_path)  || error("Stockfish binary not found: $sf_path")

    pgn = read(pgn_file, String)
    san_list, start_fen, lc_cp = parse_pgn(pgn)
    isempty(san_list) && (println("No moves found in PGN."); exit(0))

    println("Found $(length(san_list)) half-moves.  Connecting to Stockfish…")
    sf = sf_start(sf_path)
    println("Stockfish ready.  Analysing at depth $depth…\n")

    rows = EvalRow[]
    b    = board_from_fen(start_fen)

    for (i, san) in enumerate(san_list)
        fen = board_to_fen(b)
        print("\r  position $i / $(length(san_list))   ")
        flush(stdout)

        # Our static eval — evaluate() is always from White's perspective
        our_st = total(evaluate(b))

        # Our search eval — search_move returns score from side-to-move's perspective
        sr = search_move(b, 60_000; max_depth=depth, verbose=false)
        our_sr = b.side == White ? sr.score : -sr.score

        # Stockfish evals
        sf_st  = sf_eval_static(sf, fen)
        sf_sr  = sf_eval_search(sf, fen, depth)

        lc = i <= length(lc_cp) ? lc_cp[i] : nothing

        push!(rows, EvalRow(i, san, fen, our_st, our_sr, sf_st, sf_sr, lc))

        # Advance the board
        try
            mv = move_from_san(b, san)
            make_move!(b, mv)
        catch e
            println(stderr, "\n\nError applying move $i ($san): $e\n")
            break
        end
    end
    println()

    sf_quit(sf)

    isempty(rows) && (println("No results."); exit(0))

    # ── Print sorted table ─────────────────────────────────────────────────────
    println("\n", repeat('─', 96))
    println("Biggest evaluation discrepancies  (depth $depth, sorted by |our_search − sf_search|)")
    println(repeat('─', 96))

    hdr = @sprintf("%-5s %-7s %9s %9s %9s %9s %8s %8s  %s",
        "Ply", "Move", "Our-St", "Our-Srch", "SF-St", "SF-Srch",
        "Δ-Static", "Δ-Search", "FEN")
    println(hdr)
    println(repeat('─', 96))

    sorted = sort(rows; by = r -> abs(delta_search(r)), rev = true)
    for r in sorted[1:min(30, length(sorted))]
        ds   = r.sf_static !== nothing ? r.our_static - r.sf_static : 0
        dsr  = delta_search(r)
        lc_s = r.lc_eval !== nothing ? @sprintf("LC:%+d", r.lc_eval) : ""
        line = @sprintf("%-5d %-7s %+9d %+9d %9s %+9d %+8d %+8d  %-25s %s",
            r.ply, r.san,
            r.our_static, r.our_search,
            r.sf_static !== nothing ? @sprintf("%+d", r.sf_static) : "N/A",
            r.sf_search,
            ds, dsr,
            r.fen[1:min(25,length(r.fen))],
            lc_s)
        println(line)
    end

    # ── Summary statistics ─────────────────────────────────────────────────────
    valid  = filter(r -> r.sf_static !== nothing, rows)
    n      = length(rows)
    nv     = length(valid)

    search_deltas = [delta_search(r)  for r in rows]
    static_deltas = nv > 0 ? Int[r.our_static - (r.sf_static::Int) for r in valid] : Int[]

    rms(v) = sqrt(sum(x^2 for x in v) / length(v))
    bias(v) = sum(v) / length(v)

    println("\n", repeat('─', 96))
    println("Summary  ($n positions analysed)")
    println(repeat('─', 96))
    if nv > 0
        println(@sprintf("  Static  Δ  —  bias: %+.1f cp   RMS: %.1f cp   max |Δ|: %d cp   (n=%d)",
            bias(static_deltas), rms(static_deltas), maximum(abs, static_deltas), nv))
    end
    println(@sprintf("  Search  Δ  —  bias: %+.1f cp   RMS: %.1f cp   max |Δ|: %d cp   (n=%d)",
        bias(search_deltas), rms(search_deltas), maximum(abs, search_deltas), n))

    # Histogram of search delta magnitude
    buckets = [0, 25, 50, 100, 200, 500, typemax(Int)]
    labels  = ["0–25", "25–50", "50–100", "100–200", "200–500", "500+"]
    counts  = zeros(Int, length(labels))
    for r in rows
        d = abs(delta_search(r))
        for (j, hi) in enumerate(buckets[2:end])
            d < hi && (counts[j] += 1; break)
        end
    end
    println("\n  Search |Δ| distribution:")
    for (lbl, cnt) in zip(labels, counts)
        bar = repeat('█', min(cnt, 40))
        println(@sprintf("    %8s cp: %3d  %s", lbl, cnt, bar))
    end
    println()
end

main()
