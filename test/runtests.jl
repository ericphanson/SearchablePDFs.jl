using SearchablePDFs
using Test
using ImageMagick_jll: ImageMagick_jll

# `test.pdf` is already searchable by construction
# So we rasterize it first and then OCR back the text layer.

function image_to_pdf(img)
    img_base, img_ext = splitext(img)
    output = img_base * ".pdf"
    ImageMagick_jll.imagemagick_convert() do convert
        return run(`$convert $img $output`)
    end
    return output
end

# Inverse of OCR
function rasterize(pdf, output=string(splitext(pdf)[1], "_rasterized", ".pdf"))
    pages = SearchablePDFs.num_pages(pdf)
    pdfs = asyncmap(1:pages) do i
        img = SearchablePDFs.get_image(pdf, i)
        return image_to_pdf(img)
    end
    SearchablePDFs.unite_pdfs(pdfs, output)
    return output
end

TEST_PDF_PATH = joinpath(@__DIR__, "test.pdf")
TEST_PDF_RASTERIZED_PATH = joinpath(@__DIR__, "test_rasterized.pdf")
#rasterize(TEST_PDF_PATH)

@testset "SearchablePDFs.jl" begin
    @test SearchablePDFs.num_pages(TEST_PDF_PATH) == 3

    # For now, just check it runs
    ocr(TEST_PDF_RASTERIZED_PATH)
end
