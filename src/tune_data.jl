# tune_data.jl — Load ChessBench positions and pre-extract feature vectors.
#
# ChessBench (Ruoss et al., 2024 / Google DeepMind) provides ~530M board
# states annotated by Stockfish-16 with win probabilities.  The data is
# hosted on Google Cloud Storage (NOT HuggingFace) in a custom .bag format.
#
# Expected CSV format (one row per position):
#   fen,score_cp
#   rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1,28
#
# The "score_cp" column is the Stockfish centipawn evaluation from White's
# perspective (positive = White better).
#
# ── Downloading the data ──────────────────────────────────────────────────────
#   # State-value file (~36 GB):
#   wget https://storage.googleapis.com/searchless_chess/data/train/state_value_data.bag
#
# ── Converting .bag → CSV ─────────────────────────────────────────────────────
# The .bag format is read via the searchless_chess Python library.
# Clone the repo first: git clone https://github.com/google-deepmind/searchless_chess
#
#   pip install apache-beam zstandard
#   python3 - <<'EOF'
#   import sys, csv, math
#   sys.path.insert(0, '/path/to/searchless_chess')
#   from searchless_chess.src import bagz, constants
#
#   BAG   = 'state_value_data.bag'
#   OUT   = 'chessbench.csv'
#   CLIP  = 1500   # centipawn clip; positions beyond this are filtered later
#
#   coder  = constants.CODERS['state_value']
#   reader = bagz.BagReader(BAG)
#
#   def win_prob_to_cp(p, active_is_white):
#       # win_prob is from the side-to-move's perspective; convert to White's cp.
#       p = max(1e-7, min(1 - 1e-7, p))
#       cp = 400.0 * math.log(p / (1.0 - p))   # logit scaled to centipawns
#       return cp if active_is_white else -cp
#
#   with open(OUT, 'w', newline='') as f:
#       w = csv.writer(f)
#       w.writerow(['fen', 'score_cp'])
#       for i in range(len(reader)):
#           fen, win_prob = coder.decode(reader[i])
#           active_is_white = fen.split()[1] == 'w'
#           cp = round(win_prob_to_cp(win_prob, active_is_white))
#           if abs(cp) <= CLIP:
#               w.writerow([fen, cp])
#   EOF
#
# Option B — EPD files (STS, WAC, custom Stockfish annotations):
#   Use tools/epd_to_csv.jl (not yet written) to convert.

using CSV

"""
    load_positions(path; max_n, min_depth, score_clip)

Load (board, score_cp) pairs from a CSV file.  Positions that are in check,
have fewer than 5 pieces total, or have scores beyond `score_clip` centipawns
are discarded.  Returns `(boards, scores)`.
"""
function load_positions(path::String;
                        max_n::Int     = 2_000_000,
                        min_depth::Int = 0,
                        score_clip::Int = 1500)
    boards = Vector{Board}()
    scores = Vector{Float32}()
    sizehint!(boards, max_n)
    sizehint!(scores, max_n)

    skipped = 0
    loaded  = 0

    for row in CSV.File(path; header=true, delim=',', comment="#")
        loaded >= max_n && break

        # Parse mandatory fields
        fen_str  = String(row[:fen])
        score_cp = Float32(row[:score_cp])

        # Depth filter (optional column)
        if min_depth > 0 && hasproperty(row, :depth)
            row[:depth] < min_depth && (skipped += 1; continue)
        end

        # Score clip
        abs(score_cp) > score_clip && (skipped += 1; continue)

        # Parse FEN
        b = try
            board_from_fen(fen_str)
        catch
            skipped += 1
            continue
        end

        # Skip positions in check (tactical noise dominates static eval)
        king_in_check(b) && (skipped += 1; continue)

        # Skip very sparse positions (endgame tablebases would be more accurate)
        count_bits(all_occ(b)) < 5 && (skipped += 1; continue)

        push!(boards, b)
        push!(scores, score_cp)
        loaded += 1
    end

    @info "Loaded $(length(boards)) positions, skipped $skipped"
    boards, scores
end

"""
    build_feature_matrix(boards) -> Matrix{Float32}

Pre-extract feature vectors for all positions.  Returns an (N × N_WEIGHTS)
matrix X where row i is φ(boards[i]).  This is the slow step — do it once and
cache if needed.
"""
function build_feature_matrix(boards::Vector{Board})::Matrix{Float32}
    n = length(boards)
    X = Matrix{Float32}(undef, n, N_WEIGHTS)
    for i in eachindex(boards)
        φ = extract_features(boards[i])
        @inbounds X[i, :] .= Float32.(φ)
    end
    X
end

"""
    save_dataset(X, y, path)

Save pre-extracted features and labels to a binary file for fast reloading.
"""
function save_dataset(X::Matrix{Float32}, y::Vector{Float32}, path::String)
    open(path, "w") do io
        write(io, Int64(size(X, 1)))   # n_positions
        write(io, Int64(size(X, 2)))   # n_features
        write(io, X)
        write(io, y)
    end
end

"""
    load_dataset(path) -> (X, y)
"""
function load_dataset(path::String)
    open(path, "r") do io
        n = read(io, Int64)
        d = read(io, Int64)
        X = Matrix{Float32}(undef, n, d)
        y = Vector{Float32}(undef, n)
        read!(io, X)
        read!(io, y)
        X, y
    end
end
