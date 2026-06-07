# Zobrist hashing: every board feature (piece/square pair, side to move, castling
# rights, en-passant file) is assigned a random UInt64.  XOR-ing them together gives
# a position hash.  Because XOR is its own inverse, incrementally updating the hash
# on make/unmake_move! is O(1) — just XOR in/out the changed features.

using Random: MersenneTwister, rand!

const ZOBRIST_PIECE = zeros(UInt64, 2, 7, 64)   # [color+1, kind+1, square+1]
const ZOBRIST_SIDE  = Ref(UInt64(0))
# Castling rights are a 4-bit mask (K/Q for each side) → 16 possible states.
# Each state gets its own independent key so any change flips the hash.
const ZOBRIST_CAST  = zeros(UInt64, 16)          # indexed by 4-bit castling mask
# Only the ep file matters for legality (the rank is always fixed by side to move),
# so 8 keys suffice.
const ZOBRIST_EP    = zeros(UInt64, 8)           # indexed by ep file (0-7)

function _init_zobrist!()
    # Fixed seed: the transposition table survives restarts and is reproducible in
    # tests — any seed works, this one is arbitrary.
    rng = MersenneTwister(0x4B1D_CAFE)
    rand!(rng, ZOBRIST_PIECE)
    ZOBRIST_SIDE[] = rand(rng, UInt64)
    rand!(rng, ZOBRIST_CAST)
    rand!(rng, ZOBRIST_EP)
end

@inline zob_piece(c::Color, k::PieceKind, s::Square)::UInt64 =
    ZOBRIST_PIECE[Int(c)+1, Int(k)+1, s+1]

@inline zob_ep(s::Square)::UInt64 = ZOBRIST_EP[file_of(s)+1]

function compute_hash(b::Board)::UInt64
    h = UInt64(0)
    for s in 0:63
        p = b.piece_on[s+1]
        p.kind != NoPiece && (h ⊻= zob_piece(p.color, p.kind, s))
    end
    b.side == Black && (h ⊻= ZOBRIST_SIDE[])
    h ⊻= ZOBRIST_CAST[b.castling + 1]
    b.ep_square != -1 && (h ⊻= zob_ep(b.ep_square))
    h
end
_init_zobrist!()
