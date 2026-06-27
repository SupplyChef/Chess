# tune.jl — Supervised weight tuning against ChessBench Stockfish-16 labels.
#
# Loss function: sigmoid mean-squared error (standard Texel tuning, but with
# engine evaluations as labels instead of game results).
#
#   σ(x) = 1 / (1 + exp(−x))
#   L(θ) = mean_i ( σ(φᵢ·θ / K) − σ(yᵢ / K) )²
#
# where K ≈ 400 converts centipawns to a win-probability scale.
# The analytical gradient is:
#   ∂L/∂θ = (2/N) Σ_i  (σ(pred_i/K) − σ(y_i/K)) × σ'(pred_i/K)/K × φᵢ
#
# This is O(N × D) per gradient computation — no dual numbers needed.
# L-BFGS from Optim.jl converges in ~100–300 iterations.
#
# Usage:
#   using Chess
#   boards, scores = load_positions("chessbench.csv"; max_n=2_000_000)
#   X = build_feature_matrix(boards)
#   θ_tuned = tune_weights(X, scores; iterations=300, verbose=true)
#   println(weights_to_source(θ_tuned))   # paste back into eval.jl

using Optim

# ── Sigmoid helpers ────────────────────────────────────────────────────────────
@inline _sigmoid(x::Float64) = 1.0 / (1.0 + exp(-x))

# ── Loss and gradient ─────────────────────────────────────────────────────────
"""
    sigmoid_loss(θ, X, y; K=400.0) -> Float64

Sigmoid MSE between predicted and target win probabilities.
"""
function sigmoid_loss(θ::Vector{Float64},
                      X::Matrix{Float32},
                      y::Vector{Float32};
                      K::Float64 = 400.0)::Float64
    n    = size(X, 1)
    loss = 0.0
    K_inv = 1.0 / K
    @inbounds for i in 1:n
        pred   = Float64(dot(@view(X[i, :]), θ))
        σ_pred = _sigmoid(pred * K_inv)
        σ_tgt  = _sigmoid(Float64(y[i]) * K_inv)
        d      = σ_pred - σ_tgt
        loss  += d * d
    end
    loss / n
end

"""
    sigmoid_loss_and_grad!(∇θ, θ, X, y; K=400.0) -> Float64

Computes loss and fills `∇θ` in-place.  Single pass over the data.
"""
function sigmoid_loss_and_grad!(∇θ::Vector{Float64},
                                θ::Vector{Float64},
                                X::Matrix{Float32},
                                y::Vector{Float32};
                                K::Float64 = 400.0)::Float64
    n = size(X, 1); d = size(X, 2)
    fill!(∇θ, 0.0)
    loss  = 0.0
    K_inv = 1.0 / K
    inv_n = 1.0 / n

    @inbounds for i in 1:n
        φᵢ     = @view X[i, :]
        pred   = Float64(dot(φᵢ, θ))
        σ_pred = _sigmoid(pred * K_inv)
        σ_tgt  = _sigmoid(Float64(y[i]) * K_inv)
        diff   = σ_pred - σ_tgt
        loss  += diff * diff
        coeff  = 2.0 * diff * σ_pred * (1.0 - σ_pred) * K_inv * inv_n
        for j in 1:d
            ∇θ[j] += coeff * Float64(φᵢ[j])
        end
    end
    loss * inv_n
end

# ── Constraints ───────────────────────────────────────────────────────────────
# Keep piece values in a sane range and ensure pawn < knight < bishop < rook < queen.
# PST entries and scalar bonuses are box-constrained to ±500 cp.
function _clamp_weights!(θ::Vector{Float64})
    # Material: pawn ≥ 50, strictly ordered, queen ≤ 1500
    θ[1] = clamp(θ[1], 50.0,  200.0)   # pawn
    θ[2] = clamp(θ[2], 200.0, 450.0)   # knight
    θ[3] = clamp(θ[3], 200.0, 450.0)   # bishop
    θ[4] = clamp(θ[4], 350.0, 700.0)   # rook
    θ[5] = clamp(θ[5], 700.0, 1500.0)  # queen
    # PSTs: ±150 cp deviation from 0
    for i in (N_MAT+1):(N_MAT+N_PST)
        θ[i] = clamp(θ[i], -150.0, 150.0)
    end
    # Scalars: non-negative penalties and bonuses, bounded
    for i in (N_MAT+N_PST+1):N_WEIGHTS
        θ[i] = clamp(θ[i], -500.0, 500.0)
    end
    θ
end

# ── Main training function ─────────────────────────────────────────────────────
"""
    tune_weights(X, y;
                 θ₀       = default_weights(),
                 K        = 400.0,
                 iterations = 300,
                 batch_size = 200_000,
                 verbose   = true) -> Vector{Float64}

Run L-BFGS to minimise the sigmoid loss on a random mini-batch at each
iteration.  Returns the tuned weight vector.

`batch_size` controls how many positions are used per gradient evaluation.
With 2M positions, batch_size=200_000 keeps each step under ~1 second on a
modern CPU.  Larger batches → more accurate gradients → fewer iterations.

After tuning, call `weights_to_source(θ)` to generate replacement Julia code
for the constants in eval.jl.
"""
function tune_weights(X::Matrix{Float32},
                      y::Vector{Float32};
                      θ₀::Vector{Float64}  = default_weights(),
                      K::Float64           = 400.0,
                      iterations::Int      = 300,
                      batch_size::Int      = 200_000,
                      verbose::Bool        = true)::Vector{Float64}

    n = size(X, 1)
    batch_size = min(batch_size, n)
    θ = copy(θ₀)

    verbose && @info "Starting L-BFGS tuning" n_positions=n features=N_WEIGHTS batch=batch_size

    # Shuffle once before batching
    idx = randperm(n)
    Xb  = X[idx[1:batch_size], :]
    yb  = y[idx[1:batch_size]]

    # f and g! are called separately by Optim.jl; both clamp weights first.
    f(θ_)     = (_clamp_weights!(θ_); sigmoid_loss(θ_, Xb, yb; K))
    g!(G, θ_) = (_clamp_weights!(θ_); sigmoid_loss_and_grad!(G, θ_, Xb, yb; K); nothing)

    result = Optim.optimize(
        f, g!, θ,
        LBFGS(),
        Optim.Options(
            iterations = iterations,
            show_trace = verbose,
            show_every = 10,
            g_tol      = 1e-6,
        )
    )

    θ_best = Optim.minimizer(result)
    _clamp_weights!(θ_best)

    if verbose
        train_loss = sigmoid_loss(θ_best, Xb, yb; K)
        init_loss  = sigmoid_loss(θ₀,    Xb, yb; K)
        @info "Tuning complete" init_loss train_loss iterations=Optim.iterations(result)
    end

    θ_best
end

# ── Convenience: end-to-end pipeline ─────────────────────────────────────────
"""
    run_tuning(csv_path;
               max_n=2_000_000, score_clip=1500, K=400.0,
               iterations=300, batch_size=200_000,
               output_path="tuned_weights.bin") -> Vector{Float64}

Load data, extract features, run tuning, save weights.  The returned vector
can be passed to `weights_to_source()` to generate updated eval.jl constants.
"""
function run_tuning(csv_path::String;
                    max_n::Int     = 2_000_000,
                    score_clip::Int = 1500,
                    K::Float64     = 400.0,
                    iterations::Int = 300,
                    batch_size::Int = 200_000,
                    output_path::String = "tuned_weights.bin")

    @info "Loading positions from $csv_path"
    boards, scores_f32 = load_positions(csv_path; max_n, score_clip)

    @info "Extracting features ($(length(boards)) positions × $N_WEIGHTS features)"
    X = build_feature_matrix(boards)
    y = Vector{Float32}(scores_f32)

    θ = tune_weights(X, y; K, iterations, batch_size, verbose=true)

    save_dataset(X, y, output_path * ".features")
    @info "Saved feature matrix to $(output_path).features"

    open(output_path, "w") do io
        write(io, θ)
    end
    @info "Saved tuned weights to $output_path"

    θ
end
