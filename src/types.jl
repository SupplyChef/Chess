# ── Primitive aliases ──────────────────────────────────────────────────────────
const BB = UInt64          # one bitboard
const Square = Int         # 0-based: a1=0 … h8=63

# ── Colors ─────────────────────────────────────────────────────────────────────
@enum Color White = 0 Black = 1

other(c::Color) = c == White ? Black : White

# ── Piece kinds ────────────────────────────────────────────────────────────────
@enum PieceKind NoPiece = 0 Pawn = 1 Knight = 2 Bishop = 3 Rook = 4 Queen = 5 King = 6

# ── Colored piece ──────────────────────────────────────────────────────────────
struct Piece
    color::Color
    kind::PieceKind
end
const NO_PIECE = Piece(White, NoPiece)

# ── Move representation ─────────────────────────────────────────────────────────
# Packed into a UInt32 for efficiency but we expose a plain struct.
#
#  bits  0- 5  from square  (0-63)
#  bits  6-11  to square    (0-63)
#  bits 12-14  flags
#       0 = quiet
#       1 = double pawn push
#       2 = king-side castle
#       3 = queen-side castle
#       4 = capture
#       5 = en-passant capture
#       8 = promotion (bit 3 set); promo piece in bits 15-17
#
# We combine promotion + capture as flag 12 (= 8 | 4).
# Promotion piece: 0=N 1=B 2=R 3=Q (stored in bits 15-16)

const MF_QUIET    = 0x0
const MF_DPUSH    = 0x1
const MF_KS_CAST  = 0x2
const MF_QS_CAST  = 0x3
const MF_CAPTURE  = 0x4
const MF_EP       = 0x5
const MF_PROMO    = 0x8
const MF_PROMO_N  = 0x8
const MF_PROMO_B  = 0x9
const MF_PROMO_R  = 0xA
const MF_PROMO_Q  = 0xB
const MF_PRCAP_N  = 0xC
const MF_PRCAP_B  = 0xD
const MF_PRCAP_R  = 0xE
const MF_PRCAP_Q  = 0xF

struct Move
    data::UInt32
end

const NULL_MOVE = Move(0xFFFFFFFF)

@inline function Move(from::Square, to::Square, flags::Integer)
    Move(UInt32(from) | (UInt32(to) << 6) | (UInt32(flags) << 12))
end

@inline from_sq(m::Move)  = Int(m.data & 0x3F)
@inline to_sq(m::Move)    = Int((m.data >> 6) & 0x3F)
@inline flags(m::Move)    = Int((m.data >> 12) & 0xF)

@inline is_capture(m::Move)   = (flags(m) & MF_CAPTURE) != 0 || flags(m) == MF_EP
@inline is_promo(m::Move)     = (flags(m) & MF_PROMO) != 0
@inline is_castle(m::Move)    = flags(m) == MF_KS_CAST || flags(m) == MF_QS_CAST
@inline is_ep(m::Move)        = flags(m) == MF_EP

@inline promo_kind(m::Move)::PieceKind = begin
    f = flags(m) & 0x3
    f == 0 ? Knight : f == 1 ? Bishop : f == 2 ? Rook : Queen
end

# ── Board state ────────────────────────────────────────────────────────────────
mutable struct Board
    # piece bitboards: bb[color+1][kind]  (White=1, Black=2; NoPiece=1..King=6 index 1-6)
    bb::Matrix{BB}        # 2 × 7  (index 1=White,2=Black × 1..6 for piece kind; col 1 unused)

    # combined occupancy shortcuts
    occ::Vector{BB}       # occ[1]=white occ, occ[2]=black occ

    # 64-square piece map for fast capture detection
    piece_on::Vector{Piece}  # length 64

    side::Color
    ep_square::Int        # en-passant target square, or -1
    castling::UInt8       # bits: 1=WK 2=WQ 4=BK 8=BQ
    halfmove::Int         # for 50-move rule
    fullmove::Int
    hash::UInt64          # Zobrist hash, maintained incrementally

    function Board()
        new(
            zeros(BB, 2, 7),
            zeros(BB, 2),
            fill(NO_PIECE, 64),
            White,
            -1,
            0x0,
            0,
            1,
            UInt64(0),
        )
    end
end

@inline all_occ(b::Board) = b.occ[1] | b.occ[2]

# helper: get bitboard for a color+kind
@inline bb(b::Board, c::Color, k::PieceKind) = b.bb[Int(c)+1, Int(k)]

# helper: set bitboard
@inline set_bb!(b::Board, c::Color, k::PieceKind, v::BB) = (b.bb[Int(c)+1, Int(k)] = v)

# ── Castling right constants ────────────────────────────────────────────────────
const CR_WK = 0x1
const CR_WQ = 0x2
const CR_BK = 0x4
const CR_BQ = 0x8

# ── Square helpers ─────────────────────────────────────────────────────────────
@inline sq(file::Int, rank::Int)::Square = rank * 8 + file   # file,rank 0-based
@inline file_of(s::Square) = s & 7
@inline rank_of(s::Square) = s >> 3
@inline sq_bb(s::Square)::BB = BB(1) << s

# Named squares
const A1=0;  const B1=1;  const C1=2;  const D1=3;  const E1=4;  const F1=5;  const G1=6;  const H1=7
const A8=56; const B8=57; const C8=58; const D8=59; const E8=60; const F8=61; const G8=62; const H8=63

# ── Bit manipulation ──────────────────────────────────────────────────────────
@inline lsb(b::BB)::Square    = trailing_zeros(b) |> Int
@inline pop_lsb!(b::BB)::Tuple{Square,BB} = (lsb(b), b & (b - BB(1)))
@inline count_bits(b::BB)     = count_ones(b)

# Iterate over set bits: `for sq in BitIter(bb)  ...  end`
struct BitIter
    bb::BB
end
Base.iterate(it::BitIter) = it.bb == 0 ? nothing : (lsb(it.bb), it.bb & (it.bb - 1))
Base.iterate(::BitIter, rest::BB) = rest == 0 ? nothing : (lsb(rest), rest & (rest - 1))
Base.length(it::BitIter) = count_ones(it.bb)
Base.eltype(::Type{BitIter}) = Square

# ── Move list ──────────────────────────────────────────────────────────────────
const MAX_MOVES = 256
struct MoveList
    moves ::Vector{Move}
    scores::Vector{Int}        # parallel score array for in-place ordering
    count ::Base.RefValue{Int}
    MoveList() = new(Vector{Move}(undef, MAX_MOVES), Vector{Int}(undef, MAX_MOVES), Ref(0))
end

@inline Base.length(ml::MoveList) = ml.count[]
@inline function Base.push!(ml::MoveList, m::Move)
    n = ml.count[] + 1
    ml.count[] = n
    @inbounds ml.moves[n] = m
end
@inline Base.getindex(ml::MoveList, i::Int) = @inbounds ml.moves[i]
@inline function reset!(ml::MoveList)
    ml.count[] = 0
end
@inline function Base.iterate(ml::MoveList, i::Int = 1)
    i > ml.count[] ? nothing : (@inbounds (ml.moves[i], i + 1))
end
