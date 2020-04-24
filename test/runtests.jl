using PDFSandwich
using Test
using ImageMagick_jll

# `test.pdf` is already searchable by construction
# So we rasterize it first and then OCR back the text layer.

function image_to_pdf(img)
    img_base, img_ext = splitext(img)
    output = img_base * ".pdf"
    ImageMagick_jll.convert() do convert
        run(`$convert $img $output`)
    end
    return output
end

# Inverse of OCR
function rasterize(pdf, output=string(splitext(pdf)[1], "_rasterized", ".pdf"))
    pages = PDFSandwich.num_pages(pdf)
    pdfs = asyncmap(1:pages) do i
        img = PDFSandwich.get_image(pdf, i)
        image_to_pdf(img)
    end
    PDFSandwich.unite_pdfs(pdfs, output)
    return output
end

# rasterize("test.pdf")


@testset "PDFSandwich.jl" begin
    # For now, just check it runs
    ocr("test_rasterized.pdf")
end
