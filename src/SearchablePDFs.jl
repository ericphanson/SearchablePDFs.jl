module SearchablePDFs
using Pkg
using Pkg.Artifacts

using Poppler_jll
using unpaper_jll
using Tesseract_jll
using grep_jll

const pdfconfig = normpath(joinpath(@__DIR__, "..", "deps", "tessconfigs", "pdf"))

export ocr


# For now we will hardcode this choice of training data
function get_data_path()
    joinpath(artifact"tessdata_eng", "eng.traineddata")
end

# Use Poppler to extract the image
function get_image(pdf, page)
    tmp = mktempdir()
    Poppler_jll.pdftoppm() do pdftopnm
        run(`$pdftopnm -f $page -l $page $pdf $tmp/`)
    end
    img = only(readdir(tmp; join=true))
    return img
end

# Clean up an image with unpaper
function unpaper(img)
    img_base, img_ext = splitext(img)
    img_unpaper = img_base * "_unpaper" * img_ext
    unpaper_jll.unpaper() do unpaper
        run(`$unpaper $img $img_unpaper`)
    end
    return img_unpaper
end

# Use tesseract to make a single-page searchable pdf from an image
function get_text(img)
    data_path = dirname(get_data_path()) * "/"
    img_base, img_ext = splitext(img)
    output = img_base
    withenv("OMP_THREAD_LIMIT" => 1) do
        Tesseract_jll.tesseract() do tesseract
            run(`$tesseract  --tessdata-dir $data_path $img $output -c tessedit_create_pdf=1`)
        end
    end
    return output * ".pdf"
end

# Collect all the PDFs into one with `pdfunite`
function unite_pdfs(pdfs, output)
    Poppler_jll.pdfunite() do pdfunite
        run(`$pdfunite $pdfs $output`)
    end
end

# There's gotta be a better way...
function num_pages(pdf)
    result = grep_jll.grep() do grep
        Poppler_jll.pdfinfo() do pdfinfo
            read(pipeline(`$pdfinfo $pdf`, `$grep Pages`), String)
        end
    end
    return parse(Int, split(result)[2])
end

# Chain it all together
function ocr(pdf, output = string(splitext(pdf)[1], "_OCR", ".pdf"); apply_unpaper = true)    
    pages = num_pages(pdf)
    pdfs = asyncmap(1:pages; ntasks = (Sys.CPU_THREADS ÷ 2) - 1) do i
        img = get_image(pdf, i)
        if apply_unpaper
            img = unpaper(img)
        end
        get_text(img)
    end
    unite_pdfs(pdfs, output)
    return output
end

end # module
