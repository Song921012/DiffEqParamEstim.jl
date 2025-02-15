using DiffEqParamEstim, OrdinaryDiffEq, StochasticDiffEq, ParameterizedFunctions,
      DiffEqBase, RecursiveArrayTools
using Test

pf_func = function (du, u, p, t)
    du[1] = p[1] * u[1] - p[2] * u[1] * u[2]
    du[2] = -3 * u[2] + u[1] * u[2]
end

u0 = [1.0; 1.0]
tspan = (0.0, 10.0)
p = [1.5, 1.0]
prob = ODEProblem(pf_func, u0, tspan, p)
sol = solve(prob, Tsit5())

t = collect(range(0, stop = 10, length = 200))
randomized = VectorOfArray([(sol(t[i]) + 0.01randn(2)) for i in 1:length(t)])
data = convert(Array, randomized)

monte_prob = EnsembleProblem(prob)
obj = build_loss_objective(monte_prob, Tsit5(), L2Loss(t, data), maxiters = 10000,
                           abstol = 1e-8, reltol = 1e-8,
                           verbose = false, trajectories = 25)

import Optim
result = Optim.optimize(obj, [1.3, 0.8], Optim.BFGS())
@test result.minimizer≈[1.5, 1.0] atol=3e-1

pg_func = function (du, u, p, t)
    du[1] = 1e-6u[1]
    du[2] = 1e-6u[2]
end
prob = SDEProblem(pf_func, pg_func, u0, tspan, p)
sol = solve(prob, SRIW1())

monte_prob = EnsembleProblem(prob)

# Too stochastic for CI
#=
srand(200)
obj = build_loss_objective(monte_prob,SRIW1(),L2Loss(t,data),maxiters=1000,
                           verbose=false,verbose_opt=false,verbose_steps=1,trajectories=50)

result = Optim.optimize(obj, [1.4,0.95], Optim.BFGS())
@test result.minimizer ≈ [1.5,1.0] atol=3e-1
=#
