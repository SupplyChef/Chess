# Move explanation: produce natural-language commentary for Lichess chat.
#
# Two public entry points:
#   explain_move          — narrates the bot's own move to the opponent.
#   explain_opponent_move — coaching mode: compares the opponent's move to what the
#                           engine would have played in their position.
#
# Explanation priority inside explain_move (first matching branch wins):
#   1. Forced mate (us)    — we're mating in N moves; show the key idea.
#   2. Being mated (them)  — we're delaying checkmate; acknowledge and fight on.
#   3. Material gain       — we win material over the PV.  Not triggered for a
#                            recapture: taking back on the same square the opponent
#                            just moved to restores balance, not a new gain.
#      3a. Fork            — we simultaneously attack 2+ profitable targets.
#   4. Positional          — driven by the static-eval breakdown comparing the
#                            position before and after the move.  Named structural
#                            patterns (open file, outpost, passed pawn, …) are
#                            reported only when the relevant eval term confirms the
#                            improvement; the largest gaining term leads.

# ── Piece / square helpers ─────────────────────────────────────────────────────

function _san_sym(k::PieceKind)::String
    k == Knight ? "N" : k == Bishop ? "B" : k == Rook ? "R" :
    k == Queen  ? "Q" : k == King   ? "K" : ""
end

function _approx_san(m::Move, b::Board)::String
    fl = flags(m)
    fl == MF_KS_CAST && return "O-O"
    fl == MF_QS_CAST && return "O-O-O"
    k   = b.piece_on[from_sq(m)+1].kind
    cap = is_capture(m) || is_ep(m)
    dst = sq_name(to_sq(m))
    if k == Pawn
        pfx = cap ? string(Char('a' + file_of(from_sq(m)))) : ""
        sfx = is_promo(m) ? ("=" * _san_sym(promo_kind(m))) : ""
        return pfx * (cap ? "x" : "") * dst * sfx
    end
    _san_sym(k) * (cap ? "x" : "") * dst
end

function _piece_name(k::PieceKind)::String
    k == Pawn   ? "pawn"   : k == Knight ? "knight" : k == Bishop ? "bishop" :
    k == Rook   ? "rook"   : k == Queen  ? "queen"  : "piece"
end

# ── Material swing over the PV ────────────────────────────────────────────────
# Net material gained (in centipawns) by the side making pv[1] over the PV.
# Positive = we gain; negative = we lose.
function _pv_material_swing(pv::Vector{Move}, b::Board)::Int
    isempty(pv) && return 0
    us    = b.side
    net   = 0
    undos = UndoInfo[]
    for m in pv
        fl   = flags(m)
        sign = b.side == us ? 1 : -1
        if fl == MF_EP
            net += sign * PIECE_VALUE[Int(Pawn)+1]
        elseif (fl & MF_CAPTURE) != 0
            net += sign * PIECE_VALUE[Int(b.piece_on[to_sq(m)+1].kind)+1]
        end
        if (fl & MF_PROMO) != 0
            net += sign * (PIECE_VALUE[Int(promo_kind(m))+1] - PIECE_VALUE[Int(Pawn)+1])
        end
        push!(undos, make_move!(b, m))
    end
    for i in length(pv):-1:1; unmake_move!(b, pv[i], undos[i]); end
    net
end

# ── Attack / fork helpers ──────────────────────────────────────────────────────

# Reverse-lookup: does any piece of `defender` attack `sq`?
# Uses the symmetry of attack sets: a square S attacked by a knight iff a
# knight on S attacks a real knight of the defender, etc.
function _is_defended(b::Board, sq::Int, defender::Color)::Bool
    occ = all_occ(b)
    (pawn_attacks(sq, other(defender))  & bb(b, defender, Pawn))                              != 0 && return true
    (knight_attacks(sq)                 & bb(b, defender, Knight))                             != 0 && return true
    (bishop_attacks(sq, occ)            & (bb(b, defender, Bishop) | bb(b, defender, Queen))) != 0 && return true
    (rook_attacks(sq, occ)              & (bb(b, defender, Rook)   | bb(b, defender, Queen))) != 0 && return true
    (king_attacks(sq)                   & bb(b, defender, King))                               != 0 && return true
    false
end

# Enemy pieces attacked from the destination square after making move m,
# filtered to those that are "profitable to capture": either undefended,
# worth more than the mover, or the king (giving check always threatens).
# Returns them sorted most-valuable-first.  Board is restored afterward.
function _fork_targets(b::Board, m::Move, mover_val::Int)::Vector{Tuple{PieceKind,Int}}
    undo   = make_move!(b, m)
    us     = other(b.side)      # side that just moved
    them   = b.side
    dst    = to_sq(m)
    occ    = all_occ(b)
    theirs = b.occ[Int(them)+1]
    atk    = let k = b.piece_on[dst+1].kind
        k == Pawn   ? pawn_attacks(dst, us)   :
        k == Knight ? knight_attacks(dst)      :
        k == Bishop ? bishop_attacks(dst, occ) :
        k == Rook   ? rook_attacks(dst, occ)   :
        k == Queen  ? queen_attacks(dst, occ)  : BB(0)
    end
    targets = Tuple{PieceKind,Int}[]
    for s in BitIter(atk & theirs)
        pk = b.piece_on[s+1].kind
        if pk == King
            push!(targets, (King, s))
        else
            v = PIECE_VALUE[Int(pk)+1]
            if v > mover_val || !_is_defended(b, s, them)
                push!(targets, (pk, s))
            end
        end
    end
    unmake_move!(b, m, undo)
    sort!(targets; by = p -> p[1] == King ? 10_000 : -PIECE_VALUE[Int(p[1])+1])
    targets
end

# ── Endgame / structural helpers ───────────────────────────────────────────────

# Endgame: non-pawn/king material ≤ 2800 cp (≈ one queen + one rook total).
function _is_endgame(b::Board)::Bool
    mat = 0
    for c in (White, Black)
        mat += PIECE_VALUE[Int(Knight)+1] * count_bits(bb(b, c, Knight))
        mat += PIECE_VALUE[Int(Bishop)+1] * count_bits(bb(b, c, Bishop))
        mat += PIECE_VALUE[Int(Rook)+1]   * count_bits(bb(b, c, Rook))
        mat += PIECE_VALUE[Int(Queen)+1]  * count_bits(bb(b, c, Queen))
    end
    mat <= 2800
end

# ── PV continuation sentence ───────────────────────────────────────────────────
# Produces " After Xe4, I plan Rxf7." style text from the PV.
# Board must be advanced by pv[1] before calling; restored by caller afterward.
# Only used for forced mate sequences where the line is reliable.
function _pv_continuation(pv::Vector{Move}, b_after::Board)::String
    length(pv) < 2 && return ""
    opp = _approx_san(pv[2], b_after)
    if length(pv) >= 3
        undo2 = make_move!(b_after, pv[2])
        ours  = _approx_san(pv[3], b_after)
        unmake_move!(b_after, pv[2], undo2)
        return " After $opp, I plan $ours."
    end
    " I expect $opp from you next."
end

# ── Key PV moment ─────────────────────────────────────────────────────────────
# What does move m achieve on board b (before the move)?
# Returns a short phrase or "" if nothing noteworthy.
function _key_move_concept(b::Board, m::Move, our_k::PieceKind,
                            our_val::Int, my_color::Color)::String
    fl = flags(m)
    (fl & MF_PROMO) != 0 && return "promote to a queen"
    forks = _fork_targets(b, m, our_val)
    length(forks) >= 2 &&
        return "fork the $(_piece_name(forks[1][1])) and $(_piece_name(forks[2][1]))"
    if (fl & MF_CAPTURE) != 0 || fl == MF_EP
        cap_k   = fl == MF_EP ? Pawn : b.piece_on[to_sq(m)+1].kind
        cap_val = PIECE_VALUE[Int(cap_k)+1]
        if cap_val > our_val || !_is_defended(b, to_sq(m), other(my_color))
            return "win the $(_piece_name(cap_k))"
        end
    end
    ""
end

# Scan our upcoming moves in the PV (pv[3], pv[5], …) and return the first
# that achieves a concrete tactical goal: fork, winning capture, or promotion.
# Board b must be AFTER pv[1] (our current move); it is restored on return.
# Returns (concept, path) where path = pv[2..key_idx] is the line to display,
# or nothing when no key moment is found.
function _find_key_pv_moment(pv::Vector{Move}, b::Board,
                              my_color::Color)::Union{Nothing,Tuple{String,Vector{Move}}}
    length(pv) < 3 && return nothing
    undos  = UndoInfo[]
    result = nothing
    for i in 2:length(pv)
        m = pv[i]
        if isodd(i)   # pv[3], pv[5], … — our moves after each opponent reply
            # Skip recaptures: if the opponent's previous move was itself a capture
            # on this same square, we'd only be restoring balance, not winning material.
            prev = pv[i-1]
            is_recap = (is_capture(prev) || is_ep(prev)) &&
                       (is_capture(m)    || is_ep(m))    &&
                       to_sq(m) == to_sq(prev)
            if !is_recap
                our_k   = b.piece_on[from_sq(m)+1].kind
                our_val = PIECE_VALUE[Int(our_k)+1]
                concept = _key_move_concept(b, m, our_k, our_val, my_color)
                if !isempty(concept)
                    result = (concept, pv[2:i])
                    break
                end
            end
        end
        push!(undos, make_move!(b, m))
    end
    for j in length(undos):-1:1; unmake_move!(b, pv[j+1], undos[j]); end
    result
end

# Format a move sequence as a human-readable string ("Kh8 Nf6 Kg8 Nd7").
# b must be the position just before path[1]; it is restored on return.
function _format_pv_path(path::Vector{Move}, b::Board)::String
    isempty(path) && return ""
    parts = String[]
    undos = UndoInfo[]
    for m in path
        push!(parts, _approx_san(m, b))
        push!(undos, make_move!(b, m))
    end
    for j in length(undos):-1:1; unmake_move!(b, path[j], undos[j]); end
    join(parts, " ")
end

# ── explain_move ──────────────────────────────────────────────────────────────

"""
    explain_move(result, b, my_color; last_opp_move) → String

Build a Lichess-chat explanation for the bot's move.
`b` must be the board *before* the move.
`last_opp_move` is the opponent's immediately preceding move (used to detect
recaptures, where we are restoring material balance rather than gaining it).
"""
function explain_move(result::SearchResult, b::Board, my_color::Color;
                      last_opp_move::Union{Move,Nothing} = nothing)::String
    our_san  = _approx_san(result.move, b)
    scorestr = result.score >= 0 ? "+$(result.score)" : "$(result.score)"
    note     = "($(scorestr)cp, depth $(result.depth))"

    isempty(result.pv) && return "I played $our_san. $note"

    sgn     = my_color == White ? 1 : -1
    our_fr  = from_sq(result.move)
    our_k   = b.piece_on[our_fr+1].kind
    our_val = PIECE_VALUE[Int(our_k)+1]
    fl      = flags(result.move)

    # ── 1. Forced-mate sequences ───────────────────────────────────────────────
    abs_score = abs(result.score)
    if abs_score >= MATE_SCORE - MAX_PLY
        # (MATE_SCORE - abs_score) = half-moves to checkmate; +1 so integer division
        # rounds toward "mate in N" rather than N-1 for odd half-move counts.
        mate_in = (MATE_SCORE - abs_score + 1) ÷ 2

        if result.score > 0
            # We are mating.
            undo    = make_move!(b, result.move)
            cont    = _pv_continuation(result.pv, b)
            unmake_move!(b, result.move, undo)
            label   = mate_in == 1 ? "Checkmate!" :
                      "I'm playing for checkmate in $mate_in.$cont"
            return "I played $our_san — $label $note"
        else
            # We are being mated; we delay as long as possible.
            label = mate_in == 1 ? "It's checkmate — game over." :
                    "I'm being mated in $mate_in moves, but I'll keep fighting. $note"
            return "I played $our_san — $label"
        end
    end

    # ── 2. Material gain ────────────────────────────────────────────────────────
    swing = _pv_material_swing(result.pv, b)

    # A recapture (landing on the same square the opponent just vacated) restores
    # balance; we are not winning new material, so suppress the material branch.
    is_recap = last_opp_move !== nothing &&
               (is_capture(result.move) || is_ep(result.move)) &&
               to_sq(result.move) == to_sq(last_opp_move)

    genuinely_winning = swing >=  90 && result.score >=  60 && !is_recap
    genuinely_losing  = swing <= -90 && result.score <= -60 && !is_recap

    if genuinely_winning || genuinely_losing
        # 2a. Fork check: do we simultaneously threaten 2+ profitable targets?
        forks = _fork_targets(b, result.move, our_val)
        any_queen = (bb(b, White, Queen) | bb(b, Black, Queen)) != BB(0)
        if length(forks) >= 2
            n1 = _piece_name(forks[1][1])
            n2 = _piece_name(forks[2][1])
            what = swing >= 800 && any_queen ? "the queen" :
                   swing >= 800              ? "significant material" :
                   swing >= 450              ? "the rook" :
                   swing >= 270              ? "a piece"  : "a pawn"
            return "I played $our_san — forking your $n1 and $n2, winning $what. $note"
        end

        # 2b. Non-fork material gain / loss.
        what = abs(swing) >= 800 && any_queen ? "the queen" :
               abs(swing) >= 800              ? "significant material" :
               abs(swing) >= 450              ? "the rook" :
               abs(swing) >= 270              ? "a piece"  : "a pawn"
        if genuinely_winning
            return "I played $our_san — winning $what. $note"
        else
            return "I played $our_san — losing $what, but it's the best I can do. $note"
        end
    end

    # ── 3. Positional improvements ─────────────────────────────────────────────
    # Compare the static eval breakdown before and after the move to identify
    # what specifically improved.  Named structural patterns are reported only
    # when the relevant eval term confirms the gain; the largest term leads.

    # Pre-move context (needed before make_move!).
    back_rank       = my_color == White ? 0 : 7
    in_check_before = king_in_check(b, my_color)
    is_dev          = (our_k == Knight || our_k == Bishop) && rank_of(our_fr) == back_rank
    e               = evaluate(b)   # root eval; same DEFAULT_CONFIG as e2 below

    undo = make_move!(b, result.move)
    e2   = evaluate(b)
    dst  = to_sq(result.move)

    # Deltas from our side's perspective (positive = we improved).
    Δact  = sgn * (e2.piece_activity - e.piece_activity)
    Δpawn = sgn * (e2.pawn_structure - e.pawn_structure)
    Δking = sgn * (e2.king_safety    - e.king_safety)

    # Structural patterns — checked only for the relevant piece type,
    # and only when the corresponding eval term shows improvement.
    rook_concept = ""
    if our_k == Rook
        seventh   = my_color == White ? 6 : 1
        f         = file_of(dst)
        my_rooks  = bb(b, my_color, Rook)
        all_pawns = bb(b, White, Pawn) | bb(b, Black, Pawn)
        my_pawns  = bb(b, my_color, Pawn)
        occ_ex    = all_occ(b)
        visible     = rook_attacks(dst, occ_ex) & my_rooks & ~sq_bb(dst)
        file_conn   = (visible & FILE_MASK[f+1]) != 0
        rank_conn   = (visible & RANK_MASK[rank_of(dst)+1]) != 0
        if file_conn
            rook_concept = "connects my rooks on the $(Char('a'+f))-file"
        elseif rank_conn
            rook_concept = "doubles my rooks"
        elseif rank_of(dst) == seventh
            rook_concept = "invades the 7th rank"
        elseif (all_pawns & FILE_MASK[f+1]) == 0
            rook_concept = "occupies the open $(Char('a'+f))-file"
        elseif (my_pawns & FILE_MASK[f+1]) == 0
            rook_concept = "takes the semi-open $(Char('a'+f))-file"
        end
    end

    in_opp_half    = my_color == White ? rank_of(dst) >= 4 : rank_of(dst) <= 3
    knight_outpost = our_k == Knight && in_opp_half && let
        ep    = bb(b, other(my_color), Pawn)
        pmask = (my_color == White ? _PASSED_W[dst+1] : _PASSED_B[dst+1]) &
                ~FILE_MASK[file_of(dst)+1]
        # No enemy pawn can ever challenge it, AND it isn't immediately hanging
        # (opponent attacks it while we have no recapture).
        (pmask & ep) == 0 &&
        !(_is_defended(b, dst, other(my_color)) && !_is_defended(b, dst, my_color))
    end

    creates_passed = our_k == Pawn && !is_capture(result.move) && !is_ep(result.move) &&
                     _is_passed(dst, my_color, bb(b, other(my_color), Pawn))

    opens_own_file = false; open_file_char = ' '
    if our_k == Pawn && (is_capture(result.move) || is_ep(result.move))
        src_f = file_of(our_fr)
        if (bb(b, my_color, Pawn) & FILE_MASK[src_f+1]) == 0
            opens_own_file = true; open_file_char = Char('a' + src_f)
        end
    end

    pawn_center = our_k == Pawn && !is_capture(result.move) && !is_ep(result.move) &&
                  file_of(dst) in (3, 4) && rank_of(dst) in (3, 4)

    endgame = _is_endgame(b)

    # Key PV moment: find the most impactful upcoming move in the PV and
    # format the path to it while b is still in the post-move state.
    km = _find_key_pv_moment(result.pv, b, my_color)
    km_str = if km !== nothing
        c, path_km = km
        (c, _format_pv_path(path_km, b))
    else
        nothing
    end

    unmake_move!(b, result.move, undo)

    # Build the concept label.  Castling and king moves get explicit labels.
    # Structural patterns take priority when the relevant eval term confirms them.
    # The eval-delta breakdown is the final arbiter for everything else.
    concept = if fl == MF_KS_CAST
        "king to safety behind the pawn shield"
    elseif fl == MF_QS_CAST
        "king to safety, rook enters the game"
    elseif our_k == King
        if in_check_before;  "escaping check"
        elseif endgame;      "activating the king for the endgame"
        elseif Δking >= 8;   "improving king safety"
        else;                "repositioning the king"
        end
    elseif !isempty(rook_concept) && Δact >= 5
        rook_concept
    elseif knight_outpost && Δact >= 5
        "establishing a permanent outpost on $(sq_name(dst)) — your pawns can never chase it away"
    elseif creates_passed && Δpawn >= 5
        "creating a passed pawn on the $(Char('a' + file_of(dst)))-file"
    elseif opens_own_file && Δact >= 5
        "opening the $(open_file_char)-file for my rook"
    elseif pawn_center
        "fighting for the center"
    elseif is_dev && Δact >= 5
        "developing my $(_piece_name(our_k))"
    else
        # Eval-delta fallback: name the largest improving term.
        parts = Tuple{Int,String}[]
        Δact  >=  8 && push!(parts, (Δact,       "improving my piece activity"))
        Δpawn >=  8 && push!(parts, (Δpawn,       "strengthening my pawn structure"))
        Δpawn <= -8 && push!(parts, (abs(Δpawn),  "weakening your pawn structure"))
        Δking >=  8 && push!(parts, (Δking,       "improving my king safety"))
        sort!(parts; by = first, rev = true)
        isempty(parts) ? "keeping the position solid" :
        length(parts) == 1 ? parts[1][2] :
        "$(parts[1][2]) and $(parts[2][2])"
    end

    full_concept = if km_str !== nothing
        c, path_str = km_str
        "$concept, aiming to $c ($path_str)"
    else
        concept
    end

    "I played $our_san — $full_concept. $note"
end

# ── explain_opponent_move ──────────────────────────────────────────────────────

"""
    explain_opponent_move(b_before, opp_move, engine_result) → String

Coaching mode: compare the opponent's actual move to what the engine would play.
`b_before` is the position *before* the opponent moved.
"""
function explain_opponent_move(b_before::Board, opp_move::Move,
                               engine_result::SearchResult)::String
    engine_result.move == NULL_MOVE && return ""
    opp_san    = _approx_san(opp_move, b_before)
    engine_san = _approx_san(engine_result.move, b_before)
    opp_move == engine_result.move &&
        return "Good move! $opp_san is exactly what I'd play in your position."
    undo      = make_move!(b_before, engine_result.move)
    reply_str = length(engine_result.pv) >= 2 ?
                ", after which I'd play $(_approx_san(engine_result.pv[2], b_before))" : ""
    unmake_move!(b_before, engine_result.move, undo)
    "As your coach: I'd have played $engine_san there$reply_str. " *
    "Let's see how $opp_san works out. [depth $(engine_result.depth)]"
end

# ── explain_pv_outcome structural helpers ─────────────────────────────────────
# These all operate on a single board snapshot; explain_pv_outcome calls them
# on both the root and the PV endpoint and compares the results.

# Files (as UInt8 bitmask, bit i = file i) where `c` has a rook with no pawns
# of either colour on the file (fully open).
function _rook_open_files(b::Board, c::Color)::UInt8
    all_pawns = bb(b, White, Pawn) | bb(b, Black, Pawn)
    mask      = UInt8(0)
    for s in BitIter(bb(b, c, Rook))
        f = file_of(s)
        (all_pawns & FILE_MASK[f+1]) == 0 && (mask |= UInt8(1) << f)
    end
    mask
end

# Bitboard of squares where `c` has a full knight outpost: in the opponent's
# half and no enemy pawn can ever chase it (corridor clear of challengers).
function _outpost_squares(b::Board, c::Color)::BB
    result = BB(0)
    ep     = bb(b, other(c), Pawn)
    for s in BitIter(bb(b, c, Knight))
        (c == White ? rank_of(s) >= 4 : rank_of(s) <= 3) || continue
        pmask = (c == White ? _PASSED_W[s+1] : _PASSED_B[s+1]) & ~FILE_MASK[file_of(s)+1]
        (pmask & ep) == 0 && (result |= sq_bb(s))
    end
    result
end

# Bitboard of squares where `c` has a passed pawn.
function _passed_pawn_squares(b::Board, c::Color)::BB
    ep     = bb(b, other(c), Pawn)
    result = BB(0)
    for s in BitIter(bb(b, c, Pawn))
        _is_passed(s, c, ep) && (result |= sq_bb(s))
    end
    result
end

# Number of rooks `c` has sitting on the opponent's 7th rank.
function _rooks_on_seventh(b::Board, c::Color)::Int
    seventh = c == White ? 6 : 1
    n = 0
    for s in BitIter(bb(b, c, Rook)); rank_of(s) == seventh && (n += 1); end
    n
end

# Number of fully open files in the 3-file zone centred on `c`'s king
# (the files the opponent can use as invasion routes).
function _open_files_near_king(b::Board, c::Color)::Int
    kf        = file_of(lsb(bb(b, c, King)))
    all_pawns = bb(b, White, Pawn) | bb(b, Black, Pawn)
    n         = 0
    for df in -1:1
        sf = kf + df
        0 <= sf <= 7 || continue
        (all_pawns & FILE_MASK[sf+1]) == 0 && (n += 1)
    end
    n
end

# Number of files where `c` has two or more pawns (doubled pawn files).
function _doubled_files(b::Board, c::Color)::Int
    pawns = bb(b, c, Pawn)
    n     = 0
    for f in 0:7; count_bits(pawns & FILE_MASK[f+1]) > 1 && (n += 1); end
    n
end

# ── explain_pv_outcome ────────────────────────────────────────────────────────

"""
    explain_pv_outcome(result, b, my_color) → String

Describe the expected positional change between the current position and the
end of the principal variation, without referencing individual moves.

Plays through the full PV, captures structural snapshots at the endpoint and
at the root, then names the most significant specific features that appear or
disappear: which file a passed pawn lands on, which square an outpost occupies,
which file a rook opens up, etc.  Falls back to eval-delta language only when
no concrete structural change is detectable.

Returns "" when the PV is too short or changes are too small to be worth
reporting.
"""
function explain_pv_outcome(result::SearchResult, b::Board, my_color::Color)::String
    abs(result.score) >= MATE_SCORE - MAX_PLY && return ""
    length(result.pv) < 3 && return ""

    sgn    = my_color == White ? 1 : -1
    them   = other(my_color)
    e_root = evaluate(b)   # White-frame static eval at root; same DEFAULT_CONFIG as e_end

    # Gate: only produce a PV-endpoint outlook when pv[1] forces a constrained
    # opponent reply.  On quiet moves the opponent deviates at n=2 ~57% of the
    # time, making the endpoint description unreliable.
    # • Check:           opponent must escape — very few legal replies.
    # • Winning capture: material swing ≥ 80cp means the opponent can't simply
    #                    ignore the capture, so a recapture response is likely.
    undo_gate    = make_move!(b, result.pv[1])
    opp_in_check = king_in_check(b, them)
    unmake_move!(b, result.pv[1], undo_gate)
    is_cap = is_capture(result.pv[1]) || is_ep(result.pv[1])
    if !opp_in_check
        is_cap || return ""
        _pv_material_swing(result.pv, b) < 80 && return ""
    end

    # ── Play through PV; collect endpoint snapshots ────────────────────────────
    undos = UndoInfo[]
    for m in result.pv
        push!(undos, make_move!(b, m))
    end

    e_end = evaluate(b)

    # Structural snapshots at the PV endpoint.
    ep_pass       = _passed_pawn_squares(b, my_color)
    ep_out        = _outpost_squares(b, my_color)
    ep_rof        = _rook_open_files(b, my_color)
    ep_7th        = _rooks_on_seventh(b, my_color)
    ep_bpair      = count_bits(bb(b, my_color, Bishop)) >= 2
    ep_ok         = _open_files_near_king(b, them)
    ep_dp         = _doubled_files(b, them)
    ep_them_queen = bb(b, them,     Queen) != BB(0)
    ep_we_queen   = bb(b, my_color, Queen) != BB(0)

    # ── Restore to root; collect root snapshots ────────────────────────────────
    for i in length(result.pv):-1:1
        unmake_move!(b, result.pv[i], undos[i])
    end

    rp_pass  = _passed_pawn_squares(b, my_color)
    rp_out   = _outpost_squares(b, my_color)
    rp_rof   = _rook_open_files(b, my_color)
    rp_7th   = _rooks_on_seventh(b, my_color)
    rp_bpair = count_bits(bb(b, my_color, Bishop)) >= 2
    rp_ok    = _open_files_near_king(b, them)
    rp_dp    = _doubled_files(b, them)

    # ── Material delta ─────────────────────────────────────────────────────────
    Δmat          = sgn * (e_end.material - e_root.material)
    them_has_queen = bb(b, them,     Queen) != BB(0)
    we_have_queen  = bb(b, my_color, Queen) != BB(0)
    # Only label "the queen" when a queen actually changed hands during the PV.
    # Without this check, winning two rooks (≥850 cp) would also say "the queen."
    queen_won  = them_has_queen && !ep_them_queen
    queen_lost = we_have_queen  && !ep_we_queen
    mat_gain = if     Δmat >=  850 && queen_won; "the queen"
               elseif Δmat >=  850;              "significant material"
               elseif Δmat >=  450; "a rook"
               elseif Δmat >=  250; "a piece"
               elseif Δmat >=  150; "the exchange"
               elseif Δmat >=   80; "a pawn"
               else                  ""
               end
    mat_loss = if     Δmat <= -850 && queen_lost; "the queen"
               elseif Δmat <= -850;               "significant material"
               elseif Δmat <= -450; "a rook"
               elseif Δmat <= -250; "a piece"
               elseif Δmat <= -150; "the exchange"
               elseif Δmat <=  -80; "a pawn"
               else                  ""
               end

    # ── Named structural changes (sorted by chess importance) ─────────────────
    # Each entry is (priority::Int, text::String); lower priority = report first.
    changes = Tuple{Int,String}[]

    # New passed pawn — report the most advanced one by file name.
    new_pass = ep_pass & ~rp_pass
    if new_pass != BB(0)
        best = lsb(new_pass)
        for s in BitIter(new_pass)
            adv_s    = my_color == White ? rank_of(s)    : 7 - rank_of(s)
            adv_best = my_color == White ? rank_of(best) : 7 - rank_of(best)
            adv_s > adv_best && (best = s)
        end
        push!(changes, (1, "a passed pawn on the $(Char('a'+file_of(best)))-file"))
    end

    # Existing passed pawn advanced to a more dangerous rank (compare by file).
    best_adv = 0; best_adv_sq = -1
    for f in 0:7
        ep_f = ep_pass & FILE_MASK[f+1]
        rp_f = rp_pass & FILE_MASK[f+1]
        (ep_f == 0 || rp_f == 0) && continue   # no passer on this file at one end
        ep_s = lsb(ep_f); rp_s = lsb(rp_f)
        adv_end  = my_color == White ? rank_of(ep_s) : 7 - rank_of(ep_s)
        adv_root = my_color == White ? rank_of(rp_s) : 7 - rank_of(rp_s)
        gain = adv_end - adv_root
        if gain > best_adv; best_adv = gain; best_adv_sq = ep_s; end
    end
    if best_adv >= 2   # notable only when passer advanced at least two ranks
        f    = Char('a' + file_of(best_adv_sq))
        rank = my_color == White ? rank_of(best_adv_sq) + 1 : 8 - rank_of(best_adv_sq)
        push!(changes, (1, "my passer on the $f-file reaching rank $rank"))
    end

    # New full knight outpost — report the square.
    new_out = ep_out & ~rp_out
    if new_out != BB(0)
        s = lsb(new_out)
        push!(changes, (2, "a knight outpost on $(sq_name(s))"))
    end

    # Rook newly placed on an open file — report the file letter.
    new_rof = ep_rof & ~rp_rof
    if new_rof != UInt8(0)
        f = Char('a' + trailing_zeros(new_rof))
        push!(changes, (3, "a rook on the open $f-file"))
    end

    # Rook newly on the 7th rank.
    ep_7th > rp_7th &&
        push!(changes, (3, "a rook invading the 7th rank"))

    # Bishop pair gained.
    !rp_bpair && ep_bpair &&
        push!(changes, (4, "the bishop pair"))

    # New open file in the zone around the opponent's king — an invasion route.
    ep_ok > rp_ok &&
        push!(changes, (2, "an open file against your king"))

    # Opponent gains doubled pawns.
    ep_dp > rp_dp &&
        push!(changes, (5, "doubled pawns in your position"))

    # Sort by priority; cap at two for readability.
    sort!(changes; by = first)
    pos = [c[2] for c in changes[1:min(end, 2)]]

    # ── Eval-delta fallbacks (when no concrete structure was detected) ──────────
    if isempty(pos)
        Δact  = sgn * (e_end.piece_activity - e_root.piece_activity)
        Δpawn = sgn * (e_end.pawn_structure - e_root.pawn_structure)
        Δking = sgn * (e_end.king_safety    - e_root.king_safety)
        Δtot  = sgn * (total(e_end)         - total(e_root))
        if     Δact  >= 15; push!(pos, "much better piece coordination")
        elseif Δact  >=  8; push!(pos, "better piece coordination")
        end
        Δpawn >= 10 && push!(pos, "structural pawn advantages")
        Δking >= 10 && push!(pos, "a safer king")
        Δking <= -10 && push!(pos, "an exposed enemy king")
        if isempty(pos) && abs(Δtot) < 25 && isempty(mat_gain) && isempty(mat_loss)
            return ""
        end
    end

    # ── Compose output ─────────────────────────────────────────────────────────
    pos_str = length(pos) == 0 ? "" :
              length(pos) == 1 ? pos[1] :
              "$(pos[1]) and $(pos[2])"

    if !isempty(mat_gain)
        base = "Looking ahead: I expect to win $mat_gain"
        return isempty(pos_str) ? "$base." : "$base, with $pos_str to follow."
    elseif !isempty(mat_loss)
        return !isempty(pos_str) ?
            "Looking ahead: I sacrifice $mat_loss for $pos_str." :
            "Looking ahead: I expect to lose $mat_loss — best available."
    else
        return !isempty(pos_str) ?
            "Looking ahead: I'm aiming for $pos_str." :
            "Looking ahead: I expect a gradually improving position."
    end
end
