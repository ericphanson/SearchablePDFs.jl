module SearchablePDFs
using Pkg
using Pkg.Artifacts
using Random

using ProgressMeter
using Scratch

using Poppler_jll
using unpaper_jll
using Tesseract_jll
using grep_jll

export ocr

#####
##### Utilities
#####

# For now we will hardcode this choice of training data
function get_data_path()
    return artifact"tessdata_fast"
end

function get_scratch_dir(pdf)
    return joinpath(@get_scratch!("pdf_tmps"),
                    splitext(basename(pdf))[1] * "_" * string(randstring(10)))
end

# https://discourse.julialang.org/t/collecting-all-output-from-shell-commands/15592/7
function run_and_collect_logs(cmd::Cmd)
    out = Pipe()
    err = Pipe()
    process = run(pipeline(cmd; stdout=out, stderr=err); wait=false)
    close(out.in)
    close(err.in)

    stdout = @async String(read(out))
    stderr = @async String(read(err))
    wait(process)
    return (stdout=fetch(stdout), stderr=fetch(stderr), code=process.exitcode)
end

# There's gotta be a better way...
function num_pages(pdf)
    result = grep_jll.grep() do grep
        Poppler_jll.pdfinfo() do pdfinfo
            return read(pipeline(`$pdfinfo $pdf`, `$grep Pages`), String)
        end
    end
    return parse(Int, split(result)[2])
end

#####
##### Step 1: Extract images
#####

# Use Poppler to extract the image
function get_images(pdf, page_range::UnitRange{Int}, tmp)
    local logs
    Poppler_jll.pdftoppm() do pdftoppm
        return logs = run_and_collect_logs(`$pdftoppm -f $(first(page_range)) -l $(last(page_range)) $pdf -tiff -forcenum $(tmp)/page`)
    end
    @debug "`pdftoppm`" logs
    paths = [joinpath(tmp, string("page-", lpad(page, 3, '0'), ".tif"))
             for page in page_range]
    return paths, (; binary="pdftoppm", logs...)
end

get_images(pdf, page::Int, tmp) = get_images(pdf, page:page, tmp)

# Clean up an image with unpaper
function unpaper(img)
    local logs
    img_base, img_ext = splitext(img)
    img_unpaper = img_base * "_unpaper" * img_ext
    unpaper_jll.unpaper() do unpaper
        return logs = run_and_collect_logs(`$unpaper $img $img_unpaper`)
    end
    return (; img_unpaper, logs=(; binary="unpaper", logs...))
end

#####
##### Step 2: Use tesseract to generate a one-page searchable PDF from an image
#####

function make_pdf(img; tesseract_nthreads)
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
    return (; pdf=output * ".pdf", logs=(; binary="tesseract", logs...))
end

#####
##### Step 3: collect all the PDFs into one with `pdfunite`
#####

function unite_pdfs(pdfs, output)
    local logs
    Poppler_jll.pdfunite() do pdfunite
        return logs = run_and_collect_logs(`$pdfunite $pdfs $output`)
    end
    return (; binary="pdfunite", logs...)
end

# unites all the pdfs in `pdfs` recursively, `max_files` at a time.
# I ran into "too many open files" errors otherwise
# (which seems weird... maybe <https://github.com/JuliaLang/julia/issues/31126>? It was on MacOS)
function recursive_unite_pdfs!(unite_prog, all_logs, tmp, pdfs, output_path; max_files=100)
    if length(pdfs) <= max_files
        unite_logs = unite_pdfs(pdfs, output_path)
        push!(all_logs, (; page=missing, unite_logs...))
        next!(unite_prog; step=length(pdfs))
        return nothing
    end
    partially_united_pdfs = String[]
    for current_pdfs in Iterators.partition(pdfs, max_files)
        new_tmp = mktempdir(tmp)
        out_path = joinpath(new_tmp, "out.pdf")
        recursive_unite_pdfs!(unite_prog, all_logs, new_tmp, current_pdfs, out_path;
                              max_files)
        push!(partially_united_pdfs, out_path)
    end
    recursive_unite_pdfs!(unite_prog, all_logs, tmp, partially_united_pdfs, output_path;
                          max_files)
    return nothing
end

#####
##### Apply steps 1 -- 3
#####

"""
    ocr(pdf, output_path=string(splitext(pdf)[1], "_OCR", ".pdf"); apply_unpaper=false,
             ntasks=Sys.CPU_THREADS - 1, tesseract_nthreads=1, pages=num_pages(pdf),
             cleanup_after=true, tmp=get_scratch_dir(pdf), show_progress=true)

Reads in a PDF located at `pdf`, uses Tesseract to OCR each page and combines the results into a pdf located `output_path`.

Keyword arguments:

* `ntasks`: how many parallel tasks to use for launching `tesseract` and `pdftoppm`.
* `tesseract_nthreads`: how many threads to direct Tesseract to use
* `apply_unpaper`: whether or not to apply `unpaper` to try to improve the image quality
* `tmp`: a directory to store intermediate files. This directory is deleted at the end of the script if `cleanup_after` is set to `true`.
* `pages`: the number of pages of the PDF to process. It can help in debugging to set this to something small.
* `show_progress`: show a progress bar for each step of the process.

Set `ENV["JULIA_DEBUG"] = SearchablePDFs` to see (many) debug messages.
"""
function ocr(pdf, output_path=string(splitext(pdf)[1], "_OCR", ".pdf"); apply_unpaper=false,
             ntasks=Sys.CPU_THREADS - 1, tesseract_nthreads=1, pages=num_pages(pdf),
             cleanup_after=true, tmp=get_scratch_dir(pdf), show_progress=true)
    isfile(pdf) || throw(ArgumentError("File not found at $pdf"))
    ext = splitexp(pdf)[2]
    ext == "pdf" || throw(ArgumentError("Expected file extension `pdf`; got $ext"))

    # 1k page limit due to `pdftoppm` numbering by 001, 002, etc.
    # should be workaround-able...
    pages < 1000 || throw(ArgumentError("PDF must have less than 1000 pages"))

    mkpath(tmp)

    @debug "Found file" pdf pages tmp

    all_logs = @NamedTuple{page::Union{Int,UnitRange{Int},Missing},binary::String,
                           stdout::String,stderr::String,code::Int}[]
    sizehint!(all_logs, pages + 2)

    @debug "Generating images..."
    img_paths = String[]
    imag_prog = Progress(pages; desc="(1/3) Extracting images: ", disable=!show_progress)
    # we don't need the results so this could be an `async_foreach` if that existed;
    # the `ntasks` load balancing is nice though, so let's just reuse this.
    asyncmap(Iterators.partition(1:pages, 20); ntasks) do current_pages
        paths, pdftoppm_logs = get_images(pdf, page_range, tmp)
        append!(img_paths, paths)
        push!(all_logs, (; page=current_pages, pdftoppm_logs...))
        next!(imag_prog; step=length(current_pages))
        return nothing
    end

    @debug "Finished generating images. Starting tesseracting..."
    ocr_prog = Progress(pages; desc="(2/3) OCRing: ", disable=!show_progress)
    pdfs = asyncmap(enumerate(img_paths); ntasks) do (page, img)
        @debug "img" page img
        if apply_unpaper
            img, unpaper_logs = unpaper(img)
            push!(all_logs, (; page, unpaper_logs...))
        end
        pdf, tesseract_logs = make_pdf(img; tesseract_nthreads)
        push!(all_logs, (; page, tesseract_logs...))
        next!(ocr_prog)
        return pdf
    end
    @debug "Finished processing pages. Uniting..."
    unite_dir = joinpath(tmp, "unite")
    mkpath(unite_dir)
    max_files = 100
    unite_prog = Progress(pages + cld(pages, max_files) + 1;
                          desc="(3/3) Collecting pages: ", disable=!show_progress)
    recursive_unite_pdfs!(unite_prog, all_logs, unite_dir, pdfs, output_path; max_files)
    @debug "Done uniting pdfs"
    if cleanup_after
        @debug "Cleaning up"
        rm(tmp; recursive=true, force=true)
    end
    @debug "Done"
    return (; output_path, logs=all_logs)
end

end # module
