# play_lichess.jl — Connect the Chess engine to the Lichess Bot API.
#
# Usage (from Julia REPL with the project active):
#   using Chess
#   include("src/play_lichess.jl")
#
# Or run as a script:
#   julia --project src/play_lichess.jl
#
# Requires: LICHESS_TOKEN env var (OAuth token for a Lichess Bot account).
# Optional: LICHESS_BOT_NAME env var (default "BaymaxMate").

using HTTP
using JSON3

const TOKEN    = get(ENV, "LICHESS_TOKEN", "")
const BOT_NAME = get(ENV, "LICHESS_BOT_NAME", "BaymaxMate")

isempty(TOKEN) && error("Set the LICHESS_TOKEN environment variable before running.")

const AUTH_HEADER = ["Authorization" => "Bearer $TOKEN"]
const NDJSON_HDR  = vcat(AUTH_HEADER, ["Accept" => "application/x-ndjson"])

# ── Per-game mutable state ─────────────────────────────────────────────────────
const BOARDS          = Dict{String, Board}()
const COLORS          = Dict{String, Color}()
const POSITION_COUNTS = Dict{String, Dict{UInt64, Int}}()
const SEARCH_INFOS    = Dict{String, SearchInfo}()
const INCREMENTS      = Dict{String, Int}()   # increment in ms per game
const ACTIVE_GAMES    = Set{String}()
# PV deviation tracking: stores (start_halfmove_count, pv, score) per search.
# start is length(moves_played) at search time, so pv[i] should match
# all_moves[start+i].  score is result.score (our perspective, full depth) and
# is used at game end to measure opponent deviation quality without re-searching.
const PV_HISTORY      = Dict{String, Vector{Tuple{Int, Vector{Move}, Int}}}()
const OPENING_POSTED  = Dict{String, Bool}()   # true once opening name has been posted

# ── Lichess API helpers ────────────────────────────────────────────────────────

# Percent-encode a string for use in application/x-www-form-urlencoded bodies.
function _urlencode(s::AbstractString)::String
    buf = IOBuffer()
    for c in s
        if c in 'A':'Z' || c in 'a':'z' || c in '0':'9' || c in "-_.~"
            write(buf, c)
        else
            for byte in codeunits(string(c))
                write(buf, '%')
                write(buf, uppercase(string(byte; base = 16, pad = 2)))
            end
        end
    end
    String(take!(buf))
end

function post_chat(game_id::String, text::String; room::String = "player")
    url  = "https://lichess.org/api/bot/game/$game_id/chat"
    # Lichess hard-caps chat messages at 140 characters; longer posts are silently
    # dropped by the API.  Truncate here so the message always goes through.
    safe = length(text) <= 140 ? text : text[1:prevind(text, 140)] * "…"
    body = "room=$(_urlencode(room))&text=$(_urlencode(safe))"
    hdrs = vcat(AUTH_HEADER, ["Content-Type" => "application/x-www-form-urlencoded"])
    try
        HTTP.post(url, hdrs, body; readtimeout = 5, connecttimeout = 5)
    catch e
        @warn "Chat post failed: $e"
    end
end

function play_move(game_id::String, uci::String)::Bool
    url = "https://lichess.org/api/bot/game/$game_id/move/$uci"
    for attempt in 1:3
        try
            r = HTTP.post(url, AUTH_HEADER; readtimeout = 5, connecttimeout = 5)
            r.status == 200 && return true
            @warn "play_move attempt $attempt: status $(r.status) — $(String(r.body))"
        catch e
            @warn "play_move attempt $attempt: $e"
        end
        attempt < 3 && sleep(attempt * 2)
    end
    false
end

function accept_challenge(challenge_id::String)
    HTTP.post("https://lichess.org/api/challenge/$challenge_id/accept", AUTH_HEADER)
end

# ── Board helpers ──────────────────────────────────────────────────────────────

# apply_moves! is defined in Chess.fen (src/fen.jl) and exported from the module.

# Spend 1/60 of remaining time per move.  The recurrence is:
#   R[n+1] = R[n]*(59/60) + increment
# Time per move = remaining÷60 + increment×½.
# Fixed point of the recurrence R_{n+1} = R_n − time(R_n) + I:
#   R*/60 + I/2 = I  →  R* = 30×I  (≈ 60 s for 3+2)
# The clock stabilises at a safe level; thinking time at the fixed point ≈ I.
# For no-increment games the formula reduces to remaining÷60 (unchanged).
# Max cap: 5% of remaining + ¾ of increment, but always keep at least 3×increment
# (or 1 s) on the clock so a burst of complex positions can't cause flagging.
function time_for_move(remaining_ms::Int, increment_ms::Int, ::Int)::Int
    base_ms  = remaining_ms ÷ 60 + increment_ms ÷ 2
    # Safety: keep more buffer to cover HTTP latency (~200ms/move) and bursts.
    # For no-increment games the old 1 s floor was too thin once the clock
    # dropped below ~5 s, causing flagging due to network overhead.
    safety   = max(4 * increment_ms, 2_500)
    max_ms   = max(min(remaining_ms * 4 ÷ 100 + increment_ms * 3 ÷ 4,
                       remaining_ms - safety), 20)
    clamp(base_ms, 20, max_ms)
end

# ── PV deviation analysis ─────────────────────────────────────────────────────

# Given the full move list played in the game and the history of PVs generated
# by the engine, compute the first deviation index n for each PV and return
# a formatted histogram string.  pv[1] is always played (n=1 never deviates),
# so the minimum recorded n is 2.  Even n = opponent deviates; odd n = we deviate.
function _pv_deviation_report(game_id::String, all_moves::Vector{Move})::String
    history = get(PV_HISTORY, game_id, Tuple{Int, Vector{Move}, Int}[])
    isempty(history) && return ""

    counts_by_n = Dict{Int, Int}()
    # For n=2 (opponent deviates immediately), collect score deltas.
    # history[j+1].score - history[j].score: positive = we benefited (opp played worse),
    # negative = opp found something better than the PV predicted.
    # Caveat: this assumes the engine correctly evaluated both positions.
    n2_deltas = Int[]

    for j in 1:length(history)
        start, pv, score = history[j]
        first_dev = nothing
        for i in 2:length(pv)
            idx = start + i
            idx > length(all_moves) && break
            if all_moves[idx] != pv[i]
                first_dev = i
                break
            end
        end
        first_dev === nothing && continue
        counts_by_n[first_dev] = get(counts_by_n, first_dev, 0) + 1

        if first_dev == 2 && j < length(history)
            _, _, next_score = history[j + 1]
            push!(n2_deltas, next_score - score)
        end
    end

    isempty(counts_by_n) && return ""

    total = sum(values(counts_by_n))
    max_n = maximum(keys(counts_by_n))

    lines = String["PV deviation ($(length(history)) PVs, $total deviated):"]
    for n in 2:max_n
        c = get(counts_by_n, n, 0)
        c == 0 && continue
        who = iseven(n) ? "opp" : "us"
        bar = "█" ^ min(c, 15)
        if n == 2 && !isempty(n2_deltas)
            n_gained = count(d -> d >  30, n2_deltas)
            n_equal  = count(d -> abs(d) <= 30, n2_deltas)
            n_lost   = count(d -> d < -30, n2_deltas)
            push!(lines, "  n=$n ($who): $bar $c  [+>30cp:$n_gained  ≈:$n_equal  -<-30cp:$n_lost]")
        else
            push!(lines, "  n=$n ($who): $bar $c")
        end
    end
    join(lines, "\n")
end

# ── Core game logic ────────────────────────────────────────────────────────────

# Coaching: explain the opponent's last move using a quick background search.
function _coaching_async(game_id::String, moves_played::Vector{Move}, remaining_ms::Int)
    length(moves_played) == 0 && return
    # Capture the engine's score from just before the opponent moved.
    prev_score = let hist = get(PV_HISTORY, game_id, Tuple{Int,Vector{Move},Int}[])
        isempty(hist) ? nothing : hist[end][3]
    end
    @async begin
        try
            b_coach = board_from_fen(STARTPOS)
            c_coach = Dict{UInt64,Int}(b_coach.hash => 1)
            prev_str = join(move_to_uci.(moves_played[1:end-1]), " ")
            apply_moves!(b_coach, prev_str, c_coach)
            opp_move = moves_played[end]
            # Cap coaching time: at most 10% of our remaining clock or 500ms.
            # Julia @async tasks are cooperative — a long coaching search holds
            # the CPU and delays our next main search if the opponent plays fast.
            coaching_ms = clamp(remaining_ms ÷ 10, 50, 500)
            r_coach  = search_move(b_coach, coaching_ms; si = SearchInfo(), verbose = false)
            msg = explain_opponent_move(b_coach, opp_move, r_coach)
            # Critical moment detection: flag when opponent's move shifted the
            # position significantly in their favour.
            if prev_score !== nothing && r_coach.move != NULL_MOVE
                # prev_score: our side (positive = we were ahead).
                # r_coach.score: from side-to-move (opponent) perspective.
                # score_drop < 0 means we lost ground.
                score_drop = prev_score + r_coach.score
                if score_drop < -80
                    prefix = abs(score_drop) >= 200 ?
                        "⚠ Critical moment! " :
                        "Key move — changed the game. "
                    msg = isempty(msg) ? prefix : prefix * msg
                end
            end
            isempty(msg) || post_chat(game_id, msg; room = "player")
        catch e
            @warn "Coaching error: $e"
        end
    end
end

function make_bot_move(game_id::String, moves_played::Vector{Move}, remaining_ms::Int)
    board        = BOARDS[game_id]
    color        = COLORS[game_id]
    si           = SEARCH_INFOS[game_id]
    increment_ms = get(INCREMENTS, game_id, 0)

    board.side == color || return   # not our turn

    opp_just_moved = length(moves_played) >= 1 &&
        ((color == White && length(moves_played) % 2 == 0) ||
         (color == Black && length(moves_played) % 2 == 1))

    time_ms = time_for_move(remaining_ms, increment_ms, length(moves_played))
    println("Thinking $(time_ms)ms ($(remaining_ms)ms left, inc=$(increment_ms)ms, " *
            "$(length(moves_played)) half-moves played)…")

    t0     = time()
    result = search_move(board, time_ms; si, prior_counts = POSITION_COUNTS[game_id])

    if result.move == NULL_MOVE
        @warn "No legal move in game $game_id — game must be over"
        return
    end

    elapsed_ms = round(Int, (time() - t0) * 1_000)
    nps        = elapsed_ms > 0 ? result.nodes * 1_000 ÷ elapsed_ms : 0
    pv_str     = join(move_to_uci.(result.pv), " ")
    uci        = move_to_uci(result.move)
    println("Playing $uci  d=$(result.depth)  score=$(result.score)cp  " *
            "nodes=$(result.nodes)  nps=$(nps ÷ 1_000)k  time=$(elapsed_ms)ms  pv=$pv_str")

    # Record PV + score for deviation tracking.
    # result.score (our perspective, full depth) lets us measure opponent deviation
    # quality at game end by comparing consecutive entry scores around each n=2 gap.
    if haskey(PV_HISTORY, game_id)
        push!(PV_HISTORY[game_id], (length(moves_played), copy(result.pv), result.score))
    end

    play_move(game_id, uci)

    # Post move explanation to both chat rooms.
    # Pass the opponent's last move so explain_move can distinguish a recapture
    # (restoring balance) from a genuine material gain.
    # Append the PV in UCI so the explanation can be cross-checked against the line.
    last_opp = isempty(moves_played) ? nothing : moves_played[end]
    msg = explain_move(result, board, color; last_opp_move = last_opp)
    # Fit PV tag within the 140-char Lichess limit: include it only if it fits.
    pv_tag = isempty(result.pv) ? "" : " [PV: $pv_str]"
    msg_with_pv = length(msg) + length(pv_tag) <= 140 ? msg * pv_tag :
                  length(msg) <= 140 ? msg :
                  msg[1:prevind(msg, 137)] * "…"
    @async post_chat(game_id, msg_with_pv; room = "player")
    @async post_chat(game_id, msg_with_pv; room = "spectator")

    # Opening name: post once per game when we reach move 4–8.
    n_moves = length(moves_played)
    if 4 <= n_moves <= 8 && !get(OPENING_POSTED, game_id, false)
        uci_list = move_to_uci.(moves_played)
        opening  = _opening_name(uci_list)
        if !isempty(opening)
            @async post_chat(game_id, "Opening: $opening"; room = "player")
            @async post_chat(game_id, "Opening: $opening"; room = "spectator")
        end
        OPENING_POSTED[game_id] = true
    end

    # Follow-up: strategic outlook based on PV endpoint vs root eval.
    outcome_msg = explain_pv_outcome(result, board, color)
    if !isempty(outcome_msg)
        @async post_chat(game_id, outcome_msg; room = "player")
        @async post_chat(game_id, outcome_msg; room = "spectator")
    end

    # Coaching: explain the opponent's last move. Runs after our move is submitted
    # so it doesn't compete with the main search or interleave info output.
    opp_just_moved && _coaching_async(game_id, moves_played, remaining_ms)

    # Advance our local board to stay in sync so the board.side guard prevents
    # replaying if a duplicate event fires before the next gameState rebuild.
    # We do NOT manually update POSITION_COUNTS here: the next gameState event
    # triggers a full rebuild via apply_moves!, which correctly counts every
    # position from both sides.  Updating counts here would race with that
    # rebuild and double-count engine-side positions while leaving opponent
    # positions at their correct count — the "us vs them" asymmetry that caused
    # the engine to treat its own recent positions as already repeated.
    make_move!(board, result.move)
end

function play_game(game_id::String)
    url         = "https://lichess.org/api/bot/game/stream/$game_id"
    retry_delay = 2.0
    done        = false

    println("Streaming game $game_id…")
    while !done
        try
            HTTP.open("GET", url, NDJSON_HDR; stream = true) do io
                while !eof(io)
                    line = String(readavailable(io))
                    isempty(strip(line)) && continue

                    event = JSON3.read(line)
                    println("GAME $game_id [$(event.type)]")

                    if event.type == "gameFull"
                        event.state.status ∉ ("created", "started") && (done = true; return)

                        COLORS[game_id]          = event.white.name == BOT_NAME ? White : Black
                        BOARDS[game_id]          = board_from_fen(STARTPOS)
                        POSITION_COUNTS[game_id] = Dict{UInt64,Int}(BOARDS[game_id].hash => 1)
                        SEARCH_INFOS[game_id]    = SearchInfo()
                        INCREMENTS[game_id]      = Int(get(event.clock, :increment, 0))
                        PV_HISTORY[game_id]      = Tuple{Int, Vector{Move}, Int}[]

                        moves_str = String(event.state.moves)
                        played    = apply_moves!(BOARDS[game_id], moves_str, POSITION_COUNTS[game_id])
                        remaining = Int(COLORS[game_id] == White ? event.state.wtime : event.state.btime)
                        @async make_bot_move(game_id, played, remaining)

                    elseif event.type == "gameState"
                        if event.status ∉ ("created", "started")
                            # Compute PV deviation histogram over the completed game.
                            b_end = board_from_fen(STARTPOS)
                            c_end = Dict{UInt64,Int}(b_end.hash => 1)
                            all_played = apply_moves!(b_end, String(event.moves), c_end)
                            hist = _pv_deviation_report(game_id, all_played)
                            if !isempty(hist)
                                println(hist)
                                @async post_chat(game_id, hist; room = "player")
                                @async post_chat(game_id, hist; room = "spectator")
                            end
                            done = true
                            return
                        end

                        # Accept a takeback if the opponent offered one.
                        if get(event, :wtakeback, false) || get(event, :btakeback, false)
                            try
                                r = HTTP.post("https://lichess.org/api/board/game/$game_id/takeback/1",
                                              AUTH_HEADER)
                                println("Takeback: $(r.status == 200 ? "accepted" : "failed ($(r.status))")")
                            catch e
                                @warn "Takeback accept error: $e"
                            end
                        end

                        # Rebuild from startpos + full move history on every update —
                        # simple, avoids any state-tracking bugs.
                        BOARDS[game_id]          = board_from_fen(STARTPOS)
                        POSITION_COUNTS[game_id] = Dict{UInt64,Int}(BOARDS[game_id].hash => 1)
                        moves_str = String(event.moves)
                        played    = apply_moves!(BOARDS[game_id], moves_str, POSITION_COUNTS[game_id])
                        remaining = Int(COLORS[game_id] == White ? event.wtime : event.btime)
                        @async make_bot_move(game_id, played, remaining)
                    end
                end
            end
            retry_delay = 2.0   # stream ended cleanly; reset backoff
        catch e
            println("Stream error for game $game_id: $e")
            println("Retrying in $(retry_delay)s…")
            sleep(retry_delay)
            retry_delay = min(retry_delay * 2, 60.0)
        end
    end

    delete!(BOARDS, game_id)
    delete!(COLORS, game_id)
    delete!(POSITION_COUNTS, game_id)
    delete!(SEARCH_INFOS, game_id)
    delete!(INCREMENTS, game_id)
    delete!(PV_HISTORY, game_id)
    delete!(ACTIVE_GAMES, game_id)
    println("Game $game_id finished.")
end

function handle_event(event)
    t = string(event.type)
    if t == "challenge"
        ch = event.challenge
        println("Challenge from $(ch.challenger.name) ($(ch.timeControl.type))")
        @async accept_challenge(String(ch.id))
    elseif t == "gameStart"
        game_id = String(event.game.id)
        if !(game_id in ACTIVE_GAMES)
            push!(ACTIVE_GAMES, game_id)
            @async play_game(game_id)
        end
    end
end

function listen_to_events()
    url         = "https://lichess.org/api/stream/event"
    retry_delay = 2.0
    println("Listening for events as $BOT_NAME…")
    while true
        try
            HTTP.open("GET", url, NDJSON_HDR; stream = true) do io
                println("Event stream connected.")
                while !eof(io)
                    line = String(readavailable(io))
                    isempty(strip(line)) && continue
                    event = JSON3.read(line)
                    println("EVENT: $(event.type)")
                    handle_event(event)
                end
            end
            retry_delay = 2.0
        catch e
            println("Event stream error: $e")
            println("Retrying in $(retry_delay)s…")
            sleep(retry_delay)
            retry_delay = min(retry_delay * 2, 60.0)
        end
    end
end

# Optional: send a challenge to another bot or player.
function challenge_bot(username::String;
                       time_limit_s::Int = 300, increment_s::Int = 0, rated::Bool = false)
    url  = "https://lichess.org/api/challenge/$username"
    body = JSON3.write(Dict(
        "clock.limit"     => time_limit_s,
        "clock.increment" => increment_s,
        "rated"           => rated,
        "variant"         => "standard",
    ))
    r = HTTP.post(url, vcat(AUTH_HEADER, ["Content-Type" => "application/json"]), body)
    println("Challenge to $username: status $(r.status)")
    r.status != 200 && println("Body: $(String(r.body))")
end

# ── Entry point ────────────────────────────────────────────────────────────────
listen_to_events()
