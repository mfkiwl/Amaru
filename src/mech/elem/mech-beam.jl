# This file is part of Amaru package. See copyright license in https://github.com/NumSoftware/Amaru

export MechBeam

mutable struct MechBeam<:Mechanical
    id    ::Int
    shape ::ShapeType

    nodes ::Array{Node,1}
    ips   ::Array{Ip,1}
    tag   ::String
    mat   ::Material
    active::Bool
    linked_elems::Array{Element,1}
    env::ModelEnv

    function MechBeam()
        return new()
    end
end

matching_shape_family(::Type{MechBeam}) = LINE_SHAPE

function beam_shape_func(ξ::Float64, nnodes::Int)
    if nnodes==2
        N = Array{Float64}(undef,4)
        x = (ξ+1)/2
        N[1] = 1 - 3*x^2 + 2*x^3
        N[2] = x - 2*x^2 + x^3
        N[3] = 3*x^2 - 2*x^3
        N[4] = x^3 - x^2
    else
        N = Array{Float64}(undef,4)
    end
    return N
end

function beam_second_deriv(ξ::Float64, nnodes::Int)
    if nnodes==2
        DD = Array{Float64}(undef,4)
    else
        DD = Array{Float64}(undef,6)
    end
    return DD
end

function elem_config_dofs(elem::MechBeam)
    ndim = elem.env.ndim
    ndim == 1 && error("MechBeam: Beam elements do not work in 1d analyses")
    if ndim==2
        for node in elem.nodes
            add_dof(node, :ux, :fx)
            add_dof(node, :uy, :fy)
            add_dof(node, :rz, :mz)
        end
    else
        for node in elem.nodes
            add_dof(node, :ux, :fx)
            add_dof(node, :uy, :fy)
            add_dof(node, :uz, :fz)
            add_dof(node, :rx, :mx)
            add_dof(node, :ry, :my)
            add_dof(node, :rz, :mz)
        end
    end
end

function elem_map(elem::MechBeam)::Array{Int,1}
    if elem.env.ndim==2
        dof_keys = (:ux, :uy, :rz)
    else
        dof_keys = (:ux, :uy, :uz, :rx, :ry, :rz)
    end
    vcat([ [node.dofdict[key].eq_id for key in dof_keys] for node in elem.nodes]...)
end

# Return the class of element where this material can be used
#client_shape_class(mat::MechBeam) = LINE_SHAPE

function calcT(elem::MechBeam, C)
    c = (C[2,1] - C[1,1])/L
    s = (C[2,2] - C[1,1])/L
    return

end

function elem_stiffness(elem::MechBeam)
    C  = get_coords(elem)
    L  = norm(C[2,:]-C[1,:])
    L2 = L*L
    L3 = L*L*L
    mat = elem.mat
    EA = mat.E*mat.A
    EI = mat.E*mat.I

    K0 = [ EA/L     0         0         -EA/L    0         0
           0       12*EI/L3   6*EI/L2    0     -12*EI/L3   6*EI/L2
           0        6*EI/L2   4*EI/L     0      -6*EI/L2   2*EI/L
          -EA/L     0          0         EA/L     0        0
           0      -12*EI/L3  -6*EI/L2    0      12*EI/L3  -6*EI/L2
           0        6*EI/L2   2*EI/L     0      -6*EI/L2   4*EI/L  ]


    # Rotation matrix
    c = (C[2,1] - C[1,1])/L
    s = (C[2,2] - C[1,2])/L

    T = [  c s 0  0 0 0
          -s c 0  0 0 0
           0 0 1  0 0 0
           0 0 0  c s 0
           0 0 0 -s c 0
           0 0 0  0 0 1 ]

    map = elem_map(elem)
    return T'*K0*T, map, map
end

function elem_mass(elem::MechBeam)
    C  = get_coords(elem)
    L  = norm(C[2,:]-C[1,:])
    L2 = L*L
    mat = elem.mat
    EA = mat.E*mat.A
    EI = mat.E*mat.I


    M0 = mat.ρ*L/420.0*[ 140   0      0      70    0      0
                         0     156    22*L   0     54    -13*L
                         0     22*L   4*L2   0     13*L  -3*L2
                         70    0      0      140   0      0
                         0     54     13*L   0     156   -22*L
                         0    -13*L  -3*L2   0    -22*L   4*L2 ]

    # Rotation matrix
    c = (C[2,1] - C[1,1])/L
    s = (C[2,2] - C[1,2])/L
    T = [  c s 0  0 0 0
          -s c 0  0 0 0
           0 0 1  0 0 0
           0 0 0  c s 0
           0 0 0 -s c 0
           0 0 0  0 0 1 ]

    map = elem_map(elem)
    return T'*M0*T, map, map
end


function elem_update!(elem::MechBeam, U::Array{Float64,1}, F::Array{Float64,1}, dt::Float64)
    K, map, map = elem_stiffness(elem)
    dU  = U[map]
    F[map] += K*dU
end

