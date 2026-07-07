# PropertyArrays.jl

A small Julia package for accessing element attributes through a container.

In Julia, accessing the same property from every element of an array is
usually written as an explicit broadcast:

```julia
getproperty.(A, :x)
```

`PArray` provides a wrapper where property access is forwarded to the
elements:

```julia
bp = PArray(A)
bp.x
```

This is equivalent to:

```julia
getproperty.(A, :x)
```

Other array operations are intended to behave as they do for the wrapped
array. Indexing, `size`, `axes`, `reshape`, `map`, `filter`, and similar
operations remain ordinary array operations; the main special case is
`getproperty`. The original array is available as `.data`.

`PObject` is a small companion interface for registering computed
attributes on element types. For example, a calculation such as
`angle.(A)` can be exposed as `PArray(A).angle` after registration.

The package provides two complementary tools:

- **`PArray`** — exported alias for `PropertyArray`, an `AbstractArray` wrapper that forwards property
  access to its elements.
- **`PObject`** — exported alias for `PropertyObject`, an abstract type that lets you register functions as
  "virtual attributes" of a struct, accessible with `.` syntax.

---

## Example

```julia
using PropertyArrays

struct Particle <: PObject
    x::Float64
    y::Float64
end

@register angle(p::Particle) = atan(p.y, p.x) |> rad2deg
@register radius(p::Particle) = sqrt(p.x^2 + p.y^2)

particles = PArray([Particle(i+0.0, j+0.0) for i in 1:2, j in 1:3])
```

Here `x` and `y` are particle positions. A plain array would use
`getproperty.(A, :x)` to collect all `x` positions. A `PArray` wrapper
uses property syntax:

```julia
particles.x
```

```text
2×3 PArray{Float64, 2}:
 1.0  1.0  1.0
 2.0  2.0  2.0
```

Registered attributes use the same property syntax:

```julia
particles.angle
```

```text
2×3 PArray{Float64, 2}:
 45.0     63.4349  71.5651
 26.5651  45.0     56.3099
```

On a single element, registered attributes are also available through the
same syntax:

```julia
p = Particle(3.0, 4.0)

p.x
p.radius
p.angle
```

```text
3.0
5.0
53.13010235415598
```

The same attributes can be used in ordinary array operations:

```julia
queried = filter(particles) do p
    p.angle >= 45 && p.radius < 3
end

queried.radius
```

```text
3-element PArray{Float64, 1}:
 1.4142135623730951
 2.23606797749979
 2.8284271247461903
```

The filtered result is still a `PArray`, so it can be passed to later
array-style work. For example, if each selected particle requires a
heavier calculation:

```julia
using Distributed

results = pmap(queried) do p
    # Replace this with the expensive per-particle computation.
    (; angle = p.angle, radius = p.radius)
end
```

---

## Registering Attributes

`PObject` is an alias for `PropertyObject`. Any struct that inherits from it can
have functions registered as accessible attributes.

### Choosing an API

| Use case | API |
| --- | --- |
| Define a named function and register it in package code | `@register f(x::T) = ...` |
| Register a property without defining a function of the same name | `@register T :name x -> ...` |
| Register an existing named function in package code | `@register_fn f T` |
| Delegate properties from a composed field in package code | `@delegate T field (:a, :b)` |
| Evaluate a temporary REPL/test formula without registering it | `@pcalc xs A1 + B1` |
| Register from runtime values in trusted REPL/script/notebook code | `register(f, T, name)` |

Use the macro forms for static package code because they emit ordinary method
definitions and are precompile-safe. Use `register` only when the type,
attribute name, or function is genuinely chosen at runtime. `register` does not
evaluate strings, but it mutates the global method table and should not be
exposed to untrusted input or plugin code.

### In Package Code

Use `@register`. It emits ordinary top-level method definitions, so
precompilation handles it like other Julia code.

```julia
@register function angle(p::Particle)
    atan(p.y, p.x) |> rad2deg
end

@register radius(p::Particle) = sqrt(p.x^2 + p.y^2)
```

If you want the registered attribute without defining a function of the same
name, use the anonymous attribute form:

```julia
@register Particle :t p -> p.x + p.y

@register(Particle, :radius_sq) do p
    p.x^2 + p.y^2
end
```

### In the REPL or Scripts

Use `register` when working interactively or when the registration is
genuinely dynamic.

```julia
radius_sq(p::Particle) = p.x^2 + p.y^2
register(radius_sq, Particle)

register(Particle, :is_right_side) do p
    p.x > 0
end
```

After registration, the attributes are accessed through property syntax:

```julia
p = Particle(3.0, 4.0)

p.radius_sq
p.is_right_side
```

```text
25.0
true
```

> **Note.** Do not call `register` at the top level of a package module.
> It uses `@eval` internally to add methods at runtime, which conflicts
> with precompilation. Use `@register` inside package code; use `register`
> for interactive work or for cases where the registration is genuinely
> dynamic.

### Ad Hoc REPL Formulas

Use `@pcalc` for temporary calculations that are useful at the REPL or in
tests but not worth registering as attributes:

```julia
@pcalc particles x + y
@pcalc particles sqrt(x^2 + y^2)
@pcalc particles radius^2
```

Bare names in the formula are read as properties of each element. For an
array or `PArray`, the formula is evaluated element-wise and returns the
usual mapped result. For a single object, it returns a scalar:

```julia
@pcalc p x + y
```

Use `$` when a name should come from the caller's scope instead of from the
object's properties:

```julia
offset = 10
scale = 2

@pcalc particles x + $offset
@pcalc particles radius / $scale
@pcalc particles x + $(offset / scale)
```

### Delegating Composed Properties

Use `@delegate` when a `PObject` is composed from other objects and you want
selected child properties to appear on the parent. It emits ordinary method
definitions, so it is precompile-safe like `@register`.

```julia
struct Medium <: PObject
    particle::Particle
    solvent::Solvent
end

@delegate Medium particle (:speed, :mass, :charge)
@delegate Medium solvent (:viscosity, :density)
```

Then `medium.speed` forwards to `medium.particle.speed`, and
`medium.viscosity` forwards to `medium.solvent.viscosity`. Delegation uses
`getfield` for the parent field and `getproperty` for the child property, so
the child property can be either a real field or a registered attribute.

For several fields, the grouped form keeps the composition map together:

```julia
@delegate Medium begin
    particle => (:speed, :mass, :charge)
    solvent  => (:viscosity, :density)
end
```

---

## Array Behavior

`PArray` is an alias for `PropertyArray`, which wraps an `AbstractArray`. The wrapped array is available as
`.data`. For any other property name, property access is forwarded
element-wise:

```julia
particles.x       # PArray of x values
particles.angle   # PArray of registered angle values
```

For operations other than property access, `PArray` follows the ordinary
`AbstractArray` interface and preserves the behavior of the wrapped
container where possible:

```julia
size(particles)              # (2, 3)
particles[1, 2]              # Particle(1.0, 2.0)
particles[1, :]              # a 1D PArray slice
reshape(particles, 6)        # flatten to 1D
map(p -> p.x^2, particles)   # returns a PArray via similar
```

Code that works with arrays generally accepts a `PArray` as well. This
includes standard tools such as `map` and `filter`, and third-party
map-like functions such as `Distributed.pmap` or `ThreadsX.map`.

Constructors:

```julia
PArray(data)            # wrap an existing array
PArray(Float64, 10, 20) # 10x20 uninitialized array of Float64
PArray(Float64, (3, 4)) # tuple form
```

---

## How Attribute Registration Works

`register` adds a method to an internal marker function `_attr`, keyed
on a `Val{:name}` and the target type. When you write `p.angle`, Julia's
`getproperty` hook calls `_attr(Val(:angle), p)`, which dispatches to the
registered method via the usual multiple-dispatch machinery.

Because dispatch is used, attributes registered on a supertype are
automatically visible on all subtypes:

```julia
abstract type Animal <: PObject end

@register sound(a::Animal) = "generic noise"

struct Dog <: Animal end

Dog().sound
```

```text
"generic noise"
```

---

## I/O

`psave` and `pload` save and load `PropertyArray` data through JLD2.

```julia
psave("particles.jld2", particles)

# Load as raw NamedTuples (default)
nt_array = pload("particles.jld2")

# Load as a specific type; reconstructs each element via translate()
particles = pload(Particle, "particles.jld2")

# Load with a custom reconstructor
particles = pload("particles.jld2") do nt
    Particle(nt.x, nt.y)
end
```

The on-disk format is a plain array of `NamedTuple`s, so files are
independent of any user-defined types. You can load data into a different
struct definition than the one that saved it, as long as the field names
line up.

### `translate`

`translate(obj)` and `translate(obj, T)` are the conversion helpers used
internally:

```julia
nt = translate(Point(1.0, 2.0))     # (x = 1.0, y = 2.0)
p  = translate(nt, Point)           # Point(1.0, 2.0)
```

---

## Exported Names

| Name             | Kind        | Purpose                                |
|------------------|-------------|----------------------------------------|
| `PArray`         | alias    | alias for `PropertyArray` |
| `PObject`        | alias    | alias for `PropertyObject` |
| `PropertyArray`  | struct   | array with element-wise property access |
| `PropertyObject` | abstract | base type for attribute registration |
| `register`       | function    | register a function as an attribute    |
| `@register`      | macro       | define and register in one step        |
| `@register_fn`   | macro       | register an already-defined function   |
| `@delegate`      | macro       | delegate attributes from composed fields |
| `@pcalc`         | macro       | evaluate temporary property formulas   |
| `psave`          | function    | JLD2 serialization                     |
| `pload`          | function    | JLD2 deserialization                   |
| `translate`      | function    | struct <-> NamedTuple conversion       |

All exported names also have inline docstrings; use `?PArray`, `?PObject`,
`?register`, `?@pcalc`, etc. at the REPL for details.

---

## Installation

This package is not yet registered in the General registry. Install it
directly from GitHub:

```julia
import Pkg
Pkg.add(url="https://github.com/WooJoongKim0107/PropertyArrays.jl.git")
```

---

## License

[MIT](LICENSE)
