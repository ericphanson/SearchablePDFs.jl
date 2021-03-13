using SearchablePDFs
using SearchablePDFs: searchable
using Test
using Poppler_jll

TEST_PDF_PATH = joinpath(@__DIR__, "test.pdf")
TEST_PDF_RASTERIZED_PATH = joinpath(@__DIR__, "test_rasterized.pdf")

@testset "SearchablePDFs.jl" begin
    @test SearchablePDFs.num_pages(TEST_PDF_PATH) == 3

    for verbose in (false, true), apply_unpaper in (false, true), f in (searchable, ocr)
        kwargs = f === searchable ? (; logfile=joinpath(@__DIR__, "test_logs.csv")) :
                 NamedTuple()

        result = f(TEST_PDF_RASTERIZED_PATH, joinpath(@__DIR__, "out.pdf"); verbose,
                   apply_unpaper, kwargs...)
        atexit(() -> rm(result.output_path; force=true)) # make sure we delete the file eventually, even if the tests throw

        @test isfile(result.output_path)

        text = pdftotext() do exe
            return read(`$exe $(result.output_path) -`, String)
        end

        @test occursin("Chapter 9", text)
        @test occursin("evaluate expressions written in a source file", text)

        if f === searchable
            rm(joinpath(@__DIR__, "test_logs.csv"))
        end
        rm(result.output_path)
    end
end
