# Model 6 — M5's physics with the venous compliance LAW learned from the recordings.
# ---------------------------------------------------------------------------
# The finding this model exists to interrogate (Model_5/README.md): across all four
# recordings the ICP pulse amplitude is INVARIANT to a jugular compression that raises
# mean ICP by 5-10 mmHg, while M5's rises ~tenfold. Something in the patient absorbs
# each beat's arterial volume during occlusion and nothing in the model does.
#
# The experiment: replace the venous compliance — in M5 the CONSTANT Veins.C_v, the one
# runtime consumer of Params.jl's derived Cv_expr = α/(E(Pic−Pcv)) − Ca — with a small
# neural network C_v = NN(Pic, Pv), train it INSIDE the ODE against the beat-wise AMP
# and beat-wise mean ICP of the recordings, and then READ the learned function. Two
# insertion points, because they answer different questions:
#
#   variant A   Veins.C_v = NN(Pic, Pv)     the instruction as given. Volume
#               conservation at the occluded node predicts this CANNOT flatten AMP:
#               the vein's volume is set by its in/out FLOW balance, not by its
#               compliance, and with the outflow occluded the compliance has nothing
#               to trade against. If training confirms that, the failure is the result.
#   variant B   a reservoir at brain.out (the Rijvs/Rvvs junction), upstream of the
#               occlusion, C_res = NN(P_j, Pext), behind a small access resistance.
#               Its displacement reference is OUTSIDE the skull, so it can absorb the
#               beat during occlusion — the "missing reservoir" hypothesis, and the
#               object a neck radar would measure.
#
# WHY A COMPACT MODEL AND NOT M5 ITSELF. A pulsatile M5 solve is ~12 min; training a
# network inside it is years. This file re-derives M5's :Pext supine circuit — every
# element equation transcribed from Model_5/Elements.jl, every constant from
# Model_5/Params.jl's cascade — into an EXPLICIT 12-state ODE in (mmHg, mL, s), solved
# by fixed-step RK4 in ~0.3 s. Two deliberate departures, both stated:
#   * the arterial boundary is the MEASURED 100 Hz ABP (M5 fits a descriptor to it —
#     stage 0 of fit.jl becomes unnecessary);
#   * the jugular tube's area, algebraic in M5, relaxes to its tube-law value with
#     τ_A = 20 ms so the system stays an ODE. (Variant B's reservoir likewise sits
#     behind R_acc = 0.1 mmHg·s/mL.)
# The GATE stage exists to keep this honest: with 081's fitted parameters and the stock
# law, the compact model must reproduce M5's signature — the ~+10 mmHg ICP step AND the
# order-of-magnitude AMP blow-up at the plateau — before any training is believed.
#
# STAGES (env _STAGE, run from the repository root):
#   smoke    30 s solve, prints state extremes — the machinery check
#   gate     081 on the M5 fit, stock law vs recording + M5's published numbers
#   prefit   083/137/150: Nelder-Mead of the six fit.jl nuisances on the 1 Hz mean
#            (compact stage A), then a per-patient 1-D Ca scan on baseline AMP
#            (compact stage B), 081's Ca rescanned the same way for comparability
#            -> Model_6/fit/<id>_compact.jl
#   train    shared NN on 081+083+137 (150 HELD OUT), LBFGS + ForwardDiff through the
#            solver; _VARIANT=A|B -> Model_6/fit/nn_<variant>.jl
#   read     all four patients under stock/A/B, PNGs + report -> output/ude_cv_m6/
#
# Knobs: _STAGE, _VARIANT (A), _MAXITER (120), _PATIENTS (prefit list), _DT override.
# ---------------------------------------------------------------------------

using DelimitedFiles, Statistics, Printf, Random
using Optim

const ROOT = normpath(joinpath(@__DIR__, ".."))
isfile(joinpath(ROOT, "data", "jugular_prepared", "events.jl")) ||
    error("run from the repo checkout — data/jugular_prepared/ missing (scripts/prep_jugular_data.py)")
include(joinpath(ROOT, "data", "jugular_prepared", "events.jl"))   # JC_EVENTS

const OUT  = joinpath(ROOT, "api")
const FDIR = joinpath(ROOT, "fit")
mkpath(OUT); mkpath(FDIR)

# --- the recordings ---------------------------------------------------------

struct Rec
    id::String
    dur::Float64
    tw::Vector{Float64};  abp::Vector{Float64};  dabp::Vector{Float64}   # 100 Hz wave
    icpw::Vector{Float64}
    tm::Vector{Float64};  abpm::Vector{Float64}; icpm::Vector{Float64}   # 1 Hz mean
    bt::Vector{Float64};  bper::Vector{Float64}                          # beat table
    bicpm::Vector{Float64}; bamp::Vector{Float64}
    abp_base::Float64
end

function load_rec(id::String)
    ev = JC_EVENTS[id]
    D  = joinpath(ROOT, "data", "jugular_prepared")
    w, wh = readdlm(joinpath(D, "$(id)_wave.csv"), ','; header = true)
    m, mh = readdlm(joinpath(D, "$(id)_mean.csv"), ','; header = true)
    b, bh = readdlm(joinpath(D, "$(id)_beat.csv"), ','; header = true)
    ci(h, n) = findfirst(==(n), vec(h))
    fl(x) = x isa AbstractString ? (isempty(strip(x)) ? NaN : parse(Float64, x)) : Float64(x)
    col(M, i) = Float64[fl(M[r, i]) for r in 1:size(M, 1)]
    tw   = col(w, ci(wh, "t"));   abp = col(w, ci(wh, "abp"))
    icpw = col(w, ci(wh, "icp"))
    # the wave is 20 Hz-lowpassed by prep; a central difference is then a fair Ṗa
    dabp = similar(abp); n = length(abp)
    for i in 2:n-1; dabp[i] = (abp[i+1] - abp[i-1]) * 50.0; end
    dabp[1] = dabp[2]; dabp[n] = dabp[n-1]
    # NaN guard: bridge interior holes linearly (prep leaves long gaps NaN)
    for v in (abp, dabp, icpw)
        bad = findall(isnan, v)
        isempty(bad) || for i in bad
            j = i; while j > 1 && isnan(v[j]); j -= 1; end
            k = i; while k < n && isnan(v[k]); k += 1; end
            v[i] = (isnan(v[j]) ? v[k] : isnan(v[k]) ? v[j] :
                    v[j] + (v[k] - v[j]) * (i - j) / (k - j))
        end
    end
    Rec(id, ev.duration,
        tw, abp, dabp, icpw,
        col(m, ci(mh, "t")), col(m, ci(mh, "abp")), col(m, ci(mh, "icp")),
        col(b, ci(bh, "t")), col(b, ci(bh, "period")),
        col(b, ci(bh, "icp_mean")), col(b, ci(bh, "icp_amp")),
        ev.abp_base)
end

const RECS = Dict(id => load_rec(id) for id in ("081", "083", "137", "150"))
const TRAIN_IDS   = ("081", "083", "137")
const HOLDOUT_ID  = "150"

# --- parameters: Model_5/Params.jl's cascade, in mmHg·mL·s ------------------
# Nuisance vector x = (E, Psinus, Ro_tot, Rvvs, k_ijvs, Pjc) + Ca — exactly the six
# fit.jl estimates plus its stage-B Ca. Everything else is M3/M5 defaults (÷1330
# where pressure-dimensioned). Derived resistances keep Params.jl's design anchors
# (Pc=25, Pv=15, Pic=10, Pcv=5, Q=12.5) except Ra0, anchored on the PATIENT's
# measured mean ABP — the compact model's stage 0.

function build_params(E, Psinus, Ro_tot, Rvvs, k_ijvs, Pjc, Ca; abp_base, dur)
    Ctot = 1 / (E * (10.0 - 5.0)); Cc = 0.3 * Ctot
    (;  E, Psinus, Rvvs, Pjc, Ca,
        Cv   = Cc - Ca,
        ks   = 1 / (0.7 * Ctot * (10.0 - 5.0)),
        Ro   = 0.069 * Ro_tot,  Rospine = 0.931 * Ro_tot,
        Ra0  = (abp_base - 25.0) / 12.5,  Rc = 0.8,
        Rv0  = (15.0 - Psinus) / 12.5,    Rss = (Psinus - 5.0) / 12.5,
        ktube = k_ijvs, A0 = 0.3, b1 = 2.3, b2 = 7.0, ltube = 20.0, Ntube = 2.0,
        mu = 0.04,
        Rt = 0.03, Rsys = 0.035, Csys = 2.35, Cevp = 1.5, Cazy = 2.5,
        Rivp0 = 0.05, Revp0 = 0.05,
        Razy0 = 8 * 0.04 * pi * 20.0 / (1.0 * 0.6^2) / 1330.0,
        Va0 = 20.0, Vv0 = 30.0, Vivp0 = 20.0, Vevp0 = 20.0, Vazy0 = 12.0,
        Pvv_ref = 6.3, Ppx_ref = 6.0,
        G = 1.5, tau = 20.0, qn = 12.5, qprod = 0.006,
        dCn = 10.0 * Ca, dCp = 0.8 * Ca,
        Pcv = 5.0, Rspine = 201.0 / 1330.0, P0ivp = 2.0, M0 = 1.5,
        Pext0 = 2.0 * 1.0 * 981.0 / 1330.0,
        tauA = 0.02, Racc = 0.1, Rbuf = 1.0, Cbuf = 0.0,   # Cbuf = 0 disables the branch
        jc_on = -3.0, jc_off = dur - 3.0, jc_edge = 6.0)
end

const FIT081 = (E = 1.929946003, Psinus = 7812.084235 / 1330, Ro_tot = 6.59702003e6 / 1330,
                Rvvs = 3465.820286 / 1330, k_ijvs = 6.649041449 / 1330,
                Pjc = 89928.39194 / 1330, Ca = 5.639097744e-6 * 1330)

params_081() = build_params(FIT081.E, FIT081.Psinus, FIT081.Ro_tot, FIT081.Rvvs,
                            FIT081.k_ijvs, FIT081.Pjc, FIT081.Ca;
                            abp_base = RECS["081"].abp_base, dur = RECS["081"].dur)

# --- tube-law inversion table ----------------------------------------------
# g(a) = a^b1 − a^−b2 is monotone; a = g⁻¹(Ptm/k) via one shared table (b1, b2 fixed).
const TL_A = exp.(range(log(0.02), log(40.0), length = 4000))
const TL_G = TL_A .^ 2.3 .- TL_A .^ (-7.0)
function tube_area(y)                       # y = Ptm/k  ->  a = A/A0
    isnan(y)       && return oftype(y, TL_A[1])   # a diverged state; caller aborts on !isfinite
    y <= TL_G[1]   && return oftype(y, TL_A[1])
    y >= TL_G[end] && return oftype(y, TL_A[end])
    i = searchsortedfirst(TL_G, y)
    TL_A[i-1] + (TL_A[i] - TL_A[i-1]) * (y - TL_G[i-1]) / (TL_G[i] - TL_G[i-1])
end

# --- the neural network -----------------------------------------------------
# 2-6-1 tanh, output squashed into [lo, hi]. 25 weights. With W2 = 0 and b2 chosen,
# the initial law is EXACTLY a constant — training starts at M5-as-is, and every
# departure from the initial function is the data's doing.
const NNP = 25
nn_theta0(C0, lo, hi; seed = 7) = begin
    rng = MersenneTwister(seed)
    th = zeros(NNP)
    th[1:12]  .= 0.3 .* randn(rng, 12)              # W1
    th[13:18] .= 0.1 .* randn(rng, 6)               # b1
    # W2 = 0 (19:24); b2 pins the constant
    th[25] = log((C0 - lo) / (hi - C0))
    th
end
@inline function nn_eval(th, x1, x2, lo, hi)
    z = th[25]
    @inbounds for i in 1:6
        h = tanh(th[i] * x1 + th[6+i] * x2 + th[12+i])
        z += th[18+i] * h
    end
    lo + (hi - lo) / (1 + exp(-z))
end

const A_LO, A_HI = 0.002, 0.5        # variant A: Cv ∈ [lo,hi] mL/mmHg
const B_LO, B_HI = 0.02, 8.0         # variant B: C_res

# --- the ODE ----------------------------------------------------------------
# u = (V_a, C_a, q_avg, Pic, Pv, V_v, Psas, P_vv, P_px, P_sys, A, P_res, P_buf)
# law = (variant, θ):  :stock -> P.Cv const, no reservoir
#                      :A     -> Cv = NN(Pic, Pv), no reservoir
#                      :B     -> Cv const, reservoir at the jugular junction

smoother(x) = (s = clamp(x, 0.0, 1.0); s * s * s * (10 + s * (-15 + 6s)))
pext_of(P, t) = P.Pext0 + P.Pjc * (smoother((t - P.jc_on) / P.jc_edge) -
                                   smoother((t - P.jc_off) / P.jc_edge))

@inline function rhs(u::NTuple{13,T}, t, P, Pa, dPa, variant, th)::NTuple{13,T} where {T}
    V_a, C_a, q_avg, Pic, Pv, V_v, Psas, P_vv, P_px, P_sys, A, P_res, P_buf = u

    Ra  = P.Ra0 * (P.Va0 / max(V_a, 1.0))^2
    Pc  = (Pa / Ra + Pv / P.Rc - P.qprod) / (1 / Ra + 1 / P.Rc)
    R_v = P.Rv0 * (P.Vv0 / max(V_v, 1.0))^2
    R_j = 8 * P.mu * pi * P.ltube / (P.Ntube * max(A, 1e-4)^2) / 1330.0

    gB   = variant === :B ? 1.0 : 0.0
    # sinus / jugular-junction 2x2 (Ro valve open, recomputed closed if Pic < Psin)
    a2  = 1 / P.Rss + 1 / R_j + 1 / P.Rvvs + gB / P.Racc
    b2v = P_sys / R_j + P_vv / P.Rvvs + gB * P_res / P.Racc
    a1  = 1 / R_v + 1 / P.Ro + 1 / P.Rss
    b1v = Pv / R_v + Pic / P.Ro
    j   = (b1v / (a1 * P.Rss) + b2v) / (a2 - 1 / (a1 * P.Rss^2))
    s   = (b1v + j / P.Rss) / a1
    go  = 1.0
    if Pic < s
        go  = 0.0
        a1  = 1 / R_v + 1 / P.Rss
        b1v = Pv / R_v
        j   = (b1v / (a1 * P.Rss) + b2v) / (a2 - 1 / (a1 * P.Rss^2))
        s   = (b1v + j / P.Rss) / a1
    end
    q_o  = go * (Pic - s) / P.Ro
    q_v  = (Pv - s) / R_v
    q_sp = (Pic - Psas) / P.Rspine

    # spinal plexus (Marmarou), extracranial plexus, azygos
    M     = max(Psas - P_vv - P.P0ivp, 0.05)
    C_ivp = 1 / (P.ks * M)
    V_ivp = max(P.Vivp0 - log(M / P.M0) / P.ks, 1.0)
    R_ivp = P.Rivp0 * (P.Vivp0 / V_ivp)^2
    V_evp = max(P.Vevp0 + P.Cevp * (P_vv - P.Pvv_ref), 1.0)
    R_evp = P.Revp0 * (P.Vevp0 / V_evp)^2
    V_azy = max(P.Vazy0 + P.Cazy * (P_px - P.Ppx_ref), 1.0)
    R_azy = P.Razy0 * (P.Vazy0 / V_azy)^2
    q_ivp = (P_vv - P_px) / R_ivp
    q_evp = (P_vv - P_px) / R_evp
    q_azy = (P_px - P_sys) / R_azy
    q_os  = max(Psas - P_px, 0.0) / P.Rospine

    # autoregulation (AutoregUrsinoLodi, transcribed).
    # The exponent is CLAMPED, and that is not a fudge: G/(ΔC/4) is ~1000 here, so
    # exp() overflows for |x| > 0.04 and the fixed-step RK4 dies where M5's implicit
    # Rodas5P survives. σ's two limits as e→0/∞ are (Ca ± ΔC/2) either way, so
    # clamping at ±40 saturates the sigmoid exactly where it was already saturated.
    # Without it 083 and 137 diverge at x0 — their lower baseline ABP (78.7, 79.0 vs
    # 87.3, 88.6) means a lower Ra0, higher flow, and x sitting well above zero.
    x  = (q_avg - P.qn) / P.qn
    dC = P.dCn + (P.dCp - P.dCn) / (1 + exp(-clamp(10x, -40.0, 40.0)))
    e  = exp(clamp(P.G * x / (dC / 4), -40.0, 40.0))
    sig = ((P.Ca + dC / 2) + (P.Ca - dC / 2) * e) / (1 + e)
    dCa_dt = (sig - C_a) / P.tau

    Cvl = variant === :A ? nn_eval(th, (Pic - 12) / 8, (Pv - 12) / 8, A_LO, A_HI) : T(P.Cv)

    dVv  = (Pc - Pv) / P.Rc - q_v
    q_buf = P.Cbuf > 0 ? (Pic - P_buf) / P.Rbuf : zero(T)
    dPic = (C_a * dPa + dCa_dt * (Pa - Pic) + dVv + P.qprod - q_o - q_sp - q_buf) / C_a
    dPv  = dPic + dVv / Cvl
    dVa  = C_a * (dPa - dPic) + dCa_dt * (Pa - Pic)
    dqav = (Pa - Pc) / Ra + dVa - q_avg

    b_vv  = (j - P_vv) / P.Rvvs - (P_vv - P_sys) / P.Rt - q_ivp - q_evp
    dPvv  = (b_vv + q_sp - q_os) / P.Cevp
    dPsas = dPvv + (q_sp - q_os) / C_ivp
    dPpx  = (q_ivp + q_evp + q_os - q_azy) / P.Cazy

    Pxt   = pext_of(P, t)
    A_alg = P.A0 * tube_area((j - Pxt) / P.ktube)
    dA    = (A_alg - A) / P.tauA
    q_tin = (j - P_sys) / R_j
    dPsys = (q_tin - dA * P.ltube * P.Ntube + (P_vv - P_sys) / P.Rt + q_azy -
             (P_sys - P.Pcv) / P.Rsys) / P.Csys

    dPres = gB == 1.0 ?
        (j - P_res) / (P.Racc * nn_eval(th, (j - 30) / 30, (Pxt - 35) / 35, B_LO, B_HI)) :
        zero(T)

    dPbuf = P.Cbuf > 0 ? q_buf / P.Cbuf : zero(T)
    (dVa, dCa_dt, dqav, dPic, dPv, dVv, dPsas, dPvv, dPpx, dPsys, dA, dPres, dPbuf)
end

# --- solver -----------------------------------------------------------------

function init_state(P, ::Type{T}) where {T}
    a0 = P.A0 * tube_area((6.5 - P.Pext0) / P.ktube)
    T.((20.0, P.Ca, 12.5, 10.0, 15.0, 30.0, 10.0, 6.3, 6.0, 5.6, a0, 6.5, 10.0))
end

# fixed-step RK4 from t0 to t1; drive by linear interpolation on the 0.01 s grid.
# `store_every` in steps; returns (t_out, Pic_out, Pv_out) sampled on the data grid.
function solve_run(P, tgrid, abp, dabp, t0, t1, dt, variant, th::AbstractVector{T};
                   u0 = nothing, settle = 0.0, store = true, fs = 100.0) where {T}
    lerp = (v, t) -> begin
        x = (t - tgrid[1]) * fs
        i = clamp(floor(Int, x) + 1, 1, length(v) - 1)
        v[i] + (v[i+1] - v[i]) * (x - (i - 1))
    end
    u = u0 === nothing ? init_state(P, T) : u0
    if settle > 0                                    # constant-Pa spin-up, no pulse
        n0  = clamp(round(Int, 10 * fs), 1, length(abp))
        Pa0 = mean(@view abp[1:n0])
        nst = round(Int, settle / 1e-3)
        for _ in 1:nst
            u = rk4step(u, P.jc_on - 1e3, 1e-3, P, Pa0, 0.0, variant, th)
        end
    end
    nsteps = round(Int, (t1 - t0) / dt)
    per    = max(1, round(Int, 0.01 / dt))
    nout   = store ? nsteps ÷ per + 1 : 1
    tout   = Vector{Float64}(undef, nout)
    icp    = Vector{T}(undef, nout); pv = Vector{T}(undef, nout)
    k = 1
    if store; tout[1] = t0; icp[1] = u[4]; pv[1] = u[5]; end
    t = t0
    for istep in 1:nsteps
        u = rk4step(u, t, dt, P, lerp(abp, t + dt / 2), lerp(dabp, t + dt / 2), variant, th)
        t = t0 + istep * dt
        if store && istep % per == 0
            k += 1; tout[k] = t; icp[k] = u[4]; pv[k] = u[5]
        end
        isfinite(u[4]) || return (tout[1:k], icp[1:k], pv[1:k], u, false)
    end
    (tout[1:k], icp[1:k], pv[1:k], u, true)
end

@inline function rk4step(u, t, dt, P, Pa, dPa, variant, th)
    k1 = rhs(u, t, P, Pa, dPa, variant, th)
    u2 = ntuple(i -> u[i] + 0.5dt * k1[i], 13)
    k2 = rhs(u2, t + 0.5dt, P, Pa, dPa, variant, th)
    u3 = ntuple(i -> u[i] + 0.5dt * k2[i], 13)
    k3 = rhs(u3, t + 0.5dt, P, Pa, dPa, variant, th)
    u4 = ntuple(i -> u[i] + dt * k3[i], 13)
    k4 = rhs(u4, t + dt, P, Pa, dPa, variant, th)
    ntuple(i -> u[i] + dt / 6 * (k1[i] + 2k2[i] + 2k3[i] + k4[i]), 13)
end

const DT_PULSE = parse(Float64, get(ENV, "_DT", "5e-4"))
const DT_MEAN  = 5e-4   # was 1e-3: 150 diverged there, and a divergent
                        # objective is worse than an out-of-bounds one (see prefit_one)

pulsatile(P, r::Rec, variant, th; t1 = r.dur + 180.0) =
    solve_run(P, r.tw, r.abp, r.dabp, -120.0, t1, DT_PULSE, variant, th; settle = 300.0)

function meanrun(P, r::Rec)
    zdabp = zeros(length(r.tm))
    solve_run(P, r.tm, r.abpm, zdabp, -120.0, r.dur + 179.0, DT_MEAN, :stock,
              Float64[]; settle = 300.0, fs = 1.0)
end

# --- scoring ----------------------------------------------------------------

# per-beat mean and amplitude of the model ICP, on the RECORDING's own beat brackets —
# the same statistic prep_jugular_data.py computed on the recording.
function beat_stats(r::Rec, tout, icp; tlo = -60.0, thi = r.dur + 120.0)
    tb = Float64[]; am = eltype(icp)[]; mm = eltype(icp)[]; ad = Float64[]; md = Float64[]
    for (t0, per, m_d, a_d) in zip(r.bt, r.bper, r.bicpm, r.bamp)
        (t0 >= tlo && t0 + per <= thi) || continue
        i1 = clamp(round(Int, (t0 - tout[1]) * 100) + 1, 1, length(icp))
        i2 = clamp(round(Int, (t0 + per - tout[1]) * 100) + 1, 1, length(icp))
        i2 - i1 < 20 && continue
        seg = @view icp[i1:i2]
        push!(tb, t0); push!(am, maximum(seg) - minimum(seg)); push!(mm, mean(seg))
        push!(ad, a_d); push!(md, m_d)
    end
    (t = tb, amp_m = am, mean_m = mm, amp_d = ad, mean_d = md)
end

winmed(t, v, lo, hi) = (m = (t .>= lo) .& (t .<= hi); any(m) ? median(v[m]) : NaN)

function amp_summary(r::Rec, bs)
    (base = winmed(bs.t, bs.amp_m, -60.0, -10.0),
     plat = winmed(bs.t, bs.amp_m, 20.0, r.dur - 10.0),
     post = winmed(bs.t, bs.amp_m, r.dur + 40.0, r.dur + 120.0),
     base_d = winmed(bs.t, bs.amp_d, -60.0, -10.0),
     plat_d = winmed(bs.t, bs.amp_d, 20.0, r.dur - 10.0),
     post_d = winmed(bs.t, bs.amp_d, r.dur + 40.0, r.dur + 120.0))
end

# --- nuisance persistence ---------------------------------------------------

nuis_path(id) = joinpath(FDIR, "$(id)_compact.jl")
function save_nuis(id, x, rmse, ca, campnote)
    open(nuis_path(id), "w") do io
        println(io, "# GENERATED by Model_6/ude_cv.jl _STAGE=prefit — patient $id, $(round(rmse, digits=3)) mmHg mean-ICP RMSE")
        println(io, "# $campnote")
        println(io, "(E = $(x[1]), Psinus = $(x[2]), Ro_tot = $(x[3]), Rvvs = $(x[4]),")
        println(io, " k_ijvs = $(x[5]), Pjc = $(x[6]), Ca = $ca)")
    end
end
load_nuis(id) = include(nuis_path(id))

function params_for(id)
    r = RECS[id]
    if id == "081" && !isfile(nuis_path(id))
        return params_081()
    end
    nu = load_nuis(id)
    build_params(nu.E, nu.Psinus, nu.Ro_tot, nu.Rvvs, nu.k_ijvs, nu.Pjc, nu.Ca;
                 abp_base = r.abp_base, dur = r.dur)
end

# --- stages -----------------------------------------------------------------

function stage_smoke()
    P = params_081(); r = RECS["081"]
    t, icp, pv, u, ok = solve_run(P, r.tw, r.abp, r.dabp, -120.0, -90.0, DT_PULSE,
                                  :stock, Float64[]; settle = 300.0)
    @printf("smoke: ok=%s  ICP %.2f..%.2f  Pv %.2f..%.2f  A=%.3f  final=%s\n",
            ok, minimum(icp), maximum(icp), minimum(pv), maximum(pv), u[11],
            join(round.(collect(u), digits = 3), " "))
end

function stage_gate()
    P = params_081(); r = RECS["081"]
    t, icp, pv, _, ok = pulsatile(P, r, :stock, Float64[])
    ok || error("gate solve diverged")
    bs = beat_stats(r, t, icp; tlo = -110.0, thi = r.dur + 170.0)
    s  = amp_summary(r, bs)
    mbase = winmed(bs.t, bs.mean_m, -60.0, -10.0)
    mplat = winmed(bs.t, bs.mean_m, 20.0, r.dur - 10.0)
    mpost = winmed(bs.t, bs.mean_m, r.dur + 40.0, r.dur + 120.0)
    txt = @sprintf("""
    GATE — compact model, 081 fitted params, stock law   (M5 published / recording)
      mean ICP  base %6.2f  (M5 8.17 / rec 9.25)
                plat %6.2f  (M5 17.87 / rec 19.52)   step %+.2f (M5 +9.71 / rec +10.28)
                post %6.2f  (M5 7.70 / rec 8.11)
      beat AMP  base %6.2f  (M5 2.32 / rec 3.81)
                plat %6.2f  (M5 22.46 / rec 4.01)    ratio %.1fx (M5 9.7x / rec 1.05x)
                post %6.2f  (M5 1.69 / rec 3.83)
    """, mbase, mplat, mplat - mbase, mpost, s.base, s.plat, s.plat / s.base, s.post)
    print(txt)
    write(joinpath(OUT, "gate.txt"), txt)
    open(joinpath(OUT, "gate_trace.csv"), "w") do io
        println(io, "t,icp_model,icp_amp_model_beat")
        for (tt, mm) in zip(t, icp); @printf(io, "%.2f,%.4f,\n", tt, mm); end
    end
end

const NUIS_LO = [0.15, 5.2, 8.0e2, 0.3, 8.0e-4, 15.0]
const NUIS_HI = [5.0, 9.0, 2.0e4, 12.0, 0.2, 80.0]

function prefit_one(id; maxiter = parse(Int, get(ENV, "_NM_ITERS", "400")))
    r = RECS[id]
    mask = (r.tm .>= -110.0) .& (r.tm .<= r.dur + 165.0)
    tt, target = r.tm[mask], r.icpm[mask]
    x0 = [FIT081.E, FIT081.Psinus, FIT081.Ro_tot, FIT081.Rvvs, FIT081.k_ijvs, FIT081.Pjc]
    lg(x)  = [x[1], x[2], log(x[3]), log(x[4]), log(x[5]), x[6]]
    unlg(z) = [z[1], z[2], exp(z[3]), exp(z[4]), exp(z[5]), z[6]]
    evals = Ref(0); ndiv = Ref(0)
    function obj(z)
        x = unlg(z)
        pen = 0.0
        for (v, lo, hi) in zip(x, NUIS_LO, NUIS_HI)
            v < lo && (pen += 1e3 * (lo - v)^2 / max(lo, 1e-3)^2)
            v > hi && (pen += 1e3 * (v - hi)^2 / hi^2)
        end
        Cv = 0.3 / (x[1] * 5) - FIT081.Ca
        Cv < 2.5e-3 && (pen += 1e4 * (2.5e-3 - Cv)^2 * 1e6)
        # Infeasible is the WORST outcome available. It has to be: with the old
        # ordering (penalty 1e3, divergence 1e4) a simplex that met a divergent region
        # scored better OUTSIDE the bounds than inside, so it left the box, pinned Pjc
        # at its ceiling and reported "RMSE 1000.000 after 0 evals" — 150, first run.
        pen > 0 && return 1e5 + pen
        P = build_params(x..., FIT081.Ca; abp_base = r.abp_base, dur = r.dur)
        t, icp, _, _, ok = meanrun(P, r)
        ok || (ndiv[] += 1; return 1e4)
        mod = [icp[clamp(round(Int, (τ + 120.0) * 100) + 1, 1, length(icp))] for τ in tt]
        evals[] += 1
        sqrt(mean((mod .- target) .^ 2))
    end
    res = optimize(obj, lg(x0), NelderMead(),
                   Optim.Options(iterations = maxiter, show_trace = false))
    x = unlg(Optim.minimizer(res))
    rmse = Optim.minimum(res)
    @printf("prefit %s: RMSE %.3f mmHg after %d solves (%d diverged)  x = %s\n",
            id, rmse, evals[], ndiv[], join(round.(x, sigdigits = 4), ", "))
    rmse > 100 && @warn "prefit $id never found a feasible, stable point — result is NOT usable"
    x, rmse
end

# compact stage B: 1-D Ca scan against the measured BASELINE beat amplitude
function ca_scan(id, x; cas = exp.(range(log(0.002), log(0.03), length = 7)))
    r = RECS[id]
    best, bca, curve = Inf, FIT081.Ca, Tuple{Float64,Float64}[]
    for ca in cas
        (0.3 / (x[1] * 5) - ca) < 2.5e-3 && continue
        P = build_params(x..., ca; abp_base = r.abp_base, dur = r.dur)
        t, icp, _, _, ok = solve_run(P, r.tw, r.abp, r.dabp, -120.0, 0.0, DT_PULSE,
                                     :stock, Float64[]; settle = 300.0)
        ok || continue
        bs = beat_stats(r, t, icp; tlo = -60.0, thi = -5.0)
        isempty(bs.amp_m) && continue
        a = median(bs.amp_m); d = abs(a - median(bs.amp_d))
        push!(curve, (ca, a))
        d < best && (best = d; bca = ca)
    end
    note = "Ca scan (baseline AMP): " * join(["$(round(c, sigdigits=3))=>$(round(a, digits=2))" for (c, a) in curve], "  ")
    @printf("  %s  -> Ca = %.4g (|Δamp| %.2f mmHg)\n", note, bca, best)
    bca, note
end

function stage_prefit()
    ids = split(get(ENV, "_PATIENTS", "083,137,150,081"), ",")
    for id in ids
        id = String(strip(id))
        if id == "081"
            x = [FIT081.E, FIT081.Psinus, FIT081.Ro_tot, FIT081.Rvvs, FIT081.k_ijvs, FIT081.Pjc]
            ca, note = ca_scan(id, x)
            save_nuis(id, x, NaN, ca, "nuisances = M5 fit/081.jl verbatim; " * note)
        else
            x, rmse = prefit_one(id)
            ca, note = ca_scan(id, x)
            save_nuis(id, x, rmse, ca, note)
        end
    end
end

# --- training ---------------------------------------------------------------

function make_loss(variant)
    bundles = [(RECS[id], params_for(id)) for id in TRAIN_IDS]
    function loss(th::AbstractVector{T}) where {T}
        parts = Vector{T}(undef, length(bundles))
        Threads.@threads for bi in eachindex(bundles)
            r, P = bundles[bi]
            t, icp, _, _, ok = pulsatile(P, r, variant, th; t1 = r.dur + 120.0)
            part = zero(T)
            if !ok
                part = T(1e6)
            else
                bs = beat_stats(r, t, icp)
                if isempty(bs.amp_m)
                    part = T(1e6)
                else
                    for i in eachindex(bs.amp_m)
                        part += log(max(bs.amp_m[i], T(0.05)) / bs.amp_d[i])^2
                        part += 0.5 * ((bs.mean_m[i] - bs.mean_d[i]) / 2.0)^2
                    end
                end
            end
            parts[bi] = part
        end
        total = sum(parts)
        reg = zero(T)
        for i in 1:12; reg += th[i]^2; end
        for i in 19:24; reg += th[i]^2; end
        total + T(1e-3) * reg
    end
end

nn_path(v)  = joinpath(FDIR, "nn_$(v).jl")        # FINAL: this variant is done
ckpt_path(v) = joinpath(FDIR, "nn_$(v).ckpt.jl")   # PARTIAL: written every 5 iters
function save_nn(v, th, note; final = true)
    open(final ? nn_path(v) : ckpt_path(v), "w") do io
        println(io, "# GENERATED by Model_6/ude_cv.jl _STAGE=train _VARIANT=$v")
        println(io, "# $note")
        println(io, "[", join(th, ",\n "), "]")
    end
end

function stage_train()
    v  = Symbol(get(ENV, "_VARIANT", "A"))
    it = parse(Int, get(ENV, "_MAXITER", "120"))
    th0, src = isfile(nn_path(v))  ? (Float64.(include(nn_path(v))),  "final weights") :
               isfile(ckpt_path(v)) ? (Float64.(include(ckpt_path(v))), "checkpoint") :
               ((v === :A ? nn_theta0(params_for("081").Cv, A_LO, A_HI) :
                            nn_theta0(0.04, B_LO, B_HI)), "cold start (= M5 constant law)")
    println("train $v: resuming from $src")
    # NOTE: LBFGS's inverse-Hessian history is NOT checkpointed. A resume restarts the
    # quasi-Newton approximation at the saved weights — correct, but it re-spends a few
    # iterations rebuilding curvature. _MAXITER counts fresh, so a resume grants another
    # full _MAXITER iterations rather than the remainder.
    L = make_loss(v)
    t0 = time()
    @printf("train %s: initial loss %.4f  (%.1f s/eval)\n", v, L(th0), time() - t0)
    nit = Ref(0)
    cb = st -> begin
        nit[] += 1
        if nit[] % 5 == 0
            save_nn(v, st.metadata["x"], "checkpoint iter $(nit[]), loss $(st.value)";
                    final = false)
            @printf("  iter %3d  loss %.4f  (%.0f s elapsed)\n", nit[], st.value, time() - t0)
            flush(stdout)
        end
        false
    end
    res = optimize(L, th0, LBFGS(),
                   Optim.Options(iterations = it, show_trace = false, callback = cb,
                                 extended_trace = true, g_tol = 1e-8);
                   autodiff = :forward)
    th = Optim.minimizer(res)
    save_nn(v, th, "trained on $(join(TRAIN_IDS, "+")), holdout $(HOLDOUT_ID); " *
                   "final loss $(Optim.minimum(res)) after $(nit[]) iters, " *
                   "$(round((time() - t0) / 60, digits = 1)) min")
    @printf("train %s done: loss %.4f -> %.4f in %.1f min\n",
            v, L(th0), Optim.minimum(res), (time() - t0) / 60)
end

# --- read: run everything, draw everything ----------------------------------

function stage_read()
    laws = Any[("stock", :stock, Float64[])]
    for v in (:A, :B)
        f = isfile(nn_path(v)) ? nn_path(v) : isfile(ckpt_path(v)) ? ckpt_path(v) : nothing
        f === nothing && continue
        tag = f == nn_path(v) ? "UDE-$v" : "UDE-$v(partial)"
        push!(laws, (tag, v, Float64.(include(f))))
    end
    ids = ["081", "083", "137", "150"]
    results = Dict{Tuple{String,String},Any}()
    report = IOBuffer()
    println(report, "# Model 6 — learned venous compliance, results\n")
    println(report, "| patient | law | AMP base | AMP plat | ratio | data ratio | ΔICP | data ΔICP |")
    println(report, "|---|---|---|---|---|---|---|---|")
    for id in ids
        r = RECS[id]; P = params_for(id)
        for (lname, v, th) in laws
            t, icp, pv, _, ok = pulsatile(P, r, v, th)
            bs = ok ? beat_stats(r, t, icp; tlo = -110.0, thi = r.dur + 170.0) : nothing
            results[(id, lname)] = (t = t, icp = icp, pv = pv, bs = bs, ok = ok)
            ok || continue
            s = amp_summary(r, bs)
            mb = winmed(bs.t, bs.mean_m, -60.0, -10.0)
            mp = winmed(bs.t, bs.mean_m, 20.0, r.dur - 10.0)
            hold = id == HOLDOUT_ID ? " (holdout)" : ""
            @printf(report, "| %s%s | %s | %.2f | %.2f | %.1f | %.2f | %+.2f | %+.2f |\n",
                    id, hold, lname, s.base, s.plat, s.plat / s.base,
                    s.plat_d / s.base_d, mp - mb, r === nothing ? NaN :
                    (JC_EVENTS[id].icp_plateau - JC_EVENTS[id].icp_base))
        end
    end

    # per-beat AMP, four panels
    pls = []
    for id in ids
        r = RECS[id]
        p = plot(title = "$(id)$(id == HOLDOUT_ID ? " (holdout)" : "") — ICP pulse amplitude per beat",
                 xlabel = "t (s, 0 = compression onset)", ylabel = "AMP (mmHg)",
                 legend = (id == ids[1] ? :topleft : false), titlefontsize = 9)
        scatter!(p, r.bt, r.bamp; ms = 1.6, ma = 0.5, mc = :black, label = "recording")
        for (lname, _, _) in laws
            res = results[(id, lname)]
            res.ok || continue
            plot!(p, res.bs.t, res.bs.amp_m; lw = 1.6, label = lname)
        end
        vspan!(p, [0, r.dur]; alpha = 0.08, color = :orange, label = "")
        push!(pls, p)
    end
    plot(pls...; layout = (2, 2), size = (1200, 750)) |> p -> savefig(p, joinpath(OUT, "amp_per_beat.png"))

    # mean ICP, four panels
    pls = []
    for id in ids
        r = RECS[id]
        p = plot(title = "$id — mean ICP", xlabel = "t (s)", ylabel = "ICP (mmHg)",
                 legend = (id == ids[1] ? :topleft : false), titlefontsize = 9)
        plot!(p, r.tm, r.icpm; lc = :black, lw = 1.2, label = "recording (1 Hz mean)")
        for (lname, _, _) in laws
            res = results[(id, lname)]
            res.ok || continue
            plot!(p, res.bs.t, res.bs.mean_m; lw = 1.4, label = lname)
        end
        push!(pls, p)
    end
    plot(pls...; layout = (2, 2), size = (1200, 750)) |> p -> savefig(p, joinpath(OUT, "mean_icp.png"))

    # the learned law, read directly
    for (lname, v, th) in laws
        v === :stock && continue
        lo, hi = v === :A ? (A_LO, A_HI) : (B_LO, B_HI)
        xs = v === :A ? range(4, 26, 120) : range(0, 90, 120)     # Pic | P_j
        ys = v === :A ? range(4, 26, 120) : range(0, 75, 120)     # Pv  | Pext
        f(x, y) = v === :A ? nn_eval(th, (x - 12) / 8, (y - 12) / 8, lo, hi) :
                             nn_eval(th, (x - 30) / 30, (y - 35) / 35, lo, hi)
        hm = heatmap(xs, ys, [f(x, y) for y in ys, x in xs];
                     xlabel = v === :A ? "Pic (mmHg)" : "P_j (mmHg)",
                     ylabel = v === :A ? "Pv (mmHg)" : "Pext (mmHg)",
                     title = "learned $(v === :A ? "Cv(Pic, Pv)" : "C_res(P_j, Pext)") — $lname",
                     colorbar_title = "mL/mmHg")
        res = results[("081", lname)]
        if res.ok && v === :A
            ii = 1:25:length(res.icp)
            scatter!(hm, res.icp[ii], res.pv[ii]; ms = 1, mc = :white, ma = 0.35,
                     label = "081 trajectory")
        end
        savefig(hm, joinpath(OUT, "learned_law_$(lname).png"))
        # the law along 081's trajectory vs the constant it replaced
        if v === :A && res.ok
            cvt = [nn_eval(th, (res.icp[i] - 12) / 8, (res.pv[i] - 12) / 8, lo, hi)
                   for i in eachindex(res.icp)]
            p = plot(res.t, cvt; lw = 1.2, label = "learned Cv along 081",
                     xlabel = "t (s)", ylabel = "Cv (mL/mmHg)",
                     title = "learned law along the manoeuvre vs M5's constant")
            hline!(p, [params_for("081").Cv]; ls = :dash, lc = :black,
                   label = "M5 constant Cv_expr")
            vspan!(p, [0, RECS["081"].dur]; alpha = 0.08, color = :orange, label = "")
            savefig(p, joinpath(OUT, "cv_along_trajectory.png"))
        end
    end

    write(joinpath(OUT, "report.md"), String(take!(report)))
    println("read: wrote report.md + PNGs to $OUT")
end

# --- dispatch ---------------------------------------------------------------

const STAGE = get(ENV, "_STAGE", "smoke")

# Plots is loaded at TOP LEVEL, and only for the stage that draws. Doing the
# `@eval using Plots` *inside* stage_read() raised "method too new to be called from
# this world context": the function was already compiled in an older world age, so the
# plot() methods that `using` had just introduced were invisible to its own call sites.
# Loading here and calling stage_read() from a later top-level statement fixes it,
# because that call happens in the new world.
if STAGE == "read"
    ENV["GKSwstype"] = "100"          # headless GR
    @eval using Plots
end

STAGE == "smoke"  ? stage_smoke()  :
STAGE == "gate"   ? stage_gate()   :
STAGE == "prefit" ? stage_prefit() :
STAGE == "train"  ? stage_train()  :
STAGE == "read"   ? stage_read()   :
error("unknown _STAGE=$STAGE (smoke|gate|prefit|train|read)")
