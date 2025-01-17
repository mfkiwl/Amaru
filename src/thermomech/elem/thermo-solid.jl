# This file is part of Amaru package. See copyright license in https://github.com/NumSoftware/Amaru


mutable struct ThermoSolid<:Thermomechanical
    id    ::Int
    shape ::ShapeType

    nodes ::Array{Node,1}
    ips   ::Array{Ip,1}
    tag   ::String
    mat   ::Material
    active::Bool
    linked_elems::Array{Element,1}
    env::ModelEnv

    function ThermoSolid();
        return new()
    end
end

matching_shape_family(::Type{ThermoSolid}) = SOLID_SHAPE

function elem_config_dofs(elem::ThermoSolid)
    for node in elem.nodes
        add_dof(node, :ut, :ft)
    end
end

function elem_init(elem::ThermoSolid)
    nothing
end


function distributed_bc(elem::ThermoSolid, facet::Union{Facet,Nothing}, key::Symbol, val::Union{Real,Symbol,Expr})
    ndim  = elem.env.ndim
    th    = elem.env.thickness
    suitable_keys = (:tq,)

    # Check keys
    key in suitable_keys || error("distributed_bc: boundary condition $key is not applicable in a ThermoSolid element")

    target = facet!=nothing ? facet : elem
    nodes  = target.nodes
    nnodes = length(nodes)
    t      = elem.env.t

    # Force boundary condition
    nnodes = length(nodes)

    # Calculate the target coordinates matrix
    C = get_coords(nodes, ndim)

    # Calculate the nodal values
    F     = zeros(nnodes)
    J     = Array{Float64}(undef, ndim, ndim)
    shape = target.shape
    ips   = get_ip_coords(shape)

    for i=1:size(ips,1)
        R = vec(ips[i,:])
        w = R[end]
        N = shape.func(R)
        D = shape.deriv(R)
        @gemm J = D*C
        nJ = norm2(J)
        X = C'*N
        if ndim==2
            x, y = X
            vip = eval_arith_expr(val, t=t, x=x, y=y)
            if elem.env.modeltype=="axisymmetric"
                th = 2*pi*X[1]
            end
        else
            x, y, z = X
            vip = eval_arith_expr(val, t=t, x=x, y=y, z=z)
        end
        coef = vip*norm(J)*w*th
        F .+= coef*N # F is a vector
    end

    # generate a map
    map  = [ node.dofdict[:ut].eq_id for node in target.nodes ]

    return F, map
end


# thermal conductivity
function elem_conductivity_matrix(elem::ThermoSolid)
    ndim   = elem.env.ndim
    th     = elem.env.thickness
    nnodes = length(elem.nodes)
    C      = get_coords(elem)
    H      = zeros(nnodes, nnodes)
    Bt     = zeros(ndim, nnodes)
    KBt    = zeros(ndim, nnodes)

    J    = Array{Float64}(undef, ndim, ndim)

    for ip in elem.ips
        elem.env.modeltype=="axisymmetric" && (th = 2*pi*ip.coord.x)
        dNdR = elem.shape.deriv(ip.R)
        @gemm J  = dNdR*C
        detJ = det(J)
        detJ > 0.0 || error("Negative jacobian determinant in cell $(elem.id)")
        @gemm Bt = inv(J)*dNdR

        # compute H
        K = calcK(elem.mat, ip.state)
        coef = detJ*ip.w*th
        @gemm KBt = K*Bt
        @gemm H -= coef*Bt'*KBt
    end

    # map
    map = [ node.dofdict[:ut].eq_id for node in elem.nodes ]

    return H, map, map
end

function elem_mass_matrix(elem::ThermoSolid)
    ndim   = elem.env.ndim
    th     = elem.env.thickness
    nnodes = length(elem.nodes)
    C      = get_coords(elem)
    M      = zeros(nnodes, nnodes)

    J  = Array{Float64}(undef, ndim, ndim)

    for ip in elem.ips
        elem.env.modeltype=="axisymmetric" && (th = 2*pi*ip.coord.x)

        N    = elem.shape.func(ip.R)
        dNdR = elem.shape.deriv(ip.R)
        @gemm J = dNdR*C
        detJ = det(J)
        detJ > 0.0 || error("Negative jacobian determinant in cell $(elem.id)")

        # compute Cut
        coef  = elem.mat.ρ*elem.mat.cv
        coef *= detJ*ip.w*th
        M    -= coef*N*N'
    end

    # map
    map = [ node.dofdict[:ut].eq_id for node in elem.nodes ]

    return M, map, map
end

#=
function elem_internal_forces(elem::ThermoSolid, F::Array{Float64,1})
    ndim   = elem.env.ndim
    nnodes = length(elem.nodes)
    C   = get_coords(elem)
    th     = elem.env.thickness
    θ0     = elem.env.T0 + 273.15
    map_p  = [ node.dofdict[:ut].eq_id for node in elem.nodes ]

    dFt = zeros(nnodes)
    Bt  = zeros(ndim, nnodes)

    J  = Array{Float64}(undef, ndim, ndim)
    dNdX = Array{Float64}(undef, ndim, nnodes)

    for ip in elem.ips
        elem.env.modeltype=="axisymmetric" && (th = 2*pi*ip.coord.x)


        # compute Bt matrix
        dNdR = elem.shape.deriv(ip.R)
        @gemm J = dNdR*C
        detJ = det(J)
        detJ > 0.0 || error("Negative jacobian determinant in cell $(cell.id)")
        @gemm dNdX = inv(J)*dNdR

        Bt = dNdX

        # compute N
        N    = elem.shape.func(ip.R)

        # internal volumes dFw
        ut   = ip.state.ut
        coef = detJ*ip.w*elem.mat.cv*elem.mat.ρ*th # VERIFICAR
        dFt -= coef*N*ut

        D    = ip.state.D
        coef = detJ*ip.w*th/θ0
        @gemv dFt -= coef*Bt'*D
    end

    F[map_p] += dFt
end
=#


function elem_update!(elem::ThermoSolid, DU::Array{Float64,1}, DF::Array{Float64,1}, Δt::Float64)
    ndim   = elem.env.ndim
    nnodes = length(elem.nodes)
    th     = elem.env.thickness

    map_t  = [ node.dofdict[:ut].eq_id for node in elem.nodes ]

    C   = get_coords(elem)

    dUt = DU[map_t] # nodal temperature increments
    Ut  = [ node.dofdict[:ut].vals[:ut] for node in elem.nodes ]
    Ut += dUt # nodal temperature at step n+1

    dF  = zeros(nnodes*ndim)
    Bt  = zeros(ndim, nnodes)
    dFt = zeros(nnodes)

    J  = Array{Float64}(undef, ndim, ndim)
    dNdX = Array{Float64}(undef, ndim, nnodes)

    for ip in elem.ips
        elem.env.modeltype=="axisymmetric" && (th = 2*pi*ip.coord.x)

        # compute Bu matrix
        N    = elem.shape.func(ip.R)
        dNdR = elem.shape.deriv(ip.R)
        @gemm J = dNdR*C
        detJ = det(J)
        detJ > 0.0 || error("Negative jacobian determinant in cell $(cell.id)")
        @gemm dNdX = inv(J)*dNdR

        Bt = dNdX
        G  = Bt*Ut # temperature gradient

        Δut = N'*dUt # interpolation to the integ. point

        q = update_state!(elem.mat, ip.state, Δut, G, Δt)

        coef  = elem.mat.ρ*elem.mat.cv
        coef *= detJ*ip.w*th
        dFt  -= coef*N*Δut

        coef = Δt*detJ*ip.w*th
        @gemv dFt += coef*Bt'*q
    end

    DF[map_t] += dFt
    return success()
end
