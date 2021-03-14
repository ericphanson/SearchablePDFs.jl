module SearchablePDFs

using Pkg
using Pkg.Artifacts
using Random

using ProgressMeter
using Scratch
using CSV
using Comonicon

using Poppler_jll
using unpaper_jll
using Tesseract_jll

export ocr

#####
##### Utilities
#####

function argument_error(msg; exception=isinteractive())
    if exception
        throw(ArgumentError(msg))
    else
        printstyled("ERROR:"; bold=true, color=:red)
        printstyled(" ", msg, "\n"; color=:red)
        exit(1)
    end
end

function require_extension(path, ext; exception=isinteractive())
    _ext = splitext(path)[2]
    _ext == ext ||
        argument_error("Expected $path to have file extension `$ext`; got `$(_ext)`";
                       exception)
    return nothing
end

function require_no_file(path; exception=isinteractive())
    isfile(path) && argument_error("File already exists at `$(path)`!"; exception)
    return nothing
end

# For now we will hardcode this choice of training data
function get_data_path()
    return artifact"tessdata_fast"
end

# a place to store intermediate files; we could use temporary directories,
# but I've occasionally run into permissions issues there
# so I'd prefer to use a more local location. This also means that we are
# more in charge of the cleanup, which can be good for debugging.
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
    result = Poppler_jll.pdfinfo() do pdfinfo
        return read(`$pdfinfo $pdf`, String)
    end
    m = match(r"Pages\:\s*([1-9]*)", result)
    return parse(Int, m.captures[1])
end

#####
##### Step 1: Extract images
#####

# Use Poppler to extract the image
function get_images(pdf, page_range::UnitRange{Int}, tmp, total_pages)
    local logs
    Poppler_jll.pdftoppm() do pdftoppm
        return logs = run_and_collect_logs(`$pdftoppm -f $(first(page_range)) -l $(last(page_range)) $pdf -tiff -forcenum $(tmp)/page`)
    end
    @debug "`pdftoppm`" logs
    paths = [joinpath(tmp, string("page-", lpad(page, ndigits(total_pages), '0'), ".tif"))
             for page in page_range]
    return paths, (; binary="pdftoppm", logs...)
end

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
function recursive_unite_pdfs!(unite_prog, all_logs, tmp, pdfs, output_path; max_files_per_unite=100)
    if length(pdfs) <= max_files_per_unite
        unite_logs = unite_pdfs(pdfs, output_path)
        push!(all_logs, (; page=missing, unite_logs...))
        next!(unite_prog; step=length(pdfs))
        return nothing
    end
    # we have many pdfs; make sure `tmp` is an actual directory so we can use it
    # to save intermediate files.
    mkpath(tmp)
    partially_united_pdfs = String[]
    for current_pdfs in Iterators.partition(pdfs, max_files_per_unite)
        new_tmp = mktempdir(tmp)
        out_path = joinpath(new_tmp, "out.pdf")
        recursive_unite_pdfs!(unite_prog, all_logs, new_tmp, current_pdfs, out_path;
                              max_files_per_unite)
        push!(partially_united_pdfs, out_path)
    end
    recursive_unite_pdfs!(unite_prog, all_logs, tmp, partially_united_pdfs, output_path;
                          max_files_per_unite)
    return nothing
end

#####
##### Apply steps 1 -- 3
#####

"""
    ocr(pdf, output_path=string(splitext(pdf)[1], "_OCR", ".pdf"); apply_unpaper=false,
             ntasks=Sys.CPU_THREADS - 1, tesseract_nthreads=1, pages=num_pages(pdf),
             cleanup_after=true, cleanup_at_exit=true, tmp=get_scratch_dir(pdf),
             verbose=true)
             
Reads in a PDF located at `pdf`, uses Tesseract to OCR each page and combines the results into a pdf located `output_path`.

Keyword arguments:

* `ntasks`: how many parallel tasks to use for launching `tesseract` and `pdftoppm`.
* `tesseract_nthreads`: how many threads to direct Tesseract to use
* `apply_unpaper`: whether or not to apply `unpaper` to try to improve the image quality
* `tmp`: a directory to store intermediate files. This directory is deleted at the end of the function if `cleanup_after` is set to `true`, and when the Julia session is ended if `cleanup_at_exit` is set to `true`.
* `pages=nothing`: the number of pages of the PDF to process; the default of `nothing` indicates all pages in the PDF. It can help in debugging to set this to something small.
* `verbose`: show a progress bar for each step of the process.

Set `ENV["JULIA_DEBUG"] = SearchablePDFs` to see (many) debug messages.
"""
function ocr(pdf, output_path=string(splitext(pdf)[1], "_OCR", ".pdf"); apply_unpaper=false,
             ntasks=Sys.CPU_THREADS - 1, tesseract_nthreads=1, pages=nothing,
             cleanup_after=true, cleanup_at_exit=true, tmp=get_scratch_dir(pdf),
             verbose=true, force=false, max_files_per_unite = 100)
    isfile(pdf) || argument_error("Input file not found at `$pdf`"; exception=true)
    force || require_no_file(output_path; exception=true)
    require_extension(pdf, ".pdf"; exception=true)
    require_extension(output_path, ".pdf"; exception=true)

    total_pages = num_pages(pdf)

    if pages === nothing
        pages = total_pages
    elseif pages > total_pages
        argument_error("`pages` must be less than the total number of pages ($(total_pages))";
                       exception=true)
    end

    mkpath(tmp)
    if cleanup_at_exit
        atexit(() -> rm(tmp; force=true, recursive=true))
    end

    @debug "Found file" pdf pages tmp

    all_logs = @NamedTuple{page::Union{Int,UnitRange{Int},Missing},binary::String,
                           stdout::String,stderr::String,code::Int}[]
    sizehint!(all_logs, pages + 2)

    @debug "Generating images..."
    img_paths = String[]
    imag_prog = Progress(pages; desc="(1/3) Extracting images: ", enabled=verbose)
    # we don't need the results so this could be an `async_foreach` if that existed;
    # the `ntasks` load balancing is nice though, so let's just reuse this.
    asyncmap(Iterators.partition(1:pages, 20); ntasks) do page_range
        paths, pdftoppm_logs = get_images(pdf, page_range, tmp, total_pages)
        append!(img_paths, paths)
        push!(all_logs, (; page=page_range, pdftoppm_logs...))
        next!(imag_prog; step=length(page_range))
        return nothing
    end

    @debug "Finished generating images. Starting tesseracting..."
    ocr_prog = Progress(pages; desc="(2/3) OCRing: ", enabled=verbose)
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
    unite_prog = Progress(pages + cld(pages, max_files_per_unite) + 1;
                          desc="(3/3) Collecting pages: ", enabled=verbose)
    recursive_unite_pdfs!(unite_prog, all_logs, unite_dir, pdfs, output_path; max_files_per_unite)
    @debug "Done uniting pdfs"
    if cleanup_after
        @debug "Cleaning up"
        rm(tmp; recursive=true, force=true)
    end
    @debug "Done"
    if verbose
        isfile(output_path) || @error "File was not generated, check the logs!"
    end
    return (; output_path, logs=all_logs, tmp)
end

#####
##### CLI interface
#####

"""
Create a searchable version of a PDF.
"""
@main function searchable(input_pdf::String,
                          output_path::String=string(splitext(input_pdf)[1], "_OCR",
                                                     ".pdf"); apply_unpaper::Bool=false,
                          ntasks::Int=Sys.CPU_THREADS - 1, tesseract_nthreads::Int=1,
                          keep_intermediates::Bool=false,
                          tmp::String=get_scratch_dir(input_pdf), quiet::Bool=false,
                          logfile::Union{Nothing,String}=nothing, force::Bool=false)
    # some of these are redundant with checks inside `ocr`; that's because we want to do them before the "Starting to ocr" message,
    # and we want them to exit if they fail in a non-interactive context, instead of printing a stacktracee.
    isfile(input_pdf) || argument_error("Input file not found at `$(input_pdf)`")
    force || require_no_file(output_path)
    require_extension(input_pdf, ".pdf")
    require_extension(output_path, ".pdf")
    if logfile !== nothing
        force || require_no_file(logfile)
        require_extension(logfile, ".csv")
    end
    verbose = !quiet
    verbose &&
        println("Starting to ocr `$(input_pdf)`; result will be located at `$(output_path)`.")
    result = ocr(input_pdf, output_path; apply_unpaper, ntasks, tesseract_nthreads,
                 cleanup_after=!keep_intermediates, cleanup_at_exit=!keep_intermediates,
                 tmp, verbose)
    verbose && println("\nOutput is located at `$(output_path)`.")
    if keep_intermediates && verbose
        println("Intermediate files located at `$tmp`.")
    end
    if logfile !== nothing
        verbose && println("Writing logs...")
        CSV.write(logfile, result.logs)
        verbose && println("Logs written to `$(logfile)`.")
    end

    return result
end

end # module
