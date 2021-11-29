using Plots
using Random

# ## planar push model 
include("../models/double_pendulum/model.jl")
# include("../models/double_pendulum/simulator_impact.jl")
include("../models/double_pendulum/simulator_no_impact.jl")

path = @get_scratch!("acrobot")
# @load joinpath(path, "impact.jld2") r_func rz_func rθ_func rz_array rθ_array
@load joinpath(path, "no_impact.jld2") r_no_impact_func rz_no_impact_func rθ_no_impact_func rz_no_impact_array rθ_no_impact_array

# ## visualization 
include("../models/double_pendulum/visuals.jl")
include("../models/visualize.jl")
vis = Visualizer() 
render(vis)

# ## build implicit dynamics
h = 0.05
T = 101

# ## discrete-time state-space model
# im_dyn = ImplicitDynamics(acrobot, h, eval(r_func), eval(rz_func), eval(rθ_func); 
#     r_tol=1.0e-8, κ_eval_tol=1.0e-4, κ_grad_tol=1.0e-2, no_friction=true) 

im_dyn = ImplicitDynamics(acrobot, h, eval(r_no_impact_func), eval(rz_no_impact_func), eval(rθ_no_impact_func); 
    r_tol=1.0e-8, κ_eval_tol=1.0e-4, κ_grad_tol=1.0e-2, no_impact=true, no_friction=true) 

nx = 2 * acrobot.nq
nu = acrobot.nu 
nw = acrobot.nw

# ## dynamics for iLQR
ilqr_dyn = IterativeLQR.Dynamics((d, x, u, w) -> f(d, im_dyn, x, u, w), 
					(dx, x, u, w) -> fx(dx, im_dyn, x, u, w), 
					(du, x, u, w) -> fu(du, im_dyn, x, u, w), 
					nx, nx, nu)  

# ## model for iLQR
model = [ilqr_dyn for t = 1:T-1]

q0 = [0.0; 0.0]
q1 = [0.0; 0.0]
qT = [π; 0.0]
q_ref = [π; 0.0]

x1 = [q0; q1]
xT = [qT; qT]

# ## objective
function objt(x, u, w)
	J = 0.0 

	q1 = x[1:nq] 
	q2 = x[nq .+ (1:nq)] 
	v1 = (q2 - q1) ./ h

	J += 0.5 * 0.1 * transpose(v1) * v1 
	J += 0.5 * transpose(u) * u

	return J
end

function objT(x, u, w)
	J = 0.0 
	
	q1 = x[1:nq] 
	q2 = x[nq .+ (1:nq)] 
	v1 = (q2 - q1) ./ h

	J += 0.5 * 0.1 * transpose(v1) * v1

	return J
end

ct = IterativeLQR.Cost(objt, nx, nu, nw)
cT = IterativeLQR.Cost(objT, nx, 0, 0)
obj = [[ct for t = 1:T-1]..., cT]

# ## constraints
function terminal_con(x, u, w) 
    [
    x - xT; # goal 
    ]
end

cont = Constraint()
conT = Constraint(terminal_con, nx, 0)
cons = [[cont for t = 1:T-1]..., conT]

# ## rollout
ū = [1.0e-3 * randn(nu) for t = 1:T-1]
w = [zeros(nw) for t = 1:T-1]
x̄ = rollout(model, x1, ū)
q̄ = state_to_configuration(x̄)
visualize!(vis, acrobot, q̄, Δt=h)

prob = problem_data(model, obj, cons)
initialize_controls!(prob, ū)
initialize_states!(prob, x̄)

# ## solve
IterativeLQR.solve!(prob, verbose=true)

# ## solution
x_sol, u_sol = get_trajectory(prob)
q_sol = state_to_configuration(x_sol)
visualize!(vis, acrobot, q_sol, Δt=h)
