# play_lichess.jl — Connect the Chess engine to the Lichess Bot API.
# Run: julia --project src/play_lichess.jl
# Requires: LICHESS_TOKEN env var (OAuth token for a Lichess Bot account).
# Optional: LICHESS_BOT_NAME env var (default "BaymaxMate").

using Chess
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
const ACTIVE_GAMES    = Set{String}()

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
    body = "room=$(_urlencode(room))&text=$(_urlencode(text))"
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

# Apply a space-separated UCI move list to board, updating position_counts.
# Returns the list of Move objects played.
function apply_moves!(board::Board, moves_str::AbstractString,
                      counts::Dict{UInt64, Int})::Vector{Move}
    played = Move[]
    isempty(strip(moves_str)) && return played
    for uci in split(strip(moves_str))
        isempty(uci) && continue
        try
            m = move_from_uci(board, String(uci))
            make_move!(board, m)
            counts[board.hash] = get(counts, board.hash, 0) + 1
            push!(played, m)
        catch e
            @warn "Skipping illegal move $uci: $e"
        end
    end
    played
end

# How many milliseconds to think. 10% of remaining time, capped at 25 s;
# at least 1 s. Extra generous in the first 8 half-moves.
function time_for_move(remaining_ms::Int, n_moves_played::Int)::Int
    base = max(remaining_ms ÷ 10, 1_000)
    n_moves_played < 8 && (base = max(base, 10_000))
    min(base, 25_000)
end

# ── Evaluation explanation ─────────────────────────────────────────────────────

# Build the chat line that explains the position after the bot's move.
# Score is expressed from the bot's perspective so the message is intuitive
# for the opponent: positive = bot is better.
function eval_chat_line(result::SearchResult, my_color::Color)::String
    e = result.eval
    bot_cp = my_color == White ? total(e) : -total(e)

    outlook = bot_cp >  50 ? "I'm better" :
              bot_cp < -50 ? "you're better" : "roughly equal"

    s(x) = x >= 0 ? "+$x" : "$x"   # signed string helper

    "Eval $(s(bot_cp))cp ($outlook) | " *
    "material $(s(e.material)) | " *
    "activity $(s(e.piece_activity)) | " *
    "pawns $(s(e.pawn_structure)) | " *
    "king safety $(s(e.king_safety)) [depth $(result.depth)]"
end

# ── Core game logic ────────────────────────────────────────────────────────────

function make_bot_move(game_id::String, moves_played::Vector{Move}, remaining_ms::Int)
    board = BOARDS[game_id]
    color = COLORS[game_id]
    si    = SEARCH_INFOS[game_id]

    board.side == color || return   # not our turn

    time_ms = time_for_move(remaining_ms, length(moves_played))
    println("Thinking $(time_ms)ms ($(remaining_ms)ms left, $(length(moves_played)) half-moves played)…")

    result = search_move(board, time_ms; si)

    if result.move == NULL_MOVE
        @warn "No legal move in game $game_id — game must be over"
        return
    end

    uci = move_to_uci(result.move)
    println("Playing $uci  score=$(result.score)cp  depth=$(result.depth)  nodes=$(result.nodes)")

    play_move(game_id, uci)

    # Post evaluation explanation to both chat rooms (player + spectators).
    msg = eval_chat_line(result, color)
    @async post_chat(game_id, msg; room = "player")
    @async post_chat(game_id, msg; room = "spectator")

    # Advance our local board to stay in sync.
    make_move!(board, result.move)
    counts = POSITION_COUNTS[game_id]
    counts[board.hash] = get(counts, board.hash, 0) + 1
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

                        moves_str = String(event.state.moves)
                        played    = apply_moves!(BOARDS[game_id], moves_str, POSITION_COUNTS[game_id])
                        remaining = Int(COLORS[game_id] == White ? event.state.wtime : event.state.btime)
                        @async make_bot_move(game_id, played, remaining)

                    elseif event.type == "gameState"
                        event.status ∉ ("created", "started") && (done = true; return)

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
