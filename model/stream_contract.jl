# The streaming contract — everything an estimator must agree on to write api/stream/.
# ---------------------------------------------------------------------------
# Two estimators write these streams (stream_refit.jl, the expanding-window batch fit, and
# stream_filter.jl, the sequential filter). They disagree about almost everything internally
# and MUST agree about this: which six quantities are streamed, how a fitted parameter maps
# to a clinical one, where the bounds sit, and the exact bytes of a record. Held here so the
# two cannot drift apart — a divergence would be invisible in the API and would silently
# mean two different things by "healthy".
#
# Include AFTER defining PATIENT: the craniospinal derivation reads JC_EVENTS[PATIENT].

const PNAMES = ["E", "Psinus", "Ro_tot", "Rvvs", "k_ijvs", "Ca"]   # Pjc held: operator, not patient
const LO = [0.15, 5.2, 2.0e2, 0.02, 5.0e-4, 3.0e-3]
const HI = [5.00, 12.0, 5.0e4, 30.0, 0.50,  0.10]

# fitted-parameter -> streamed clinical quantity (must match model/api_spec.jl)
const TL_A2 = exp.(range(log(0.02), log(40.0), length = 4000))
const TL_G2 = TL_A2 .^ 2.3 .- TL_A2 .^ (-7.0)
jug_area(k) = 0.3 * begin
    y = (6.5 - 2.0 * 981.0 / 1330.0) / k
    y <= TL_G2[1] ? TL_A2[1] : y >= TL_G2[end] ? TL_A2[end] :
    (i = searchsortedfirst(TL_G2, y);
     TL_A2[i-1] + (TL_A2[i] - TL_A2[i-1]) * (y - TL_G2[i-1]) / (TL_G2[i] - TL_G2[i-1]))
end
const DERIVE = Dict(
  "craniospinal_compliance"       => θ -> 1.0 / (θ[1] * max(JC_EVENTS[PATIENT].icp_base - 5.0, 0.5)),
  "sagittal_sinus_pressure"       => θ -> θ[2],
  "csf_outflow_resistance"        => θ -> 0.069 * 0.931 * θ[3] / 60.0,
  "collateral_outflow_resistance" => θ -> θ[4],
  "jugular_resting_area"          => θ -> jug_area(θ[5]),
  "arterial_compliance"           => θ -> θ[6],
)
const BOUNDS = Dict(   # (min_path, min_healthy, max_healthy, max_path)
  "craniospinal_compliance"       => (0.10, 0.50, 1.10, 2.00),
  "sagittal_sinus_pressure"       => (2.0,  5.0,  8.0, 15.0),
  "csf_outflow_resistance"        => (3.0,  6.0, 10.0, 18.0),
  "collateral_outflow_resistance" => (0.01, 0.02, 0.20, 2.00),
  "jugular_resting_area"          => (0.30, 0.80, 2.00, 4.00),
  "arterial_compliance"           => (0.005, 0.015, 0.050, 0.100),
)

# which fitted parameter each streamed quantity derives from — the uncertainty on the
# derived value is the SOURCE parameter's fractional sigma, carried through the derivation
const SRC_INDEX = Dict(
  "craniospinal_compliance" => 1, "sagittal_sinus_pressure"       => 2,
  "csf_outflow_resistance"  => 3, "collateral_outflow_resistance" => 4,
  "jugular_resting_area"    => 5, "arterial_compliance"           => 6,
)

const IDENT_MAX_SIGMA = 0.5        # fractional sd below which a value is worth reporting

function classify(v, b)
    (mn_p, mn_h, mx_h, mx_p) = b
    v < mn_p || v > mx_p ? "pathological" :
    v < mn_h || v > mx_h ? "borderline"   : "healthy"
end

"""
    emit_record(io, t_end, value, σ_frac, key, rmse, n_solves)

Write one stream record and flush, so a reader sees it immediately. `σ_frac` is the
fractional (log-space) sd of the source parameter; NaN means "no information at all".

isfinite, not isnan, on the bounds: a large-but-finite sigma overflows exp(1.96σ) to Inf,
and a bare `Inf` is not valid JSON — every client silently drops the whole record. That
would lose exactly the wide windows the stream exists to show. `null` is in the contract.
"""
function emit_record(io, t_end, value, σ_frac, key, rmse, n_solves)
    lo_, hi_ = isnan(σ_frac) ? (NaN, NaN) :
               (value * exp(-1.96σ_frac), value * exp(1.96σ_frac))
    ident = !isnan(σ_frac) && σ_frac < IDENT_MAX_SIGMA
    st    = ident ? classify(value, BOUNDS[key]) : "unidentifiable"
    println(io,
        "{\"t_end\": $(round(t_end, digits=2)), \"value\": $(round(value, sigdigits=6)), " *
        "\"ci_lo\": $(isfinite(lo_) ? round(lo_, sigdigits=6) : "null"), " *
        "\"ci_hi\": $(isfinite(hi_) ? round(hi_, sigdigits=6) : "null"), " *
        "\"status\": \"$st\", \"identifiable\": $(ident), " *
        "\"rmse\": $(round(rmse, digits=4)), \"n_solves\": $(n_solves)}")
    flush(io)
    (ident, st)
end

"""
    take_stream_lock(dir)

Refuse to start if another estimator is already writing this patient's streams.

Both estimators open the six .jsonl files with "w". Two of them at once truncate each other
and then interleave records at their own file offsets, and the damage is quiet: every line
still parses, so the API serves a coherent-looking mixture of two different runs. A guard in
any one client cannot prevent this — the second writer is usually a terminal — so the guard
belongs here, in the thing doing the writing.

Advisory, by pid, released at exit and reclaimed automatically if the holder died.
"""
function take_stream_lock(dir)
    lockfile = joinpath(dir, ".writer.pid")
    alive(pid) = @static Sys.islinux() ? isdir("/proc/$pid") :
                 success(`kill -0 $pid`)
    if isfile(lockfile)
        old = tryparse(Int, strip(read(lockfile, String)))
        if old !== nothing && old != getpid() && alive(old)
            error("""

                another estimator (pid $old) is already writing $dir
                Two writers truncate and interleave each other's records, so this one is
                refusing to start. Stop that one first (kill $old), or set _PATIENT to a
                patient nobody else is fitting, or _SDIR to write somewhere else.
                """)
        end
    end
    write(lockfile, string(getpid()))
    atexit() do
        try
            isfile(lockfile) && strip(read(lockfile, String)) == string(getpid()) &&
                rm(lockfile; force = true)
        catch
        end
    end
end
