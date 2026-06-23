"""
Test coverage includes:

- `PObject` field access, registered computed attributes, `hasproperty`,
  and missing-property errors.
- `register` and `@register` attribute registration paths.
- `PArray` behavior: size, axes, indexing, slicing, property forwarding,
  `reshape`, `map`, and `filter`.
- `PArray` constructors and mutation through `setindex!`.
- `translate` conversions between structs and `NamedTuple`s.
- `psave` / `pload` JLD2 round trips, including typed and
  custom reconstruction.
"""

using PropertyArrays
using Test

@test PArray === PropertyArray
@test PObject === PropertyObject

struct TestRGBA{T}
    r::T
    g::T
    b::T
    a::T
end

struct TestParticle <: PObject
    x::Float64
    y::Float64
end

@register radius(p::TestParticle) = sqrt(p.x^2 + p.y^2)

@register function angle(p::TestParticle)
    atan(p.y, p.x) |> rad2deg
end

@testset "PObject attributes" begin
    p = TestParticle(3.0, 4.0)

    @test p.x == 3.0
    @test p.radius == 5.0
    @test p.angle ≈ 53.13010235415598
    @test hasproperty(p, :x)
    @test hasproperty(p, :radius)
    @test !hasproperty(p, :missing)
    @test_throws ErrorException p.missing
end

@testset "Dynamic registration" begin
    struct DynamicParticle <: PObject
        x::Int
        y::Int
    end

    register(DynamicParticle, :manhattan) do p
        abs(p.x) + abs(p.y)
    end

    @test DynamicParticle(-2, 5).manhattan == 7
end

@testset "PArray behavior" begin
    particles = PArray([TestParticle(i, j) for i in 1.0:2.0, j in 3.0:5.0])

    @test size(particles) == (2, 3)
    @test axes(particles) == (Base.OneTo(2), Base.OneTo(3))
    @test particles.data isa Matrix{TestParticle}
    @test particles[1, 2] == TestParticle(1.0, 4.0)
    @test particles[:, 1] isa PArray
    @test particles[:, 1].data == TestParticle.(1.0:2.0, 3.0)

    @test particles.x isa PArray
    @test particles.x.data == [1.0 1.0 1.0; 2.0 2.0 2.0]
    @test particles.y.data == [3.0 4.0 5.0; 3.0 4.0 5.0]
    @test particles.radius.data ≈ [sqrt(10) sqrt(17) sqrt(26); sqrt(13) sqrt(20) sqrt(29)]
    @test hasproperty(particles, :data)
    @test hasproperty(particles, :radius)
    @test !hasproperty(particles, :missing)

    flattened = reshape(particles, 6)
    @test flattened isa PArray
    @test size(flattened) == (6,)

    doubled_x = map(p -> 2p.x, particles)
    @test doubled_x isa PArray
    @test doubled_x.data == [2.0 2.0 2.0; 4.0 4.0 4.0]

    selected = filter(p -> p.radius > 4.0, particles)
    @test selected isa PArray
    @test selected.radius.data == [sqrt(17), sqrt(20), sqrt(26), sqrt(29)]
end

@testset "PArray conversion" begin
    matrix = [1 2; 3 4]
    wrapped_matrix = PArray(matrix)
    converted_matrix = convert(Union{Int, Matrix{Int}}, wrapped_matrix)

    @test converted_matrix isa Matrix{Int}
    @test converted_matrix == matrix
    @test converted_matrix !== matrix

    wrapped_reshaped = PArray(reshape(1:4, 2, 2))
    converted_reshaped = convert(Union{Int, Matrix{Int}}, wrapped_reshaped)

    @test converted_reshaped isa Matrix{Int}
    @test converted_reshaped == Matrix(wrapped_reshaped)
    @test convert(Matrix{Int}, wrapped_matrix) isa Matrix{Int}
    @test_throws MethodError convert(Union{Int, Vector{Int}}, wrapped_matrix)

    function makie_like_numbers_to_colors(numbers::Union{AbstractArray{<:Number, N}, Number})::Union{Array{TestRGBA{Float32}, N}, TestRGBA{Float32}} where {N}
        return map(numbers) do number
            gray = Float32(number)
            TestRGBA(gray, gray, gray, 1.0f0)
        end
    end

    colors = makie_like_numbers_to_colors(PArray(Float64[0.0 0.5; 0.75 1.0]))

    @test colors isa Matrix{TestRGBA{Float32}}
    @test colors == [
        TestRGBA(0.0f0, 0.0f0, 0.0f0, 1.0f0) TestRGBA(0.5f0, 0.5f0, 0.5f0, 1.0f0)
        TestRGBA(0.75f0, 0.75f0, 0.75f0, 1.0f0) TestRGBA(1.0f0, 1.0f0, 1.0f0, 1.0f0)
    ]
end

@testset "Constructors and mutation" begin
    particles = PArray(TestParticle, 2, 1)
    particles[1, 1] = TestParticle(3.0, 4.0)
    particles[2, 1] = TestParticle(5.0, 12.0)

    @test particles isa PArray{TestParticle, 2}
    @test particles.radius.data == [5.0; 13.0;;]

    vector = PArray(Int, (3,))
    vector[1] = 10
    vector[2] = 20
    vector[3] = 30
    @test vector.data == [10, 20, 30]
end

@testset "Translation and JLD2 round trip" begin
    p = TestParticle(3.0, 4.0)
    nt = translate(p)

    @test nt == (; x = 3.0, y = 4.0)
    @test translate(nt, TestParticle) == p

    mktempdir() do dir
        filename = joinpath(dir, "particles.jld2")
        particles = PArray([TestParticle(1.0, 2.0), TestParticle(3.0, 4.0)])

        psave(filename, particles)

        loaded_nt = pload(filename)
        @test loaded_nt isa PArray
        @test loaded_nt.data == translate.(particles.data)

        loaded_particles = pload(TestParticle, filename)
        @test loaded_particles isa PArray
        @test loaded_particles.data == particles.data

        loaded_custom = pload(filename) do row
            TestParticle(row.x + 1, row.y + 1)
        end
        @test loaded_custom.data == [TestParticle(2.0, 3.0), TestParticle(4.0, 5.0)]
    end
end
