# Expanding-window sequential refit — the parameter stream behind the API.
# ---------------------------------------------------------------------------
# WHAT "OVER TIME" MEANS HERE, because two readings are possible and they are different
# pipelines. This is the EXPANDING WINDOW: at each step the model is refitted against all
# mean-ICP data from the start of the recording up to t_end, and t_end walks forward. Each
# emitted record answers "what would we have estimated, knowing only what had happened by
# now". That is the clinically meaningful version — it is what a bedside monitor could have
# shown at that instant — and it makes the arrival of information visible.
#
# It is NOT a sliding window. A sliding window cannot work here: the model is an initial
# value problem, so every objective evaluation integrates from t = -120 regardless of which
# window is being scored. Sliding buys nothing and discards the settling.
#
# WHY THE CONFIDENCE INTERVALS ARE THE POINT. Resting ICP is almost blind to the venous
# outflow path — |dlog(ICP_base)/dlog| is 0.0000 for Rvvs, 0.0000 for Pjc and 0.0004 for
# k_ijvs. So in every window BEFORE the compression those parameters are not estimated, they
# are guessed, and a stream that emitted a number without an interval would look like a
# measurement. Each record therefore carries a FIM-derived interval and an `identifiable`
# flag, and the interesting thing to watch is those intervals collapsing the moment the
# manoeuvre supplies the information.
#
# Warm-started Nelder-Mead: each window starts from the previous window's estimate, so a
# step costs ~25 solves rather than ~150.
#
#   _PATIENT=081 julia --project=. Model_6/stream_refit.jl
#
# Emits, incrementally and flushed after every window (so `tail -f` works):
#   output/ude_cv_m6/api/stream/<patient>/<param>.jsonl

ENV["_STAGE"] = "smoke"
include(joinpath(@__DIR__, "ude_cv.jl"))
using Optim, Printf, Statistics, LinearAlgebra

const PATIENT = get(ENV, "_PATIENT", "081")
const NWIN    = parse(Int, get(ENV, "_NWIN", "24"))
const ITERS   = parse(Int, get(ENV, "_WIN_ITERS", "30"))
const API     = OUT
const SDIR    = get(ENV, "_SDIR", joinpath(API, "stream", PATIENT))   # _SDIR to test off to one side
mkpath(SDIR)


const REC = RECS[PATIENT]
# the six quantities, their bounds and the exact bytes of a record — shared with
# model/stream_filter.jl so the two estimators cannot mean different things by "healthy"
include(joinpath(@__DIR__, "stream_contract.jl"))
take_stream_lock(SDIR)      # one writer per patient; see the contract

mkP(θ) = build_params(θ[1], θ[2], θ[3], θ[4], θ[5], 67.6, θ[6];
                      abp_base = REC.abp_base, dur = REC.dur)

# residual vector against the 1 Hz mean ICP, up to t_end
function resid(θ, t_end)
    P = mkP(θ)
    t, icp, _, _, ok = meanrun(P, REC)
    ok || return nothing
    m = (REC.tm .>= -110.0) .& (REC.tm .<= t_end)
    idx = [clamp(round(Int, (τ + 120.0) * 100) + 1, 1, length(icp)) for τ in REC.tm[m]]
    icp[idx] .- REC.icpm[m]
end

function objective(z, t_end, nev)
    θ = exp.(z)
    pen = 0.0
    for i in eachindex(θ)
        θ[i] < LO[i] && (pen += 1e3 * ((LO[i] - θ[i]) / LO[i])^2)
        θ[i] > HI[i] && (pen += 1e3 * ((θ[i] - HI[i]) / HI[i])^2)
    end
    (0.3 / (θ[1] * 5) - θ[6]) < 2.5e-3 && (pen += 1e6)
    pen > 0 && return 1e5 + pen             # infeasible must cost MORE than divergent
    r = resid(θ, t_end)
    r === nothing && return 1e4
    nev[] += 1
    sqrt(mean(r .^ 2))
end

# FIM at the converged point, restricted to this window's data -> per-parameter sigma
function sigmas(θ, t_end, σ_meas = 0.35)
    r0 = resid(θ, t_end)
    r0 === nothing && return fill(NaN, 6), NaN
    S = zeros(length(r0), 6)
    δ = 0.05
    for j in 1:6
        up = copy(θ); up[j] *= exp(δ)
        dn = copy(θ); dn[j] *= exp(-δ)
        ru, rd = resid(up, t_end), resid(dn, t_end)
        (ru === nothing || rd === nothing) && return fill(NaN, 6), sqrt(mean(r0 .^ 2))
        S[:, j] = (ru .- rd) ./ (2δ)
    end
    F = (S' * S) ./ σ_meas^2
    # relative sigma on log-parameters == fractional uncertainty on the parameter
    σ = sqrt.(max.(diag(pinv(F)), 0.0))
    σ, sqrt(mean(r0 .^ 2))
end

function main()
    nu = load_nuis(PATIENT)
    θ = [nu.E, nu.Psinus, nu.Ro_tot, nu.Rvvs, nu.k_ijvs, nu.Ca]
    # windows: start just before the compression is visible, walk past the release
    t_ends = collect(range(-60.0, REC.dur + 150.0, length = NWIN))

    files = Dict(k => open(joinpath(SDIR, "$k.jsonl"), "w") for k in keys(DERIVE))
    @printf("patient %s: %d windows, t_end %.0f .. %.0f s\n", PATIENT, NWIN, first(t_ends), last(t_ends))
    @printf("%8s %9s %7s", "t_end", "rmse", "solves")
    for k in sort(collect(keys(DERIVE))); @printf(" %22s", first(k, 22)); end
    println()

    for (w, te) in enumerate(t_ends)
        nev = Ref(0); t0 = time()
        res = optimize(z -> objective(z, te, nev), log.(θ), NelderMead(),
                       Optim.Options(iterations = ITERS, show_trace = false))
        θ = clamp.(exp.(Optim.minimizer(res)), LO, HI)
        σ, rmse = sigmas(θ, te)

        @printf("%8.1f %9.3f %7d", te, rmse, nev[])
        for k in sort(collect(keys(DERIVE)))
            v = DERIVE[k](θ)
            # propagate the fractional sigma of the SOURCE parameter through the derivation
            j = SRC_INDEX[k]
            ident, st = emit_record(files[k], te, v, σ[j], k, rmse, nev[])
            @printf(" %10.4g%s", v, ident ? (st == "healthy" ? "  ok " :
                                             st == "borderline" ? " bord" : " PATH") : " ????")
        end
        @printf("   [%.0fs]\n", time() - t0); flush(stdout)
    end
    close.(values(files))
    println("\nwrote $(length(files)) streams to $SDIR")
end
main()
