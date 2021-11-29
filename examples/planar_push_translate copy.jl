using Plots
using Random
Random.seed!(1)

# ## planar push model 
include("../models/planar_push/model.jl")
include("../models/planar_push/simulator.jl")

# path = @get_scratch!("planarpush")
@load "/home/taylor/Research/optimization_based_dynamics/residual.jld2" r_func rz_func rθ_func rz_array rθ_array

# ## visualization 
include("../models/planar_push/visuals.jl")
include("../models/visualize.jl")
vis = Visualizer() 
render(vis)

# ## build implicit dynamics

h = 0.1
T = 26

eval_sim = Simulator(planarpush, 1; 
        h=h, 
        residual=eval(r_func), 
        jacobian_z=eval(rz_func), 
        jacobian_θ=eval(rθ_func),
        diff_sol=false,
        solver_opts=InteriorPointOptions(
            undercut=Inf,
            γ_reg=0.1,
            r_tol=1.0e-6,
            κ_tol=1.0e-3,  
            max_ls=25,
            ϵ_min=0.25,
            diff_sol=false,
            verbose=false))

# ## discrete-time state-space model
im_dyn = ImplicitDynamics(planarpush, h, eval(r_func), eval(rz_func), eval(rθ_func); 
    r_tol=1.0e-8, κ_eval_tol=1.0e-4, κ_grad_tol=1.0e-3) 

nx = 2 * planarpush.nq
nu = planarpush.nu 
nw = planarpush.nw

# ## dynamics for iLQR
ilqr_dyn = IterativeLQR.Dynamics((d, x, u, w) -> f(d, im_dyn, x, u, w), 
					(dx, x, u, w) -> fx(dx, im_dyn, x, u, w), 
					(du, x, u, w) -> fu(du, im_dyn, x, u, w), 
					nx, nx, nu)  

# ## model for iLQR
model = [ilqr_dyn for t = 1:T-1]


# ## goal
x_goal = 1.0
y_goal = 0.0
θ_goal = 0.0 * π
qT = [x_goal, y_goal, θ_goal, x_goal - r_dim, y_goal - r_dim]
xT = [qT; qT]

# ## objective
function objt(x, u, w)
	J = 0.0 

	q1 = x[1:nq] 
	q2 = x[nq .+ (1:nq)] 
	v1 = (q2 - q1) ./ h

	J += 0.5 * transpose(v1) * Diagonal([1.0, 1.0, 1.0, 0.1, 0.1]) * v1 
	J += 0.5 * transpose(x - xT) * Diagonal([1.0, 1.0, 1.0, 0.1, 0.1, 1.0, 1.0, 1.0, 0.1, 0.1]) * (x - xT) 
	J += 0.5 * 1.0e-1 * transpose(u) * u

	return J
end

function objT(x, u, w)
	J = 0.0 
	
	q1 = x[1:nq] 
	q2 = x[nq .+ (1:nq)] 
	v1 = (q2 - q1) ./ h

	J += 0.5 * transpose(v1) * Diagonal([1.0, 1.0, 1.0, 0.1, 0.1]) * v1 
	J += 0.5 * transpose(x - xT) * Diagonal([1.0, 1.0, 1.0, 0.1, 0.1, 1.0, 1.0, 1.0, 0.1, 0.1]) * (x - xT) 

	return J
end

ct = IterativeLQR.Cost(objt, nx, nu, nw)
cT = IterativeLQR.Cost(objT, nx, 0, 0)
obj = [[ct for t = 1:T-1]..., cT]

# ## constraints
ul = [-5.0; -5.0]
uu = [5.0; 5.0]

function stage_con(x, u, w) 
    [
     ul - u; # control limit (lower)
     u - uu; # control limit (upper)
    ]
end 

function terminal_con(x, u, w) 
    [
     (x - xT)[collect([(1:3)..., (6:8)...])]; # goal 
    ]
end

cont = Constraint(stage_con, nx, nu, idx_ineq=collect(1:(2 * nu)))
conT = Constraint(terminal_con, nx, 0)
cons = [[cont for t = 1:T-1]..., conT]

q0 = [0.0, 0.0, 0.0, -r_dim - 1.0e-8, 0.0]
q1 = [0.0, 0.0, 0.0, -r_dim - 1.0e-8, 0.0]
x1 = [q0; q1]
ū = [t < 5 ? [1.0; 0.0] : [0.0; 0.0] for t = 1:T-1]
w = [zeros(nw) for t = 1:T-1]

x̄ = rollout(model, x1, ū)
q̄ = state_to_configuration(x̄)

prob = problem_data(model, obj, cons)
initialize_controls!(prob, ū)
initialize_states!(prob, x̄)

# ## solve
IterativeLQR.solve!(prob, verbose=true)

# ## solution
x_sol, u_sol = get_trajectory(prob)
q_sol = state_to_configuration(x_sol)
visualize!(vis, cartpole, q_sol, Δt=h)