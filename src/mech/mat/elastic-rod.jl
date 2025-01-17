# This file is part of Amaru package. See copyright license in https://github.com/NumSoftware/Amaru

export ElasticRod

mutable struct ElasticRodIpState<:IpState
    env::ModelEnv
    σ::Float64
    ε::Float64
    function ElasticRodIpState(env::ModelEnv=ModelEnv())
        this = new(env)
        this.σ = 0.0
        this.ε = 0.0
        return this
    end
end

mutable struct ElasticRod<:Material
    E::Float64
    A::Float64
    ρ::Float64

    function ElasticRod(prms::Dict{Symbol,Float64})
        return  ElasticRod(;prms...)
    end

    function ElasticRod(;E::Number=NaN, A::Number=NaN, dm::Number=NaN, rho::Number=0.0)
        @check E>0.0
        @check A>0.0 || dm>0.0
        @check rho>=0.0
        dm>0 && (A=π*dm^2/4)
        return new(E, A, rho)
    end
end

matching_elem_type(::ElasticRod) = MechRod
matching_elem_type_if_embedded(::ElasticRod) = MechEmbRod

# Type of corresponding state structure
ip_state_type(mat::ElasticRod) = ElasticRodIpState

function stress_update(mat::ElasticRod, ipd::ElasticRodIpState, Δε::Float64)
    E  = mat.E
    Δσ = mat.E*Δε
    ipd.ε += Δε
    ipd.σ += Δσ
    return Δσ, success()
end

function ip_state_vals(mat::ElasticRod, ipd::ElasticRodIpState)
    return OrderedDict(
      :sa => ipd.σ,
      :ea => ipd.ε,
      :fa => ipd.σ*mat.A,
      :A  => mat.A )
end

function calcD(mat::ElasticRod, ips::ElasticRodIpState)
    return mat.E
end

