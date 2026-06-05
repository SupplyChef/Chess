# FEN (Forsyth–Edwards Notation) parsing and serialisation.
# A FEN string has 6 space-separated fields:
#   1. piece placement (ranks 8→1, '/' separated, digits = empty squares)
#   2. side to move ('w'/'b')
#   3. castling rights ('KQkq' or '-')
#   4. en-passant target square or '-'
#   5. halfmove clock (for the 50-move rule)
#   6. fullmove number
# Ranks are stored 8→1 in the string but 0→7 internally, so we iterate descending.

const PIECE_CHARS = Dict(
    'P' => (White, Pawn),   'N' => (White, Knight), 'B' => (White, Bishop),
    'R' => (White, Rook),   'Q' => (White, Queen),  'K' => (White, King),
    'p' => (Black, Pawn),   'n' => (Black, Knight), 'b' => (Black, Bishop),
    'r' => (Black, Rook),   'q' => (Black, Queen),  'k' => (Black, King),
)

const KIND_CHAR = Dict(Pawn=>'P', Knight=>'N', Bishop=>'B', Rook=>'R', Queen=>'Q', King=>'K')

# Update both the bitboard layer and the mailbox simultaneously.
# The engine relies on both representations staying in sync (the hybrid invariant):
# bitboards for fast bulk operations, mailbox for O(1) piece-on-square queries.
function _place_piece!(b::Board, c::Color, k::PieceKind, s::Square)
    mask = sq_bb(s)
    set_bb!(b, c, k, bb(b, c, k) | mask)
    b.occ[Int(c)+1] |= mask
    b.piece_on[s+1] = Piece(c, k)

    # Incremental eval
    mg = MG_TABLE[Int(c)+1, Int(k)+1, s+1]
    eg = EG_TABLE[Int(c)+1, Int(k)+1, s+1]
    v  = k == King ? 0 : PIECE_VALUE[Int(k)+1]

    if c == White
        b.mg_score += mg
        b.eg_score += eg
        b.material += v
    else
        b.mg_score -= mg
        b.eg_score -= eg
        b.material -= v
    end
    b.phase += PHASE_TABLE[Int(k)+1]
end

function board_from_fen(fen::AbstractString)::Board
    parts = split(strip(fen))
    @assert length(parts) >= 2 "FEN must have at least piece and side fields"

    b = Board()

    # 1. Piece placement — walk the string left-to-right while tracking (rank, file).
    #    Digits skip empty squares; '/' drops to the next rank.
    rank = 7
    file = 0
    for ch in parts[1]
        if ch == '/'
            rank -= 1; file = 0
        elseif isdigit(ch)
            file += (ch - '0')
        else
            (c, k) = PIECE_CHARS[ch]
            _place_piece!(b, c, k, sq(file, rank))
            file += 1
        end
    end

    # 2. Side to move — "w" or "b".
    b.side = parts[2] == "w" ? White : Black

    # 3. Castling rights — each present letter ORs in the corresponding bit flag.
    b.castling = 0x0
    if length(parts) >= 3 && parts[3] != "-"
        for ch in parts[3]
            ch == 'K' && (b.castling |= CR_WK)
            ch == 'Q' && (b.castling |= CR_WQ)
            ch == 'k' && (b.castling |= CR_BK)
            ch == 'q' && (b.castling |= CR_BQ)
        end
    end

    # 4. En-passant target square (e.g. "e6") — convert algebraic to 0-based index.
    b.ep_square = -1
    if length(parts) >= 4 && parts[4] != "-"
        ep = parts[4]
        b.ep_square = sq(Int(ep[1]) - Int('a'), Int(ep[2]) - Int('1'))
    end

    # 5. Halfmove clock (50-move rule counter) and fullmove number — both optional.
    if length(parts) >= 5; b.halfmove = parse(Int, parts[5]); end
    if length(parts) >= 6; b.fullmove = parse(Int, parts[6]); end

    b.hash = compute_hash(b)
    # The incremental scores and phase are handled automatically by _place_piece! -> _add_piece!
    b
end

const STARTPOS = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

function board_to_fen(b::Board)::String
    io = IOBuffer()
    for rank in 7:-1:0
        empty = 0
        for file in 0:7
            s = sq(file, rank)
            p = b.piece_on[s+1]
            if p.kind == NoPiece
                empty += 1
            else
                empty > 0 && (print(io, empty); empty = 0)
                ch = KIND_CHAR[p.kind]
                print(io, p.color == White ? ch : lowercase(ch))
            end
        end
        empty > 0 && print(io, empty)
        rank > 0 && print(io, '/')
    end
    print(io, " ", b.side == White ? "w" : "b", " ")
    cr = ""
    (b.castling & CR_WK) != 0 && (cr *= "K")
    (b.castling & CR_WQ) != 0 && (cr *= "Q")
    (b.castling & CR_BK) != 0 && (cr *= "k")
    (b.castling & CR_BQ) != 0 && (cr *= "q")
    print(io, isempty(cr) ? "-" : cr, " ")
    if b.ep_square == -1
        print(io, "-")
    else
        print(io, Char(Int('a') + file_of(b.ep_square)), Char(Int('1') + rank_of(b.ep_square)))
    end
    print(io, " ", b.halfmove, " ", b.fullmove)
    String(take!(io))
end

# Pretty-print the board to stdout (useful for debugging)
function display_board(b::Board)
    println("+---+---+---+---+---+---+---+---+")
    for rank in 7:-1:0
        print("| ")
        for file in 0:7
            s = sq(file, rank)
            p = b.piece_on[s+1]
            ch = p.kind == NoPiece ? '.' : KIND_CHAR[p.kind]
            ch = p.color == Black ? lowercase(ch) : ch
            print(ch, " | ")
        end
        println(" ", rank+1)
        println("+---+---+---+---+---+---+---+---+")
    end
    println("  a   b   c   d   e   f   g   h")
    println("Side: ", b.side, "  EP: ", b.ep_square == -1 ? "-" : string(Char(Int('a')+file_of(b.ep_square)), rank_of(b.ep_square)+1))
    println("Castling: ", string(
        (b.castling & CR_WK) != 0 ? "K" : "",
        (b.castling & CR_WQ) != 0 ? "Q" : "",
        (b.castling & CR_BK) != 0 ? "k" : "",
        (b.castling & CR_BQ) != 0 ? "q" : "",
    ))
end

# Convert a square to algebraic notation
sq_name(s::Square) = string(Char(Int('a') + file_of(s)), Char(Int('1') + rank_of(s)))

# Parse a UCI move string to a Move on board b.
# We generate all legal moves and find the one matching (from, to, promo) rather than
# constructing a Move directly — this implicitly validates the UCI string (illegal
# moves simply won't appear in the list) and correctly fills in move flags like
# castling, en-passant, and capture bits without duplicating that logic here.
function move_from_uci(b::Board, uci::AbstractString)::Move
    length(uci) < 4 && error("invalid UCI: $uci")
    from = sq(Int(uci[1]) - Int('a'), Int(uci[2]) - Int('1'))
    to   = sq(Int(uci[3]) - Int('a'), Int(uci[4]) - Int('1'))
    promo = length(uci) >= 5 ? uci[5] : '\0'

    ml = MoveList()
    generate_moves!(ml, b)
    for m in ml
        from_sq(m) == from && to_sq(m) == to || continue
        if is_promo(m)
            pk = promo_kind(m)
            pc = pk == Knight ? 'n' : pk == Bishop ? 'b' : pk == Rook ? 'r' : 'q'
            pc == promo || continue
        end
        return m
    end
    error("move $uci not found in position")
end

function move_to_uci(m::Move)::String
    s = sq_name(from_sq(m)) * sq_name(to_sq(m))
    if is_promo(m)
        pk = promo_kind(m)
        s *= pk == Knight ? "n" : pk == Bishop ? "b" : pk == Rook ? "r" : "q"
    end
    s
end
