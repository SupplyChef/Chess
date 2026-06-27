# tune_data.jl — Load ChessBench positions and pre-extract feature vectors.
#
# ChessBench (Ruoss et al., 2024 / Google DeepMind) provides ~10M chess
# positions annotated with Stockfish-16 action-values.  We only need static
# position evaluations, so we take the Q-value of the best move per FEN as
# the supervision signal.
#
# Expected CSV format (one row per position):
#   fen,score_cp[,depth]
#   rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1,28
#
# The "score_cp" column is the Stockfish centipawn evaluation from White's
# perspective (positive = White better).  Depth is optional; use --min_depth
# to filter unreliable shallow evaluations.
#
# ── Preparing the data ────────────────────────────────────────────────────────
# Option A — Python conversion from HuggingFace Parquet:
#
#   pip install datasets pyarrow pandas
#   python3 - <<'EOF'
#   from datasets import load_dataset
#   import pandas as pd
#
#   ds = load_dataset("google-deepmind/chess_state_value", split="train")
#   df = ds.to_pandas()
#
#   # Keep best-move Q-value per position; convert WDL → centipawns if needed.
#   # Adjust column names to match your dataset version.
#   df = df.rename(columns={"fen": "fen", "value": "score_cp"})
#   df["score_cp"] = (df["score_cp"] * 400).round().astype(int)  # if WDL in [-1,1]
#   df[["fen", "score_cp"]].to_csv("chessbench.csv", index=False)
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
