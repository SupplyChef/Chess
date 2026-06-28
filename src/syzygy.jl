# syzygy.jl — Pure Julia Syzygy WDL tablebase prober
# Reference: python-chess chess/syzygy.py (Ronald de Man format)

# ── WDL result constants (from side-to-move perspective) ─────────────────────
const WDL_LOSS         = 0
const WDL_BLESSED_LOSS = 1
const WDL_DRAW         = 2
const WDL_CURSED_WIN   = 3
const WDL_WIN          = 4

const TB_LARGEST = Ref{Int}(0)
const WDL_MAGIC  = UInt8[0x71, 0xE8, 0x23, 0x5D]

const PCHR = ['K','Q','R','B','N','P']

# ── Symmetry tables ───────────────────────────────────────────────────────────
const TRIANGLE = Int[
    6, 0, 1, 2, 2, 1, 0, 6,
    0, 7, 3, 4, 4, 3, 7, 0,
    1, 3, 8, 5, 5, 8, 3, 1,
    2, 4, 5, 9, 9, 5, 4, 2,
    2, 4, 5, 9, 9, 5, 4, 2,
    1, 3, 8, 5, 5, 8, 3, 1,
    0, 7, 3, 4, 4, 3, 7, 0,
    6, 0, 1, 2, 2, 1, 0, 6,
]

const LOWER = Int[
    28,  0,  1,  2,  3,  4,  5,  6,
     0, 29,  7,  8,  9, 10, 11, 12,
     1,  7, 30, 13, 14, 15, 16, 17,
     2,  8, 13, 31, 18, 19, 20, 21,
     3,  9, 14, 18, 32, 22, 23, 24,
     4, 10, 15, 19, 22, 33, 25, 26,
     5, 11, 16, 20, 23, 25, 34, 27,
     6, 12, 17, 21, 24, 26, 27, 35,
]

const DIAG = Int[
     0,  0,  0,  0,  0,  0,  0,  8,
     0,  1,  0,  0,  0,  0,  9,  0,
     0,  0,  2,  0,  0, 10,  0,  0,
     0,  0,  0,  3, 11,  0,  0,  0,
     0,  0,  0, 12,  4,  0,  0,  0,
     0,  0, 13,  0,  0,  5,  0,  0,
     0, 14,  0,  0,  0,  0,  6,  0,
    15,  0,  0,  0,  0,  0,  0,  7,
]

const KK_IDX = Vector{Int}[
    Int[-1,-1,-1, 0, 1, 2, 3, 4,
        -1,-1,-1, 5, 6, 7, 8, 9,
        10,11,12,13,14,15,16,17,
        18,19,20,21,22,23,24,25,
        26,27,28,29,30,31,32,33,
        34,35,36,37,38,39,40,41,
        42,43,44,45,46,47,48,49,
        50,51,52,53,54,55,56,57],
    Int[58,-1,-1,-1,59,60,61,62,
        63,-1,-1,-1,64,65,66,67,
        68,69,70,71,72,73,74,75,
        76,77,78,79,80,81,82,83,
        84,85,86,87,88,89,90,91,
        92,93,94,95,96,97,98,99,
       100,101,102,103,104,105,106,107,
       108,109,110,111,112,113,114,115],
    Int[116,117,-1,-1,-1,118,119,120,
       121,122,-1,-1,-1,123,124,125,
       126,127,128,129,130,131,132,133,
       134,135,136,137,138,139,140,141,
       142,143,144,145,146,147,148,149,
       150,151,152,153,154,155,156,157,
       158,159,160,161,162,163,164,165,
       166,167,168,169,170,171,172,173],
    Int[174,-1,-1,-1,175,176,177,178,
       179,-1,-1,-1,180,181,182,183,
       184,-1,-1,-1,185,186,187,188,
       189,190,191,192,193,194,195,196,
       197,198,199,200,201,202,203,204,
       205,206,207,208,209,210,211,212,
       213,214,215,216,217,218,219,220,
       221,222,223,224,225,226,227,228],
    Int[229,230,-1,-1,-1,231,232,233,
       234,235,-1,-1,-1,236,237,238,
       239,240,-1,-1,-1,241,242,243,
       244,245,246,247,248,249,250,251,
       252,253,254,255,256,257,258,259,
       260,261,262,263,264,265,266,267,
       268,269,270,271,272,273,274,275,
       276,277,278,279,280,281,282,283],
    Int[284,285,286,287,288,289,290,291,
       292,293,-1,-1,-1,294,295,296,
       297,298,-1,-1,-1,299,300,301,
       302,303,-1,-1,-1,304,305,306,
       307,308,309,310,311,312,313,314,
       315,316,317,318,319,320,321,322,
       323,324,325,326,327,328,329,330,
       331,332,333,334,335,336,337,338],
    Int[-1,-1,339,340,341,342,343,344,
        -1,-1,345,346,347,348,349,350,
        -1,-1,441,351,352,353,354,355,
        -1,-1,-1,442,356,357,358,359,
        -1,-1,-1,-1,443,360,361,362,
        -1,-1,-1,-1,-1,444,363,364,
        -1,-1,-1,-1,-1,-1,445,365,
        -1,-1,-1,-1,-1,-1,-1,446],
    Int[-1,-1,-1,366,367,368,369,370,
        -1,-1,-1,371,372,373,374,375,
        -1,-1,-1,376,377,378,379,380,
        -1,-1,-1,447,381,382,383,384,
        -1,-1,-1,-1,448,385,386,387,
        -1,-1,-1,-1,-1,449,388,389,
        -1,-1,-1,-1,-1,-1,450,390,
        -1,-1,-1,-1,-1,-1,-1,451],
    Int[452,391,392,393,394,395,396,397,
        -1,-1,-1,-1,398,399,400,401,
        -1,-1,-1,-1,402,403,404,405,
        -1,-1,-1,-1,406,407,408,409,
        -1,-1,-1,-1,453,410,411,412,
        -1,-1,-1,-1,-1,454,413,414,
        -1,-1,-1,-1,-1,-1,455,415,
        -1,-1,-1,-1,-1,-1,-1,456],
    Int[457,416,417,418,419,420,421,422,
        -1,458,423,424,425,426,427,428,
        -1,-1,-1,-1,-1,429,430,431,
        -1,-1,-1,-1,-1,432,433,434,
        -1,-1,-1,-1,-1,435,436,437,
        -1,-1,-1,-1,-1,459,438,439,
        -1,-1,-1,-1,-1,-1,460,440,
        -1,-1,-1,-1,-1,-1,-1,461],
]

# King-pair index space size per enc_type (index enc_type+1)
const PIVFAC = Int[31332, 28056, 462]

# BINOMIAL[k, n+1] = C(n,k), k in 1..6, n in 0..63
const BINOMIAL = let
    B = zeros(Int64, 6, 64)
    for k in 1:6, n in (k-1):63
        B[k, n+1] = (k == 1) ? n : B[k-1, n] + B[k, n]
    end
    B
end

# ── Structs ───────────────────────────────────────────────────────────────────
mutable struct PairsData
    indextable  ::Int
    sizetable   ::Int
    blockdata   ::Int
    blocksize   ::Int
    idxbits     ::Int
    offset_ptr  ::Int   # adjusted: points to (length 0 slot) before first valid entry
    sympat      ::Int
    symlen      ::Vector{Int}
    min_len     ::Int
    base        ::Vector{UInt64}
    PairsData() = new(0,0,0,0,0,0,0,Int[],0,UInt64[])
end

mutable struct WdlTable
    data         ::Vector{UInt8}
    key          ::String
    mirrored_key ::String
    symmetric    ::Bool
    has_pawns    ::Bool
    split        ::Bool
    num          ::Int
    enc_type     ::Int
    pieces       ::Vector{Vector{Int}}
    norm         ::Vector{Vector{Int}}
    factor       ::Vector{Vector{Int64}}
    tb_size      ::Vector{Int64}
    precomp      ::Vector{PairsData}
end

const _TABLES      = Dict{String,WdlTable}()
const _INITIALIZED = Ref{Bool}(false)

# ── I/O helpers (0-based offsets, Julia array is 1-indexed) ──────────────────
@inline _r8(d::Vector{UInt8}, o::Int)  = Int(d[o+1])
@inline _r16le(d::Vector{UInt8}, o::Int) =
    Int(UInt16(d[o+1]) | (UInt16(d[o+2]) << 8))
@inline _r32le(d::Vector{UInt8}, o::Int) =
    Int(UInt32(d[o+1]) | (UInt32(d[o+2])<<8) | (UInt32(d[o+3])<<16) | (UInt32(d[o+4])<<24))
@inline _r32be(d::Vector{UInt8}, o::Int) =
    UInt32(UInt32(d[o+1])<<24 | UInt32(d[o+2])<<16 | UInt32(d[o+3])<<8 | UInt32(d[o+4]))
@inline function _r64be(d::Vector{UInt8}, o::Int)
    UInt64(d[o+1])<<56 | UInt64(d[o+2])<<48 | UInt64(d[o+3])<<40 | UInt64(d[o+4])<<32 |
    UInt64(d[o+5])<<24 | UInt64(d[o+6])<<16 | UInt64(d[o+7])<<8  | UInt64(d[o+8])
end

# ── Geometry ──────────────────────────────────────────────────────────────────
@inline _offdiag(s::Int)  = (s >> 3) - (s & 7)
@inline _flipdiag(s::Int) = let f = s & 7, r = s >> 3; f * 8 + r end
@inline function _binom(n::Int, k::Int)::Int64
    (k < 1 || k > 6 || n < 0 || n > 63) && return Int64(0)
    BINOMIAL[k, n+1]
end

# ── enc_type from filename ────────────────────────────────────────────────────
function _enc_type_from_name(name::String)::Int
    i = findfirst(==('v'), name)
    i === nothing && return 2
    white_part = name[1:i-1]
    black_part = name[i+1:end]
    j = 0
    for c in PCHR
        count(==(c), white_part) == 1 && (j += 1)
        count(==(c), black_part) == 1 && (j += 1)
    end
    j >= 3 ? 0 : 2
end

# ── Material key ──────────────────────────────────────────────────────────────
function _board_key(b::Board, mirror::Bool=false)::String
    w  = mirror ? Black : White
    bk = mirror ? White : Black
    chars = "KQRBNP"
    kinds = (King, Queen, Rook, Bishop, Knight, Pawn)
    io = IOBuffer()
    for (c, k) in zip(chars, kinds)
        for _ in 1:count_bits(bb(b, w, k)); write(io, c); end
    end
    write(io, 'v')
    for (c, k) in zip(chars, kinds)
        for _ in 1:count_bits(bb(b, bk, k)); write(io, c); end
    end
    String(take!(io))
end

# Piece code list (bit3=color, bits0-2=type) → key string
function _recalc_key(pieces::Vector{Int}, mirror::Bool=false)::String
    w  = mirror ? 8 : 0
    bk = mirror ? 0 : 8
    chars = "KQRBNP"
    kinds = (6, 5, 4, 3, 2, 1)
    io = IOBuffer()
    for (c, kv) in zip(chars, kinds)
        for _ in 1:count(==(kv ⊻ w), pieces); write(io, c); end
    end
    write(io, 'v')
    for (c, kv) in zip(chars, kinds)
        for _ in 1:count(==(kv ⊻ bk), pieces); write(io, c); end
    end
    String(take!(io))
end

# ── Setup helpers ─────────────────────────────────────────────────────────────
function _calc_symlen!(symlen::Vector{Int}, data::Vector{UInt8},
                       sympat::Int, s::Int, tmp::Vector{Bool})
    w  = sympat + 3 * s
    s2 = (_r8(data, w+2) << 4) | (_r8(data, w+1) >> 4)
    if s2 == 0x0fff
        symlen[s+1] = 0
    else
        s1 = ((_r8(data, w+1) & 0xf) << 8) | _r8(data, w)
        tmp[s1+1] || _calc_symlen!(symlen, data, sympat, s1, tmp)
        tmp[s2+1] || _calc_symlen!(symlen, data, sympat, s2, tmp)
        symlen[s+1] = symlen[s1+1] + symlen[s2+1] + 1
    end
    tmp[s+1] = true
end

function _set_norm_piece!(norm::Vector{Int}, pieces::Vector{Int}, enc_type::Int)
    norm[1] = enc_type == 0 ? 3 : 2
    i = norm[1]
    n = length(pieces)
    while i < n
        j = i
        while j < n && pieces[j+1] == pieces[i+1]
            norm[i+1] += 1
            j += 1
        end
        i += norm[i+1]
    end
end

function _calc_factors_piece!(factor::Vector{Int64}, order::Int,
                               norm::Vector{Int}, num::Int, enc_type::Int)::Int64
    n = Int64(64 - norm[1])
    f = Int64(1)
    i = norm[1]
    k = 0
    while i < num || k == order
        if k == order
            factor[1] = f
            f *= PIVFAC[enc_type+1]
        else
            factor[i+1] = f
            f *= _binom(Int(n), norm[i+1])
            n -= norm[i+1]
            i += norm[i+1]
        end
        k += 1
    end
    f
end

# Returns (PairsData, next_data_ptr)
function _setup_pairs(data::Vector{UInt8}, data_ptr::Int,
                      tb_size::Int64, size::Vector{Int64},
                      size_idx::Int)::Tuple{PairsData,Int}
    pd = PairsData()
    flags = _r8(data, data_ptr)

    if (flags & 0x80) != 0   # constant table
        pd.idxbits = 0
        pd.min_len = _r8(data, data_ptr + 1)
        size[size_idx+1] = 0; size[size_idx+2] = 0; size[size_idx+3] = 0
        return (pd, data_ptr + 2)
    end

    pd.blocksize    = _r8(data, data_ptr + 1)
    pd.idxbits      = _r8(data, data_ptr + 2)
    real_num_blocks = _r32le(data, data_ptr + 4)
    num_blocks      = real_num_blocks + _r8(data, data_ptr + 3)
    max_len         = _r8(data, data_ptr + 8)
    min_len         = _r8(data, data_ptr + 9)
    h               = max_len - min_len + 1
    num_syms        = _r16le(data, data_ptr + 10 + 2 * h)

    offset_base = data_ptr + 10
    sympat      = data_ptr + 12 + 2 * h
    next        = sympat + 3 * num_syms + (num_syms & 1)

    symlen = zeros(Int, num_syms)
    tmp    = zeros(Bool, num_syms)
    for s in 0:num_syms-1
        tmp[s+1] || _calc_symlen!(symlen, data, sympat, s, tmp)
    end

    base = zeros(UInt64, h)
    # base[h] = 0 already; build from max_len down to min_len.
    # Use Int64 intermediate to avoid UInt64 wrap-around on subtraction.
    for i in h-2:-1:0
        v = Int64(base[i+2]) +
            Int64(_r16le(data, offset_base + i*2)) -
            Int64(_r16le(data, offset_base + (i+1)*2))
        base[i+1] = UInt64(v >> 1)
    end
    for i in 0:h-1
        base[i+1] <<= (64 - (min_len + i))
    end

    num_indices = (tb_size + (Int64(1) << pd.idxbits) - 1) >> pd.idxbits
    size[size_idx+1] = 6 * num_indices
    size[size_idx+2] = 2 * num_blocks
    size[size_idx+3] = (Int64(1) << pd.blocksize) * real_num_blocks

    pd.sympat     = sympat
    pd.symlen     = symlen
    pd.min_len    = min_len
    pd.base       = base
    pd.offset_ptr = offset_base - 2 * min_len

    return (pd, next)
end

function _setup_pieces_piece!(t::WdlTable, data::Vector{UInt8}, p_data::Int)
    num = t.num
    for bside in 0:1
        pcs = Vector{Int}(undef, num)
        order_byte = _r8(data, p_data)
        ord = bside == 0 ? (order_byte & 0x0f) : (order_byte >> 4)
        for i in 0:num-1
            b = _r8(data, p_data + i + 1)
            pcs[i+1] = bside == 0 ? (b & 0x0f) : (b >> 4)
        end
        t.pieces[bside+1] = pcs
        nm = zeros(Int, num)
        _set_norm_piece!(nm, pcs, t.enc_type)
        t.norm[bside+1] = nm
        fc = zeros(Int64, num)
        t.tb_size[bside+1] = _calc_factors_piece!(fc, ord, nm, num, t.enc_type)
        t.factor[bside+1] = fc
    end
end

function _init_wdl_table!(t::WdlTable)
    data = t.data
    size = zeros(Int64, 6)

    data_ptr = 5

    # Determine enc_type from actual file data rather than the filename heuristic.
    # Read bside=0 piece codes and check for consecutive identical pieces:
    # two identical adjacent codes means 3-leader encoding (enc_type=0), else KK (enc_type=2).
    pcs0 = [Int(_r8(data, data_ptr + i + 1)) & 0x0f for i in 0:t.num-1]
    t.enc_type = 2
    for s in 2:t.num
        if pcs0[s] == pcs0[s-1]
            t.enc_type = 0
            break
        end
    end

    _setup_pieces_piece!(t, data, data_ptr)
    data_ptr += t.num + 1
    data_ptr += (data_ptr & 1)

    pd0, data_ptr = _setup_pairs(data, data_ptr, t.tb_size[1], size, 0)
    t.precomp[1] = pd0
    if t.split
        pd1, data_ptr = _setup_pairs(data, data_ptr, t.tb_size[2], size, 3)
        t.precomp[2] = pd1
    else
        t.precomp[2] = pd0
        t.tb_size[2] = t.tb_size[1]
    end

    t.precomp[1].indextable = data_ptr;  data_ptr += size[1]
    if t.split; t.precomp[2].indextable = data_ptr; data_ptr += size[4]; end
    t.precomp[1].sizetable  = data_ptr;  data_ptr += size[2]
    if t.split; t.precomp[2].sizetable  = data_ptr; data_ptr += size[5]; end

    data_ptr = (data_ptr + 63) & ~63
    t.precomp[1].blockdata = data_ptr;  data_ptr += size[3]
    if t.split
        data_ptr = (data_ptr + 63) & ~63
        t.precomp[2].blockdata = data_ptr
    end

    t.key          = _recalc_key(t.pieces[1], false)
    t.mirrored_key = _recalc_key(t.pieces[1], true)
    t.symmetric    = (t.key == t.mirrored_key)
end

# ── Index encoding ────────────────────────────────────────────────────────────
function _collect_squares(b::Board, pieces::Vector{Int},
                           cmirror::Int, mirror::Int)::Vector{Int}
    n   = length(pieces)
    pos = Vector{Int}(undef, n)
    i   = 0
    # Mirror python-chess: scan the bitboard for pieces[i], filling pos[i..i+k]
    # for as many squares as the board has of that piece type.  i advances past
    # them all, so repeated piece codes (e.g. [2,2] for two knights) are consumed
    # in one bb scan, not two.
    while i < n
        pc    = pieces[i+1]
        ptype = pc & 0x07
        color = (pc ⊻ cmirror) >> 3
        c     = color == 0 ? White : Black
        k     = PieceKind(ptype)
        for sq in BitIter(bb(b, c, k))
            i += 1
            pos[i] = sq ⊻ mirror
        end
    end
    pos
end

function _encode_piece(t::WdlTable, bside::Int, pos::Vector{Int})::Int64
    n        = t.num
    enc_type = t.enc_type

    if enc_type < 3
        if (pos[1] & 4) != 0
            for i in 1:n; pos[i] = pos[i] ⊻ 7; end
        end
        if (pos[1] & 32) != 0
            for i in 1:n; pos[i] = pos[i] ⊻ 56; end
        end
        threshold = enc_type == 0 ? 3 : 2
        found = threshold
        for i in 1:threshold
            if _offdiag(pos[i]) != 0; found = i; break; end
        end
        if found < threshold && _offdiag(pos[found]) > 0
            for i in 1:n; pos[i] = _flipdiag(pos[i]); end
        end
    end

    idx     = Int64(0)
    i_start = 0

    if enc_type == 0
        p0, p1, p2 = pos[1], pos[2], pos[3]
        ii = Int(p1 > p0)
        jj = Int(p2 > p0) + Int(p2 > p1)
        if _offdiag(p0) != 0
            idx = Int64(TRIANGLE[p0+1]) * 63 * 62 + Int64(p1-ii) * 62 + Int64(p2-jj)
        elseif _offdiag(p1) != 0
            idx = 6*63*62 + Int64(DIAG[p0+1])*28*62 + Int64(LOWER[p1+1])*62 + Int64(p2-jj)
        elseif _offdiag(p2) != 0
            idx = 6*63*62 + 4*28*62 + Int64(DIAG[p0+1])*7*28 +
                  Int64(DIAG[p1+1]-ii)*28 + Int64(LOWER[p2+1])
        else
            idx = 6*63*62 + 4*28*62 + 4*7*28 + Int64(DIAG[p0+1])*7*6 +
                  Int64(DIAG[p1+1]-ii)*6 + Int64(DIAG[p2+1]-jj)
        end
        i_start = 3
    elseif enc_type == 2
        tri = TRIANGLE[pos[1]+1]
        kk  = KK_IDX[tri+1][pos[2]+1]
        kk < 0 && return Int64(-1)
        idx     = Int64(kk)
        i_start = 2
    else
        return Int64(-1)
    end

    idx *= t.factor[bside+1][1]

    norm   = t.norm[bside+1]
    factor = t.factor[bside+1]
    i = i_start
    while i < n
        t_cnt = norm[i+1]
        for a in i+1:i+t_cnt-1, b_idx in a+1:i+t_cnt
            if pos[a] > pos[b_idx]; pos[a], pos[b_idx] = pos[b_idx], pos[a]; end
        end
        s = Int64(0)
        for m in i:i+t_cnt-1
            p  = pos[m+1]
            jj = 0
            for l in 1:i; p > pos[l] && (jj += 1); end
            s += _binom(p - jj, m - i + 1)
        end
        idx += s * factor[i+1]
        i   += t_cnt
    end
    idx
end

# ── Huffman decompression ─────────────────────────────────────────────────────
function _decompress_pairs(t::WdlTable, pd::PairsData, idx::Int64)::Int
    pd.idxbits == 0 && return pd.min_len

    data    = t.data
    m       = pd.min_len
    mainidx = Int(idx >> pd.idxbits)
    litidx  = Int(idx & ((Int64(1) << pd.idxbits) - 1)) - (1 << (pd.idxbits - 1))

    block      = _r32le(data, pd.indextable + 6*mainidx)
    idx_offset = _r16le(data, pd.indextable + 6*mainidx + 4)
    litidx    += idx_offset

    if litidx < 0
        while litidx < 0
            block  -= 1
            litidx += _r16le(data, pd.sizetable + 2*block) + 1
        end
    else
        while litidx > _r16le(data, pd.sizetable + 2*block)
            litidx -= _r16le(data, pd.sizetable + 2*block) + 1
            block  += 1
        end
    end

    ptr    = pd.blockdata + (block << pd.blocksize)
    code   = _r64be(data, ptr)
    ptr   += 8
    bitcnt = 0
    sym    = 0

    while true
        l = m
        while code < pd.base[l - m + 1]; l += 1; end
        sym = _r16le(data, pd.offset_ptr + l*2)
        sym += Int((code - pd.base[l - m + 1]) >> (64 - l))
        litidx < pd.symlen[sym+1] + 1 && break
        litidx -= pd.symlen[sym+1] + 1
        code    = (code << l) & 0xffffffffffffffff
        bitcnt += l
        if bitcnt >= 32
            bitcnt -= 32
            code   |= UInt64(_r32be(data, ptr)) << bitcnt
            ptr    += 4
        end
    end

    sympat = pd.sympat
    while pd.symlen[sym+1] != 0
        w  = sympat + 3*sym
        s1 = ((_r8(data, w+1) & 0xf) << 8) | _r8(data, w)
        if litidx < pd.symlen[s1+1] + 1
            sym = s1
        else
            litidx -= pd.symlen[s1+1] + 1
            sym     = (_r8(data, w+2) << 4) | (_r8(data, w+1) >> 4)
        end
    end

    w = sympat + 3*sym
    _r8(data, w)   # raw WDL value 0..4 (file stores WDL_LOSS..WDL_WIN directly)
end

# ── File loading ──────────────────────────────────────────────────────────────
function _load_wdl_table(path::String, name::String)::Union{WdlTable,Nothing}
    try
        data = read(path)
        length(data) < 5 && return nothing
        data[1:4] == WDL_MAGIC || return nothing

        flags    = Int(data[5])
        split    = (flags & 0x01) != 0
        has_pawn = (flags & 0x02) != 0

        i = findfirst(==('v'), name)
        i === nothing && return nothing
        num = length(name) - 1

        enc_type = has_pawn ? 0 : _enc_type_from_name(name)

        t = WdlTable(
            data, name, name, false, has_pawn, split, num, enc_type,
            [Vector{Int}() for _ in 1:2],
            [Vector{Int}() for _ in 1:2],
            [Vector{Int64}() for _ in 1:2],
            zeros(Int64, 2),
            [PairsData(), PairsData()],
        )

        has_pawn && return t

        _init_wdl_table!(t)
        return t
    catch e
        @warn "Syzygy: failed to load $path" exception=e
        return nothing
    end
end

const _DEFAULT_SYZYGY_PATH = joinpath(@__DIR__, "..", "syzygy")

"""
    syzygy_init!(path) -> Bool

Scan `path` for .rtbw files and load all Syzygy WDL tables found.
Returns `true` on success (≥1 table loaded). Sets `TB_LARGEST`.
Defaults to `Chess/syzygy/` (next to `src/`) when no path is given.
"""
syzygy_init!() = syzygy_init!(get(ENV, "SYZYGY_PATH", _DEFAULT_SYZYGY_PATH))

function syzygy_init!(path::String)::Bool
    isdir(path) || return false
    empty!(_TABLES)
    TB_LARGEST[] = 0
    _INITIALIZED[] = false
    count = 0
    for file in sort(readdir(path))
        endswith(file, ".rtbw") || continue
        name = file[1:end-5]
        t = _load_wdl_table(joinpath(path, file), name)
        t === nothing && continue
        if !t.has_pawns
            _TABLES[t.key] = t
            t.key != t.mirrored_key && (_TABLES[t.mirrored_key] = t)
        else
            _TABLES[name] = t
        end
        t.num > TB_LARGEST[] && (TB_LARGEST[] = t.num)
        count += 1
    end
    if count > 0
        _INITIALIZED[] = true
        @info "Syzygy: loaded $count WDL tables, TB_LARGEST=$(TB_LARGEST[])"
        return true
    end
    false
end

# ── WDL probe ─────────────────────────────────────────────────────────────────
function _probe_wdl_table(t::WdlTable, b::Board)::Union{Int,Nothing}
    key = _board_key(b, false)

    cmirror = 0; mirror = 0; bside = 0
    if t.symmetric
        if b.side == Black; cmirror = 8; mirror = 56; end
        bside = 0
    elseif key != t.key
        cmirror = 8; mirror = 56
        bside = b.side == White ? 1 : 0
    else
        bside = b.side == White ? 0 : 1
    end

    pos = _collect_squares(b, t.pieces[bside+1], cmirror, mirror)
    idx = _encode_piece(t, bside, pos)
    idx < 0 && return nothing

    raw = _decompress_pairs(t, t.precomp[bside+1], idx)
    raw   # 0=WDL_LOSS … 4=WDL_WIN
end

"""
    syzygy_probe_wdl(b::Board) -> Union{Int, Nothing}

Probe WDL value for the position. Returns WDL_LOSS/WDL_BLESSED_LOSS/WDL_DRAW/
WDL_CURSED_WIN/WDL_WIN (0–4), or `nothing` when the position cannot be probed
(castling rights present, piece count exceeds TB_LARGEST, or no table found).
"""
function syzygy_probe_wdl(b::Board)::Union{Int,Nothing}
    _INITIALIZED[]                         || return nothing
    b.castling != 0x0                      && return nothing
    count_bits(all_occ(b)) > TB_LARGEST[]  && return nothing

    key = _board_key(b, false)
    t   = get(_TABLES, key, nothing)
    if t === nothing
        t = get(_TABLES, _board_key(b, true), nothing)
        t === nothing && return nothing
    end
    t.has_pawns && return nothing

    _probe_wdl_table(t, b)
end
