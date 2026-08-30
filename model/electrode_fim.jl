# Could the six parameters be estimated WITHOUT a bolt? — the evidence behind
# SENSORS_MINIMUM.tex.
# ---------------------------------------------------------------------------
# stream_refit.jl fits one observable: mean ICP at 1 Hz, which needs a burr hole. This
# asks what a tetrapolar NECK IMPEDANCE would identify instead. The model already carries
# the state such an electrode sees — u[11], the jugular cross-section A, relaxing to the
# tube law — so no new physics is needed to answer the question, only a solver that stores
# a third state and a Fisher matrix against it.
#
# Three observables, all on the recording's own 1 Hz grid:
#   (a) mean ICP                      what the API is fitted to today
#   (b) neck venous volume A*ltube*Ntube   what the electrodes see, up to an unknown gain
#   (c) both
# The impedance GAIN (ohms per mL: neck geometry, electrode span, haematocrit) is unknown
# per patient, so it is PROFILED OUT rather than assumed: the observable scales linearly
# with g, so d obs / d log g = obs is appended as a 7th column and the 7x7 inverted. The
# "elec+calib" column omits that column — what a perfectly calibrated electrode would buy.
#
# The operating point is the one the API PUBLISHES, not the prefit. R3 says the stream
# hides raw theta, so each derivation in stream_contract.jl is inverted to recover it.
#
#   _PATIENT=081 _SRC=081_batch julia --project=. model/electrode_fim.jl
#
# _SRC picks the stream directory the operating point is read from (default: _PATIENT).
# Note api/stream/081 is currently byte-identical to 081_filter, whose collateral
# coordinate is frozen — RULEBOOK R7. 081_batch is the expanding-window refit.
#
# Prints only; writes nothing. ~13 mean-run solves, about two minutes.
# ---------------------------------------------------------------------------
ENV["_STAGE"] = "smoke"
include(joinpath(@__DIR__, "ude_cv.jl"))
using LinearAlgebra, Printf

const PATIENT = get(ENV, "_PATIENT", "081")
const SRC     = get(ENV, "_SRC", PATIENT)   # which stream dir the operating point comes from
include(joinpath(ROOT, "model", "stream_contract.jl"))
const REC = RECS[PATIENT]

mkP(θ) = build_params(θ[1], θ[2], θ[3], θ[4], θ[5], 67.6, θ[6];
                      abp_base = REC.abp_base, dur = REC.dur)

# solve_run stores only u[4] (Pic) and u[5] (Pv). The electrode observable needs u[11]
# (the jugular area A), so this is solve_run with one more output vector.
function solve_obs(P, r::Rec)
    tgrid, abp, dabp = r.tm, r.abpm, zeros(length(r.tm))
    t0, t1, dt, fs = -120.0, r.dur + 179.0, DT_MEAN, 1.0
    lerp = (v, t) -> begin
        x = (t - tgrid[1]) * fs
        i = clamp(floor(Int, x) + 1, 1, length(v) - 1)
        v[i] + (v[i+1] - v[i]) * (x - (i - 1))
    end
    u = init_state(P, Float64)
    n0 = clamp(round(Int, 10 * fs), 1, length(abp)); Pa0 = mean(@view abp[1:n0])
    for _ in 1:round(Int, 300.0 / 1e-3)
        u = rk4step(u, P.jc_on - 1e3, 1e-3, P, Pa0, 0.0, :stock, Float64[])
    end
    nsteps = round(Int, (t1 - t0) / dt); per = max(1, round(Int, 0.01 / dt))
    nout = nsteps ÷ per + 1
    tout = Vector{Float64}(undef, nout); icp = Vector{Float64}(undef, nout)
    ar = Vector{Float64}(undef, nout)
    k = 1; tout[1] = t0; icp[1] = u[4]; ar[1] = u[11]; t = t0
    for istep in 1:nsteps
        u = rk4step(u, t, dt, P, lerp(abp, t + dt/2), lerp(dabp, t + dt/2), :stock, Float64[])
        t = t0 + istep * dt
        if istep % per == 0
            k += 1; tout[k] = t; icp[k] = u[4]; ar[k] = u[11]
        end
        isfinite(u[4]) || return (tout[1:k], icp[1:k], ar[1:k], false)
    end
    (tout[1:k], icp[1:k], ar[1:k], true)
end

# both observables on the recording's own 1 Hz grid, full window
const MASK = (REC.tm .>= -110.0) .& (REC.tm .<= REC.tm[end])
idxs(icp) = [clamp(round(Int, (τ + 120.0) * 100) + 1, 1, length(icp)) for τ in REC.tm[MASK]]

# neck venous blood volume seen by the electrodes, mL: both jugulars over the 20 cm segment
neckvol(a) = a .* 20.0 .* 2.0

function obs(θ)
    t, icp, ar, ok = solve_obs(mkP(θ), REC)
    ok || return nothing
    ix = idxs(icp)
    (icp[ix], neckvol(ar[ix]))
end

# Evaluate at the point the API actually PUBLISHES — the final window of
# api/stream/<patient>/. R3: the stream hides raw θ, so invert each derivation.
function theta_from_stream(id)
    val(k) = begin
        ln = readlines(joinpath(ROOT, "api", "stream", SRC, "$k.jsonl"))[end]
        m = match(r"\"value\":\s*([-0-9.eE+]+)", ln); parse(Float64, m.captures[1])
    end
    C  = val("craniospinal_compliance")
    E  = 1.0 / (C * max(JC_EVENTS[id].icp_base - 5.0, 0.5))
    Ro = val("csf_outflow_resistance") * 60.0 / (0.069 * 0.931)
    ar = val("jugular_resting_area")                      # invert jug_area()
    a  = ar / 0.3
    k  = (6.5 - 2.0 * 981.0 / 1330.0) / (a^2.3 - a^(-7.0))
    [E, val("sagittal_sinus_pressure"), Ro, val("collateral_outflow_resistance"),
     k, val("arterial_compliance")]
end

θ0 = theta_from_stream(PATIENT)
@printf("patient %s  operating point from api/stream/%s  θ = %s\n",
        PATIENT, SRC, join(round.(θ0, sigdigits=4), "  "))
@printf("  (prefit θ for comparison: %s)\n",
        join(round.(collect(load_nuis(PATIENT))[[1,2,3,4,5,7]], sigdigits=4), "  "))

o0 = obs(θ0); o0 === nothing && error("base solve diverged")
icp0, vol0 = o0
@printf("mean ICP  %.2f -> %.2f mmHg   (step %+.2f)\n",
        icp0[1], maximum(icp0), maximum(icp0) - icp0[1])
A_rest = vol0[1] / 40.0; A_plat = minimum(vol0) / 40.0
@printf("neck vol  rest %.2f mL -> plateau %.2f mL   (excursion %.1f mL)\n",
        vol0[1], minimum(vol0), vol0[1] - minimum(vol0))
@printf("jugular   A_rest %.3f  A_plat %.4f cm2/vein   ratio %.4f (%.1f%% of resting)\n",
        A_rest, A_plat, A_plat / A_rest, 100 * A_plat / A_rest)
# Nyboer sanity check: is the volume swing above an impedance amplifier's noise floor?
#   dV = rho (L/Z0)^2 dZ  ->  dZ = dV Z0^2 / (rho L^2)
# rho_blood 150 ohm.cm, Z0 25 ohm (neck), L 8 cm sensing span. The model's 20 cm tube is
# longer than the span, so only L/ltube of the volume swing sits between the sense pair.
for (rho, Z0, L) in ((150.0, 25.0, 8.0),)
    dV_span = (vol0[1] - minimum(vol0)) * L / 20.0
    @printf("Nyboer    dV_span %.1f mL  ->  dZ %.3f ohm  (rho %.0f, Z0 %.0f, L %.0f cm)\n",
            dV_span, dV_span * Z0^2 / (rho * L^2), rho, Z0, L)
end

# central-difference sensitivity in log-parameters, same δ as sigmas() in stream_refit.jl
δ = 0.05
S_icp = zeros(length(icp0), 6); S_vol = zeros(length(vol0), 6)
for j in 1:6
    up = copy(θ0); up[j] *= exp(δ); dn = copy(θ0); dn[j] *= exp(-δ)
    ou, od = obs(up), obs(dn)
    (ou === nothing || od === nothing) && error("perturbed solve diverged at j=$j")
    S_icp[:, j] = (ou[1] .- od[1]) ./ (2δ)
    S_vol[:, j] = (ou[2] .- od[2]) ./ (2δ)
    @printf("  col %d (%s) done\n", j, PNAMES[j]); flush(stdout)
end

σ_icp = 0.35                       # mmHg, as in stream_refit.jl
σ_vol = 0.02 * (maximum(vol0) - minimum(vol0))   # 2% of the manoeuvre's own excursion

function fracsig(S, σ; profile_gain = false, base = nothing)
    A = profile_gain ? hcat(S, base) : S      # 7th column: d obs / d log gain = obs
    F = (A' * A) ./ σ^2
    sqrt.(max.(diag(pinv(F)), 0.0))[1:6]
end

s_icp   = fracsig(S_icp, σ_icp)
s_vol   = fracsig(S_vol, σ_vol; profile_gain = true, base = vol0)   # gain unknown
s_volc  = fracsig(S_vol, σ_vol)                                     # gain calibrated
# joint: stack the two residual blocks, each with its own noise, gain still profiled
Ajoint  = vcat(hcat(S_icp ./ σ_icp, zeros(size(S_icp,1))),
               hcat(S_vol ./ σ_vol, vol0 ./ σ_vol))
s_joint = sqrt.(max.(diag(pinv(Ajoint' * Ajoint)), 0.0))[1:6]

println("\nfractional sigma (log-space sd). identifiable threshold = $IDENT_MAX_SIGMA")
@printf("%-10s %12s %12s %12s %12s\n",
        "param", "ICP only", "electrode", "elec+calib", "both")
for j in 1:6
    mark(x) = x < IDENT_MAX_SIGMA ? " *" : "  "
    @printf("%-10s %10.3f%s %10.3f%s %10.3f%s %10.3f%s\n", PNAMES[j],
            s_icp[j], mark(s_icp[j]), s_vol[j], mark(s_vol[j]),
            s_volc[j], mark(s_volc[j]), s_joint[j], mark(s_joint[j]))
end
@printf("\nsigma_icp = %.2f mmHg, sigma_vol = %.3f mL (2%% of the manoeuvre's excursion)\n",
        σ_icp, σ_vol)

# RMS relative sensitivity, noise-model independent
println("\nRMS |d obs / d log θ| over the window, in the observable's own units")
@printf("%-10s %14s %14s\n", "param", "mmHg / log", "mL / log")
for j in 1:6
    @printf("%-10s %14.4g %14.4g\n", PNAMES[j],
            sqrt(mean(S_icp[:, j].^2)), sqrt(mean(S_vol[:, j].^2)))
end
