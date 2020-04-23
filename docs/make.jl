using PDFSandwich
using Documenter

makedocs(;
    modules=[PDFSandwich],
    authors="Eric P. Hanson",
    repo="https://github.com/Eric P. Hanson/PDFSandwich.jl/blob/{commit}{path}#L{line}",
    sitename="PDFSandwich.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)
