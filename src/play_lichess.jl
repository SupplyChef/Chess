using JSON3

import Base.haskey


const AUTH_HEADER = ["Authorization" => "Bearer $TOKEN", "Accept" => "application/x-ndjson"]
const BOT_USERNAME = "BaymaxMate"

# Track game board states
const BOARDS = Dict{String, Board}()
const PVS = Dict{String, Array{Move, 1}}()
const COLORS = Dict{String, PieceColor}()
const POSITION_COUNTS = Dict{String, Dict{UInt64, Int}}()
const POSITION_EVALS = Dict{String, LRU{Tuple{UInt64, Symbol}, SearchEval}}()
const MOVE_LISTS = Dict{String, Array{MoveList, 1}}()

function listen_to_events()
    url = "https://lichess.org/api/stream/event"

    retry_delay = 2.0
    max_delay = 60.0

    while true
        try
            HTTP.open("GET", url, headers=AUTH_HEADER, stream=true) do io
            println("connected...")
            while !eof(io)
                line = String(readavailable(io))
                if !isempty(strip(line))
                    event = JSON3.read(line)
                    println(event)
                    handle_event(event)
                end
            end
        end
        catch err 
            println("Error while listening: $err")
            println("Retrying in $retry_delay seconds...")
            sleep(retry_delay)
            retry_delay = min(retry_delay * 2, max_delay)
        else
            # If no error (stream ended naturally), reset delay
            retry_delay = 2.0
        end
    end
end

function handle_event(event)
    if event.type == "challenge"
        println("accepting challenge...")
        @async accept_challenge(event.challenge.id)
        #game_id = event.challenge.id
        #@async play_game(game_id)
    elseif event.type == "gameStart"
        println("starting game...")
        game_id = event.game.id
        if !haskey(BOARDS, game_id)
            @async play_game(game_id)
        else
            if haskey(event.game, :fen) && haskey(event.game, :isMyTurn) && event.game.isMyTurn
                BOARDS[game_id] = fromfen(event.game.fen)
                @async play_game(game_id)
            end
        end
    end
end

function accept_challenge(challenge_id)
    url = "https://lichess.org/api/challenge/$challenge_id/accept"
    HTTP.post(url, headers=AUTH_HEADER)
end

function play_game(game_id)
    url = "https://lichess.org/api/bot/game/stream/$game_id"
    println("Streaming game: $game_id")
    
    retry_delay = 2.0
    max_delay = 60.0

    done = false
    while !done
        try
            HTTP.open("GET", url, headers=AUTH_HEADER, stream=true) do io
            while !eof(io)
                line = String(readavailable(io))
                println("GAME: $line")

                if !isempty(strip(line))
                    event = JSON3.read(line)

                    if event.type == "gameFull"
                        if event.state.status ∉ ["created", "started"]
                            done = true
                            return
                        end

                        COLORS[game_id] = (event.white.name == BOT_USERNAME) ? WHITE : BLACK

                        BOARDS[game_id] = startboard()
                        POSITION_COUNTS[game_id] = Dict{UInt64, Int}()
                        hash = BOARDS[game_id].key
                        POSITION_COUNTS[game_id][hash] = 1
                        POSITION_EVALS[game_id] = LRU{Tuple{UInt64, Symbol}, SearchEval}(maxsize=10_000_000)

                        moves = apply_moves!(BOARDS[game_id], event.state.moves, POSITION_COUNTS[game_id])
                        
                        if COLORS[game_id] == WHITE
                            remaining_time_ms = event.state.wtime
                        else
                            remaining_time_ms = event.state.btime
                        end
                        @async make_move_if_needed(game_id, moves, Millisecond(remaining_time_ms))
                    elseif event.type == "gameState"
                        if event.status ∉ ["created", "started"]
                            done = true
                            return
                        end

                        if (haskey(event, :wtakeback) && event.wtakeback) || (haskey(event, :btakeback) && event.btakeback)
                            url = "https://lichess.org/api/board/game/$game_id/takeback/1"
                            r = HTTP.post(url, headers=AUTH_HEADER)
                            if r.status == 200
                                println("Allowed take back successfully.")
                            else
                                println("Failed to allow take back.")
                            end
                        end

                        BOARDS[game_id] = startboard()
                        POSITION_COUNTS[game_id] = Dict{UInt64, Int}()
                        hash = BOARDS[game_id].key
                        POSITION_COUNTS[game_id][hash] = 1

                        moves = apply_moves!(BOARDS[game_id], event.moves, POSITION_COUNTS[game_id])
                        
                        if COLORS[game_id] == WHITE
                            remaining_time_ms = event.wtime
                        else
                            remaining_time_ms = event.btime
                        end
                        @async make_move_if_needed(game_id, moves, Millisecond(remaining_time_ms))
                    end
                end
            end
        end
        catch err 
            println("Error while listening: $err")
            println("Retrying in $retry_delay seconds...")
            sleep(retry_delay)
            retry_delay = min(retry_delay * 2, max_delay)
        else
            # If no error (stream ended naturally), reset delay
            retry_delay = 2.0
        end
    end
end

function apply_moves!(board::Board, moves_str::String, position_counts)
    #reset!(board)
    moves = Move[]
    if !isempty(moves_str)
        for move in split(moves_str)
            try
                move = Chess.movefromstring(String(move))
                domove!(board, move, position_counts)
                push!(moves, move)
            catch err
                println("Warning: Illegal move skipped: $move, $err")
            end
        end
    end
    return moves
end

function make_move_if_needed(game_id, moves, remaining_time)
    println("Planning move... with $(remaining_time) remaining")

    board = BOARDS[game_id]
    is_my_turn = (sidetomove(board) == COLORS[game_id])

    if is_my_turn
        make_move(game_id, moves, remaining_time)
    end
end

function make_move(game_id, moves, remaining_time)
    depth = 20
    max_time = min(Nanosecond(round(Int64, Dates.value(convert(Nanosecond, remaining_time)) / 10)), Second(25))
    max_time = convert(Nanosecond, max_time)
    if length(moves) < 8
        max_time = Second(10)
    end

    board = BOARDS[game_id]
    color = COLORS[game_id]

    position_counts = POSITION_COUNTS[game_id]
    position_evals = POSITION_EVALS[game_id]
    move_lists = [MoveList(100) for i in 1:depth+6+10]

    primary_variation = Move[]
    if haskey(PVS, game_id)
        pv = PVS[game_id]
        if length(pv) > 2 && pv[2] == moves[end]
            primary_variation = pv[3:end]
        end
    end

    move = nothing
    pv = Move[]
    try
        move, value, pv, time = find_best_move_with_deepening_search(board, color, depth, max_time, move_lists, position_counts; 
                                                                explain=false, primary_variation=primary_variation, position_evals=position_evals)

        PVS[game_id] = pv
        println(fen(board))
        println("Playing move: $(floor((length(moves) + 2) / 2)). $(movetosan(board, move))")
    catch err
        showerror(stdout, err, catch_backtrace())
    end
    @async success = play_move(game_id, tostring(move))
    try
        println("PV $pv")
        board1 = deepcopy(board)
        for mv in pv
            if mv == MOVE_NULL
                break
            end
            try
             board1 = domoves(board1, mv)
            catch err
                println("Error playing $mv")
            end
        end
        pprint(board1; unicode=true)
        evaluate_board(board1, color; explain = true)
    catch err 
        showerror(stdout, err, catch_backtrace())
    end
    domove!(board, move, POSITION_COUNTS[game_id])
    println(fen(board))
end

function play_move(game_id, move)
    url = "https://lichess.org/api/bot/game/$game_id/move/$move"
    
    delay_s = 2
    max_retries = 3
    for attempt in 1:max_retries
        try
            println("Sending move: $move")
            r = HTTP.post(url, AUTH_HEADER; readtimeout=5, connecttimeout=5)
            if r.status == 200
                println("Move $move played successfully.")
                return true
            else
                println("Attempt $attempt: Failed to play move. Status: $(r.status)")
                println("Response body: $(String(r.body))")
            end
        catch e
            @warn "Attempt $attempt: Exception posting move $move: $e"
        end

        if attempt < max_retries
            sleep(delay_s * attempt)  # exponential backoff
            println("Retrying move $move (attempt $(attempt + 1))...")
        end
    end

    return false
end

function challenge_bot(opponent_username::String; time_limit_s=300, increment_s=0, rated=false)
    url = "https://lichess.org/api/challenge/$opponent_username"
    body = JSON3.write(Dict(
        "clock.limit" => time_limit_s,     # in seconds
        "clock.increment" => increment_s,  # in seconds per move
        "rated" => rated,
        "variant" => "standard"
    ))

    headers = vcat(AUTH_HEADER, ["Content-Type" => "application/json"])
    response = HTTP.post(url, headers, body)
    
    println("Challenge sent to $opponent_username — Status: ", response.status)
    if response.status != 200
        println("Error: ", String(response.body))
    else
        println("Response: ", String(response.body))
    end
end