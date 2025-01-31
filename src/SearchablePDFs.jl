module SearchablePDFs

using Pkg
using Pkg.Artifacts
using Random
using OutputCollectors

using ProgressMeter
using Scratch
using CSV
using DocOpt

using Poppler_jll
using Tesseract_jll

export ocr

#####
##### Utilities
#####

function argument_error(msg; exit_on_error)
    if exit_on_error
        printstyled("ERROR:"; bold=true, color=:red)
        printstyled(" ", msg, "\n"; color=:red)
        exit(1)
    else
        throw(ArgumentError(msg))
    end
end

struct CommandError <: Exception
    msg::String
end

function command_error(msg; exit_on_error)
    if exit_on_error
        printstyled("ERROR:"; bold=true, color=:red)
        printstyled(" ", msg, "\n"; color=:red)
        exit(1)
    else
        throw(CommandError(msg))
    end
end

function require_extension(path, ext; exit_on_error)
    _ext = splitext(path)[2]
    _ext == ext ||
        argument_error("Expected $path to have file extension `$ext`; got `$(_ext)`";
                       exit_on_error)
    return nothing
end

function require_no_file(path; exit_on_error)
    isfile(path) && argument_error("File already exists at `$(path)`!"; exit_on_error)
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
function run_and_collect_logs(cmd::Cmd; exit_on_error)
    oc = OutputCollector(cmd)
    succeeded = wait(oc)
    code = oc.P.exitcode
    str = merge(oc)
    if !succeeded
        command_error("""Command failed with exitcode $code

        $str"""; exit_on_error)
    end
    return (output=str, code)
end

# There's gotta be a better way...
function _num_pages(pdf)
    result = read(`$(Poppler_jll.pdfinfo()) $pdf`, String)
    m = match(r"Pages\:\s*([0-9]*)", result)
    return parse(Int, m.captures[1])
end

function num_pages(pdf; exit_on_error)
    try
        _num_pages(pdf)
    catch e
        command_error("""
        Could not extract the number of pages from $(pdf).

        $(sprint(Base.showerror, e))"""; exit_on_error)
    end
end

#####
##### Step 1: Extract images
#####

# Use Poppler to extract the image
function get_images(pdf, page_range::UnitRange{Int}, tmp, total_pages; exit_on_error)
    logs = run_and_collect_logs(`$(Poppler_jll.pdftoppm()) -f $(first(page_range)) -l $(last(page_range)) $pdf -tiff -forcenum $(tmp)/page`;
                                exit_on_error)
    @debug "`pdftoppm`" logs
    paths = [joinpath(tmp, string("page-", lpad(page, ndigits(total_pages), '0'), ".tif"))
             for page in page_range]
    return paths, (; binary="pdftoppm", logs...)
end

#####
##### Step 2: Use tesseract to generate a one-page searchable PDF from an image
#####

function make_pdf(img; tesseract_nthreads, exit_on_error)
    data_path = get_data_path() * "/"
    img_base, img_ext = splitext(img)
    output = img_base
    tesseract = addenv(Tesseract_jll.tesseract(), "OMP_THREAD_LIMIT" => tesseract_nthreads)
    cmd = `$tesseract -l eng+equ --tessdata-dir $data_path $img $output -c tessedit_create_pdf=1`
    @debug "Tesseracting!" img
    logs = run_and_collect_logs(cmd; exit_on_error)
    @debug logs
    return (; pdf=output * ".pdf", logs=(; binary="tesseract", logs...))
end

#####
##### Step 3: collect all the PDFs into one with `pdfunite`
#####

function unite_pdfs(pdfs, output; exit_on_error)
    logs = run_and_collect_logs(`$(Poppler_jll.pdfunite()) $pdfs $output`; exit_on_error)
    return (; binary="pdfunite", logs...)
end

# unites all the pdfs in `pdfs`, `max_files` at a time.
# I ran into "too many open files" errors otherwise
# (which seems weird... maybe <https://github.com/JuliaLang/julia/issues/31126>? It was on MacOS)
function unite_many_pdfs!(unite_progress_meter, all_logs, tmp, pdfs, output_path;
                          max_files_per_unite=100, exit_on_error)
    isdir(tmp) || mkdir(tmp)

    output_paths = map(enumerate(Iterators.partition(pdfs, max_files_per_unite))) do (i,
                                                                                      current_pdfs)
        current_output_path = joinpath(tmp, string("section_", i, ".pdf"))
        unite_logs = unite_pdfs(current_pdfs, current_output_path; exit_on_error)
        put!(all_logs, (; page=missing, unite_logs...))
        next!(unite_progress_meter; step=length(current_pdfs))
        return current_output_path
    end

    unite_logs = unite_pdfs(output_paths, output_path; exit_on_error)
    put!(all_logs, (; page=missing, unite_logs...))

    next!(unite_progress_meter; step=length(output_paths))
    return nothing
end

#####
##### Apply steps 1 -- 3
#####

"""
    ocr(pdf, output_path=string(splitext(pdf)[1], "_OCR", ".pdf");
             ntasks=Sys.CPU_THREADS - 1, tesseract_nthreads=1, pages=num_pages(pdf),
             cleanup_after=true, cleanup_at_exit=true, tmp=get_scratch_dir(pdf),
             verbose=true)

Reads in a PDF located at `pdf`, uses Tesseract to OCR each page and combines the results into a pdf located `output_path`.

Keyword arguments:

* `ntasks`: how many parallel tasks to use for launching `tesseract` and `pdftoppm`.
* `tesseract_nthreads`: how many threads to direct Tesseract to use
* `tmp`: a directory to store intermediate files. This directory is deleted at the end of the function if `cleanup_after` is set to `true`, and when the Julia session is ended if `cleanup_at_exit` is set to `true`.
* `pages=nothing`: the number of pages of the PDF to process; the default of `nothing` indicates all pages in the PDF. It can help in debugging to set this to something small.
* `verbose`: show a progress bar for each step of the process.

Set `ENV["JULIA_DEBUG"] = SearchablePDFs` to see (many) debug messages.
"""
function ocr(pdf, output_path=string(splitext(pdf)[1], "_OCR", ".pdf");
             ntasks=Sys.CPU_THREADS - 1, tesseract_nthreads=1, pages=nothing,
             cleanup_after=true, cleanup_at_exit=true, tmp=get_scratch_dir(pdf),
             verbose=true, force=false, max_files_per_unite=100,
             exit_on_error=false)
    isfile(pdf) || argument_error("Input file not found at `$pdf`"; exit_on_error)
    force || require_no_file(output_path; exit_on_error)
    require_extension(pdf, ".pdf"; exit_on_error)
    require_extension(output_path, ".pdf"; exit_on_error)

    total_pages = num_pages(pdf; exit_on_error)
    if pages === nothing
        pages = total_pages
    elseif pages > total_pages
        argument_error("`pages` must be less than the total number of pages ($(total_pages))";
                       exit_on_error)
    end

    mkpath(tmp)
    if cleanup_at_exit
        atexit(() -> rm(tmp; force=true, recursive=true))
    end

    @debug "Found file" pdf pages tmp

    all_logs = Channel{@NamedTuple{page::Union{Int,UnitRange{Int},Missing},binary::String,
                                   output::String,code::Int}}(Inf)

    @debug "Generating images..."
    imag_prog = Progress(pages; desc="(1/3) Extracting images: ", enabled=verbose)

    img_paths_grps = asyncmap(Iterators.partition(1:pages, 20); ntasks) do page_range
        paths, pdftoppm_logs = get_images(pdf, page_range, tmp, total_pages; exit_on_error)
        put!(all_logs, (; page=page_range, pdftoppm_logs...))
        next!(imag_prog; step=length(page_range))
        return paths
    end

    img_paths = reduce(vcat, img_paths_grps)

    @debug "Finished generating images. Starting tesseracting..."
    ocr_prog = Progress(pages; desc="(2/3) OCRing: ", enabled=verbose)
    pdfs = asyncmap(enumerate(img_paths); ntasks) do (page, img)
        @debug "img" page img
        pdf, tesseract_logs = make_pdf(img; tesseract_nthreads, exit_on_error)
        put!(all_logs, (; page, tesseract_logs...))
        next!(ocr_prog)
        return pdf
    end
    @debug "Finished processing pages. Uniting..."
    unite_dir = joinpath(tmp, "unite")
    unite_progress_meter = Progress(pages + cld(pages, max_files_per_unite) + 1;
                                    desc="(3/3) Collecting pages: ", enabled=verbose)
    unite_many_pdfs!(unite_progress_meter, all_logs, unite_dir, pdfs, output_path;
                     max_files_per_unite, exit_on_error)
    @debug "Done uniting pdfs"
    if cleanup_after
        @debug "Cleaning up"
        rm(tmp; recursive=true, force=true)
    end
    @debug "Done"
    if verbose
        isfile(output_path) || @error "File was not generated, check the logs!"
    end
    close(all_logs)
    return (; output_path, logs=collect(all_logs), tmp)
end

#####
##### CLI interface
#####

doc::String = """Searchable PDFs (OCR).

Usage:
  searchable-pdf <input_pdf> [<output_path>] [--keep_intermediates] [--quiet] [--force] [--logfile=<logfile>] [--tmp=<tmp>] [-n=<ntasks>] [-t=<tesseract_nthreads>]
  searchable-pdf -h | --help
  searchable-pdf --version

Options:
  -h --help        Show this screen.
  --version        Show version.
  --keep_intermediates  xyz
  --quiet           todo
  --force           todo
  --logfile=<logfile>    todo
  --tmp=<tmp>             todo
  -n <ntasks>, --ntasks=<ntasks>  todo
  -t <tesseract_nthreads>, --tesseract_nthreads=<tesseract_nthreads>  todo [default: 1]

"""

@doc doc
function main(args=ARGS)
    parsed = docopt(doc, args; version=pkgversion(SearchablePDFs))
    input_pdf = parsed["<input_pdf>"]
    output_path = something(get(parsed, "<output_path>", nothing),
                            string(splitext(input_pdf)[1], "_OCR", ".pdf"))

    if parsed["--ntasks"] === nothing
        ntasks = Sys.CPU_THREADS - 1
    else
        ntasks = parse(Int, parsed["--ntasks"])
    end

    tesseract_nthreads = parse(Int, parsed["--tesseract_nthreads"])
    result = _main(input_pdf, output_path;
                   ntasks,
                   tesseract_nthreads,
                   keep_intermediates=parsed["--keep_intermediates"],
                   tmp=something(parsed["--tmp"], get_scratch_dir(input_pdf)),
                   quiet=parsed["--quiet"],
                   force=parsed["--force"],
                   logfile=parsed["--logfile"],
                   exit_on_error=true)

    all_success = all(==(0), (l.code for l in result.logs))
    all_success && isfile(output_path) && return 0
    printstyled(stdout, "ERROR: Some step(s) did not complete successfully. Printing logs.")
    for (idx, log) in enumerate(result.logs)
        page::Union{Int,UnitRange{Int},Missing}, binary::String,
        output::String, code::Int
        (; page, binary, output, code) = log
        println("Step $idx. For binary $binary, page $page finished with exit code $code, and output:\n$output\n")
    end
    return 1
end

function _main(input_pdf::String,
               output_path::String=string(splitext(input_pdf)[1], "_OCR",
                                          ".pdf");
               ntasks::Int=Sys.CPU_THREADS - 1, tesseract_nthreads::Int=1,
               keep_intermediates::Bool=false,
               tmp::String=get_scratch_dir(input_pdf), quiet::Bool=false,
               logfile::Union{Nothing,String}=nothing, force::Bool=false,
               exit_on_error=false)
    # some of these are redundant with checks inside `ocr`; that's because we want to do them before the "Starting to ocr" message,
    # and we want them to exit if they fail in a non-interactive context, instead of printing a stacktracee.
    isfile(input_pdf) ||
        argument_error("Input file not found at `$(input_pdf)`"; exit_on_error)
    force || require_no_file(output_path; exit_on_error)
    require_extension(input_pdf, ".pdf"; exit_on_error)
    require_extension(output_path, ".pdf"; exit_on_error)
    if logfile !== nothing
        force || require_no_file(logfile; exit_on_error)
        require_extension(logfile, ".csv"; exit_on_error)
    end
    verbose = !quiet
    verbose &&
        println("Starting to ocr `$(input_pdf)`; result will be located at `$(output_path)`.")
    result = ocr(input_pdf, output_path; ntasks, tesseract_nthreads,
                 cleanup_after=!keep_intermediates, cleanup_at_exit=!keep_intermediates,
                 tmp, verbose, force, exit_on_error)
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

@static if isdefined(Base, Symbol("@main"))
    @main
end

precompile(main, (Vector{String},))

end # module
