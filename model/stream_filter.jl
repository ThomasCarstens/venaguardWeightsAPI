# Sequential joint state-parameter filter — the estimator that can actually run continuously.
# ---------------------------------------------------------------------------------------
# WHY THIS EXISTS. stream_refit.jl answers each window by re-running a batch optimisation:
# ~55 objective evaluations, each integrating the WHOLE recording from t = -120, because the
# six fitted quantities are structural parameters of the ODE — change E and the trajectory
# differs from the first step, so nothing from the previous window's simulation can be
# reused. That is ~62 million RK4 steps per emitted record, which is 11x slower than the
# patient at the coarsest useful window spacing and ~155x at the 1 Hz resolution of the data.
# It reconstructs, retrospectively, what a monitor could have shown. It cannot BE one.
#
# The filter inverts the cost model. State and parameters are tracked jointly:
#
#     x = [u (13 model states) ; z (6 log-parameters)]        19-dimensional
#
# and advanced one measurement interval at a time. Per 1 Hz sample that is 2n+1 = 39
# one-second integrations — ~39 simulated seconds per record against the batch fit's ~23,000.
# Three orders of magnitude, and the result runs ahead of real time.
#
# WHY A LINEARISED FILTER AND NOT A UKF, since the UKF is the usual answer for a nonlinear
# joint filter. A UKF places its sigma points at sqrt(n+lambda)*sigma, which is 4.4 sigma in
# 19 dimensions. An honest prior on these parameters is ~100% fractional, and Psinus's whole
# search box is only +/-0.42 wide in log space — so every sigma point lands outside the box
# and has to be clamped back. Clamped points sit CLOSER together than the covariance says,
# so the posterior comes out too tight: the filter would report more confidence than it has,
# which is the one direction this API must not be wrong in. A central-difference Jacobian
# perturbs by a fixed tiny delta instead, never leaves the feasible region, and costs the
# same 2n+1 integrations. Over a 1 s step the dynamics are mild enough that the sigma
# points' extra nonlinear fidelity was not buying anything anyway.
#
# WHAT IT COSTS YOU, stated plainly because it is not a free win:
#
#   - The interval is a filter covariance, not the Fisher information of a converged
#     optimum. Both are "how much does the data constrain this parameter", they are not the
#     same object, and the filter's answer depends on the process noise you assume.
#   - Parameters here are allowed to DRIFT (random walk, _QTHETA). The batch fit assumes one
#     constant parameter set per window. If you set _QTHETA too high the filter will explain
#     genuine model error by wandering the parameters, and the stream will look responsive
#     while meaning nothing. This is the knob to be suspicious of.
#   - An unidentifiable parameter drifts under process noise instead of standing still with
#     a wide interval. Its covariance does inflate — that is what keeps the `identifiable`
#     flag honest — but the point estimate is not pinned the way the batch fit pins it.
#
# The measurement is mean ICP, which is state 4 exactly, so h(x) is LINEAR and the update is
# an exact Kalman step. Only the time propagation needs linearising. That is not a
# simplification of the physics; it is a property of what is measured.
#
# THE INITIAL COVARIANCE IS NOT DIAGONAL, and this is the difference between a filter that
# works and one that fabricates confidence. A diagonal P0 says "the state is the settled
# state, AND the parameters are uncertain" — two claims that contradict each other, because
# a different k_ijvs settles to a different state. Perturb a parameter from a state that
# does not belong to it and the first second produces a large artificial transient, which
# the filter reads as information: with a diagonal P0 the jugular tube law collapsed from
# 100% to 31% uncertainty on a SINGLE measurement, which is not physics, it is the
# inconsistency being paid off. So P0 is built by settling the perturbed parameter sets:
#     J = d(settled state)/dz,   P0 = [J;I] * diag(sigma0^2) * [J;I]' + (state floor)
# 12 extra settles, once, and the parameters then start as uninformed as they really are.
#
#   _PATIENT=081 julia --project=. model/stream_filter.jl
#
# Writes the same records to the same place as stream_refit.jl (api/stream/<patient>/*.jsonl,
# flushed per record). NEVER run both for one patient: they open the same files with "w".

ENV["_STAGE"] = "smoke"
include(joinpath(@__DIR__, "ude_cv.jl"))
using Printf, Statistics, LinearAlgebra

const PATIENT = get(ENV, "_PATIENT", "081")
include(joinpath(@__DIR__, "stream_contract.jl"))

const REC  = RECS[PATIENT]
const SDIR = get(ENV, "_SDIR", joinpath(OUT, "stream", PATIENT))
mkpath(SDIR)
take_stream_lock(SDIR)      # one writer per patient; see the contract


# --- filter tuning ---------------------------------------------------------------------
const DT     = parse(Float64, get(ENV, "_DT_FILTER", "5e-4"))  # propagation step; 1e-3 diverged for 150
const EMIT   = parse(Float64, get(ENV, "_EMIT",   "1.0"))      # seconds of data per record
const SPEED  = parse(Float64, get(ENV, "_SPEED",  "0.0"))      # data-seconds per wall-second; 0 = unpaced
const SIGMA0 = parse(Float64, get(ENV, "_SIGMA0", "0.7"))      # prior fractional sd; >0.5 so nothing
                                                               # starts identifiable by assumption
const QTHETA = parse(Float64, get(ENV, "_QTHETA", "0.005"))    # parameter random walk, per sqrt(s)
const QSTATE = parse(Float64, get(ENV, "_QSTATE", "0.01"))     # state process noise, relative, per sqrt(s)
# R is NOT the pressure transducer's precision. It is everything the model cannot explain,
# and this model has a documented structural error (it overestimates the pulse amplitude
# under compression ~7x); the batch fit's own residual runs 0.25-1.0 mmHg. Claiming 0.35
# tells the filter the model is nearly perfect, so it explains real model error by driving
# parameters to their bounds — which is exactly what it did at R=0.35.
const RMEAS  = parse(Float64, get(ENV, "_RMEAS",  "0.5"))      # sensor + model error, mmHg
const NX, NU, NP = 19, 13, 6
const ICP_IDX = 4                                              # u[4] is Pic — the measurement

# --- model plumbing --------------------------------------------------------------------
mkP(θ) = build_params(θ[1], θ[2], θ[3], θ[4], θ[5], 67.6, θ[6];
                      abp_base = REC.abp_base, dur = REC.dur)

# mean ABP, linearly interpolated off the 1 Hz grid (the mean run drives with dPa = 0)
function abp_at(t)
    tm = REC.tm
    x = (t - tm[1])
    i = clamp(floor(Int, x) + 1, 1, length(tm) - 1)
    REC.abpm[i] + (REC.abpm[i+1] - REC.abpm[i]) * (t - tm[i])
end

"""Integrate the 13 states from t0 to t1. Returns (u, ok) — ok = false on divergence, which
is a real outcome for an outlying sigma point, not an error."""
function propagate(u::NTuple{13,Float64}, P, t0, t1)
    n = max(1, round(Int, (t1 - t0) / DT))
    h = (t1 - t0) / n
    t = t0
    for _ in 1:n
        u = rk4step(u, t, h, P, abp_at(t + h / 2), 0.0, :stock, Float64[])
        isfinite(u[ICP_IDX]) || return (u, false)
        t += h
    end
    (u, true)
end

# --- initialisation ---------------------------------------------------------------------
const DELTA_Z0 = 1e-3      # perturbation used for d(settled state)/d(log parameter)

"""The state the model relaxes to under this parameter set, before the recording starts."""
function settled_state(z)
    θ = exp.(clamp.(z, log.(LO), log.(HI)))
    _, _, _, u, ok = solve_run(mkP(θ), REC.tm, REC.abpm, zeros(length(REC.tm)),
                               -120.0, -120.0 + 1e-6, DT, :stock, Float64[];
                               settle = 300.0, store = false, fs = 1.0)
    (u, ok)
end

# --- linearised prediction --------------------------------------------------------------
const DELTA_U = 1e-5      # relative perturbation on a state
const DELTA_Z = 1e-4      # absolute perturbation on a log-parameter

"""One prediction step over [t0, t1] of data.

Builds F = d x(t1) / d x(t0) by central differences — 2n integrations — then propagates the
covariance as F P F' + Q. The parameter block of F is the identity (they do not evolve) and
its upper-right block is d(state)/d(parameter): that sensitivity IS the channel through
which a parameter becomes observable, so a parameter the ICP cannot see keeps a near-zero
column here and its variance simply never shrinks. That is the mechanism behind
`identifiable`, arrived at from the opposite direction to the batch fit's Fisher matrix."""
function predict(x, P, t0, t1)
    lz, hz = log.(LO), log.(HI)
    runto(v) = propagate(NTuple{13,Float64}(v[1:NU]),
                         mkP(exp.(clamp.(v[NU+1:end], lz, hz))), t0, t1)

    ubase, ok = runto(x)
    if !ok
        # The centre trajectory blew up — the state has been driven somewhere the model
        # cannot integrate. Freezing here would strand the filter for the rest of the
        # recording, so recover onto the state these parameters actually relax to, and widen
        # the parameter covariance to say the estimate has just become much less trustworthy.
        us, oks = settled_state(x[NU+1:end])
        oks || return (x, P, -1)
        Pr = copy(P)
        for i in NU+1:NX; Pr[i, i] += (4 * QTHETA)^2 * (t1 - t0) + 0.01; end
        return (vcat(collect(us), clamp.(x[NU+1:end], lz, hz)), Pr, 1)
    end
    xp = vcat(collect(ubase), clamp.(x[NU+1:end], lz, hz))

    F = zeros(NX, NX)
    nbad = 0
    for j in 1:NX
        δ = j <= NU ? max(DELTA_U * abs(x[j]), 1e-8) : DELTA_Z
        a = copy(x); a[j] += δ
        b = copy(x); b[j] -= δ
        ua, oka = runto(a)
        ub, okb = runto(b)
        if !(oka && okb)
            nbad += 1
            continue                          # column stays 0: no information this way
        end
        F[1:NU, j] = (collect(ua) .- collect(ub)) ./ (2δ)
    end
    for j in NU+1:NX; F[j, j] = 1.0; end       # parameters persist between samples

    Pp = F * P * F'
    dt = t1 - t0
    for i in 1:NU                              # relative state noise, absolute floor
        Pp[i, i] += (QSTATE * abs(xp[i]) + 1e-6)^2 * dt
    end
    for i in NU+1:NX                           # parameters random-walk in log space
        Pp[i, i] += QTHETA^2 * dt
    end
    (xp, Matrix(Symmetric(Pp)), nbad)
end

"""Exact Kalman update: the measurement IS state 4, so h is linear and no sigma points or
linearisation are needed here."""
function update(x, P, y)
    S = P[ICP_IDX, ICP_IDX] + RMEAS^2
    K = P[:, ICP_IDX] ./ S
    innov = y - x[ICP_IDX]
    xn = x .+ K .* innov
    Pn = P .- (K * S) * K'
    xn[NU+1:end] .= clamp.(xn[NU+1:end], log.(LO), log.(HI))
    (xn, Matrix(Symmetric(Pn)), innov)
end

# --- main ------------------------------------------------------------------------------
function main()
    nu = load_nuis(PATIENT)
    θ0 = [nu.E, nu.Psinus, nu.Ro_tot, nu.Rvvs, nu.k_ijvs, nu.Ca]
    P0 = mkP(θ0)

    # the settle, once — the batch fit pays this 55 times per record
    z0 = log.(θ0)
    u_init, ok = settled_state(z0)
    ok || error("settle diverged for patient $PATIENT")

    # d(settled state)/d(log parameter), so the prior state is consistent with the prior
    # parameters instead of contradicting them (see the header)
    J = zeros(NU, NP)
    for j in 1:NP
        a = copy(z0); a[j] += DELTA_Z0
        b = copy(z0); b[j] -= DELTA_Z0
        ua, oka = settled_state(a)
        ub, okb = settled_state(b)
        (oka && okb) || continue
        J[:, j] = (collect(ua) .- collect(ub)) ./ (2 * DELTA_Z0)
    end

    x    = vcat(collect(Float64, u_init), z0)
    Pzz  = SIGMA0^2 * Matrix(I, NP, NP)
    Puz  = J * Pzz
    Puu  = J * Pzz * J' + Diagonal([(0.02 * abs(x[i]) + 1e-3)^2 for i in 1:NU])
    P    = [Puu Puz; Puz' Pzz]

    keys_sorted = sort(collect(keys(DERIVE)))
    files = Dict(k => open(joinpath(SDIR, "$k.jsonl"), "w") for k in keys_sorted)

    tm, icpm = REC.tm, REC.icpm
    @printf("patient %s: sequential filter over %d samples, t %.0f .. %.0f s\n",
            PATIENT, length(tm), first(tm), last(tm))
    @printf("  dt=%.0e  sigma0=%.2f  q_theta=%.3f  q_state=%.3f  R=%.2f  emit=%.1fs  speed=%s\n",
            DT, SIGMA0, QTHETA, QSTATE, RMEAS, EMIT, SPEED == 0 ? "unpaced" : string(SPEED))
    @printf("%8s %9s %8s %7s", "t", "innov", "rmse", "nolin")
    for k in keys_sorted; @printf(" %22s", first(k, 22)); end
    println()

    ss, nobs, nprop, t_start, next_emit = 0.0, 0, 0, time(), tm[1]
    for k in 2:length(tm)
        x, P, ndiv = predict(x, P, tm[k-1], tm[k])
        nprop += 2NX + 1
        x, P, innov = update(x, P, icpm[k])
        ss += innov^2; nobs += 1
        rmse = sqrt(ss / nobs)

        if tm[k] >= next_emit - 1e-9
            next_emit = tm[k] + EMIT
            θ = exp.(x[NU+1:end])
            σ = sqrt.(max.(diag(P)[NU+1:end], 0.0))
            @printf("%8.1f %9.3f %8.3f %7d", tm[k], innov, rmse, ndiv)
            for key in keys_sorted
                j  = SRC_INDEX[key]
                v  = DERIVE[key](θ)
                id, st = emit_record(files[key], tm[k], v, σ[j], key, rmse, 2NX + 1)
                @printf(" %10.4g%s", v, id ? (st == "healthy" ? "  ok " :
                                              st == "borderline" ? " bord" : " PATH") : " ????")
            end
            @printf("\n"); flush(stdout)
        end

        if SPEED > 0                          # pace the stream against the wall clock
            target = t_start + (tm[k] - tm[1]) / SPEED
            while time() < target; sleep(0.01); end
        end
    end

    close.(values(files))
    el = time() - t_start
    @printf("\n%d records, %d one-second integrations, %.1f s wall for %.0f s of data (%.1fx real time)\n",
            nobs, nprop, el, tm[end] - tm[1], (tm[end] - tm[1]) / el)
    println("wrote $(length(files)) streams to $SDIR")
end
main()
