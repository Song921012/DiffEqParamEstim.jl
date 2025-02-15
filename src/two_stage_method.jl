export TwoStageCost, two_stage_method

struct TwoStageCost{F, F2, D} <: Function
    cost_function::F
    cost_function2::F2
    estimated_solution::D
    estimated_derivative::D
end

(f::TwoStageCost)(p) = f.cost_function(p)
(f::TwoStageCost)(p, g) = f.cost_function2(p, g)

decide_kernel(kernel::CollocationKernel) = kernel
function decide_kernel(kernel::Symbol)
    if kernel == :Epanechnikov
        return EpanechnikovKernel()
    elseif kernel == :Uniform
        return UniformKernel()
    elseif kernel == :Triangular
        return TriangularKernel()
    elseif kernel == :Quartic
        return QuarticKernel()
    elseif kernel == :Triweight
        return TriweightKernel()
    elseif kernel == :Tricube
        return TricubeKernel()
    elseif kernel == :Gaussian
        return GaussianKernel()
    elseif kernel == :Cosine
        return CosineKernel()
    elseif kernel == :Logistic
        return LogisticKernel()
    elseif kernel == :Sigmoid
        return SigmoidKernel()
    else
        return SilvermanKernel()
    end
end

function construct_t1(t, tpoints)
    hcat(ones(eltype(tpoints), length(tpoints)), tpoints .- t)
end
function construct_t2(t, tpoints)
    hcat(ones(eltype(tpoints), length(tpoints)), tpoints .- t, (tpoints .- t) .^ 2)
end
function construct_w(t, tpoints, h, kernel)
    W = @. calckernel((kernel,), (tpoints - t) / h) / h
    Diagonal(W)
end
function construct_estimated_solution_and_derivative!(data, kernel, tpoints)
    _one = oneunit(first(data))
    _zero = zero(first(data))
    e1 = [_one; _zero]
    e2 = [_zero; _one; _zero]
    n = length(tpoints)
    h = (n^(-1 / 5)) * (n^(-3 / 35)) * ((log(n))^(-1 / 16))

    Wd = similar(data, n, size(data, 1))
    WT1 = similar(data, n, 2)
    WT2 = similar(data, n, 3)
    x = map(tpoints) do _t
        T1 = construct_t1(_t, tpoints)
        T2 = construct_t2(_t, tpoints)
        W = construct_w(_t, tpoints, h, kernel)
        mul!(Wd, W, data')
        mul!(WT1, W, T1)
        mul!(WT2, W, T2)
        (e2' * ((T2' * WT2) \ T2')) * Wd, (e1' * ((T1' * WT1) \ T1')) * Wd
    end
    estimated_derivative = reduce(hcat, transpose.(first.(x)))
    estimated_solution = reduce(hcat, transpose.(last.(x)))
    estimated_derivative, estimated_solution
end
function construct_iip_cost_function(f, du, preview_est_sol, preview_est_deriv, tpoints)
    function (p)
        _du = PreallocationTools.get_tmp(du, p)
        vecdu = vec(_du)
        cost = zero(first(p))
        for i in 1:length(preview_est_sol)
            est_sol = preview_est_sol[i]
            f(_du, est_sol, p, tpoints[i])
            vecdu .= vec(preview_est_deriv[i]) .- vec(_du)
            cost += sum(abs2, vecdu)
        end
        sqrt(cost)
    end
end

function construct_oop_cost_function(f, du, preview_est_sol, preview_est_deriv, tpoints)
    function (p)
        cost = zero(first(p))
        for i in 1:length(preview_est_sol)
            est_sol = preview_est_sol[i]
            _du = f(est_sol, p, tpoints[i])
            cost += sum(abs2, vec(preview_est_deriv[i]) .- vec(_du))
        end
        sqrt(cost)
    end
end

get_chunksize(cs) = cs
get_chunksize(cs::Type{Val{CS}}) where {CS} = CS

function two_stage_method(prob::DiffEqBase.DEProblem, tpoints, data;
                          kernel = EpanechnikovKernel(),
                          loss_func = L2Loss, mpg_autodiff = false,
                          verbose = false, verbose_steps = 100,
                          autodiff_chunk = length(prob.p))
    f = prob.f
    kernel_function = decide_kernel(kernel)
    estimated_derivative, estimated_solution = construct_estimated_solution_and_derivative!(data,
                                                                                            kernel_function,
                                                                                            tpoints)

    # Step - 2

    du = PreallocationTools.dualcache(similar(prob.u0), autodiff_chunk)
    preview_est_sol = [@view estimated_solution[:, i]
                       for i in 1:size(estimated_solution, 2)]
    preview_est_deriv = [@view estimated_derivative[:, i]
                         for i in 1:size(estimated_solution, 2)]
    if DiffEqBase.isinplace(prob)
        cost_function = construct_iip_cost_function(f, du, preview_est_sol,
                                                    preview_est_deriv, tpoints)
    else
        cost_function = construct_oop_cost_function(f, du, preview_est_sol,
                                                    preview_est_deriv, tpoints)
    end

    if mpg_autodiff
        gcfg = ForwardDiff.GradientConfig(cost_function, prob.p,
                                          ForwardDiff.Chunk{get_chunksize(autodiff_chunk)}())
        g! = (x, out) -> ForwardDiff.gradient!(out, cost_function, x, gcfg)
    else
        g! = (x, out) -> Calculus.finite_difference!(cost_function, x, out, :central)
    end
    if verbose
        count = 0 # keep track of # function evaluations
    end
    cost_function2 = function (p, grad)
        if length(grad) > 0
            g!(p, grad)
        end
        loss_val = cost_function(p)
        if verbose
            count::Int += 1
            if mod(count, verbose_steps) == 0
                println("Iteration: $count")
                println("Current Cost: $loss_val")
                println("Parameters: $p")
            end
        end
        loss_val
    end

    return TwoStageCost(cost_function, cost_function2, estimated_solution,
                        estimated_derivative)
end
