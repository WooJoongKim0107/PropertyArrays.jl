module PropertyArrays
export PropertyObject, PObject, register, @register, @register_fn, @delegate, @pcalc, PropertyArray, PArray, translate, psave, pload

using JLD2: save_object, load_object

# ============================================================================
# PropertyObject AbstractType
# ============================================================================

"""
    abstract type PropertyObject

Base type for structs that opt into the attribute-registration system.
`PObject` is an exported alias for `PropertyObject`.

A function registered for a `PropertyObject` subtype can be accessed as if
it were a real field of that type. This is useful with `PropertyArray`
(`PArray` is an exported alias): after registering a calculation such as
`angle(p)`, a property array of particles can expose it as
`particles.angle` instead of `angle.(particles)`.

# Example
```julia
struct Particle <: PObject
    x::Float64
    y::Float64
end

register(Particle, :radius_sq) do p
    p.x^2 + p.y^2
end

p = Particle(3.0, 4.0)
p.radius_sq  # 25.0
```

See [`register`](@ref) and [`@register`](@ref) for ways to add attributes.
"""
abstract type PropertyObject end

"""
    PObject

Alias for `PropertyObject`.
"""
const PObject = PropertyObject

# Marker function: dispatch target for registered attributes.
# A registered attribute (T, :name => f) becomes a method:
#     _attr(::Val{:name}, x::T) = f(x)
function _attr end

function Base.getproperty(x::T, s::Symbol) where T <: PropertyObject
    if hasfield(T, s)
        return getfield(x, s)
    elseif hasmethod(_attr, Tuple{Val{s}, T})
        return _attr(Val(s), x)
    else
        error("type $(T) has no field $(s)")
    end
end

function Base.hasproperty(x::T, s::Symbol) where T <: PropertyObject
    if hasfield(T, s)
        return true
    elseif hasmethod(_attr, Tuple{Val{s}, T})
        return true
    else
        return false
    end
end

"""
    register(f, T::Type, s::Symbol = Symbol(f))

Register function `f` as attribute `s` for type `T`, which must be a
[`PropertyObject`](@ref) subtype. After registration, `x.s` on any `x::T`
returns `f(x)`.

If `s` is omitted it defaults to `Symbol(f)` — the function's name.

This function uses `@eval` internally to add a method to the dispatch
table at runtime. It is intended for **interactive use** (REPL, scripts).
**Do not use it at the top level of a package module**: the `@eval` call
runs during precompilation and may overwrite methods, breaking the
precompile cache. For package code, use the [`@register`](@ref) macro,
which emits the method definition as ordinary top-level code.

Use `register` when the type, attribute name, or callable is chosen at
runtime. For static package code, prefer [`@register`](@ref); for an existing
named function in package code, prefer [`@register_fn`](@ref).

`register` is a trusted-code extension hook: it does not evaluate strings, but
it mutates the global method table and should not be exposed to untrusted input
or plugin code.

# Examples (interactive use)
```julia
# Plain function reference
radius_sq(p::Particle) = p.x^2 + p.y^2
register(radius_sq, Particle)

# do-block form (anonymous function)
register(Particle, :angle) do p
    atan(p.y, p.x) |> rad2deg
end
```
"""
function register(f, T::Type, s::Symbol)
    T <: PropertyObject || error("register: $T is not a subtype of PropertyObject")
    @eval _attr(::Val{$(QuoteNode(s))}, x::$T) = $f(x)
    return f
end

register(f, T::Type) = register(f, T, Symbol(f))

function _pcalc_apply(f, x)
    return f(x)
end

function _pcalc_apply(f, A::AbstractArray)
    return map(f, A)
end

function _pcalc_call_head(head)
    if head isa Symbol
        return esc(head)
    elseif head isa Expr && head.head === :$
        length(head.args) == 1 || error("@pcalc: invalid interpolation")
        return esc(head.args[1])
    else
        return head
    end
end

function _pcalc_rewrite(ex, arg::Symbol)
    if ex isa Symbol
        return :($(GlobalRef(Base, :getproperty))($arg, $(QuoteNode(ex))))
    elseif ex isa QuoteNode || !(ex isa Expr)
        return ex
    elseif ex.head === :$
        length(ex.args) == 1 || error("@pcalc: invalid interpolation")
        return esc(ex.args[1])
    elseif ex.head === :quote
        return ex
    elseif ex.head === :call
        return Expr(:call, _pcalc_call_head(ex.args[1]), (_pcalc_rewrite(a, arg) for a in ex.args[2:end])...)
    elseif ex.head === :.
        return Expr(:., _pcalc_rewrite(ex.args[1], arg), ex.args[2:end]...)
    else
        return Expr(ex.head, (_pcalc_rewrite(a, arg) for a in ex.args)...)
    end
end

"""
    @pcalc target expression
    @pcalc(target, expression)

Evaluate an ad hoc property formula on `target`.

Bare identifiers in `expression` are read as properties of each target
element. Use `\$name` or `\$(expr)` to interpolate caller-scope Julia values
instead of treating them as properties.

For an array or `PArray`, the formula is evaluated element-wise with `map`.
For a scalar object, the scalar result is returned.

# Examples
```julia
@pcalc particles x + y
@pcalc particles sqrt(x^2 + y^2)

offset = 10
@pcalc particles x + \$offset
```
"""
macro pcalc(target, ex)
    arg = gensym(:pcalc)
    return :($(GlobalRef(@__MODULE__, :_pcalc_apply))($(esc(target))) do $arg
        $(_pcalc_rewrite(ex, arg))
    end)
end

macro pcalc(args...)
    error("@pcalc expects `@pcalc target expression` or `@pcalc(target, expression)`")
end

"""
    @register function f(x::T) ... end
    @register f(x::T) = ...
    @register T :name x -> ...

Define a function and register it as an attribute of `T` (which must be
a [`PropertyObject`](@ref) subtype). Equivalent in effect to writing the
function definition followed by `register(f, T, :f)`.

The anonymous attribute form registers a property without defining a public
function with the same name. Use it when the property name is short or likely
to conflict with local variables or other functions.

Use `@register` for static package code when defining the calculation and
registration together, or when registering an anonymous property body. Use
[`@register_fn`](@ref) instead when the named function is defined separately.
Use [`register`](@ref) only when registration must depend on runtime values.

Unlike [`register`](@ref), this macro emits the registration as an
ordinary top-level method definition, so it is **safe to use inside a
package module**. Precompilation handles it like any other method.

Only the method introduced by this definition is registered. To register
additional methods on other `PropertyObject` types, place `@register` in front
of each definition.

# Examples
```julia
@register function angle(p::Particle)
    atan(p.y, p.x) |> rad2deg
end

@register radius(p::Particle) = sqrt(p.x^2 + p.y^2)

@register Particle :t p -> p.x + p.y

@register(Particle, :radius_sq) do p
    p.x^2 + p.y^2
end
```
"""
function _register_attr_symbol(attr)
    if attr isa QuoteNode && attr.value isa Symbol
        return attr.value
    else
        error("@register: attribute name must be a quoted Symbol, e.g. `:t`; use `register` for runtime names")
    end
end

function _register_arrow_arg(arg)
    if arg isa Symbol
        return arg
    elseif arg isa Expr && arg.head === :tuple && length(arg.args) == 1 && arg.args[1] isa Symbol
        return arg.args[1]
    else
        error("@register: anonymous attribute function must take exactly one plain, untyped argument")
    end
end

function _register_attr_method(s::Symbol, Tname, arg::Symbol, body; escape_body::Bool = true)
    body_expr = escape_body ? esc(body) : body
    return quote
        function $(GlobalRef(@__MODULE__, :_attr))(::Val{$(QuoteNode(s))}, $(esc(arg))::$(esc(Tname)))
            $body_expr
        end
    end
end

function _register_named(funcdef)
    # Accept both `function f(...) ... end` (head :function) and
    # short form `f(...) = ...` (head :(=)).
    if !(funcdef isa Expr) || !(funcdef.head === :function || funcdef.head === :(=))
        error("@register expects a function definition (long or short form)")
    end
    sig = funcdef.args[1]
    if !(sig isa Expr) || sig.head !== :call
        error("@register: could not parse function signature from $(sig)")
    end
    length(sig.args) >= 2 || error("@register: function must take at least one argument")
    fname = sig.args[1]
    fname isa Symbol || error("@register: function name must be a plain identifier, got $(fname)")
    first_arg = sig.args[2]
    if !(first_arg isa Expr && first_arg.head === :(::) && length(first_arg.args) == 2)
        error("@register: first argument must be type-annotated, e.g. `x::Particle`")
    end
    Tname = first_arg.args[2]
    # Emit two top-level definitions:
    #   1. The user's function, as written.
    #   2. A method on PropertyArrays._attr that dispatches to it.
    # This avoids @eval entirely, so precompilation handles both like any
    # other ordinary method definition.
    attrdef = _register_attr_method(fname, Tname, :x, :($(esc(fname))(x)); escape_body = false)
    return quote
        $(esc(funcdef))
        $attrdef
    end
end

function _register_anonymous(Tname, attr, fnexpr)
    if !(fnexpr isa Expr && fnexpr.head === :->)
        error("@register: anonymous attribute form expects `T :name x -> body`")
    end
    s = _register_attr_symbol(attr)
    arg = _register_arrow_arg(fnexpr.args[1])
    body = fnexpr.args[2]
    return _register_attr_method(s, Tname, arg, body)
end

macro register(args...)
    if length(args) == 1
        return _register_named(args[1])
    elseif length(args) == 3 && args[1] isa Expr && args[1].head === :->
        # Supports `@register(T, :name) do x ... end`.
        return _register_anonymous(args[2], args[3], args[1])
    elseif length(args) == 3
        return _register_anonymous(args[1], args[2], args[3])
    else
        error("@register expects a function definition or `@register T :name x -> body`")
    end
end

"""
    @register_fn f T

Register an already-defined function `f` as an attribute of `T` (which must
be a [`PropertyObject`](@ref) subtype) under the attribute name `:f`. After
registration, `x.f` on any `x::T` returns `f(x)`.

Unlike [`register`](@ref), this macro emits a plain method definition so it
is **safe to use inside a package module**. Use it when `f` is defined
separately — typically when extending a function imported from another module.
Use [`@register`](@ref) instead when defining and registering the function in
one place, or when registering an anonymous property body. Use [`register`](@ref)
only when registration must depend on runtime values.

# Example
```julia
function Commons.sigma(rec::Record)
    action(rec) .|> sigma
end
@register_fn sigma Record   # rec.sigma now works
```

See [`@register`](@ref) for the combined define-and-register form.
"""
macro register_fn(fname, Tname)
    fname isa Symbol || error("@register_fn: first argument must be a plain function name")
    return _register_attr_method(fname, Tname, :x, :($(esc(fname))(x)); escape_body = false)
end

function _delegate_field_symbol(field)
    if field isa Symbol
        return field
    elseif field isa QuoteNode && field.value isa Symbol
        return field.value
    else
        error("@delegate: field name must be a plain identifier, e.g. `particle`")
    end
end

function _delegate_prop_symbol(prop)
    if prop isa QuoteNode && prop.value isa Symbol
        return prop.value
    else
        error("@delegate: delegated properties must be quoted Symbols, e.g. `:speed`")
    end
end

function _delegate_prop_symbols(props)
    if props isa QuoteNode && props.value isa Symbol
        return Symbol[props.value]
    elseif props isa Expr && props.head === :tuple
        isempty(props.args) && error("@delegate: property tuple must contain at least one property")
        return [_delegate_prop_symbol(prop) for prop in props.args]
    else
        error("@delegate: properties must be a quoted Symbol or tuple of quoted Symbols, e.g. `:speed` or `(:speed, :mass)`")
    end
end

function _delegate_pair(entry)
    if entry isa Expr && entry.head === :call && length(entry.args) == 3 && entry.args[1] === :(=>)
        return _delegate_field_symbol(entry.args[2]), _delegate_prop_symbols(entry.args[3])
    else
        error("@delegate block entries must look like `field => (:prop, ...)`")
    end
end

function _delegate_entries(block)
    if block isa Expr && block.head === :block
        entries = Any[x for x in block.args if !(x isa LineNumberNode)]
        isempty(entries) && error("@delegate block must contain at least one delegation entry")
        return [_delegate_pair(entry) for entry in entries]
    else
        return [_delegate_pair(block)]
    end
end

function _delegate_attr_method(Tname, field::Symbol, prop::Symbol)
    return _register_attr_method(
        prop,
        Tname,
        :x,
        :($(GlobalRef(Base, :getproperty))($(GlobalRef(Core, :getfield))(x, $(QuoteNode(field))), $(QuoteNode(prop)))),
        escape_body = false,
    )
end

function _delegate_methods(Tname, entries)
    seen = Set{Symbol}()
    defs = Any[]
    for (field, props) in entries
        for prop in props
            if prop in seen
                error("@delegate: property :$prop is delegated more than once in the same @delegate expression")
            end
            push!(seen, prop)
            push!(defs, _delegate_attr_method(Tname, field, prop))
        end
    end
    return Expr(:block, defs...)
end

"""
    @delegate T field :a
    @delegate T field (:a, :b, ...)
    @delegate T begin
        field1 => (:a, :b, ...)
        field2 => (:c, :d, ...)
    end

Delegate child properties from fields of a composed [`PropertyObject`](@ref)
type. The expression `@delegate T field (:a, :b)` makes `x.a` and `x.b` on
`x::T` forward to `x.field.a` and `x.field.b`.

`@delegate` is intended for package code. Like [`@register`](@ref), it expands
to ordinary method definitions and does not call [`register`](@ref), so it is
safe to use during precompilation.

Fields are accessed with `getfield`, while delegated properties are accessed
with `getproperty`. This means the child property can be either a real field or
a registered property.

# Examples
```julia
struct Medium <: PObject
    particle::Particle
    solvent::Solvent
end

@delegate Medium particle (:speed, :mass, :charge)

@delegate Medium begin
    particle => (:speed, :mass, :charge)
    solvent  => (:viscosity, :density)
end
```
"""
macro delegate(Tname, args...)
    if length(args) == 1
        return _delegate_methods(Tname, _delegate_entries(args[1]))
    elseif length(args) == 2
        return _delegate_methods(Tname, [(_delegate_field_symbol(args[1]), _delegate_prop_symbols(args[2]))])
    else
        error("@delegate expects `@delegate T field (:prop, ...)` or `@delegate T begin field => (:prop, ...) end`")
    end
end

# ============================================================================
# Core PropertyArray Type
# ============================================================================

"""
    PropertyArray{T, N, A<:AbstractArray{T, N}} <: AbstractArray{T, N}

An `AbstractArray` wrapper that forwards property access to its elements.

Instead of writing `getproperty.(A, :x)` to ask every element of an array
for its `x` attribute, wrap the array as `PArray(A)` and write
`PArray(A).x`. The container forwards the attribute request to each
element and returns the collected result.

For any property name `s` other than `:data`, `bp.s` evaluates to
`PArray(getproperty.(bp, s))` — i.e. each element is asked for its `s`
attribute, and the results are collected into a new `PropertyArray`
(`PArray`) of the same shape.

The underlying array is accessible as `bp.data`.

# Constructors
```julia
PArray(data::AbstractArray)         # alias for PropertyArray(data)
PArray(T, dims::NTuple{N, Int})     # alias for PropertyArray(T, dims)
PArray(T, dims::Int...)             # alias for PropertyArray(T, dims...)
```

# Examples
```julia
struct Point
    x::Float64
    y::Float64
end

pts = PArray([Point(i+0.0, j+0.0) for i in 1:2, j in 1:3])
size(pts)    # (2, 3)
pts.x        # 2×3 PArray of x values
pts.y        # 2×3 PArray of y values
pts[1, 2]    # Point(1.0, 2.0)
```

Standard `AbstractArray` operations (`map`, `filter`, `broadcast`,
indexing, `reshape`, etc.) all work as expected. Because `PropertyArray` (`PArray`)
participates in the array protocol, third-party map-likes such as
`Distributed.pmap` and `ThreadsX.map` accept a `PArray` directly.
"""
struct PropertyArray{T, N, A<:AbstractArray{T, N}} <: AbstractArray{T, N}
    data::A
    PropertyArray(data::A) where {T, N, A<:AbstractArray{T, N}} = new{T, N, A}(data)
end

"""
    PArray

Alias for `PropertyArray`.
"""
const PArray = PropertyArray

PropertyArray(::Type{T}, shape::NTuple{N, Int}) where {T, N} = PropertyArray(Array{T, N}(undef, shape))
PropertyArray(::Type{T}, shape::Int...) where {T} = PropertyArray(T, shape)

Base.size(A::PropertyArray) = size(getfield(A, :data))
Base.axes(A::PropertyArray) = axes(getfield(A, :data))
Base.IndexStyle(::Type{PropertyArray{T, N, A}}) where {T, N, A} = IndexStyle(A)
Base.similar(A::PropertyArray, ::Type{T}, dims::Dims) where {T} = PropertyArray(similar(getfield(A, :data), T, dims))
# Defensive interop for APIs that convert through unions like Union{T, Matrix{T}}.
Base.convert(::Type{Union{T, Array{T, N}}}, A::PropertyArray{T, N}) where {T, N} = Array(A)
Base.view(A::PropertyArray, I...) = PropertyArray(view(getfield(A, :data), to_indices(A, I)...))
@inline Base.setindex!(A::PropertyArray, v, I...) = setindex!(getfield(A, :data), v, to_indices(A, I)...)

function Base.getindex(A::PropertyArray, I...)
    inds = to_indices(A, I)
    r = getfield(A, :data)[inds...]
    return r isa AbstractArray ? PropertyArray(r) : r
end

function Base.getproperty(A::PropertyArray, s::Symbol)
    if s === :data
        return getfield(A, :data)
    else
        return PropertyArray(getproperty.(A, s))
    end
end

function Base.hasproperty(A::PropertyArray, s::Symbol)
    if s === :data
        return true
    else
        return !isempty(A) && hasproperty(first(A), s)
    end
end

function Base.reshape(A::PropertyArray, dims::Union{Int,AbstractUnitRange}...)
    PropertyArray(reshape(getfield(A, :data), dims...))
end

function Base.summary(io::IO, A::PropertyArray{T,N}) where {T,N}
    if N == 1
        print(io, length(A), "-element PArray{", T, ", ", N, "}")
    else
        print(io, join(size(A), '×'), " PArray{", T, ", ", N, "}")
    end
end

# ============================================================================
# I/O System
# ============================================================================

"""
    translate(obj)             -> NamedTuple
    translate(obj, T::Type)    -> T

Convert between a struct and a `NamedTuple` representation by field name.

`translate(obj)` returns a `NamedTuple` whose names and values mirror the
fields of `obj` (in declaration order).

`translate(obj, T)` constructs a `T` by reading fields with the same names
from `obj` and passing them positionally to `T`'s constructor. This works
when `obj` already has those fields (e.g. when `obj` is a `NamedTuple`
loaded from disk).

These functions are used internally by [`psave`](@ref) and
[`pload`](@ref) so that JLD2 files do not depend on any
user-defined types.

# Example
```julia
struct Point
    x::Float64
    y::Float64
end

nt = translate(Point(1.0, 2.0))     # (x = 1.0, y = 2.0)
p  = translate(nt, Point)           # Point(1.0, 2.0)
```
"""
translate(obj::T) where T = NamedTuple{fieldnames(T)}(getfield(obj, f) for f in fieldnames(T))
translate(obj, ::Type{T}) where T = T((getfield(obj, f) for f in fieldnames(T))...)

"""
    psave(filename, bp::PropertyArray)
    psave(filename, arr::AbstractArray)

Save an array (or a `PropertyArray`) to a JLD2 file as a plain array of
`NamedTuple`s. Element types are not preserved on disk so the file can
be loaded into different struct definitions later (see [`pload`](@ref)).
"""
function psave(filename, self::PropertyArray)
    save_object(filename, translate.(getfield(self, :data)))
end

function psave(filename, data::AbstractArray)
    save_object(filename, translate.(data))
end

"""
    pload(filename)              -> PropertyArray{<:NamedTuple}
    pload(T::Type, filename)     -> PropertyArray{T}
    pload(f, filename)           -> PropertyArray

Load a JLD2 file saved by [`psave`](@ref).

Without a transformer the elements are returned as raw `NamedTuple`s.
With a type `T`, each element is reconstructed as `T` via [`translate`](@ref).
With a function `f`, each element is reconstructed as `f(nt)`, where `nt`
is the raw `NamedTuple` read from disk. This third form is useful when
reconstruction needs custom logic beyond field-by-field copying.

# Examples
```julia
nt_array  = pload("particles.jld2")
particles = pload(Particle, "particles.jld2")

# Custom reconstructor
particles = pload("particles.jld2") do nt
    Particle(nt.x, nt.y)
end
```
"""
pload(filename::AbstractString) = PropertyArray(load_object(filename))

function pload(::Type{T}, filename::AbstractString) where T
    loaded = load_object(filename)
    return T === NamedTuple ? PropertyArray(loaded) : PropertyArray(translate.(loaded, T))
end

function pload(f, filename::AbstractString)
    loaded = load_object(filename)
    return PropertyArray(f.(loaded))
end

end
