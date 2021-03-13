using SearchablePDFs
using Test

TEST_PDF_PATH = joinpath(@__DIR__, "test.pdf")
TEST_PDF_RASTERIZED_PATH = joinpath(@__DIR__, "test_rasterized.pdf")
#rasterize(TEST_PDF_PATH)

@testset "SearchablePDFs.jl" begin
    @test SearchablePDFs.num_pages(TEST_PDF_PATH) == 3

    # For now, just check it runs
    for show_progress in (false, true), apply_unpaper in (false, true)
        ocr(TEST_PDF_RASTERIZED_PATH; show_progress)
    end
end
