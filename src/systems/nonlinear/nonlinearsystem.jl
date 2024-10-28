"""
$(TYPEDEF)

A nonlinear system of equations.

# Fields
$(FIELDS)

# Examples

```julia
@variables x y z
@parameters σ ρ β

eqs = [0 ~ σ*(y-x),
       0 ~ x*(ρ-z)-y,
       0 ~ x*y - β*z]
@named ns = NonlinearSystem(eqs, [x,y,z],[σ,ρ,β])
```
"""
struct NonlinearSystem <: AbstractTimeIndependentSystem
    """
    A tag for the system. If two systems have the same tag, then they are
    structurally identical.
    """
    tag::UInt
    """Vector of equations defining the system."""
    eqs::Vector{Equation}
    """Unknown variables."""
    unknowns::Vector
    """Parameters."""
    ps::Vector
    """Array variables."""
    var_to_name::Any
    """Observed variables."""
    observed::Vector{Equation}
    """
    Jacobian matrix. Note: this field will not be defined until
    [`calculate_jacobian`](@ref) is called on the system.
    """
    jac::RefValue{Any}
    """
    The name of the system.
    """
    name::Symbol
    """
    A description of the system.
    """
    description::String
    """
    The internal systems. These are required to have unique names.
    """
    systems::Vector{NonlinearSystem}
    """
    The default values to use when initial conditions and/or
    parameters are not supplied in `ODEProblem`.
    """
    defaults::Dict
    """
    Type of the system.
    """
    connector_type::Any
    """
    Topologically sorted parameter dependency equations, where all symbols are parameters and
    the LHS is a single parameter.
    """
    parameter_dependencies::Vector{Equation}
    """
    Metadata for the system, to be used by downstream packages.
    """
    metadata::Any
    """
    Metadata for MTK GUI.
    """
    gui_metadata::Union{Nothing, GUIMetadata}
    """
    Cache for intermediate tearing state.
    """
    tearing_state::Any
    """
    Substitutions generated by tearing.
    """
    substitutions::Any
    """
    If a model `sys` is complete, then `sys.x` no longer performs namespacing.
    """
    complete::Bool
    """
    Cached data for fast symbolic indexing.
    """
    index_cache::Union{Nothing, IndexCache}
    """
    The hierarchical parent system before simplification.
    """
    parent::Any
    isscheduled::Bool

    function NonlinearSystem(
            tag, eqs, unknowns, ps, var_to_name, observed, jac, name, description,
            systems,
            defaults, connector_type, parameter_dependencies = Equation[], metadata = nothing,
            gui_metadata = nothing,
            tearing_state = nothing, substitutions = nothing,
            complete = false, index_cache = nothing, parent = nothing,
            isscheduled = false; checks::Union{Bool, Int} = true)
        if checks == true || (checks & CheckUnits) > 0
            u = __get_unit_type(unknowns, ps)
            check_units(u, eqs)
        end
        new(tag, eqs, unknowns, ps, var_to_name, observed,
            jac, name, description, systems, defaults,
            connector_type, parameter_dependencies, metadata, gui_metadata, tearing_state,
            substitutions, complete, index_cache, parent, isscheduled)
    end
end

function NonlinearSystem(eqs, unknowns, ps;
        observed = [],
        name = nothing,
        description = "",
        default_u0 = Dict(),
        default_p = Dict(),
        defaults = _merge(Dict(default_u0), Dict(default_p)),
        systems = NonlinearSystem[],
        connector_type = nothing,
        continuous_events = nothing, # this argument is only required for ODESystems, but is added here for the constructor to accept it without error
        discrete_events = nothing,   # this argument is only required for ODESystems, but is added here for the constructor to accept it without error
        checks = true,
        parameter_dependencies = Equation[],
        metadata = nothing,
        gui_metadata = nothing)
    continuous_events === nothing || isempty(continuous_events) ||
        throw(ArgumentError("NonlinearSystem does not accept `continuous_events`, you provided $continuous_events"))
    discrete_events === nothing || isempty(discrete_events) ||
        throw(ArgumentError("NonlinearSystem does not accept `discrete_events`, you provided $discrete_events"))
    name === nothing &&
        throw(ArgumentError("The `name` keyword must be provided. Please consider using the `@named` macro"))
    length(unique(nameof.(systems))) == length(systems) ||
        throw(ArgumentError("System names must be unique."))
    (isempty(default_u0) && isempty(default_p)) ||
        Base.depwarn(
            "`default_u0` and `default_p` are deprecated. Use `defaults` instead.",
            :NonlinearSystem, force = true)

    # Accept a single (scalar/vector) equation, but make array for consistent internal handling
    if !(eqs isa AbstractArray)
        eqs = [eqs]
    end

    # Copy equations to canonical form, but do not touch array expressions
    eqs = [wrap(eq.lhs) isa Symbolics.Arr ? eq : 0 ~ eq.rhs - eq.lhs for eq in eqs]

    jac = RefValue{Any}(EMPTY_JAC)
    defaults = todict(defaults)
    defaults = Dict{Any, Any}(value(k) => value(v)
    for (k, v) in pairs(defaults) if value(v) !== nothing)

    unknowns, ps = value.(unknowns), value.(ps)
    var_to_name = Dict()
    process_variables!(var_to_name, defaults, unknowns)
    process_variables!(var_to_name, defaults, ps)
    isempty(observed) || collect_var_to_name!(var_to_name, (eq.lhs for eq in observed))

    parameter_dependencies, ps = process_parameter_dependencies(
        parameter_dependencies, ps)
    NonlinearSystem(Threads.atomic_add!(SYSTEM_COUNT, UInt(1)),
        eqs, unknowns, ps, var_to_name, observed, jac, name, description, systems, defaults,
        connector_type, parameter_dependencies, metadata, gui_metadata, checks = checks)
end

function NonlinearSystem(eqs; kwargs...)
    eqs = collect(eqs)
    allunknowns = OrderedSet()
    ps = OrderedSet()
    for eq in eqs
        collect_vars!(allunknowns, ps, eq, nothing)
    end
    for eq in get(kwargs, :parameter_dependencies, Equation[])
        if eq isa Pair
            collect_vars!(allunknowns, ps, eq, nothing)
        else
            collect_vars!(allunknowns, ps, eq, nothing)
        end
    end
    new_ps = OrderedSet()
    for p in ps
        if iscall(p) && operation(p) === getindex
            par = arguments(p)[begin]
            if Symbolics.shape(Symbolics.unwrap(par)) !== Symbolics.Unknown() &&
               all(par[i] in ps for i in eachindex(par))
                push!(new_ps, par)
            else
                push!(new_ps, p)
            end
        else
            push!(new_ps, p)
        end
    end

    return NonlinearSystem(eqs, collect(allunknowns), collect(new_ps); kwargs...)
end

function calculate_jacobian(sys::NonlinearSystem; sparse = false, simplify = false)
    cache = get_jac(sys)[]
    if cache isa Tuple && cache[2] == (sparse, simplify)
        return cache[1]
    end

    # observed equations may depend on unknowns, so substitute them in first
    # TODO: rather keep observed derivatives unexpanded, like "Differential(obs)(expr)"?
    obs = Dict(eq.lhs => eq.rhs for eq in observed(sys))
    rhs = map(eq -> fixpoint_sub(eq.rhs, obs), equations(sys))
    vals = [dv for dv in unknowns(sys)]

    if sparse
        jac = sparsejacobian(rhs, vals, simplify = simplify)
    else
        jac = jacobian(rhs, vals, simplify = simplify)
    end
    get_jac(sys)[] = jac, (sparse, simplify)
    return jac
end

function generate_jacobian(
        sys::NonlinearSystem, vs = unknowns(sys), ps = parameters(sys);
        sparse = false, simplify = false, wrap_code = identity, kwargs...)
    jac = calculate_jacobian(sys, sparse = sparse, simplify = simplify)
    pre, sol_states = get_substitutions_and_solved_unknowns(sys)
    p = reorder_parameters(sys, ps)
    wrap_code = wrap_code .∘ wrap_array_vars(sys, jac; dvs = vs, ps) .∘
                wrap_parameter_dependencies(sys, false)
    return build_function(
        jac, vs, p...; postprocess_fbody = pre, states = sol_states, wrap_code, kwargs...)
end

function calculate_hessian(sys::NonlinearSystem; sparse = false, simplify = false)
    obs = Dict(eq.lhs => eq.rhs for eq in observed(sys))
    rhs = map(eq -> fixpoint_sub(eq.rhs, obs), equations(sys))
    vals = [dv for dv in unknowns(sys)]
    if sparse
        hess = [sparsehessian(rhs[i], vals, simplify = simplify) for i in 1:length(rhs)]
    else
        hess = [hessian(rhs[i], vals, simplify = simplify) for i in 1:length(rhs)]
    end
    return hess
end

function generate_hessian(
        sys::NonlinearSystem, vs = unknowns(sys), ps = parameters(sys);
        sparse = false, simplify = false, wrap_code = identity, kwargs...)
    hess = calculate_hessian(sys, sparse = sparse, simplify = simplify)
    pre = get_preprocess_constants(hess)
    p = reorder_parameters(sys, ps)
    wrap_code = wrap_code .∘ wrap_array_vars(sys, hess; dvs = vs, ps) .∘
                wrap_parameter_dependencies(sys, false)
    return build_function(hess, vs, p...; postprocess_fbody = pre, wrap_code, kwargs...)
end

function generate_function(
        sys::NonlinearSystem, dvs = unknowns(sys), ps = parameters(sys);
        wrap_code = identity, kwargs...)
    rhss = [deq.rhs for deq in equations(sys)]
    pre, sol_states = get_substitutions_and_solved_unknowns(sys)
    wrap_code = wrap_code .∘ wrap_array_vars(sys, rhss; dvs, ps) .∘
                wrap_parameter_dependencies(sys, false)
    p = reorder_parameters(sys, value.(ps))
    return build_function(rhss, value.(dvs), p...; postprocess_fbody = pre,
        states = sol_states, wrap_code, kwargs...)
end

function jacobian_sparsity(sys::NonlinearSystem)
    jacobian_sparsity([eq.rhs for eq in equations(sys)],
        unknowns(sys))
end

function hessian_sparsity(sys::NonlinearSystem)
    [hessian_sparsity(eq.rhs,
         unknowns(sys)) for eq in equations(sys)]
end

"""
```julia
SciMLBase.NonlinearFunction{iip}(sys::NonlinearSystem, dvs = unknowns(sys),
                                 ps = parameters(sys);
                                 version = nothing,
                                 jac = false,
                                 sparse = false,
                                 kwargs...) where {iip}
```

Create an `NonlinearFunction` from the [`NonlinearSystem`](@ref). The arguments
`dvs` and `ps` are used to set the order of the dependent variable and parameter
vectors, respectively.
"""
function SciMLBase.NonlinearFunction(sys::NonlinearSystem, args...; kwargs...)
    NonlinearFunction{true}(sys, args...; kwargs...)
end

function SciMLBase.NonlinearFunction{iip}(sys::NonlinearSystem, dvs = unknowns(sys),
        ps = parameters(sys), u0 = nothing; p = nothing,
        version = nothing,
        jac = false,
        eval_expression = false,
        eval_module = @__MODULE__,
        sparse = false, simplify = false,
        kwargs...) where {iip}
    if !iscomplete(sys)
        error("A completed `NonlinearSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `NonlinearFunction`")
    end
    f_gen = generate_function(sys, dvs, ps; expression = Val{true}, kwargs...)
    f_oop, f_iip = eval_or_rgf.(f_gen; eval_expression, eval_module)
    f(u, p) = f_oop(u, p)
    f(u, p::MTKParameters) = f_oop(u, p...)
    f(du, u, p) = f_iip(du, u, p)
    f(du, u, p::MTKParameters) = f_iip(du, u, p...)

    if jac
        jac_gen = generate_jacobian(sys, dvs, ps;
            simplify = simplify, sparse = sparse,
            expression = Val{true}, kwargs...)
        jac_oop, jac_iip = eval_or_rgf.(jac_gen; eval_expression, eval_module)
        _jac(u, p) = jac_oop(u, p)
        _jac(u, p::MTKParameters) = jac_oop(u, p...)
        _jac(J, u, p) = jac_iip(J, u, p)
        _jac(J, u, p::MTKParameters) = jac_iip(J, u, p...)
    else
        _jac = nothing
    end

    observedfun = ObservedFunctionCache(sys; eval_expression, eval_module)

    if length(dvs) == length(equations(sys))
        resid_prototype = nothing
    else
        u0ElType = u0 === nothing ? Float64 : eltype(u0)
        if SciMLStructures.isscimlstructure(p)
            u0ElType = promote_type(
                eltype(SciMLStructures.canonicalize(SciMLStructures.Tunable(), p)[1]),
                u0ElType)
        end
        resid_prototype = zeros(u0ElType, length(equations(sys)))
    end

    NonlinearFunction{iip}(f,
        sys = sys,
        jac = _jac === nothing ? nothing : _jac,
        resid_prototype = resid_prototype,
        jac_prototype = sparse ?
                        similar(calculate_jacobian(sys, sparse = sparse),
            Float64) : nothing,
        observed = observedfun)
end

"""
```julia
SciMLBase.NonlinearFunctionExpr{iip}(sys::NonlinearSystem, dvs = unknowns(sys),
                                     ps = parameters(sys);
                                     version = nothing,
                                     jac = false,
                                     sparse = false,
                                     kwargs...) where {iip}
```

Create a Julia expression for an `ODEFunction` from the [`ODESystem`](@ref).
The arguments `dvs` and `ps` are used to set the order of the dependent
variable and parameter vectors, respectively.
"""
struct NonlinearFunctionExpr{iip} end

function NonlinearFunctionExpr{iip}(sys::NonlinearSystem, dvs = unknowns(sys),
        ps = parameters(sys), u0 = nothing, p = nothing;
        version = nothing, tgrad = false,
        jac = false,
        linenumbers = false,
        sparse = false, simplify = false,
        kwargs...) where {iip}
    if !iscomplete(sys)
        error("A completed `NonlinearSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `NonlinearFunctionExpr`")
    end
    idx = iip ? 2 : 1
    f = generate_function(sys, dvs, ps; expression = Val{true}, kwargs...)[idx]

    if jac
        _jac = generate_jacobian(sys, dvs, ps;
            sparse = sparse, simplify = simplify,
            expression = Val{true}, kwargs...)[idx]
    else
        _jac = :nothing
    end

    jp_expr = sparse ? :(similar($(get_jac(sys)[]), Float64)) : :nothing
    if length(dvs) == length(equations(sys))
        resid_expr = :nothing
    else
        u0ElType = u0 === nothing ? Float64 : eltype(u0)
        if SciMLStructures.isscimlstructure(p)
            u0ElType = promote_type(
                eltype(SciMLStructures.canonicalize(SciMLStructures.Tunable(), p)[1]),
                u0ElType)
        end

        resid_expr = :(zeros($u0ElType, $(length(equations(sys)))))
    end
    ex = quote
        f = $f
        jac = $_jac
        NonlinearFunction{$iip}(f,
            jac = jac,
            resid_prototype = resid_expr,
            jac_prototype = $jp_expr)
    end
    !linenumbers ? Base.remove_linenums!(ex) : ex
end

"""
```julia
DiffEqBase.NonlinearProblem{iip}(sys::NonlinearSystem, u0map,
                                 parammap = DiffEqBase.NullParameters();
                                 jac = false, sparse = false,
                                 checkbounds = false,
                                 linenumbers = true, parallel = SerialForm(),
                                 kwargs...) where {iip}
```

Generates an NonlinearProblem from a NonlinearSystem and allows for automatically
symbolically calculating numerical enhancements.
"""
function DiffEqBase.NonlinearProblem(sys::NonlinearSystem, args...; kwargs...)
    NonlinearProblem{true}(sys, args...; kwargs...)
end

function DiffEqBase.NonlinearProblem{iip}(sys::NonlinearSystem, u0map,
        parammap = DiffEqBase.NullParameters();
        check_length = true, kwargs...) where {iip}
    if !iscomplete(sys)
        error("A completed `NonlinearSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `NonlinearProblem`")
    end
    f, u0, p = process_SciMLProblem(NonlinearFunction{iip}, sys, u0map, parammap;
        check_length, kwargs...)
    pt = something(get_metadata(sys), StandardNonlinearProblem())
    NonlinearProblem{iip}(f, u0, p, pt; filter_kwargs(kwargs)...)
end

"""
```julia
DiffEqBase.NonlinearLeastSquaresProblem{iip}(sys::NonlinearSystem, u0map,
                                 parammap = DiffEqBase.NullParameters();
                                 jac = false, sparse = false,
                                 checkbounds = false,
                                 linenumbers = true, parallel = SerialForm(),
                                 kwargs...) where {iip}
```

Generates an NonlinearProblem from a NonlinearSystem and allows for automatically
symbolically calculating numerical enhancements.
"""
function DiffEqBase.NonlinearLeastSquaresProblem(sys::NonlinearSystem, args...; kwargs...)
    NonlinearLeastSquaresProblem{true}(sys, args...; kwargs...)
end

function DiffEqBase.NonlinearLeastSquaresProblem{iip}(sys::NonlinearSystem, u0map,
        parammap = DiffEqBase.NullParameters();
        check_length = false, kwargs...) where {iip}
    if !iscomplete(sys)
        error("A completed `NonlinearSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `NonlinearLeastSquaresProblem`")
    end
    f, u0, p = process_SciMLProblem(NonlinearFunction{iip}, sys, u0map, parammap;
        check_length, kwargs...)
    pt = something(get_metadata(sys), StandardNonlinearProblem())
    NonlinearLeastSquaresProblem{iip}(f, u0, p; filter_kwargs(kwargs)...)
end

"""
```julia
DiffEqBase.NonlinearProblemExpr{iip}(sys::NonlinearSystem, u0map,
                                     parammap = DiffEqBase.NullParameters();
                                     jac = false, sparse = false,
                                     checkbounds = false,
                                     linenumbers = true, parallel = SerialForm(),
                                     kwargs...) where {iip}
```

Generates a Julia expression for a NonlinearProblem from a
NonlinearSystem and allows for automatically symbolically calculating
numerical enhancements.
"""
struct NonlinearProblemExpr{iip} end

function NonlinearProblemExpr(sys::NonlinearSystem, args...; kwargs...)
    NonlinearProblemExpr{true}(sys, args...; kwargs...)
end

function NonlinearProblemExpr{iip}(sys::NonlinearSystem, u0map,
        parammap = DiffEqBase.NullParameters();
        check_length = true,
        kwargs...) where {iip}
    if !iscomplete(sys)
        error("A completed `NonlinearSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `NonlinearProblemExpr`")
    end
    f, u0, p = process_SciMLProblem(NonlinearFunctionExpr{iip}, sys, u0map, parammap;
        check_length, kwargs...)
    linenumbers = get(kwargs, :linenumbers, true)

    ex = quote
        f = $f
        u0 = $u0
        p = $p
        NonlinearProblem(f, u0, p; $(filter_kwargs(kwargs)...))
    end
    !linenumbers ? Base.remove_linenums!(ex) : ex
end

"""
```julia
DiffEqBase.NonlinearLeastSquaresProblemExpr{iip}(sys::NonlinearSystem, u0map,
                                     parammap = DiffEqBase.NullParameters();
                                     jac = false, sparse = false,
                                     checkbounds = false,
                                     linenumbers = true, parallel = SerialForm(),
                                     kwargs...) where {iip}
```

Generates a Julia expression for a NonlinearProblem from a
NonlinearSystem and allows for automatically symbolically calculating
numerical enhancements.
"""
struct NonlinearLeastSquaresProblemExpr{iip} end

function NonlinearLeastSquaresProblemExpr(sys::NonlinearSystem, args...; kwargs...)
    NonlinearLeastSquaresProblemExpr{true}(sys, args...; kwargs...)
end

function NonlinearLeastSquaresProblemExpr{iip}(sys::NonlinearSystem, u0map,
        parammap = DiffEqBase.NullParameters();
        check_length = false,
        kwargs...) where {iip}
    if !iscomplete(sys)
        error("A completed `NonlinearSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `NonlinearProblemExpr`")
    end
    f, u0, p = process_SciMLProblem(NonlinearFunctionExpr{iip}, sys, u0map, parammap;
        check_length, kwargs...)
    linenumbers = get(kwargs, :linenumbers, true)

    ex = quote
        f = $f
        u0 = $u0
        p = $p
        NonlinearLeastSquaresProblem(f, u0, p; $(filter_kwargs(kwargs)...))
    end
    !linenumbers ? Base.remove_linenums!(ex) : ex
end

function flatten(sys::NonlinearSystem, noeqs = false)
    systems = get_systems(sys)
    if isempty(systems)
        return sys
    else
        return NonlinearSystem(noeqs ? Equation[] : equations(sys),
            unknowns(sys),
            parameters(sys),
            observed = observed(sys),
            defaults = defaults(sys),
            name = nameof(sys),
            description = description(sys),
            checks = false)
    end
end

function Base.:(==)(sys1::NonlinearSystem, sys2::NonlinearSystem)
    isequal(nameof(sys1), nameof(sys2)) &&
        _eq_unordered(get_eqs(sys1), get_eqs(sys2)) &&
        _eq_unordered(get_unknowns(sys1), get_unknowns(sys2)) &&
        _eq_unordered(get_ps(sys1), get_ps(sys2)) &&
        all(s1 == s2 for (s1, s2) in zip(get_systems(sys1), get_systems(sys2)))
end

"""
$(TYPEDEF)

A type of Nonlinear problem which specializes on polynomial systems and uses
HomotopyContinuation.jl to solve the system. Requires importing HomotopyContinuation.jl to
create and solve.
"""
struct HomotopyContinuationProblem{uType, H, D, O} <:
       SciMLBase.AbstractNonlinearProblem{uType, true}
    """
    The initial values of states in the system. If there are multiple real roots of
    the system, the one closest to this point is returned.
    """
    u0::uType
    """
    A subtype of `HomotopyContinuation.AbstractSystem` to solve. Also contains the
    parameter object.
    """
    homotopy_continuation_system::H
    """
    A function with signature `(u, p) -> resid`. In case of rational functions, this
    is used to rule out roots of the system which would cause the denominator to be
    zero.
    """
    denominator::D
    """
    The `NonlinearSystem` used to create this problem. Used for symbolic indexing.
    """
    sys::NonlinearSystem
    """
    A function which generates and returns observed expressions for the given system.
    """
    obsfn::O
end

function HomotopyContinuationProblem(::AbstractSystem, _u0, _p; kwargs...)
    error("HomotopyContinuation.jl is required to create and solve `HomotopyContinuationProblem`s. Please run `Pkg.add(\"HomotopyContinuation\")` to continue.")
end

SymbolicIndexingInterface.symbolic_container(p::HomotopyContinuationProblem) = p.sys
SymbolicIndexingInterface.state_values(p::HomotopyContinuationProblem) = p.u0
function SymbolicIndexingInterface.set_state!(p::HomotopyContinuationProblem, args...)
    set_state!(p.u0, args...)
end
function SymbolicIndexingInterface.parameter_values(p::HomotopyContinuationProblem)
    parameter_values(p.homotopy_continuation_system)
end
function SymbolicIndexingInterface.set_parameter!(p::HomotopyContinuationProblem, args...)
    set_parameter!(parameter_values(p), args...)
end
function SymbolicIndexingInterface.observed(p::HomotopyContinuationProblem, sym)
    if p.obsfn !== nothing
        return p.obsfn(sym)
    else
        return SymbolicIndexingInterface.observed(p.sys, sym)
    end
end
