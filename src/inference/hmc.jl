###
### Sampler states
###

mutable struct HMCState{
    TV <: TypedVarInfo,
    TTraj<:AHMC.AbstractTrajectory,
    TAdapt<:AHMC.Adaptation.AbstractAdaptor,
    PhType <: AHMC.PhasePoint
} <: AbstractSamplerState
    vi       :: TV
    eval_num :: Int
    i        :: Int
    traj     :: TTraj
    h        :: AHMC.Hamiltonian
    adaptor  :: TAdapt
    z        :: PhType
end

##########################
# Hamiltonian Transition #
##########################

struct HamiltonianTransition{T, NT<:NamedTuple, F<:AbstractFloat} <: AbstractTransition
    θ    :: T
    lp   :: F
    stat :: NT
end

function HamiltonianTransition(spl::Sampler{<:Hamiltonian}, t::T) where T<:AHMC.Transition
    theta = tonamedtuple(spl.state.vi)
    lp = getlogp(spl.state.vi)
    return HamiltonianTransition(theta, lp, t.stat)
end

transition_type(spl::Sampler{<:Union{StaticHamiltonian, AdaptiveHamiltonian}}) = 
    HamiltonianTransition

function additional_parameters(::Type{<:HamiltonianTransition})
    return [:lp,:stat]
end


###
### Hamiltonian Monte Carlo samplers.
###

"""
    HMC(ϵ::Float64, n_leapfrog::Int)

Hamiltonian Monte Carlo sampler with static trajectory.

Arguments:

- `ϵ::Float64` : The leapfrog step size to use.
- `n_leapfrog::Int` : The number of leapfrop steps to use.

Usage:

```julia
HMC(0.05, 10)
```

Tips:

- If you are receiving gradient errors when using `HMC`, try reducing the
`step_size` parameter, e.g.

```julia
# Original step_size
sample(gdemo([1.5, 2]), HMC(1000, 0.1, 10))

# Reduced step_size.
sample(gdemo([1.5, 2]), HMC(1000, 0.01, 10))
```
"""
mutable struct HMC{AD, space, metricT <: AHMC.AbstractMetric} <: StaticHamiltonian{AD}
    ϵ           ::  Float64   # leapfrog step size
    n_leapfrog  ::  Int       # leapfrog step number
end

transition_type(::Sampler{<:Hamiltonian}) = Transition
alg_str(::Sampler{<:Hamiltonian}) = "HMC"

HMC(args...) = HMC{ADBackend()}(args...)
function HMC{AD}(ϵ::Float64, n_leapfrog::Int, ::Type{metricT}, space::Tuple) where {AD, metricT <: AHMC.AbstractMetric}
    return HMC{AD, space, metricT}(ϵ, n_leapfrog)
end
function HMC{AD}(
    ϵ::Float64,
    n_leapfrog::Int,
    ::Tuple{};
    kwargs...
) where AD
    return HMC{AD}(ϵ, n_leapfrog; kwargs...)
end
function HMC{AD}(
    ϵ::Float64,
    n_leapfrog::Int,
    space::Symbol...;
    metricT=AHMC.UnitEuclideanMetric
) where AD
    return HMC{AD}(ϵ, n_leapfrog, metricT, space)
end

function sample_init!(
    rng::AbstractRNG,
    model::Model,
    spl::Sampler{<:Hamiltonian},
    N::Integer;
    verbose::Bool=true,
    resume_from=nothing,
    kwargs...
) where T<:Hamiltonian

    # Resume the sampler.
    set_resume!(spl; resume_from=resume_from, kwargs...)

    # Get `init_theta`
    initialize_parameters!(spl; verbose=verbose, kwargs...)

    # Set the defualt number of adaptations, if relevant.
    if spl.alg isa AdaptiveHamiltonian
        # If there's no chain passed in, verify the n_adapts.
        if resume_from === nothing
            if spl.alg.n_adapts == 0
                n_adapts_default = Int(round(N / 2))
                spl.alg.n_adapts = n_adapts_default > 1000 ? 1000 : n_adapts_default
            else
                # Verify that n_adapts is less than the samples to draw.
                spl.alg.n_adapts < N || !ismissing(resume_from) ?
                    nothing :
                    throw(ArgumentError("n_adapt of $(spl.alg.n_adapts) is greater than total samples of $N."))
            end
        else
            spl.alg.n_adapts = 0
        end
    end

    # Convert to transformed space if we're using
    # non-Gibbs sampling.
    if !islinked(spl.state.vi, spl) && spl.selector.tag == :default
        link!(spl.state.vi, spl)
        runmodel!(model, spl.state.vi, spl)
    end
end

"""
    HMCDA(n_adapts::Int, δ::Float64, λ::Float64; ϵ::Float64=0.0)

Hamiltonian Monte Carlo sampler with Dual Averaging algorithm.

Usage:

```julia
HMCDA(200, 0.65, 0.3)
```

Arguments:

- `n_adapts::Int` : Numbers of samples to use for adaptation.
- `δ::Float64` : Target acceptance rate. 65% is often recommended.
- `λ::Float64` : Target leapfrop length.
- `ϵ::Float64=0.0` : Inital step size; 0 means automatically search by Turing.

For more information, please view the following paper ([arXiv link](https://arxiv.org/abs/1111.4246)):

- Hoffman, Matthew D., and Andrew Gelman. "The No-U-turn sampler: adaptively
  setting path lengths in Hamiltonian Monte Carlo." Journal of Machine Learning
  Research 15, no. 1 (2014): 1593-1623.
"""
mutable struct HMCDA{AD, space, metricT <: AHMC.AbstractMetric} <: AdaptiveHamiltonian{AD}
    n_adapts    ::  Int         # number of samples with adaption for ϵ
    δ           ::  Float64     # target accept rate
    λ           ::  Float64     # target leapfrog length
    ϵ           ::  Float64     # (initial) step size
end
HMCDA(args...; kwargs...) = HMCDA{ADBackend()}(args...; kwargs...)
function HMCDA{AD}(n_adapts::Int, δ::Float64, λ::Float64, ϵ::Float64, ::Type{metricT}, space::Tuple) where {AD, metricT <: AHMC.AbstractMetric}
    return HMCDA{AD, space, metricT}(n_adapts, δ, λ, ϵ)
end

function HMCDA{AD}(
    δ::Float64,
    λ::Float64;
    init_ϵ::Float64=0.0,
    metricT=AHMC.UnitEuclideanMetric
) where AD
    return HMCDA{AD}(0, δ, λ, init_ϵ, metricT, ())
end

function HMCDA{AD}(
    n_adapts::Int,
    δ::Float64,
    λ::Float64,
    ::Tuple{};
    kwargs...
) where AD
    return HMCDA{AD}(n_adapts, δ, λ; kwargs...)
end

function HMCDA{AD}(
    n_adapts::Int,
    δ::Float64,
    λ::Float64,
    space::Symbol...;
    init_ϵ::Float64=0.0,
    metricT=AHMC.UnitEuclideanMetric
) where AD
    return HMCDA{AD}(n_adapts, δ, λ, init_ϵ, metricT, space)
end


"""
    NUTS(n_adapts::Int, δ::Float64; max_depth::Int=5, Δ_max::Float64=1000.0, ϵ::Float64=0.0)

No-U-Turn Sampler (NUTS) sampler.

Usage:

```julia
NUTS(200, 0.6j_max)
```

Arguments:

- `n_adapts::Int` : The number of samples to use with adapatation.
- `δ::Float64` : Target acceptance rate.
- `max_depth::Float64` : Maximum doubling tree depth.
- `Δ_max::Float64` : Maximum divergence during doubling tree.
- `ϵ::Float64` : Inital step size; 0 means automatically search by Turing.

"""
mutable struct NUTS{AD, space, metricT <: AHMC.AbstractMetric} <: AdaptiveHamiltonian{AD}
    n_adapts    ::  Int         # number of samples with adaption for ϵ
    δ           ::  Float64     # target accept rate
    max_depth   ::  Int         # maximum tree depth
    Δ_max       ::  Float64
    ϵ           ::  Float64     # (initial) step size
end

NUTS(args...; kwargs...) = NUTS{ADBackend()}(args...; kwargs...)
function NUTS{AD}(
    n_adapts::Int,
    δ::Float64,
    max_depth::Int,
    Δ_max::Float64,
    ϵ::Float64,
    ::Type{metricT},
    space::Tuple
) where {AD, metricT}
    return NUTS{AD, space, metricT}(n_adapts, δ, max_depth, Δ_max, ϵ)
end

function NUTS{AD}(
    n_adapts::Int,
    δ::Float64,
    ::Tuple{};
    kwargs...
) where AD
    NUTS{AD}(n_adapts, δ; kwargs...)
end

function NUTS{AD}(
    n_adapts::Int,
    δ::Float64,
    space::Symbol...;
    max_depth::Int=10,
    Δ_max::Float64=1000.0,
    init_ϵ::Float64=0.0,
    metricT=AHMC.DiagEuclideanMetric
) where AD
    NUTS{AD}(n_adapts, δ, max_depth, Δ_max, init_ϵ, metricT, space)
end

function NUTS{AD}(
    δ::Float64;
    max_depth::Int=10,
    Δ_max::Float64=1000.0,
    init_ϵ::Float64=0.0,
    metricT=AHMC.DiagEuclideanMetric
) where AD
    NUTS{AD}(0, δ, max_depth, Δ_max, init_ϵ, metricT, ())
end

function NUTS{AD}(kwargs...) where AD
    NUTS{AD}(0, 0.65; kwargs...)
end

for alg in (:HMC, :HMCDA, :NUTS)
    @eval getmetricT(::$alg{<:Any, <:Any, metricT}) where {metricT} = metricT
end

####
#### Sampler construction
####

# Sampler(alg::Hamiltonian) =  Sampler(alg, AHMCAdaptor())
function Sampler(
    alg::SamplerType,
    model::Model,
    s::Selector=Selector()
) where {SamplerType<:Union{StaticHamiltonian, AdaptiveHamiltonian}}
    info = Dict{Symbol, Any}()
    # Create an empty sampler state that just holds a typed VarInfo.
    initial_state = SamplerState(VarInfo(model))

    # Create an initial sampler, to get all the initialization out of the way.
    initial_spl = Sampler(alg, info, s, initial_state)

    # Create the actual state based on the alg type.
    state = HMCState(model, initial_spl, GLOBAL_RNG)

    # Create a real sampler after getting all the types/running the init phase.
    return Sampler(alg, initial_spl.info, initial_spl.selector, state)
end



####
#### Transition / step functions for HMC samplers.
####

# Single step of a Hamiltonian.
function step!(
    rng::AbstractRNG,
    model::Model,
    spl::Sampler{T},
    N::Integer;
    kwargs...
) where T<:Hamiltonian
    # Get step size
    ϵ = T <: AdaptiveHamiltonian ?
        AHMC.getϵ(spl.state.adaptor) :
        spl.alg.ϵ

    spl.state.i += 1
    spl.state.eval_num = 0

    Turing.DEBUG && @debug "current ϵ: $ϵ"
    
    # Gibbs component specified cares
    if spl.selector.tag != :default
        # Transform the space
        Turing.DEBUG && @debug "X-> R..."
        link!(spl.state.vi, spl)
        runmodel!(model, spl.state.vi, spl)
        # Update Hamiltonian
        metric = gen_metric(length(spl.state.vi[spl]), spl)
        ∂logπ∂θ = gen_∂logπ∂θ(spl.state.vi, spl, model)
        logπ = gen_logπ(spl.state.vi, spl, model)
        spl.state.h = AHMC.Hamiltonian(metric, logπ, ∂logπ∂θ)
    end

    # Get position and log density before transition
    θ_old, log_density_old = spl.state.vi[spl], spl.state.vi.logp

    # Transition
    t = AHMC.step(rng, spl.state.h, spl.state.traj, spl.state.z)
    # Update z in state
    spl.state.z = t.z

    # Adaptation
    if T <: AdaptiveHamiltonian
        spl.state.h, spl.state.traj, isadapted = 
            AHMC.adapt!(spl.state.h, spl.state.traj, spl.state.adaptor, 
                        spl.state.i, spl.alg.n_adapts, t.z.θ, t.stat.acceptance_rate)
    end

    Turing.DEBUG && @debug "decide whether to accept..."

    # Update `vi` based on acceptance
    if t.stat.is_accept
        spl.state.vi[spl] = t.z.θ
        setlogp!(spl.state.vi, t.stat.log_density)
    else
        spl.state.vi[spl] = θ_old
        setlogp!(spl.state.vi, log_density_old)
    end

    # Gibbs component specified cares
    # Transform the space back
    Turing.DEBUG && @debug "R -> X..."
    spl.selector.tag != :default && invlink!(spl.state.vi, spl)

    return HamiltonianTransition(spl, t)
end


#####
##### HMC core functions
#####

"""
    gen_∂logπ∂θ(vi::VarInfo, spl::Sampler, model)

Generate a function that takes a vector of reals `θ` and compute the logpdf and
gradient at `θ` for the model specified by `(vi, spl, model)`.
"""
function gen_∂logπ∂θ(vi::VarInfo, spl::Sampler, model)
    function ∂logπ∂θ(x)
        return gradient_logp(x, vi, model, spl)
    end
    return ∂logπ∂θ
end

"""
    gen_logπ(vi::VarInfo, spl::Sampler, model)

Generate a function that takes `θ` and returns logpdf at `θ` for the model specified by
`(vi, spl, model)`.
"""
function gen_logπ(vi::VarInfo, spl::Sampler, model)
    function logπ(x)::Float64
        x_old, lj_old = vi[spl], vi.logp
        vi[spl] = x
        runmodel!(model, vi, spl)
        lj = vi.logp
        vi[spl] = x_old
        setlogp!(vi, lj_old)
        return lj
    end
    return logπ
end

gen_metric(dim::Int, spl::Sampler{<:Hamiltonian}) = AHMC.UnitEuclideanMetric(dim)
gen_metric(dim::Int, spl::Sampler{<:AdaptiveHamiltonian}) = AHMC.renew(spl.state.h.metric, AHMC.getM⁻¹(spl.state.adaptor.pc))

gen_traj(alg::HMC, ϵ) = AHMC.StaticTrajectory(AHMC.Leapfrog(ϵ), alg.n_leapfrog)
gen_traj(alg::HMCDA, ϵ) = AHMC.HMCDA(AHMC.Leapfrog(ϵ), alg.λ)
gen_traj(alg::NUTS, ϵ) = AHMC.NUTS(AHMC.Leapfrog(ϵ), alg.max_depth, alg.Δ_max)


####
#### Compiler interface, i.e. tilde operators.
####
function assume(spl::Sampler{<:Hamiltonian},
    dist::Distribution,
    vn::VarName,
    vi::VarInfo
)
    Turing.DEBUG && @debug "assuming..."
    updategid!(vi, vn, spl)
    r = vi[vn]
    # acclogp!(vi, logpdf_with_trans(dist, r, istrans(vi, vn)))
    # r
    Turing.DEBUG && @debug "dist = $dist"
    Turing.DEBUG && @debug "vn = $vn"
    Turing.DEBUG && @debug "r = $r" "typeof(r)=$(typeof(r))"
    return r, logpdf_with_trans(dist, r, istrans(vi, vn))
end

function assume(spl::Sampler{<:Hamiltonian},
    dists::Vector{<:Distribution},
    vn::VarName,
    var::Any,
    vi::VarInfo
)
    @assert length(dists) == 1 "[observe] Turing only support vectorizing i.i.d distribution"
    dist = dists[1]
    n = size(var)[end]

    vns = map(i -> VarName(vn, "[$i]"), 1:n)

    rs = vi[vns]  # NOTE: inside Turing the Julia conversion should be sticked to

    # acclogp!(vi, sum(logpdf_with_trans(dist, rs, istrans(vi, vns[1]))))

    if isa(dist, UnivariateDistribution) || isa(dist, MatrixDistribution)
        @assert size(var) == size(rs) "Turing.assume variable and random number dimension unmatched"
        var = rs
    elseif isa(dist, MultivariateDistribution)
        if isa(var, Vector)
            @assert length(var) == size(rs)[2] "Turing.assume variable and random number dimension unmatched"
            for i = 1:n
                var[i] = rs[:,i]
            end
        elseif isa(var, Matrix)
            @assert size(var) == size(rs) "Turing.assume variable and random number dimension unmatched"
            var = rs
        else
            error("[Turing] unsupported variable container")
        end
    end

    var, sum(logpdf_with_trans(dist, rs, istrans(vi, vns[1])))
end

observe(spl::Sampler{<:Hamiltonian},
    d::Distribution,
    value::Any,
    vi::VarInfo) = observe(nothing, d, value, vi)

observe(spl::Sampler{<:Hamiltonian},
    ds::Vector{<:Distribution},
    value::Any,
    vi::VarInfo) = observe(nothing, ds, value, vi)


####
#### Default HMC stepsize and mass matrix adaptor
####

function AHMCAdaptor(alg::AdaptiveHamiltonian, metric::AHMC.AbstractMetric; ϵ=alg.ϵ)
    pc = AHMC.Preconditioner(metric)
    da = AHMC.NesterovDualAveraging(alg.δ, ϵ)
    if metric == AHMC.UnitEuclideanMetric
        adaptor = AHMC.NaiveHMCAdaptor(pc, da)
    else
        adaptor = AHMC.StanHMCAdaptor(alg.n_adapts, pc, da)
    end
    return adaptor
end

AHMCAdaptor(::Hamiltonian, ::AHMC.AbstractMetric; kwargs...) = AHMC.Adaptation.NoAdaptation()

##########################
# HMC State Constructors #
##########################

function HMCState(
    model::Model,
    spl::Sampler{<:Hamiltonian},
    rng::AbstractRNG;
    kwargs...
)
    # Reuse the VarInfo.
    vi = spl.state.vi

    # Link everything if needed.
    !islinked(vi, spl) && link!(vi, spl)

    # Get the initial log pdf and gradient functions.
    ∂logπ∂θ = gen_∂logπ∂θ(vi, spl, model)
    logπ = gen_logπ(vi, spl, model)

    # Get the metric type.
    metricT = getmetricT(spl.alg)

    # Create a Hamiltonian.
    θ_init = Vector{Float64}(spl.state.vi[spl])
    metric = metricT(length(θ_init))
    h = AHMC.Hamiltonian(metric, logπ, ∂logπ∂θ)

    # Find good eps if not provided one
    if spl.alg.ϵ == 0.0
        ϵ = AHMC.find_good_eps(h, θ_init)
        @info "Found initial step size" ϵ
    else
        ϵ = spl.alg.ϵ
    end

    # Generate a trajectory.
    traj = gen_traj(spl.alg, ϵ)

    # Generate a phasepoint. Replaced during sample_init!
    h, t = AHMC.sample_init(rng, h, θ_init) # this also ensure AHMC has the same dim as θ.

    # Unlink everything.
    invlink!(vi, spl)

    return HMCState(vi, 0, 0, traj, h, AHMCAdaptor(spl.alg, metric; ϵ=ϵ), t.z)
end

#######################################################
# Special callback functionality for the HMC samplers #
#######################################################

mutable struct HMCCallback{
    ProgType<:ProgressMeter.AbstractProgress
} <: AbstractCallback
    p :: ProgType
end


function callback(
    rng::AbstractRNG,
    model::ModelType,
    spl::SamplerType,
    N::Integer,
    iteration::Integer,
    t::HamiltonianTransition,
    cb::HMCCallback;
    kwargs...
) where {
    ModelType<:Sampleable,
    SamplerType<:AbstractSampler
}
    AHMC.pm_next!(cb.p, t.stat, iteration, spl.state.h.metric)
end

function init_callback(
    rng::AbstractRNG,
    model::Model,
    s::Sampler{<:Union{StaticHamiltonian, AdaptiveHamiltonian}},
    N::Integer;
    dt::Real=0.25,
    kwargs...
)
    return HMCCallback(ProgressMeter.Progress(N, dt=dt, desc="Sampling ", barlen=31))
end