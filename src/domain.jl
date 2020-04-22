# This file is part of Amaru package. See copyright license in https://github.com/NumSoftware/Amaru

abstract type AbstractDomain<:AbstractMesh end

"""
`Domain(mesh, [filekey="out"])`

Creates an `Domain` object based on a Mesh object `mesh` and represents the geometric domain to be analysed by the finite element analysis.

**Fields**

`nodes`: An array of nodes

`elems`: An array of finite elements

`faces`: An array of `Face` objects containing the boundary faces

`edges`: An array of `Edge` objects containing all the boundary faces

"""
mutable struct Domain<:AbstractDomain
    #mesh::Mesh
    nodes::Array{Node,1}
    elems::Array{Element,1}
    faces::Array{Face,1}
    edges::Array{Edge,1}

    _elempartition::ElemPartition

    loggers::Array{AbstractLogger,1}
    ndofs::Integer
    env::ModelEnv

    # Data
    node_data::OrderedDict{String,Array}
    elem_data ::OrderedDict{String,Array}

    function Domain()
        this = new()

        this.loggers = []
        this.ndofs   = 0

        this._elempartition = ElemPartition()
        this.node_data = OrderedDict()
        this.elem_data  = OrderedDict()
        return this
    end
end

#=
mutable struct SubDomain<:AbstractDomain
    nodes::Array{Node,1}
    elems::Array{Element,1}
    faces::Array{Face,1}

    env::ModelEnv
end


function SubDomain(dom::Domain, expr::Expr)
    elems = dom.elems[expr]
    node_ids = unique( node.id for elem in elems for node in elem.nodes )
    nodes = dom.nodes[node_ids]

    cells  = [ elem.cell for elem in elems ]
    scells = get_surface(cells)

    # Setting faces
    faces = Array{Face}(0)
    for (i,cell) in enumerate(scells)
        conn = [ p.id for p in cell.nodes ]
        face = Face(cell.shape, dom.nodes[conn], ndim, cell.tag)
        face.oelem = dom.elems[cell.oelem.id]
        face.id = i
        push!(faces, face)
    end

    return SubDomain(nodes, elems, faces, dom.env)
end


function SubDomain(elems::Array{<:Element,1})
    nodesset = OrderedSet(node for elem in elems for node in elem.nodes)
    nodes    = collect(nodesset)

    nodemap = zeros(maximum(node.id for node in nodes))
    for (i,node) in enumerate(nodes); nodemap[node.id] = i end

    elemmap = zeros(maximum(elem.id for elem in elems))
    for (i,elem) in enumerate(elems); elemmap[elem.id] = i end

    cells  = [ elem.cell for elem in elems ]
    scells = get_surface(cells)

    # Setting faces
    faces = Array{Face}(0)
    for (i,cell) in enumerate(scells)
        conn = [ nodemap[p.id] for p in cell.nodes ]
        face = Face(cell.shape, nodes[conn], ndim, cell.tag)
        face.oelem = elems[elemmap[cell.oelem.id]]
        face.id = i
        push!(faces, face)
    end

    return SubDomain(nodes, elems, faces, ModelEnv())
end
=#


"""
    Domain(mesh, mats, options...)

Uses a mesh and a list of meterial especifications to construct a finite element `Domain`.

# Arguments

`mesh` : A finite element mesh

`mats` : Material definitions given as an array of pairs ( tag or location => constitutive model instance )

# Keyword arguments

`modeltype`
`thickness`
`filekey = ""` : File key for output files
`verbose = false` : If true, provides information of the domain construction

"""
function Domain(
                mesh      :: Mesh,
                matbinds  :: Array{<:Pair,1};
                modeltype :: Symbol = :general, # :plane_stress, plane_strain
                thickness :: Real   = 1.0,
                verbose   :: Bool   = false,
                silent    :: Bool   = false,
                params... # extra parameters required for specific solvers
               )

    verbosity = 1
    verbose && (verbosity=2)
    silent && (verbosity=0)

    dom  = Domain()

    # Shared analysis data
    ndim = mesh.ndim
    env = ModelEnv()
    dom.env = env
    env.ndim = ndim
    env.modeltype = modeltype
    env.thickness = thickness
    env.t = 0.0

    # Saving extra parameters
    for (k,v) in params
        typeof(v) <: Number && ( env.params[k] = v )
    end

    # Save a mesh reference
    #dom.mesh = mesh

    verbosity>0 && printstyled("Domain setup:\n", bold=true, color=:cyan)

    # Setting nodes
    #dom.nodes = [ Node([p.x, p.y, p.z], tag=p.tag, id=i) for (i,p) in enumerate(mesh.nodes)]
    dom.nodes = copy(mesh.nodes)

    # Setting new elements
    verbosity>0 && print("  setting elements...\r")
    ncells    = length(mesh.elems)
    dom.elems = Array{Element,1}(undef, ncells)
    #Nips      = zeros(Int, ncells)       # list with number of ips per element
    #Tips      = Array{String,1}(undef, ncells)  # list with the ip tag per element
    #Tips     .= ""
    for (filter, mat) in matbinds
        cells = mesh.elems[filter]
        if ! (cells isa Array)
            cells = [ cells ]
        end
        if isempty(cells)
            @warn "Domain: binding material model $(typeof(mat)) to an empty list of cells:" expr=filter
        end

        for cell in cells
            if cell.embedded
                etype = matching_elem_type_if_embedded(mat)
            else
                etype = matching_elem_type(mat)
            end

            if matching_shape_family(etype) != cell.shape.family
                error("Domain: material model $(typeof(mat)) cannot be used with shape $(cell.shape.name) (cell id: $(cell.id))\n")
            end

            conn = [ p.id for p in cell.nodes ]
            elem = new_element(etype, cell.shape, dom.nodes[conn], cell.tag, env)
            #@show typeof(elem)

            elem.id = cell.id
            elem.mat = mat
            dom.elems[cell.id] = elem
            #Nips[elem.id] = cell.nips
            #Nips[elem.id] = 0
        end
    end

    # Check if all elements have material defined
    undefined_elem_shapes = Set{String}()
    for i=1:ncells
        if !isassigned(dom.elems, i)
            push!(undefined_elem_shapes, mesh.elems[i].shape.name)
        end
    end
    if !isempty(undefined_elem_shapes)
        error("Domain: missing material definition to allocate elements with shape: $(join(undefined_elem_shapes, ", "))\n")
    end

    # Setting linked elements
    for cell in mesh.elems
        for lcell in cell.linked_elems
            push!(dom.elems[cell.id].linked_elems, dom.elems[lcell.id])
        end
    end

    # Setting faces
    dom.faces = Face[]
    for (i,cell) in enumerate(mesh.faces)
        conn = [ p.id for p in cell.nodes ]
        face = Face(cell.shape, dom.nodes[conn], tag=cell.tag)
        face.oelem = dom.elems[cell.oelem.id]
        face.id = i
        push!(dom.faces, face)
    end

    # Setting edges
    dom.edges = Edge[]
    for (i,cell) in enumerate(mesh.edges)
        conn = [ p.id for p in cell.nodes ]
        edge = Edge(cell.shape, dom.nodes[conn], tag=cell.tag)
        edge.oelem = dom.elems[cell.oelem.id]
        edge.id = i
        push!(dom.edges, edge)
    end

    # Finishing to configure elements
    ip_id = 0
    for elem in dom.elems
        elem_config_dofs(elem)               # dofs
        set_quadrature!(elem) # ips
        for ip in elem.ips # updating ip tags
            ip_id += 1
            ip.id = ip_id
            #ip.tag = Tips[elem.id]
        end
    end

    # Initializing elements
    for elem in dom.elems
        elem_init(elem)
    end

    if verbosity>0
        print("  ", ndim, "D domain $modeltype model      \n")
        @printf "  %5d nodes\n" length(dom.nodes)
        @printf "  %5d elements\n" length(dom.elems)
    end

    if verbosity>1
        if ndim==2
            @printf "  %5d edges\n" length(dom.faces)
        else
            @printf "  %5d faces\n" length(dom.faces)
            @printf "  %5d edges\n" length(dom.edges)
        end
        @printf "  %5d materials\n" length(matbinds)
        @printf "  %5d loggers\n" length(dom.loggers)
    end

    return dom
end


# Function for setting loggers
"""
    setloggers!(domain, loggers)

Register the loggers from the array `loggers` into `domain`.

"""
#function setloggers!(dom::Domain, logger::Union{AbstractLogger, Array{<:AbstractLogger,1}})
function setloggers!(dom::Domain, loggers::Array{<:Pair,1})
    dom.loggers = []
    for (filter,logger) in loggers
        push!(dom.loggers, logger)
        setup_logger!(dom, filter, logger)
    end
    #setup_logger!.(Ref(dom), dom.loggers)
end


# Function for updating loggers
#update_loggers!(domain::Domain) = update_logger!.(domain.loggers, Ref(domain.env))

function update_single_loggers!(domain::Domain)
    for logger in domain.loggers
        isa(logger, SingleLogger) && update_logger!(logger, domain)
    end
end

function update_composed_loggers!(domain::Domain)
    for logger in domain.loggers
        isa(logger, ComposedLogger) && update_logger!(logger, domain)
    end
end

#function get_segment_data(dom::Domain, X1::Array{<:Real,1}, X2::Array{<:Real,1}, filename::String=""; npoints=200)
    #mesh = convert(Mesh, dom)
    #return get_segment_data(mesh, X1, X2, filename, npoints=npoints)
#end


# Function to reset a domain
#= This is error prone specially with ips in loggers
A new Domain is preferable
function reset!(dom::Domain)
    dom.nincs = 0
    dom.stage = 0

    # Reconfigure nodes and dofs
    for node in dom.nodes
        empty!(node.dofs)
        empty!(node.dofdict)
    end

    # Reconfigure elements, dofs and ips
    ip_id = 0
    for elem in dom.elems
        elem_config_dofs(elem)
        ip_tags = [ ip.tag for ip in elem.ips]
        elem_config_ips(elem, length(elem.ips)) # ips
        for (i,ip) in enumerate(elem.ips) # updating ip tags
            ip_id += 1
            ip.id = ip_id
            ip.tag = ip_tags[i]
        end
    end

    # Reconfigure loggers
    for logger in dom.loggers
        setup_logger!(dom, logger)
    end
end

function reset!(dom::Domain)
    dom.nincs = 0
    dom.stage = 0

    # Reconfigure nodes and dofs
    for node in dom.nodes
        reset!(node)
    end

    # Reconfigure elements, dofs and ips
    for elem in dom.elems
        reset!(elem)
    end

    # Reconfigure loggers
    for logger in dom.loggers
        reset!(logger)
    end

end

=#



function update_output_data!(dom::Domain)
    # Updates data arrays in the domain
    dom.node_data = OrderedDict()
    dom.elem_data  = OrderedDict()

    # Nodal values
    # ============
    nnodes = length(dom.nodes)

    # get node field symbols
    node_fields_set = OrderedSet{Symbol}()
    for node in dom.nodes
        for dof in node.dofs
            union!(node_fields_set, keys(dof.vals))
        end
    end
    node_fields = collect(node_fields_set)

    # Generate empty lists
    for field in node_fields
        dom.node_data[string(field)] = zeros(nnodes)
    end

    # Fill dof values
    for node in dom.nodes
        for dof in node.dofs
            for (field,val) in dof.vals
                dom.node_data[string(field)][node.id] = val
            end
        end
    end

    # add nodal values from patch recovery (solid elements) : regression + averaging
    V_rec, fields_rec = nodal_patch_recovery(dom)
    for (i,field) in enumerate(fields_rec)
        dom.node_data[string(field)] = V_rec[:,i]
    end
    append!(node_fields, fields_rec)

    # add nodal values from local recovery (joints) : extrapolation + averaging
    V_rec, fields_rec = nodal_local_recovery(dom)
    for (i,field) in enumerate(fields_rec)
        dom.node_data[string(field)] = V_rec[:,i]
    end
    append!(node_fields, fields_rec)


    # Nodal vector values
    # ===================

    if :ux in node_fields
        if :uz in node_fields
            dom.node_data["U"] = [ dom.node_data["ux"] dom.node_data["uy"] dom.node_data["uz"] ]
        elseif :uy in node_fields
            dom.node_data["U"] = [ dom.node_data["ux"] dom.node_data["uy"] zeros(nnodes) ]
        else
            dom.node_data["U"] = [ dom.node_data["ux"] zeros(nnodes) zeros(nnodes) ]
        end
    end

    if :vx in node_fields
        if :vz in node_fields
            dom.node_data["V"] = [ dom.node_data["vx"] dom.node_data["vy"] dom.node_data["vz"] ]
        elseif :vy in node_fields
            dom.node_data["V"] = [ dom.node_data["vx"] dom.node_data["vy"] zeros(nnodes) ]
        else
            dom.node_data["V"] = [ dom.node_data["vx"] zeros(nnodes) zeros(nnodes) ]
        end
    end


    # Element values
    # ==============

    nelems = length(dom.elems)
    all_elem_vals   = [ elem_vals(elem) for elem in dom.elems ]
    elem_fields_set = Set( key for elem in dom.elems for key in keys(all_elem_vals[elem.id]) )
    elem_fields     = collect(elem_fields_set)

    # generate empty lists
    for field in elem_fields
        dom.elem_data[string(field)] = zeros(nelems)
    end

    # fill elem values
    for elem in dom.elems
        for (field,val) in all_elem_vals[elem.id]
            dom.elem_data[string(field)][elem.id] = val
        end
    end

end



function get_node_and_elem_vals(dom::Domain)
    # Return symbols and values for nodes and elements
    # Note: nodal ids must be numbered starting from 1

    # nodal values
    nnodes = length(dom.nodes)

    # get node field symbols
    node_fields_set = Set{Symbol}()
    for node in dom.nodes
        for dof in node.dofs
            union!(node_fields_set, keys(dof.vals))
        end
    end

    # get node field values
    node_fields_idx = OrderedDict( key=>i for (i,key) in enumerate(node_fields_set) )
    nfields = length(node_fields_set)
    NV = zeros(nnodes, nfields)
    for node in dom.nodes
        for dof in node.dofs
            for (field,val) in dof.vals
                NV[ node.id, node_fields_idx[field] ] = val
            end
        end
    end

    # add nodal values from patch recovery (solid elements) : regression + averaging
    V_rec, fields_rec = nodal_patch_recovery(dom)
    NV = [ NV V_rec ]
    node_fields = [ collect(node_fields_set); fields_rec ]

    # add nodal values from local recovery (joints) : extrapolation + averaging
    V_rec, fields_rec = nodal_local_recovery(dom)
    NV = [ NV V_rec ]
    node_fields = [ node_fields; fields_rec ]

    # element values
    nelems = length(dom.elems)
    all_elem_vals   = [ elem_vals(elem) for elem in dom.elems ]
    elem_fields_set = Set( key for elem in dom.elems for key in keys(all_elem_vals[elem.id]) )
    elem_fields_idx = OrderedDict( key=>i for (i,key) in enumerate(elem_fields_set) )
    nfields = length(elem_fields_set)
    EV = zeros(nelems, nfields)
    for elem in dom.elems
        for (field,val) in all_elem_vals[elem.id]
            EV[ elem.id, elem_fields_idx[field] ] = val
        end
    end

    elem_fields = collect(elem_fields_set)
    return NV, node_fields, EV, elem_fields

end

function reg_terms(x::Float64, y::Float64, nterms::Int64)
    nterms==6 && return ( 1.0, x, y, x*y, x^2, y^2 )
    nterms==4 && return ( 1.0, x, y, x*y )
    nterms==3 && return ( 1.0, x, y )
    return (1.0,)
end

function reg_terms(x::Float64, y::Float64, z::Float64, nterms::Int64)
    nterms==10 && return ( 1.0, x, y, z, x*y, y*z, x*z, x^2, y^2, z^2 )
    nterms==7  && return ( 1.0, x, y, z, x*y, y*z, x*z )
    nterms==4  && return ( 1.0, x, y, z )
    return (1.0,)
end


function nodal_patch_recovery(dom::Domain)
    # Note: nodal ids must be numbered starting from 1

    ndim = dom.env.ndim
    nnodes = length(dom.nodes)
    length(dom.faces)==0 && return zeros(nnodes,0), Symbol[]

    # get surface nodes
    bry_nodes_set = Set( node for face in dom.faces for node in face.nodes )

    # list for boundary nodes
    at_bound = falses(nnodes)
    for node in bry_nodes_set
        at_bound[node.id] = true
    end

    # generate patches for solid elements
    patches     = [ Element[] for i=1:nnodes ] # internal patches
    bry_patches = [ Element[] for i=1:nnodes ] # boundary patches
    for elem in dom.elems
        elem.shape.family != SOLID_SHAPE && continue
        for node in elem.nodes[1:elem.shape.basic_shape.npoints] # only at corners
            if at_bound[node.id]
                push!(bry_patches[node.id], elem)
            else
                push!(patches[node.id], elem)
            end
        end
    end

    # check if nodes are in at least one internal patch
    npatches = zeros(Int, nnodes)
    haspatch = falses(nnodes)
    for patch in patches
        for elem in patch
            for node in elem.nodes
                haspatch[node.id] = true
            end
        end
    end
    orphan_nodes = [ node for node in dom.nodes if (!haspatch[node.id] && at_bound[node.id]) ]

    # add border patches avoiding patches with few elements
    if length(orphan_nodes)>0
        for n=3:-1:1
            # add orphan_nodes patches if patch has more than n elems
            for node in orphan_nodes
                patch = bry_patches[node.id]
                length(patch)>=n && ( patches[node.id] = patch )
            end

            # check for orphan nodes
            for node in orphan_nodes
                patch = patches[node.id]
                for elem in patch
                    for node in elem.nodes
                        haspatch[node.id] = true
                    end
                end
            end
            orphan_nodes = [ node for node in orphan_nodes if !haspatch[node.id] ]
            length(orphan_nodes)==0 && break
        end
    end

    # all data from ips per element and field names
    all_ips_vals   = Array{Array{OrderedDict{Symbol,Float64}},1}()
    all_fields_set = OrderedSet{Symbol}()
    for elem in dom.elems
        if elem.shape.family==SOLID_SHAPE
            ips_vals = [ ip_state_vals(elem.mat, ip.data) for ip in elem.ips ]
            push!(all_ips_vals, ips_vals)
            union!(all_fields_set, keys(ips_vals[1]))
        else # skip data from non solid elements
            push!(all_ips_vals, [])
        end
    end

    # map field => index
    all_fields_idx = OrderedDict( key=>i for (i,key) in enumerate(all_fields_set) )
    nfields = length(all_fields_set)

    # matrices for all nodal values and repetitions
    V_vals =  zeros(Float64, nnodes, nfields)
    V_reps =  zeros(Int64  , nnodes, nfields)

    # patch recovery
    for patch in patches
        length(patch) == 0 && continue

        # list of fields
        fields = unique( key for elem in patch for key in keys(all_ips_vals[elem.id][1]) )

        last_subpatch  = [] # elements of a subpatch for a particular field
        invM = Array{Float64,2}(undef,0,0)
        #N    = Array{Int64,2}(0,0)
        local N
        subpatch_ips = Ip[]
        subpatch_nodes = Node[]
        nterms = 0

        for field in fields
            # find subpatch for current field
            subpatch = [ elem for elem in patch if haskey(all_ips_vals[elem.id][1],field) ]

            # get subpatch data
            if subpatch != last_subpatch
                subpatch_ips   = [ ip for elem in subpatch for ip in elem.ips ]
                subpatch_nodes = unique( node for elem in subpatch for node in elem.nodes )
                last_subpatch  = subpatch

                m = length(subpatch_ips)
                n = length(subpatch_nodes)

                # number of polynomial terms
                if ndim==3
                    nterms = m>=10 ? 10 : m>=7 ? 7 : m>=4 ? 4 : 1
                else
                    nterms = m>=6 ? 6 : m>=4 ? 4 : m>=3 ? 3 : 1
                end

                # matrix M for regression
                M = Array{Float64,2}(undef,m,nterms)
                for (i,ip) in enumerate(subpatch_ips)
                    x, y, z = ip.coord
                    if ndim==3
                        M[i,:] .= reg_terms(x, y, z, nterms)
                    else
                        M[i,:] .= reg_terms(x, y, nterms)
                    end
                end
                invM = pinv(M)

                # find nodal values
                N = Array{Float64,2}(undef,n,nterms)
                for (i,node) in enumerate(subpatch_nodes)
                    x, y, z = node.coord
                    if ndim==3
                        N[i,:] .= reg_terms(x, y, z, nterms)
                    else
                        N[i,:] .= reg_terms(x, y, nterms)
                    end
                end
            end

            # values at ips
            W = Float64[ dict[field] for elem in subpatch for dict in all_ips_vals[elem.id] ]
            # coefficients vector from regression polynomial
            A = invM*W
            # values at nodes
            V = N*A

            # saving for later averaging
            field_idx = all_fields_idx[field]
            for (i,node) in enumerate(subpatch_nodes)
                V_vals[node.id, field_idx] += V[i]
                V_reps[node.id, field_idx] += 1
            end

        end
    end

    # average values
    V_vals ./= V_reps
    V_vals[isnan.(V_vals)] .= 0.0

    return V_vals, collect(all_fields_set)

end


function nodal_local_recovery(dom::Domain)
    # Recovers nodal values from non-solid elements as joints and joint1d elements
    # The element type should implement the elem_extrapolated_node_vals function
    # Note: nodal ids must be numbered starting from 1

    ndim = dom.env.ndim
    nnodes = length(dom.nodes)

    # all local data from elements
    all_node_vals  = Array{OrderedDict{Symbol,Array{Float64,1}}, 1}()
    all_fields_set = OrderedSet{Symbol}()
    rec_elements   = Array{Element, 1}()

    for elem in dom.elems
        elem.shape.family == SOLID_SHAPE && continue
        node_vals = elem_extrapolated_node_vals(elem)
        length(node_vals) == 0 && continue

        push!(rec_elements, elem)
        push!(all_node_vals, node_vals)
        union!(all_fields_set, keys(node_vals))
    end

    # map field => index
    all_fields_idx = OrderedDict( key=>i for (i,key) in enumerate(all_fields_set) )
    nfields = length(all_fields_set)

    # matrices for all nodal values and repetitions
    V_vals =  zeros(Float64, nnodes, nfields)
    V_reps =  zeros(Int64  , nnodes, nfields)

    length(rec_elements) == 0 && return V_vals, collect(all_fields_set)

    # local recovery
    for (i,elem) in enumerate(rec_elements)
        node_vals = all_node_vals[i]
        row_idxs  = [ node.id for node in elem.nodes ]

        for (field, vals) in node_vals

            idx = all_fields_idx[field]
            V_vals[row_idxs, idx] .+= vals
            V_reps[row_idxs, idx] .+= 1
        end
    end

    # average values
    V_vals ./= V_reps
    V_vals[isnan.(V_vals)] .= 0.0

    return V_vals, collect(all_fields_set)
end

#=
function save(dom::Domain, filename::String; verbose=true, silent=false)
    format = split(filename, ".")[end]
    mesh = convert(Mesh, dom)
    save(mesh, filename, silent=silent)

    #if     format=="vtk" ; save_dom_vtk(dom, filename, silent=silent)
    #elseif format=="json"; save_dom_json(dom, filename, silent=silent)
    #else   error("save: Cannot save $(typeof(dom)) in $format format. Available formats are vtk and json")
    #end
end
=#


function save(elems::Array{<:Element,1}, filename::String; verbose=true)
    # Save a group of elements as a subdomain
    subdom = SubDomain(elems)
    save(subdom, filename, silent=silent)
end


function save_dom_vtk(dom::Domain, filename::String; verbose=true, silent=false)
    mesh = convert(Mesh, dom)
    save(mesh, filename, silent=silent)
    #verbose && printstyled("  file $filename written (Domain)\n", color=:cyan)
end


function save_dom_json(dom::Domain, filename::String; verbose=true)
    data  = OrderedDict{String,Any}()
    #ugrid = convert(UnstructuredGrid, dom)

    data["points"] = ugrid.nodes
    data["cells"]  = ugrid.elems
    data["types"]  = [ split(string(typeof(elem)),".")[end] for elem in dom.elems]
    data["node_data"] = ugrid.node_data
    data["elem_data"]  = ugrid.elem_data

    X = [ ip.coord[1] for elem in dom.elems for ip in elem.ips ]
    Y = [ ip.coord[2] for elem in dom.elems for ip in elem.ips ]
    Z = [ ip.coord[3] for elem in dom.elems for ip in elem.ips ]
    data["state_points"] = [ X, Y, Z ]

    cell_state_points = []
    k = 0
    for elem in dom.elems
        nips = length(elem.ips)
        push!(cell_state_points, collect(k+1:k+nips))
        k += nips
    end
    data["cell_state_points"] = cell_state_points

    data["state_node_data"] = [ ip_state_vals(elem.mat, ip.data) for elem in dom.elems for ip in elem.ips ]

    f = open(filename, "w")
    print(f, JSON.json(data,4))
    close(f)

    verbose && printstyled("  file $filename written (Domain)\n", color=:cyan)
end


#function Base.convert(::Type{Mesh}, dom::AbstractDomain)
    #merge!(dom.mesh.node_data, dom.node_data)
    #merge!(dom.mesh.elem_data , dom.elem_data)
    #return dom.mesh
#end

#=
function Base.convert(::Type{Mesh}, dom::AbstractDomain)
    mesh = Mesh()
    mesh.ndim = dom.env.ndim

    # Setting points
    npoints = length(dom.nodes)
    for i=1:npoints
        X = dom.nodes[i].coord
        point = Point(X[1], X[2], X[3])
        push!(mesh.nodes, point)
    end

    # Setting cells
    ncells = length(dom.elems)
    for i=1:ncells
        elem = dom.elems[i]
        points = [ mesh.nodes[node.id] for node in elem.nodes ]
        push!(mesh.elems, Cell(elem.shape, points, tag=elem.tag ) )
    end

    fixup!(mesh, reorder=false) # updates also point and cell numbering

    merge!(mesh.node_data, dom.node_data)
    merge!(mesh.elem_data , dom.elem_data)

    return mesh
end


"""
    mplot(dom<:AbstractDomain, args...)

    Plots `dom` using the PyPlot package.
"""
function mplot(dom::AbstractDomain, filename::String=""; args...)

    any(node.id==0 for node in dom.nodes) && error("mplot: all nodes must have a valid id")

    mesh = convert(Mesh, dom)

    mplot(mesh, filename; args...)
end


function datafields(dom::Domain)
    mesh = convert(Mesh, dom)
    return datafields(mesh)
end
=#

#=
function get_segment_data(dom::Domain, X1::Array{<:Real,1}, X2::Array{<:Real,1}, filename::String=""; npoints=50)
    msh = dom.mesh
    data = dom.node_data
    table = DataTable(["s"; collect(keys(data))])
    X1 = [X1; 0.0][1:3]
    X2 = [X2; 0.0][1:3]
    Δ = (X2-X1)/(npoints-1)
    Δs = norm(Δ)
    s1 = 0.0

    for i=1:npoints
        X = X1 + Δ*(i-1)
        s = s1 + Δs*(i-1)
        cell = find_elem(X, msh.elems, msh._elempartition, 1e-7, Cell[])
        coords = getcoords(cell)
        R = inverse_map(cell.shape, coords, X)
        N = cell.shape.func(R)
        map = [ p.id for p in cell.nodes ]
        vals = [ s ]
        for (k,V) in data
            val = dot(V[map], N)
            push!(vals, val)
        end
        push!(table, vals)
    end

    filename != "" && save(table, filename)

    return table
end
=#
