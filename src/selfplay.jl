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
