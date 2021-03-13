module SearchablePDFs
using Pkg
using Pkg.Artifacts

using ProgressMeter
using Scratch

using Poppler_jll
using unpaper_jll
using Tesseract_jll
using grep_jll

export ocr

# For now we will hardcode this choice of training data
function get_data_path()
    artifact"tessdata_fast"
end

# Use Poppler to extract the image
function get_image(pdf, page, tmp)
    local logs
    Poppler_jll.pdftoppm() do pdftoppm
        logs = run_and_collect_logs(`$pdftoppm -f $page -l $page $pdf $tmp/`)
    end
    @debug "`pdftopnm`" logs
    img = only(readdir(tmp; join=true))
    return (; img, logs)
end

# Clean up an image with unpaper
function unpaper(img)
    local logs
    img_base, img_ext = splitext(img)
    img_unpaper = img_base * "_unpaper" * img_ext
    unpaper_jll.unpaper() do unpaper
        logs = run_and_collect_logs(`$unpaper $img $img_unpaper`)
    end
    return (; img_unpaper, logs)
end

# https://discourse.julialang.org/t/collecting-all-output-from-shell-commands/15592/7
function run_and_collect_logs(cmd::Cmd)
    out = Pipe()
    err = Pipe()
    process = run(pipeline(cmd, stdout=out, stderr=err), wait=false)
    close(out.in)
    close(err.in)

    stdout = @async String(read(out))
    stderr = @async String(read(err))
    wait(process)
    return (
        stdout = fetch(stdout),
        stderr = fetch(stderr),
        code = process.exitcode
    )
end

# Use tesseract to make a single-page searchable pdf from an image
function get_text(img; tesseract_nthreads)
    data_path = get_data_path() * "/"
    img_base, img_ext = splitext(img)
    output = img_base
    local logs
    withenv("OMP_THREAD_LIMIT" => tesseract_nthreads) do
        Tesseract_jll.tesseract() do tesseract
            cmd = `$tesseract -l eng+equ --tessdata-dir $data_path $img $output -c tessedit_create_pdf=1`
            @debug "Tesseracting!" img
            logs = run_and_collect_logs(cmd)
            @debug logs
        end
    end
    return (; pdf = output * ".pdf", logs=(; binary="tesseract", logs...))
end

# Collect all the PDFs into one with `pdfunite`
function unite_pdfs(pdfs, output)
    local logs
    Poppler_jll.pdfunite() do pdfunite
        logs = run_and_collect_logs(`$pdfunite $pdfs $output`)
    end
    return (; binary="pdfunite", logs...)
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
"""
    ocr(pdf, output_path = string(splitext(pdf)[1], "_OCR", ".pdf"); apply_unpaper = false, ntasks = (Sys.CPU_THREADS ÷ 2) - 1)

Reads in a PDF located at `pdf`, uses Tesseract to OCR each page and combines the results into a pdf located `output_path`.

Keyword arguments:

* `apply_unpaper`:
* `ntasks`:
* `tesseract_nthreads`

"""
function ocr(pdf, output_path = string(splitext(pdf)[1], "_OCR", ".pdf"); apply_unpaper = false, ntasks = (Sys.CPU_THREADS ÷ 2) - 1, capture_logs = true, tesseract_nthreads=1, pages = num_pages(pdf), cleanup_after=true)
    isfile(pdf) || throw(ArgumentError("PDF file not found at $pdf"))
    pages < 1000 || throw(ArgumentError("PDF must have less than 1000 pages"))
    all_logs = @NamedTuple{page::Union{Int, UnitRange{Int}, Missing}, binary::String, stdout::String, stderr::String, code::Int}[]
    sizehint!(all_logs, pages+2)

    @debug "Found file" pdf pages

    tmp = joinpath(@get_scratch!("pdf_tmps"), splitext(basename(pdf))[1] * "_" * string(rand(1:1000)))
    mkpath(tmp)

    @debug "Working in tempdir" tmp

    @debug "Generating images..."
    imag_prog = Progress(pages; desc="(1/3) Extracting images: ")
    asyncmap(Iterators.partition(1:pages, 20); ntasks) do current_pages
        local pdftoppm_logs
        Poppler_jll.pdftoppm() do pdftoppm
            pdftoppm_logs = run_and_collect_logs(`$pdftoppm -f $(first(current_pages)) -l $(last(current_pages)) $pdf -tiff -forcenum $(tmp)/page`)
        end
        push!(all_logs, (; page=current_pages, binary="pdftoppm", pdftoppm_logs...))
        @debug "" pdftoppm_logs
        next!(imag_prog; step=length(current_pages))
    end

    @debug "Finished generating images. Starting tesseracting..."

    ocr_prog = Progress(pages; desc="(2/3) OCRing: ")
    pdfs = asyncmap(1:pages; ntasks) do page
        img = joinpath(tmp, string("page-", lpad(page, 3, '0'), ".tif"))
        @debug "img" page img
        @assert isfile(img)
        if apply_unpaper
            img, unpaper_logs = unpaper(img)
            push!(all_logs, (; page, unpaper_logs...))
        end
        pdf, tesseract_logs = get_text(img; tesseract_nthreads)
        push!(all_logs, (; page, tesseract_logs...))
        next!(ocr_prog)
        return pdf
    end
    @debug "Finished processing pages. Uniting..."
    unite_dir = joinpath(tmp, "unite")
    mkpath(unite_dir)
    max_files = 100
    unite_prog = Progress(pages + cld(pages, max_files) + 1; desc="(3/3) Collecting pages: ")
    recursive_unite_pdfs!(unite_prog, all_logs, unite_dir, pdfs, output_path; max_files)
    @debug "Done uniting pdfs"

    if cleanup_after
        @debug "Cleaning up"
        rm(tmp; recursive=true, force=true)
    end
    @debug "Done"
    return (; output_path, logs = all_logs)
end

function recursive_unite_pdfs!(unite_prog, all_logs, tmp, pdfs, output_path; max_files=100)
    if length(pdfs) <= max_files
        unite_logs = unite_pdfs(pdfs, output_path)
        push!(all_logs, (; page=missing, unite_logs...))
        next!(unite_prog; step = length(pdfs))
        return nothing
    end
    outs = String[]
    for collection in Iterators.partition(pdfs, max_files)
        new_tmp = mktempdir(tmp)
        out_path = joinpath(new_tmp, "out.pdf")
        recursive_unite_pdfs!(unite_prog, all_logs, new_tmp, collection, out_path; max_files)
        push!(outs, out_path)
    end
    recursive_unite_pdfs!(unite_prog, all_logs, tmp, outs, output_path; max_files)
    return nothing
end

end # module
