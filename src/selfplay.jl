# selfplay.jl — Engine self-play harness for ablation testing.
#
# Usage:
#   # Does null-move help?  Compare full engine vs engine without null-move:
#   result = selfplay(DEFAULT_CONFIG, EngineConfig(null_move=false); games=20, time_ms=200)
#   println(result)   # e.g. W:14 D:3 L:3  (+11 from cfg_a perspective)

"""
    MatchResult

Result of a self-play match between two configurations.
- `wins`, `draws`, `losses`: from cfg_a's perspective.
- `score`: wins + 0.5*draws − losses (positive means cfg_a won more).
"""
struct MatchResult
    wins  ::Int
    draws ::Int
    losses::Int
end

function Base.show(io::IO, r::MatchResult)
    score = r.wins - r.losses + 0.5 * r.draws
    @printf(io, "W:%d D:%d L:%d  (score %.1f)", r.wins, r.draws, r.losses, score)
end

"""
    selfplay(cfg_a, cfg_b; games=10, time_ms=100, max_ply=400, verbose=true) → MatchResult

Play `games` games (alternating colours) between cfg_a and cfg_b.
- `time_ms`: milliseconds per move per engine.
- `max_ply`: game is adjudicated as a draw after this many half-moves.
- `verbose`: print game-by-game results.

Returns a `MatchResult` from cfg_a's perspective.
"""
function selfplay(cfg_a::EngineConfig, cfg_b::EngineConfig;
                  games::Int    = 10,
                  time_ms::Int  = 100,
                  max_ply::Int  = 400,
                  verbose::Bool = true)::MatchResult

    wins = draws = losses = 0

    # Two SearchInfo objects so each engine has its own TT, killers, history.
    si_a = SearchInfo(cfg_a)
    si_b = SearchInfo(cfg_b)

    for g in 1:games
        # Alternate colours: cfg_a plays White on odd games, Black on even.
        a_is_white = isodd(g)

        b = board_from_fen(STARTPOS)
        prior_counts = Dict{UInt64,Int}()
        ply = 0
        outcome = :draw   # default if max_ply reached

        while ply < max_ply
            # Whose turn?
            side_to_move = b.side  # White or Black
            a_to_move    = (side_to_move == White) == a_is_white

            si = a_to_move ? si_a : si_b

            # Reset per-game info but keep TT warm across the game.
            prior_counts[b.hash] = get(prior_counts, b.hash, 0) + 1

            result = search_move(b, time_ms;
                                 si            = si,
                                 prior_counts  = prior_counts,
                                 verbose       = false)

            if result.move == NULL_MOVE
                # No legal move: checkmate or stalemate
                if king_in_check(b, b.side)
                    # Side to move is mated — the other side wins
                    outcome = a_to_move ? :loss : :win
                else
                    outcome = :draw
                end
                break
            end

            make_move!(b, result.move)
            ply += 1

            # 50-move rule
            if b.halfmove >= 100
                outcome = :draw
                break
            end
        end

        if outcome == :win
            wins  += 1
        elseif outcome == :loss
            losses += 1
        else
            draws += 1
        end

        if verbose
            label = outcome == :win ? "cfg_a wins" : outcome == :loss ? "cfg_b wins" : "draw"
            a_col = a_is_white ? "White" : "Black"
            @printf("Game %2d  cfg_a=%s  %s  (plies=%d)\n", g, a_col, label, ply)
        end
    end

    MatchResult(wins, draws, losses)
end

# ── Elo estimation ────────────────────────────────────────────────────────────
# Logistic approximation: Δelo = 400 × log10(score_a / score_b).
# Returns 0 when either side has no score to avoid log(0).
function _elo_delta(r::MatchResult)::Float64
    w = r.wins  + 0.5 * r.draws
    l = r.losses + 0.5 * r.draws
    (w <= 0 || l <= 0) && return w > l ? 400.0 : -400.0
    400.0 * log10(w / l)
end

"""
    ablation_suite(; games=30, time_ms=200, verbose=true)

Run a structured ablation: for each search feature flag, play `DEFAULT_CONFIG` vs
the version with that single flag disabled.  Prints Δelo for each flag and returns
a sorted vector of `(feature, result, elo)` NamedTuples.

**Interpreting results:**
- Δelo > 0  → feature helps (as expected)
- Δelo < -10 → feature *hurts*; likely a bug or bad parameter value
- |Δelo| < 15 at 30 games → statistically insignificant; increase `games` to 100+
"""
function ablation_suite(;
        games::Int    = 30,
        time_ms::Int  = 200,
        verbose::Bool = true)

    flags = [
        (:null_move,        EngineConfig(null_move=false)),
        (:lmr,              EngineConfig(lmr=false)),
        (:rfp,              EngineConfig(rfp=false)),
        (:futility,         EngineConfig(futility=false)),
        (:lmp,              EngineConfig(lmp=false)),
        (:probcut,          EngineConfig(probcut=false)),
        (:singular_ext,     EngineConfig(singular_ext=false)),
        (:pvs,              EngineConfig(pvs=false)),
        (:aspiration,       EngineConfig(aspiration=false)),
        (:see,              EngineConfig(see=false)),
        (:iir,              EngineConfig(iir=false)),
        (:history_malus,    EngineConfig(history_malus=false)),
        (:countermove,      EngineConfig(countermove=false)),
        (:check_extensions, EngineConfig(check_extensions=false)),
    ]

    results = NamedTuple{(:feature, :result, :elo), Tuple{Symbol, MatchResult, Float64}}[]
    verbose && @printf("%-20s  %s\n", "feature (ON vs OFF)", "W   D   L   Δelo")
    verbose && println(repeat('-', 52))

    for (name, cfg_off) in flags
        r   = selfplay(DEFAULT_CONFIG, cfg_off; games=games, time_ms=time_ms, verbose=false)
        elo = _elo_delta(r)
        push!(results, (feature=name, result=r, elo=elo))
        verbose && @printf("%-20s  W:%-3d D:%-3d L:%-3d  %+.0f\n",
                           name, r.wins, r.draws, r.losses, elo)
    end

    sort!(results; by = x -> -x.elo)
    verbose && println()
    verbose && println("(sorted by Elo above; negative Δelo = that feature is hurting strength)")
    results
end
