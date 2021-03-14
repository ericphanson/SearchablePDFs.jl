using SearchablePDFs
using SearchablePDFs: searchable, require_extension, require_no_file
using Test
using Poppler_jll
using Aqua

TEST_PDF_PATH = joinpath(@__DIR__, "test.pdf")
TEST_PDF_RASTERIZED_PATH = joinpath(@__DIR__, "test_rasterized.pdf")

@testset "SearchablePDFs.jl" begin
    @test SearchablePDFs.num_pages(TEST_PDF_PATH) == 3

    for verbose in (false, true), apply_unpaper in (false, true), f in (searchable, ocr), opt in (true, false)
        kwargs = f === searchable ?
                 (; logfile=joinpath(@__DIR__, "test_logs.csv"), quiet=!verbose, keep_intermediates = opt) :
                 (; verbose=verbose, max_files_per_unite= opt ? 2 : 100)

        result = f(TEST_PDF_RASTERIZED_PATH, joinpath(@__DIR__, "out.pdf"); apply_unpaper,
                   kwargs...)
        # make sure we delete the generated files eventually, even if the tests throw
        atexit(() -> rm(result.output_path; force=true)) 
        atexit(() -> rm(result.tmp; recursive=true, force=true))
        atexit(() -> rm(joinpath(@__DIR__, "test_logs.csv"); force=true))

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

    @testset "Errors" begin
        @test require_no_file("DOES_NOT_EXIST.pdf"; exception=true) === nothing
        @test_throws ArgumentError require_no_file("runtests.jl"; exception=true)

        @test require_extension("DOES_NOT_EXIST.pdf", ".pdf"; exception=true) === nothing
        @test_throws ArgumentError require_extension("runtests.jl", ".pdf"; exception=true)
    end
end

@testset "Aqua tests" begin
    Aqua.test_all(SearchablePDFs; ambiguities=false)
end
