using Amaru
#using Test
#

# Mesh generation
blocks = [Block([0 0; 1 2], nx=4, ny=8, tag="solids"),]

msh = Mesh(blocks, verbose = true)

# Finite element analysis

# Analysis data
k = 0.0502  # thermal conductivity kW/m/K
rho = 7.8   # densidade ton/m3
cv = 486    # specific heat (capacity) kJ/ton/K

materials = ["solids" => LinThermo(k=k, rho=rho, cv=cv)]
dom = Domain(msh, materials)
#dom.env.T0 = 0
#@show dump(dom.env)

log1 = NodeGroupLogger()
loggers = [
           :(y==1) => log1,
           :(x==0.5 && y==1) => NodeLogger("node.dat")
          ]
setloggers!(dom, loggers)


bcs = [:(y == 0) => NodeBC(ut=100.0),
       :(y == 2) => NodeBC(ut=20.0),
]

tm_solve!(dom, bcs, end_time=9000, tol=0.1, nincs=10, nouts=10, verbose=true)
