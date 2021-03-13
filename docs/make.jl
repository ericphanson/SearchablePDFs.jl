using SearchablePDFs
using Documenter

makedocs(; modules=[SearchablePDFs], authors="Eric P. Hanson",
         repo="https://github.com/ericphanson/SearchablePDFs.jl/blob/{commit}{path}#L{line}",
         sitename="SearchablePDFs.jl",
         format=Documenter.HTML(; prettyurls=get(ENV, "CI", "false") == "true",
                                assets=String[]), pages=["Home" => "index.md"])
